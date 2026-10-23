//! Resolve read identity from the current process. Never adopt saved identity.
use crate::ia::types::Session;
use crate::tools::wechat_db::{find_wechat_pid, get_db_path, list_account_dbs};
use crate::tools::wechat_keys::{extract_keys_async, get_stored_keys, store_keys, verify_key};
use axum::{http::StatusCode, Json};
use std::collections::{BTreeSet, HashMap};
use std::path::Path;

pub type ActiveReadError = (StatusCode, Json<serde_json::Value>);
pub fn active_error(code: &'static str) -> ActiveReadError {
    (StatusCode::CONFLICT, Json(serde_json::json!({"error": code})))
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ActiveAccount {
    pub pid: i64,
    pub account_dir: String,
    started_at: String,
}

fn account_from_targets(targets: impl Iterator<Item = String>) -> Result<String, &'static str> {
    let mut accounts = BTreeSet::new();
    for target in targets {
        if !target.contains("/db_storage/") || !target.ends_with(".db") { continue; }
        if let Some((_, rest)) = target.split_once("/xwechat_files/") {
            let account = rest.split('/').next().unwrap_or("");
            if account.is_empty() || account == "." || account == ".."
                || account.chars().any(|c| c.is_control() || c == '\\') {
                return Err("active_account_invalid");
            }
            accounts.insert(account.to_string());
        }
    }
    match accounts.len() {
        0 => Err("active_account_unknown"),
        1 => Ok(accounts.into_iter().next().unwrap()),
        _ => Err("active_account_ambiguous"),
    }
}

fn start_time(process: &Path) -> Result<String, &'static str> {
    let stat = std::fs::read_to_string(process.join("stat"))
        .map_err(|_| "active_process_unreadable")?;
    stat.rsplit_once(')').and_then(|(_, fields)| fields.split_whitespace().nth(19))
        .map(String::from).ok_or("active_process_unreadable")
}

fn observe_process(root: &Path, pid: i64, display: &str, user: &str) -> Result<ActiveAccount, &'static str> {
    if pid <= 0 { return Err("active_process_unknown"); }
    let process = root.join(pid.to_string());
    let started_at = start_time(&process)?;
    let exe = std::fs::read_link(process.join("exe")).map_err(|_| "active_process_unreadable")?;
    if exe.file_name().and_then(|s| s.to_str()).map(|s| s.eq_ignore_ascii_case("wechat")) != Some(true) {
        return Err("active_process_unverified");
    }
    let environment = std::fs::read(process.join("environ")).map_err(|_| "active_process_unreadable")?;
    let expected_display = format!("DISPLAY={display}");
    let expected_home = format!("HOME=/home/{user}");
    if !environment.split(|b| *b == 0).any(|part| part == expected_display.as_bytes())
        || !environment.split(|b| *b == 0).any(|part| part == expected_home.as_bytes()) {
        return Err("active_process_session_mismatch");
    }
    let entries = std::fs::read_dir(process.join("fd")).map_err(|_| "active_account_unreadable")?;
    let mut targets = Vec::new();
    for entry in entries {
        let entry = entry.map_err(|_| "active_account_unreadable")?;
        match std::fs::read_link(entry.path()) {
            Ok(target) => targets.push(target.to_string_lossy().into_owned()),
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {},
            Err(_) => return Err("active_account_unreadable"),
        }
    }
    let account_dir = account_from_targets(targets.into_iter())?;
    if start_time(&process)? != started_at { return Err("active_process_changed"); }
    Ok(ActiveAccount { pid, account_dir, started_at })
}

pub fn resolve_active_account(session: &Session) -> Result<ActiveAccount, &'static str> {
    let pid = find_wechat_pid().ok_or("active_process_unknown")?;
    observe_process(Path::new("/proc"), pid, &session.display, &session.linux_user)
}

fn unchanged(expected: &ActiveAccount, observed: &ActiveAccount) -> Result<(), &'static str> {
    if expected == observed { Ok(()) } else { Err("active_account_changed_during_read") }
}

pub fn ensure_active_account(session: &Session, expected: &ActiveAccount) -> Result<(), &'static str> {
    unchanged(expected, &resolve_active_account(session)?)
}

#[derive(Clone, Copy)]
pub enum ReadKind { Contacts, Chats, Messages }

/// Keys remain partitioned by session + account. Session identity and cursors are never written.
pub async fn active_read_keys(session: &Session, kind: ReadKind)
    -> Result<(ActiveAccount, HashMap<String, String>), ActiveReadError> {
    let active = resolve_active_account(session).map_err(active_error)?;
    let mut keys = { let db = crate::db::get_db(); get_stored_keys(&db, &session.id, &active.account_dir) };
    let available = list_account_dbs(&active.account_dir);
    let required: Vec<String> = match kind {
        ReadKind::Contacts => vec!["contact.db".into()],
        ReadKind::Chats => vec!["contact.db".into(), "session.db".into()],
        ReadKind::Messages => available.iter().filter(|name| name.starts_with("message_")
            && name.ends_with(".db") && !name.contains("fts") && !name.contains("resource")).cloned().collect(),
    };
    if required.is_empty() || required.iter().any(|name| !available.contains(name)) {
        return Err(active_error("active_account_databases_unavailable"));
    }
    if required.iter().any(|name| !keys.contains_key(name)) {
        let extracted = extract_keys_async(active.pid).await;
        ensure_active_account(session, &active).map_err(active_error)?;
        // Verify against this account's actual DB; ignore the extractor's account label.
        let verified: HashMap<String, String> = extracted.into_iter()
            .filter(|(name, key)| available.contains(name) && !keys.contains_key(name)
                && verify_key(&get_db_path(&active.account_dir, name), key)).collect();
        ensure_active_account(session, &active).map_err(active_error)?;
        { let db = crate::db::get_db(); store_keys(&db, &session.id, &active.account_dir, &verified); }
        keys.extend(verified);
    }
    if required.iter().any(|name| !keys.contains_key(name)) {
        return Err(active_error("active_account_keys_unavailable"));
    }
    ensure_active_account(session, &active).map_err(active_error)?;
    Ok((active, keys))
}

#[cfg(test)]
mod active_account_tests {
    use super::*;
    use rusqlite::Connection;
    fn target(account: &str) -> String {
        format!("/home/wechat/xwechat_files/{account}/db_storage/session/session.db")
    }
    #[test]
    fn active_account_uses_current_fd_instead_of_saved_identity() {
        let stored = "synthetic-old";
        let actual = account_from_targets(vec![target("synthetic-new")].into_iter()).unwrap();
        assert_eq!(actual, "synthetic-new");
        assert_ne!(actual, stored);
    }
    #[test]
    fn active_account_missing_and_ambiguous_fail_closed() {
        assert_eq!(account_from_targets(Vec::new().into_iter()), Err("active_account_unknown"));
        assert_eq!(account_from_targets(vec![target("a"), target("b")].into_iter()), Err("active_account_ambiguous"));
        assert_eq!(account_from_targets(vec![target("a"), target("a")].into_iter()).unwrap(), "a");
    }
    #[test]
    fn active_account_pid_account_and_process_start_changes_are_rejected() {
        let expected = ActiveAccount { pid: 12, account_dir: "new".into(), started_at: "100".into() };
        assert!(unchanged(&expected, &expected).is_ok());
        for observed in [ActiveAccount { pid: 13, ..expected.clone() },
            ActiveAccount { account_dir: "other".into(), ..expected.clone() },
            ActiveAccount { started_at: "101".into(), ..expected.clone() }] {
            assert_eq!(unchanged(&expected, &observed), Err("active_account_changed_during_read"));
        }
    }
    #[test]
    fn active_account_new_keys_preserve_old_identity_keys_and_checkpoint() {
        let db = Connection::open_in_memory().unwrap();
        db.execute_batch("CREATE TABLE sessions(id TEXT,logged_in_user TEXT);INSERT INTO sessions VALUES('s','synthetic-old');
            CREATE TABLE wechat_keys(id TEXT,session_id TEXT,account_dir TEXT,db_name TEXT,hex_key TEXT,verified_at TEXT,UNIQUE(session_id,account_dir,db_name));
            CREATE TABLE sync_state(session_id TEXT,key TEXT,value TEXT);INSERT INTO sync_state VALUES('s','checkpoint','old-position');").unwrap();
        store_keys(&db, "s", "synthetic-old", &HashMap::from([("contact.db".into(), "old-key".into())]));
        store_keys(&db, "s", "synthetic-new", &HashMap::from([("contact.db".into(), "new-key".into())]));
        assert_eq!(get_stored_keys(&db, "s", "synthetic-old")["contact.db"], "old-key");
        assert_eq!(get_stored_keys(&db, "s", "synthetic-new")["contact.db"], "new-key");
        assert_eq!(db.query_row("SELECT logged_in_user FROM sessions", [], |row| row.get::<_, String>(0)).unwrap(), "synthetic-old");
        assert_eq!(db.query_row("SELECT value FROM sync_state", [], |row| row.get::<_, String>(0)).unwrap(), "old-position");
    }
    #[test]
    #[cfg(unix)]
    fn active_account_real_proc_shape_checks_session_and_all_fd_targets() {
        let root = tempfile::tempdir().unwrap();
        let process = root.path().join("12");
        std::fs::create_dir_all(process.join("fd")).unwrap();
        let fields = (3..=22).map(|n| if n == 22 { "100" } else { "0" }).collect::<Vec<_>>().join(" ");
        std::fs::write(process.join("stat"), format!("12 (wechat) {fields}")).unwrap();
        std::fs::write(process.join("environ"), b"DISPLAY=:99\0HOME=/home/wechat\0").unwrap();
        std::os::unix::fs::symlink("/usr/bin/wechat", process.join("exe")).unwrap();
        std::os::unix::fs::symlink(target("synthetic-new"), process.join("fd/1")).unwrap();
        let active = observe_process(root.path(), 12, ":99", "wechat").unwrap();
        assert_eq!(active.account_dir, "synthetic-new");
        assert_eq!(observe_process(root.path(), 12, ":100", "wechat"), Err("active_process_session_mismatch"));
        std::os::unix::fs::symlink(target("synthetic-other"), process.join("fd/2")).unwrap();
        assert_eq!(observe_process(root.path(), 12, ":99", "wechat"), Err("active_account_ambiguous"));
    }
}

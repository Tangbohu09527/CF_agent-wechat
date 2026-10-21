//! Preserve-only login contract. No runtime cleanup, logout or account switch.
use std::collections::BTreeSet;
use rusqlite::{params, Connection};

pub const CONTRACT: &str = "expected-account-v1";
pub fn capabilities() -> serde_json::Value {
    serde_json::json!({"contract":CONTRACT,"required":true,"preservesSessionOnMismatch":true})
}
pub fn validate_input(expected: Option<&str>, new_account: bool) -> Result<&str, &'static str> {
    if new_account { return Err("preserve_account_rejects_new_account"); }
    let expected=expected.filter(|s|!s.is_empty()).ok_or("expected_account_required")?;
    if expected.len()>256 || expected.chars().any(|c|c.is_control()||c.is_whitespace()||c=='/'||c=='\\') { return Err("expected_account_invalid"); }
    Ok(expected)
}
pub fn validate_stored(expected: &str, stored: Option<&str>) -> Result<(), &'static str> {
    validate_input(Some(expected),false)?;
    match stored { Some(value) if value==expected=>Ok(()),Some(_)=>Err("expected_account_mismatch"),None=>Err("stored_account_unknown") }
}
pub fn validate_observed(conn: &Connection, session: &str, expected: &str, observed: Option<&str>) -> Result<(), &'static str> {
    let stored=crate::db::queries::get_session_logged_in_user(conn,session);
    validate_stored(expected,stored.as_deref())?;
    match observed { Some(value) if value==expected=>Ok(()),Some(_)=>Err("observed_account_mismatch"),None=>Err("observed_account_unknown") }
}
/// Caller holds the shared database lock. Identity is never replaced.
pub fn commit_verified_session(conn: &Connection, session: &str, expected: &str, observed: &str, pid: i64) -> Result<(), &'static str> {
    validate_observed(conn,session,expected,Some(observed))?;
    let count=conn.execute("UPDATE sessions SET wechat_pid=?1,login_state='logged_in',updated_at=?2 WHERE id=?3 AND logged_in_user=?4",params![pid,chrono::Utc::now().to_rfc3339(),session,expected]).map_err(|_|"account_state_write_failed")?;
    if count!=1 { return Err("stored_account_changed"); } Ok(())
}
/// Upstream picks the first fd. Preserve-only login rejects multiple identities.
pub fn account_from_targets(targets: impl Iterator<Item=String>) -> Result<Option<String>, &'static str> {
    let mut accounts=BTreeSet::new();
    for target in targets {
        if target.contains("db_storage")&&target.ends_with(".db") {
            if let Some((_,rest))=target.split_once("xwechat_files/") {
                if let Some(account)=rest.split('/').next().filter(|s|!s.is_empty()) { accounts.insert(account.to_string()); }
            }
        }
    }
    if accounts.len()>1 { return Err("observed_account_ambiguous"); } Ok(accounts.into_iter().next())
}
pub fn observe_account(pid: i64) -> Result<Option<String>, &'static str> {
    let entries=std::fs::read_dir(format!("/proc/{pid}/fd")).map_err(|_|"observed_account_unreadable")?;
    let mut targets=Vec::new();
    for entry in entries {
        let entry=entry.map_err(|_|"observed_account_unreadable")?;
        let target=std::fs::read_link(entry.path()).map_err(|_|"observed_account_unreadable")?;
        targets.push(target.to_string_lossy().into_owned());
    }
    account_from_targets(targets.into_iter())
}

#[cfg(test)]
mod tests {
    use super::*;
    fn database()->Connection {
        let conn=Connection::open_in_memory().unwrap();
        conn.execute_batch("CREATE TABLE sessions(id TEXT PRIMARY KEY,logged_in_user TEXT,wechat_pid INTEGER,login_state TEXT,updated_at TEXT);CREATE TABLE wechat_keys(value TEXT);CREATE TABLE sync_state(value TEXT);INSERT INTO sessions VALUES('default','synthetic-a',10,'logged_out','before');INSERT INTO wechat_keys VALUES('synthetic-preserved-key');INSERT INTO sync_state VALUES('preserved-checkpoint');").unwrap();conn
    }
    fn snapshot(conn:&Connection)->(String,i64,String,String) {
        conn.query_row("SELECT logged_in_user,wechat_pid,login_state,updated_at FROM sessions WHERE id='default'",[],|r|Ok((r.get(0)?,r.get(1)?,r.get(2)?,r.get(3)?))).unwrap()
    }
    #[test]
    fn expected_account_input_is_required_and_cannot_switch() {
        assert_eq!(validate_input(None,false),Err("expected_account_required"));
        assert_eq!(validate_input(Some("synthetic-a"),true),Err("preserve_account_rejects_new_account"));
        assert!(validate_input(Some("../../a"),false).is_err());
        assert_eq!(validate_stored("synthetic-a",None),Err("stored_account_unknown"));
        assert_eq!(validate_stored("synthetic-a",Some("synthetic-b")),Err("expected_account_mismatch"));
    }
    #[test]
    fn expected_account_mismatch_leaves_real_sqlite_rows_unchanged() {
        let conn=database();let before=snapshot(&conn);
        assert!(validate_observed(&conn,"default","synthetic-a",None).is_err());
        assert!(commit_verified_session(&conn,"default","synthetic-a","synthetic-b",99).is_err());
        assert_eq!(snapshot(&conn),before);
        assert_eq!(conn.query_row("SELECT value FROM wechat_keys",[],|r|r.get::<_,String>(0)).unwrap(),"synthetic-preserved-key");
        assert_eq!(conn.query_row("SELECT value FROM sync_state",[],|r|r.get::<_,String>(0)).unwrap(),"preserved-checkpoint");
    }
    #[test]
    fn expected_account_verified_update_preserves_identity() {
        let conn=database();commit_verified_session(&conn,"default","synthetic-a","synthetic-a",20).unwrap();
        let row=snapshot(&conn);assert_eq!(row.0,"synthetic-a");assert_eq!(row.1,20);assert_eq!(row.2,"logged_in");
        conn.execute("UPDATE sessions SET logged_in_user='synthetic-b'",[]).unwrap();
        assert!(validate_observed(&conn,"default","synthetic-a",Some("synthetic-a")).is_err());
        assert_eq!(conn.query_row("SELECT count(*) FROM wechat_keys",[],|r|r.get::<_,i64>(0)).unwrap(),1);
    }
    #[test]
    fn expected_account_discovery_rejects_multiple_accounts() {
        let target=|s:&str|format!("/home/wechat/xwechat_files/{s}/db_storage/message/message_0.db");
        assert_eq!(account_from_targets(vec![target("synthetic-a"),target("synthetic-a")].into_iter()).unwrap(),Some("synthetic-a".into()));
        assert_eq!(account_from_targets(vec![target("synthetic-a"),target("synthetic-b")].into_iter()),Err("observed_account_ambiguous"));
        assert_eq!(account_from_targets(Vec::<String>::new().into_iter()).unwrap(),None);
    }
}

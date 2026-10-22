#[cfg(test)]
mod live_login_db_tests {
    use super::query_wechat_db;
    use rusqlite::Connection;

    const KEY: &str = "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f";

    fn fixture(path: &str, wal: bool) -> Connection {
        let writer = Connection::open(path).unwrap();
        writer.execute_batch(&format!(
            "PRAGMA key = \"x'{KEY}'\"; PRAGMA cipher_compatibility = 4;
             CREATE TABLE messages(id INTEGER PRIMARY KEY, content TEXT);
             CREATE TABLE sessions(id INTEGER PRIMARY KEY, last_timestamp INTEGER);
             INSERT INTO messages VALUES (1, 'baseline');
             INSERT INTO sessions VALUES (1, 100);"
        )).unwrap();
        if wal {
            writer.execute_batch(
                "PRAGMA journal_mode = WAL; PRAGMA wal_autocheckpoint = 0;
                 PRAGMA wal_checkpoint(TRUNCATE);"
            ).unwrap();
        }
        writer
    }

    #[test]
    fn live_login_wal_new_messages_are_visible_while_writer_remains_open() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("message.db");
        let path = path.to_str().unwrap();
        let writer = fixture(path, true);
        writer.execute("INSERT INTO messages VALUES (2, 'wal-only')", []).unwrap();
        assert!(std::fs::metadata(format!("{path}-wal")).unwrap().len() > 32);
        let rows = query_wechat_db(path, KEY, "SELECT id, content FROM messages ORDER BY id");
        assert_eq!(rows.len(), 2, "reader must include committed WAL rows, not just main.db");
        assert_eq!(rows[1]["content"], "wal-only");
        writer.execute("INSERT INTO messages VALUES (3, 'later-wal')", []).unwrap();
        let rows = query_wechat_db(path, KEY, "SELECT max(id) AS latest FROM messages");
        assert_eq!(rows[0]["latest"], 3, "each short read sees the next committed WAL state");
    }

    #[test]
    fn live_login_wal_session_timestamp_is_current_without_checkpoint() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("session.db");
        let path = path.to_str().unwrap();
        let writer = fixture(path, true);
        writer.execute("UPDATE sessions SET last_timestamp = 200 WHERE id = 1", []).unwrap();
        let rows = query_wechat_db(path, KEY, "SELECT max(last_timestamp) AS latest FROM sessions");
        assert_eq!(rows[0]["latest"], 200, "session query must observe committed WAL updates");
    }

    #[test]
    fn live_login_query_is_readonly_and_does_not_keep_a_delete_journal_lock() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("delete.db");
        let path = path.to_str().unwrap();
        let writer = fixture(path, false);
        assert_eq!(query_wechat_db(path, KEY, "SELECT id FROM messages").len(), 1);
        writer.execute_batch("PRAGMA busy_timeout = 0; BEGIN EXCLUSIVE;
                              INSERT INTO messages VALUES (2, 'next'); COMMIT;").unwrap();
        assert!(query_wechat_db(path, KEY, "DELETE FROM messages RETURNING id").is_empty());
        assert_eq!(writer.query_row("SELECT count(*) FROM messages", [], |row|row.get::<_, i64>(0)).unwrap(), 2);
    }

    #[test]
    fn live_login_wal_reader_releases_before_writer_and_preserves_journal_mode() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("writer.db");
        let path = path.to_str().unwrap();
        let writer = fixture(path, true);
        assert_eq!(query_wechat_db(path, KEY, "SELECT id FROM messages").len(), 1);
        writer.execute_batch("PRAGMA busy_timeout = 0; BEGIN IMMEDIATE;
                              INSERT INTO messages VALUES (2, 'after-read'); COMMIT;").unwrap();
        let mode: String = writer.query_row("PRAGMA journal_mode", [], |row|row.get(0)).unwrap();
        assert_eq!(mode, "wal");
        assert_eq!(query_wechat_db(path, KEY, "SELECT id FROM messages").len(), 2);
    }
}

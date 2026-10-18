//! File-send temporary storage. The basename is user-visible; uniqueness belongs
//! to the parent directory, not to the name shown by WeChat.
use std::fs::{self, DirBuilder, OpenOptions};
use std::future::Future;
use std::io::{self, Write};
use std::os::unix::fs::{DirBuilderExt, OpenOptionsExt, PermissionsExt};
use std::path::{Path, PathBuf};

pub fn valid_filename(name: &str) -> bool {
    if name.is_empty() || name.len() > 255 || name == "." || name == ".."
        || name.ends_with(['.', ' '])
        || name.chars().any(|c| c.is_control() || "<>:\"/\\|?*".contains(c)
            || matches!(c, '\u{061c}' | '\u{200e}' | '\u{200f}' | '\u{202a}'..='\u{202e}' | '\u{2066}'..='\u{2069}')) {
        return false;
    }
    let stem = name.split('.').next().unwrap_or("").trim_end_matches(' ').to_ascii_uppercase();
    !matches!(stem.as_str(), "CON" | "PRN" | "AUX" | "NUL" | "CONIN$" | "CONOUT$"
        | "COM¹" | "COM²" | "COM³" | "LPT¹" | "LPT²" | "LPT³")
        && !(stem.len() == 4 && (stem.starts_with("COM") || stem.starts_with("LPT"))
            && matches!(stem.as_bytes()[3], b'1'..=b'9'))
}

pub struct PreparedFile { directory: PathBuf, path: PathBuf }

impl PreparedFile {
    pub fn create(parent: &Path, filename: &str, bytes: &[u8]) -> io::Result<Self> {
        if !valid_filename(filename) {
            return Err(io::Error::new(io::ErrorKind::InvalidInput, "invalid file name"));
        }
        for _ in 0..8 {
            let directory = parent.join(format!("send_file_{}", uuid::Uuid::new_v4()));
            match DirBuilder::new().mode(0o700).create(&directory) {
                Err(e) if e.kind() == io::ErrorKind::AlreadyExists => continue,
                Err(e) => return Err(e),
                Ok(()) => {}
            }
            let owned = Self { path: directory.join(filename), directory };
            let mut file = OpenOptions::new().write(true).create_new(true).mode(0o600).open(&owned.path)?;
            file.write_all(bytes)?;
            file.flush()?;
            // The server is root but the GUI runs as wechat. Publish only after
            // all bytes are present; retain the established cross-user read contract.
            file.set_permissions(fs::Permissions::from_mode(0o644))?;
            fs::set_permissions(&owned.directory, fs::Permissions::from_mode(0o711))?;
            return Ok(owned);
        }
        Err(io::Error::new(io::ErrorKind::AlreadyExists, "temporary directory collision"))
    }

    pub fn path(&self) -> &Path { &self.path }
}

impl Drop for PreparedFile {
    fn drop(&mut self) {
        // Never recurse or remove unrelated paths; only this exclusive pair.
        let _ = fs::remove_file(&self.path);
        let _ = fs::remove_dir(&self.directory);
    }
}

/// A cancelled HTTP waiter must not remove a file while the accepted GUI plan
/// is still consuming it. The existing bounded plan owns the file until return.
pub fn retain_for_send<T, F>(file: PreparedFile, send: F) -> tokio::task::JoinHandle<T>
where T: Send + 'static, F: Future<Output = T> + Send + 'static {
    tokio::spawn(async move {
        let result = send.await;
        drop(file);
        result
    })
}

#[cfg(test)]
mod filename_tests {
    use super::*;
    use std::sync::{Arc, Barrier, Mutex};
    use tokio::sync::oneshot;

    #[test]
    fn original_name_bytes_and_cross_user_modes() {
        let root = tempfile::tempdir().unwrap();
        for name in ["中文 报告 (1).pdf", "report %23 #?.pdf", "résumé.pdf", "emoji😀.pdf"] {
            if name.contains('?') { assert!(!valid_filename(name)); continue; }
            let f = PreparedFile::create(root.path(), name, b"\0unchanged\xff").unwrap();
            assert_eq!(f.path().file_name().unwrap(), name);
            assert_eq!(fs::read(f.path()).unwrap(), b"\0unchanged\xff");
            assert_eq!(fs::metadata(f.path()).unwrap().permissions().mode() & 0o777, 0o644);
            assert_eq!(fs::metadata(f.path().parent().unwrap()).unwrap().permissions().mode() & 0o777, 0o711);
        }
    }

    #[test]
    fn rejects_paths_controls_invalid_names_and_overlong_names() {
        for name in ["", ".", "..", "../x", "x/y", "x\\y", "C:x", "x\0.pdf", "x\n.pdf", "x\u{85}.pdf", "x\u{202e}.pdf", "NUL.pdf", "con", "COM1.txt", "LPT9", "COM¹.txt", "LPT².pdf", "CONIN$", "file.", "file ", "a*b", "x|y", "a<b", "a>b", "x\"y"] {
            assert!(!valid_filename(name), "{name:?}");
        }
        assert!(valid_filename(&"a".repeat(255)));
        assert!(!valid_filename(&"a".repeat(256)));
        assert!(!valid_filename(&"中".repeat(86)));
        assert!(valid_filename("文件 %23 # (2).pdf"));
    }

    #[test]
    fn concurrent_same_name_isolated_and_cleanup_exact() {
        let root = tempfile::tempdir().unwrap();
        let results = Arc::new(Mutex::new(Vec::new()));
        let start = Arc::new(Barrier::new(24));
        std::thread::scope(|scope| {
            for value in 0..24u8 {
                let results = results.clone(); let root = root.path(); let start = start.clone();
                scope.spawn(move || {
                    start.wait();
                    let file = PreparedFile::create(root, "相同 (1).pdf", &[value]).unwrap();
                    results.lock().unwrap().push((value, file));
                });
            }
        });
        let mut files = results.lock().unwrap();
        let paths: std::collections::HashSet<_> = files.iter().map(|(_, f)| f.path().to_path_buf()).collect();
        assert_eq!(paths.len(), 24);
        for (value, file) in files.iter() { assert_eq!(fs::read(file.path()).unwrap(), [*value]); }
        files.clear();
        assert_eq!(fs::read_dir(root.path()).unwrap().count(), 0);
    }

    #[test]
    fn later_input_rejection_cleans_prepared_file_before_any_sender() {
        let root = tempfile::tempdir().unwrap();
        let reject_other_input = || -> Result<(), ()> {
            let _file = PreparedFile::create(root.path(), "原件.pdf", b"bytes").unwrap();
            Err(()) // e.g. the combined image exceeds its existing limit.
        };
        assert!(reject_other_input().is_err());
        assert_eq!(fs::read_dir(root.path()).unwrap().count(), 0);
    }

    #[tokio::test]
    async fn fake_sender_success_and_failure_keep_bytes_until_return() {
        for success in [true, false] {
            let root = tempfile::tempdir().unwrap();
            let file = PreparedFile::create(root.path(), "原件.pdf", b"content").unwrap();
            let path = file.path().to_path_buf(); let consumed = path.clone();
            let result = retain_for_send(file, async move {
                tokio::task::yield_now().await;
                assert_eq!(fs::read(consumed).unwrap(), b"content"); success
            }).await.unwrap();
            assert_eq!(result, success); assert!(!path.exists());
        }
    }

    #[tokio::test]
    async fn cancelled_waiter_does_not_delete_pending_clipboard_file() {
        let root = tempfile::tempdir().unwrap();
        let file = PreparedFile::create(root.path(), "等待.pdf", b"content").unwrap();
        let path = file.path().to_path_buf(); let consumed = path.clone();
        let (release, wait) = oneshot::channel(); let (done, finished) = oneshot::channel();
        let handle = retain_for_send(file, async move {
            wait.await.unwrap(); assert_eq!(fs::read(consumed).unwrap(), b"content");
            done.send(()).unwrap();
        });
        drop(handle); // HTTP waiter disconnects; accepted bounded sender remains.
        tokio::task::yield_now().await; assert!(path.exists());
        release.send(()).unwrap(); finished.await.unwrap();
        tokio::task::yield_now().await; assert!(!path.exists());
    }

    #[test]
    fn actual_qt_uri_and_different_user_read_original_bytes() {
        let Some(probe) = std::env::var_os("CF_FILENAME_QT_PROBE") else { return; };
        // /tmp is traversable by the GUI account; the actual PreparedFile
        // directory/file permissions, rather than a Python reimplementation,
        // are exercised by a different UID in the Qt helper.
        let file = PreparedFile::create(&std::env::temp_dir(), "中文 空格 (1) %23 #.pdf", b"\0original\xffbytes").unwrap();
        let status = std::process::Command::new("python3").arg(probe)
            .arg("--existing").arg(file.path()).status().unwrap();
        assert!(status.success());
        assert_eq!(fs::read(file.path()).unwrap(), b"\0original\xffbytes");
    }
}

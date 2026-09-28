// Appended to the pinned upstream wechat_media.rs by the isolated CI job.
// These are synthetic byte fixtures, not valid PDF/Office documents or proof of
// native WeChat downloads, image decoding, content parsing, or production receipt.
#[cfg(test)]
mod cf_media_cache_contract_tests {
    use super::{get_file_attachment, image_suffixes, safe_attachment_name, ImageQuality};
    use crate::ia::types::MediaResult;
    use base64::Engine;
    use md5::{Digest, Md5};
    use std::fs;
    use std::path::{Path, PathBuf};
    use tempfile::TempDir;

    const CACHE_ROOTS: [&str; 2] = [
        "/home/wechat/xwechat_files",
        "/home/wechat/Documents/xwechat_files",
    ];
    const CREATE_TIME: i64 = 1_700_000_000; // 2023-11-14 UTC
    const MONTH: &str = "2023-11";
    const LOCAL_ID: i64 = 17;
    const BYTES: &[u8] = b"synthetic attachment bytes\0\x80\xff\r\n";

    struct SyntheticAccount {
        name: String,
        primary: TempDir,
        secondary: PathBuf,
    }

    impl SyntheticAccount {
        fn new() -> Self {
            // CI provides empty cache roots. Never enumerate accounts or adopt an
            // existing directory, including the alternate root searched upstream.
            let primary = tempfile::Builder::new()
                .prefix("cf-media-contract-")
                .tempdir_in(CACHE_ROOTS[0])
                .expect("CI must provide an isolated writable first cache root");
            let name = primary.path().file_name().unwrap().to_str().unwrap().to_owned();
            let secondary = Path::new(CACHE_ROOTS[1]).join(&name);
            fs::create_dir(&secondary)
                .expect("alternate synthetic account must be new, never pre-existing");
            Self { name, primary, secondary }
        }

        fn account_path(&self, root: usize) -> &Path {
            match root {
                0 => self.primary.path(),
                1 => &self.secondary,
                _ => panic!("invalid synthetic cache root"),
            }
        }

        fn file_path(&self, root: usize, filename: &str) -> PathBuf {
            assert!(safe_attachment_name(filename));
            let directory = self.account_path(root).join("msg/file").join(MONTH);
            fs::create_dir_all(&directory).unwrap();
            directory.join(filename)
        }

        fn read(&self, xml: &str) -> MediaResult {
            get_file_attachment(&self.name, xml, CREATE_TIME, LOCAL_ID)
        }
    }

    impl Drop for SyntheticAccount {
        fn drop(&mut self) {
            // This exact directory was created exclusively above. The primary
            // directory has tempfile's RAII cleanup; neither root is removed.
            let _ = fs::remove_dir_all(&self.secondary);
        }
    }

    fn attachment_xml(filename: &str, extension: &str, bytes: &[u8]) -> String {
        metadata_xml(
            filename,
            extension,
            &format!(
                "<totallen>{}</totallen><md5>{:x}</md5>",
                bytes.len(),
                Md5::digest(bytes)
            ),
        )
    }

    fn metadata_xml(filename: &str, extension: &str, metadata: &str) -> String {
        format!(
            "<msg><appmsg><title><![CDATA[{filename}]]></title><type>6</type>\
             <appattach><fileext>{extension}</fileext>{metadata}</appattach>\
             </appmsg></msg>"
        )
    }

    fn assert_pending(result: MediaResult) {
        assert_eq!(result.media_type, "pending");
        assert!(result.data.is_none());
        assert!(result.url.is_none());
    }

    fn assert_bytes(result: MediaResult, filename: &str, extension: &str, bytes: &[u8]) {
        assert_eq!(result.media_type, "file");
        assert_eq!(result.filename, filename);
        assert_eq!(result.format, extension);
        assert!(result.url.is_none());
        let decoded = base64::engine::general_purpose::STANDARD
            .decode(result.data.expect("ready file must contain actual Base64 bytes"))
            .expect("file payload must be valid Base64");
        assert_eq!(decoded, bytes);
    }

    #[test]
    fn generic_files_require_complete_matching_bytes_in_each_cache_root() {
        // Extensions exercise transport only; old Office and unknown formats
        // must not disappear because a downstream content parser lacks support.
        for root in 0..CACHE_ROOTS.len() {
            let account = SyntheticAccount::new();
            for extension in ["pdf", "docx", "xlsx", "pptx", "doc", "xls", "ppt", "unknown"] {
                let filename = format!("资料 & draft 01.{extension}");
                let xml = attachment_xml(&filename, extension, BYTES);
                let path = account.file_path(root, &filename);

                assert_pending(account.read(&xml));
                fs::write(&path, &BYTES[..BYTES.len() - 1]).unwrap();
                assert_pending(account.read(&xml));

                let mut wrong_bytes = BYTES.to_vec();
                wrong_bytes[0] ^= 1;
                fs::write(&path, wrong_bytes).unwrap();
                assert_pending(account.read(&xml));

                fs::write(&path, BYTES).unwrap();
                assert_bytes(account.read(&xml), &filename, extension, BYTES);
                assert_bytes(account.read(&xml), &filename, extension, BYTES);
            }
        }
    }

    #[test]
    fn corrupt_first_root_does_not_hide_matching_second_root() {
        let account = SyntheticAccount::new();
        let filename = "same name.pdf";
        let xml = attachment_xml(filename, "pdf", BYTES);
        let mut wrong_bytes = BYTES.to_vec();
        wrong_bytes[0] ^= 1;
        fs::write(account.file_path(0, filename), wrong_bytes).unwrap();
        fs::write(account.file_path(1, filename), BYTES).unwrap();
        assert_bytes(account.read(&xml), filename, "pdf", BYTES);
    }

    #[test]
    fn missing_or_invalid_integrity_metadata_never_returns_cached_bytes() {
        let account = SyntheticAccount::new();
        let filename = "metadata.pdf";
        fs::write(account.file_path(0, filename), BYTES).unwrap();
        let hash = format!("{:x}", Md5::digest(BYTES));
        let size = BYTES.len();
        for metadata in [
            String::new(),
            format!("<totallen>{size}</totallen>"),
            format!("<md5>{hash}</md5>"),
            format!("<totallen></totallen><md5>{hash}</md5>"),
            format!("<totallen>invalid</totallen><md5>{hash}</md5>"),
            format!("<totallen>-1</totallen><md5>{hash}</md5>"),
            format!("<totallen>18446744073709551616</totallen><md5>{hash}</md5>"),
            format!("<totallen>{size}</totallen><md5></md5>"),
            format!("<totallen>{size}</totallen><md5>{}</md5>", &hash[..31]),
            format!("<totallen>{size}</totallen><md5>{hash}0</md5>"),
            format!("<totallen>{size}</totallen><md5>{}</md5>", "g".repeat(32)),
        ] {
            assert_pending(account.read(&metadata_xml(filename, "pdf", &metadata)));
        }
        let uppercase_hash = format!("<totallen>{size}</totallen><md5>{}</md5>", hash.to_uppercase());
        assert_bytes(
            account.read(&metadata_xml(filename, "pdf", &uppercase_hash)),
            filename,
            "pdf",
            BYTES,
        );
    }

    #[test]
    fn file_lookup_is_bound_to_the_message_month() {
        let account = SyntheticAccount::new();
        let filename = "monthly.docx";
        let xml = attachment_xml(filename, "docx", BYTES);
        let adjacent_month = account.account_path(0).join("msg/file/2023-10");
        fs::create_dir_all(&adjacent_month).unwrap();
        fs::write(adjacent_month.join(filename), BYTES).unwrap();
        assert_pending(account.read(&xml));
        fs::write(account.file_path(0, filename), BYTES).unwrap();
        assert_bytes(account.read(&xml), filename, "docx", BYTES);
    }

    #[test]
    fn unsafe_titles_cannot_read_outside_the_attachment_directory() {
        // Check external-looking names purely, without probing external paths.
        for filename in ["", ".", "..", "../file", "/etc/passwd", "folder\\file", "a\0b"] {
            assert!(!safe_attachment_name(filename));
        }
        assert!(safe_attachment_name("合同 & notes 01.pdf"));

        let account = SyntheticAccount::new();
        let unused = account.file_path(0, "placeholder.pdf");
        let escaped_file = unused.parent().unwrap().parent().unwrap().join("escape.pdf");
        fs::write(&escaped_file, BYTES).unwrap();
        // Both targets remain inside a directory created by this test even if
        // the production path guard regresses, so no real files are exposed.
        for filename in ["../escape.pdf", escaped_file.to_str().unwrap()] {
            let result = account.read(&attachment_xml(filename, "pdf", BYTES));
            assert_eq!(result.media_type, "unsupported");
            assert!(result.data.is_none());
            assert!(result.url.is_none());
        }
    }

    #[test]
    fn explicit_image_quality_never_selects_another_variants_suffix() {
        // Pure selection check only: no real image cache, decryption, or native
        // downloads. Full/standard/thumbnail remain distinct request contracts.
        assert_eq!(image_suffixes(ImageQuality::Full), &["_h"]);
        assert_eq!(image_suffixes(ImageQuality::Standard), &[""]);
        assert_eq!(image_suffixes(ImageQuality::Thumbnail), &["_t"]);
    }
}

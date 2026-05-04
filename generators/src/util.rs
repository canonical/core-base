use std::io;
use std::os::unix::fs as unix_fs;
use std::path::Path;
use std::{fmt, fs};

/// Create a symlink at `dst` pointing to `src`, atomically replacing any
/// existing file or symlink at `dst`.
///
/// A temporary symlink is created in the same directory as `dst` and then
/// renamed over it. Because `rename(2)` is atomic this avoids the TOCTOU
/// window present in a remove-then-create approach.
pub fn symlink_force(src: &str, dst: &str) -> io::Result<()> {
    let dst_path = Path::new(dst);
    let dir = dst_path.parent().unwrap_or(Path::new("."));
    let file_name = dst_path
        .file_name()
        .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidInput, "dst has no file name"))?;

    let tmp = dir.join(format!(".tmp.{}", file_name.to_string_lossy()));
    // First, remove any leftover temp symlink from a previous interrupted run.
    let _ = fs::remove_file(&tmp);
    // Create, then (atomically) rename
    unix_fs::symlink(src, &tmp)?;
    fs::rename(&tmp, dst_path)
}

/// Log message to kernel ring buffer.
pub fn log_kmsg(args: fmt::Arguments) {
    // Write directly to kernel message buffer as we cannot talk to other
    // processes (see systemd.generator(7)).
    let _ = fs::write("/dev/kmsg", format!("{}\n", args));
}

/// Wrapper for `log_kmsg`.
#[macro_export]
macro_rules! kprint {
    ($($arg:tt)*) => {
        $crate::util::log_kmsg(format_args!($($arg)*))
    };
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::fs::symlink;

    fn tmp_dir() -> std::path::PathBuf {
        let dir = std::env::temp_dir().join(format!(
            "symlink-force-test-{}",
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .subsec_nanos()
        ));
        fs::create_dir_all(&dir).unwrap();
        dir
    }

    #[test]
    fn creates_symlink_when_dst_absent() {
        let dir = tmp_dir();
        let dst = dir.join("link");
        symlink_force("/some/target", dst.to_str().unwrap()).unwrap();
        assert_eq!(
            fs::read_link(&dst).unwrap().to_str().unwrap(),
            "/some/target"
        );
        fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn creates_symlink_rel_dir() {
        let dir = tmp_dir();
        let dst = dir.join("link");
        symlink_force("../some/target", dst.to_str().unwrap()).unwrap();
        assert_eq!(
            fs::read_link(&dst).unwrap().to_str().unwrap(),
            "../some/target"
        );
        fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn replaces_existing_symlink() {
        let dir = tmp_dir();
        let dst = dir.join("link");
        symlink("/old/target", &dst).unwrap();
        symlink_force("/new/target", dst.to_str().unwrap()).unwrap();
        assert_eq!(
            fs::read_link(&dst).unwrap().to_str().unwrap(),
            "/new/target"
        );
        fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn replaces_existing_regular_file() {
        let dir = tmp_dir();
        let dst = dir.join("file");
        fs::write(&dst, b"hello").unwrap();
        symlink_force("/new/target", dst.to_str().unwrap()).unwrap();
        assert_eq!(
            fs::read_link(&dst).unwrap().to_str().unwrap(),
            "/new/target"
        );
        fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn no_tmp_file_left_on_success() {
        let dir = tmp_dir();
        let dst = dir.join("link");
        symlink_force("/some/target", dst.to_str().unwrap()).unwrap();
        assert!(!dir.join(".tmp.link").exists());
        fs::remove_dir_all(dir).unwrap();
    }
}

use std::fs;
use std::io::{self, BufRead};

/// Look up an entry in a snapd modeenv file.
///
/// Returns `Some(value)` if the entry is found, or `None` if not found or
/// the file cannot be read.
///
/// `modeenv_path` defaults to `/var/lib/snapd/modeenv`.
pub fn get_mode(name: &str, modeenv_path: Option<&str>) -> Option<String> {
    let path = modeenv_path.unwrap_or("/var/lib/snapd/modeenv");
    let file = fs::File::open(path).ok()?;
    let reader = io::BufReader::new(file);
    let prefix = format!("{}=", name);

    for line in reader.lines() {
        let line = line.ok()?;
        if let Some(value) = line.strip_prefix(&prefix) {
            return Some(value.to_string());
        }
    }

    None
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;

    fn write_modeenv(content: &str) -> std::path::PathBuf {
        let dir = std::env::temp_dir();
        let path = dir.join(format!(
            "test-modeenv-{}",
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .subsec_nanos()
        ));
        let mut f = fs::File::create(&path).unwrap();
        f.write_all(content.as_bytes()).unwrap();
        path
    }

    #[test]
    fn test_get_mode_found() {
        let path = write_modeenv("mode=run\nrecovery_system=/systems/20240101\n");
        assert_eq!(
            get_mode("mode", Some(path.to_str().unwrap())),
            Some("run".to_string())
        );
        let _ = fs::remove_file(path);
    }

    #[test]
    fn test_get_mode_not_found() {
        let path = write_modeenv("mode=run\n");
        assert_eq!(get_mode("missing", Some(path.to_str().unwrap())), None);
        let _ = fs::remove_file(path);
    }

    #[test]
    fn test_get_mode_missing_file() {
        assert_eq!(get_mode("mode", Some("/nonexistent/modeenv")), None);
    }
}

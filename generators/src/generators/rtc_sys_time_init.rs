use crate::{kernel_args, kprint, util};
use std::fs;

// This generator instantiates rtc-sys-time-init@dev-rtc*.service by hooking it
// into sysinit.target when requested by kernel command line parameter
// ubuntu_core.rtc_sys_time_init=dev-rtc*. Instances are based on the template
// rtc-sys-time-init@.service that is not generated.
pub fn run(
    normal_dir: &str,
    _early_dir: &str,
    _late_dir: &str,
) -> Result<(), Box<dyn std::error::Error>> {
    let dev_node = match kernel_args::get_arg("ubuntu_core.rtc_sys_time_init") {
        Some(val) => val,
        None => return Ok(()),
    };

    if !is_valid_rtc_dev(&dev_node) {
        kprint!(
            "Warning: kernel command line parameter ubuntu_core.rtc_sys_time_init={} seems invalid",
            dev_node
        );
        // Do not exit; require a highly visible service failure instead.
    }

    let dev_unit = systemd_escape_path(&dev_node);
    let instance = format!("rtc-sys-time-init@{}.service", dev_unit);
    let target_dir = format!("{}/sysinit.target.wants", normal_dir);
    let target_link = format!("{}/{}", target_dir, instance);
    let template = "/usr/lib/systemd/system/rtc-sys-time-init@.service";

    fs::create_dir_all(&target_dir).map_err(|e| {
        kprint!(
            "Error: cannot create target directory {}: {}",
            target_dir,
            e
        );
        e
    })?;

    util::symlink_force(template, &target_link).map_err(|e| {
        kprint!(
            "Error: cannot create symlink {} -> {}: {}",
            target_link,
            template,
            e
        );
        e
    })?;

    Ok(())
}

/// Returns true for `/dev/rtc` or `/dev/rtcN` (N a single digit).
fn is_valid_rtc_dev(path: &str) -> bool {
    if path == "/dev/rtc" {
        return true;
    }
    if let Some(suffix) = path.strip_prefix("/dev/rtc") {
        suffix.len() == 1 && suffix.starts_with(|c: char| c.is_ascii_digit())
    } else {
        false
    }
}

/// Escape a device path for use in a systemd unit name.
///
/// Equivalent to `systemd-escape --path <path>`.
fn systemd_escape_path(path: &str) -> String {
    let stripped = path.trim_matches('/');
    if stripped.is_empty() {
        return "-".to_string();
    }

    let mut result = String::new();
    let mut first = true;

    for ch in stripped.chars() {
        if ch == '/' {
            result.push('-');
        } else if first && ch == '.' {
            result.push_str("\\x2e");
        } else if ch.is_ascii_alphanumeric() || matches!(ch, '_' | ':' | '.') {
            result.push(ch);
        } else if ch.is_ascii() {
            result.push_str(&format!("\\x{:02x}", ch as u8));
        } else {
            let mut buf = [0u8; 4];
            for byte in ch.encode_utf8(&mut buf).as_bytes() {
                result.push_str(&format!("\\x{:02x}", byte));
            }
        }
        first = false;
    }

    result
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_is_valid_rtc_dev() {
        assert!(is_valid_rtc_dev("/dev/rtc"));
        assert!(is_valid_rtc_dev("/dev/rtc0"));
        assert!(is_valid_rtc_dev("/dev/rtc9"));
        assert!(!is_valid_rtc_dev("/dev/rtc10"));
        assert!(!is_valid_rtc_dev("/dev/sda"));
        assert!(!is_valid_rtc_dev("rtc0"));
    }

    #[test]
    fn test_systemd_escape_path() {
        assert_eq!(systemd_escape_path("/dev/rtc0"), "dev-rtc0");
        assert_eq!(systemd_escape_path("/dev/rtc"), "dev-rtc");
        assert_eq!(systemd_escape_path("/"), "-");
        assert_eq!(systemd_escape_path("/foo-blah/bar"), r"foo\x2dblah-bar");
        assert_eq!(systemd_escape_path(""), "-");
    }
}

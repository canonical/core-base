use crate::util;
use std::fs;

pub fn run(
    normal_dir: &str,
    _early_dir: &str,
    _late_dir: &str,
) -> Result<(), Box<dyn std::error::Error>> {
    let active = fs::read_to_string("/sys/class/tty/console/active")?;

    for tty in active.split_whitespace() {
        let getty_wants = format!("{}/getty.target.wants", normal_dir);
        fs::create_dir_all(&getty_wants)?;

        if is_regular_tty(tty) {
            let src = "/usr/lib/systemd/system/console-conf@.service";
            let dst = format!("{}/console-conf@{}.service", getty_wants, tty);
            util::symlink_force(src, &dst)?;
        } else {
            // assume serial tty
            let src = "/usr/lib/systemd/system/serial-console-conf@.service";
            let dst = format!("{}/serial-console-conf@{}.service", getty_wants, tty);
            util::symlink_force(src, &dst)?;
        }
    }

    Ok(())
}

/// Returns true for virtual TTYs (tty[0-9]*), false for serial and others.
fn is_regular_tty(tty: &str) -> bool {
    if let Some(rest) = tty.strip_prefix("tty") {
        rest.starts_with(|c: char| c.is_ascii_digit())
    } else {
        false
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_is_regular_tty() {
        assert!(is_regular_tty("tty0"));
        assert!(is_regular_tty("tty1"));
        assert!(is_regular_tty("tty12"));
        assert!(!is_regular_tty("ttyS0"));
        assert!(!is_regular_tty("ttyUSB0"));
        assert!(!is_regular_tty("tty"));
        assert!(!is_regular_tty("console"));
    }
}

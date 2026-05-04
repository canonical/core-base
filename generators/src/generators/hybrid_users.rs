use crate::{kernel_args, modeenv, util};
use std::fs;
use std::path::Path;

pub fn run(
    normal_dir: &str,
    _early_dir: &str,
    _late_dir: &str,
) -> Result<(), Box<dyn std::error::Error>> {
    let mode = modeenv::get_mode("mode", None)
        .or_else(|| kernel_args::get_arg("snapd_recovery_mode"))
        .unwrap_or_else(|| "unknown".to_string());

    let users_passwd = Path::new("/run/snapd/hybrid-users/passwd");

    if users_passwd.exists() && mode == "recover" {
        let wants = format!("{}/local-fs.target.wants", normal_dir);
        fs::create_dir_all(&wants)?;
        enable(&wants, "etc-passwd.mount")?;
        enable(&wants, "etc-shadow.mount")?;
        enable(&wants, "etc-group.mount")?;
        enable(&wants, "etc-gshadow.mount")?;
    }

    Ok(())
}

fn enable(wants_dir: &str, unit: &str) -> std::io::Result<()> {
    let src = format!("/usr/lib/systemd/system/{}", unit);
    let dst = format!("{}/{}", wants_dir, unit);
    util::symlink_force(&src, &dst)
}

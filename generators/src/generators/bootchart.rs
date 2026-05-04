use crate::{kernel_args, modeenv, util};
use std::env;
use std::fs;
use std::path::Path;

pub fn run(
    normal_dir: &str,
    _early_dir: &str,
    _late_dir: &str,
) -> Result<(), Box<dyn std::error::Error>> {
    if env::var("SYSTEMD_ARCHITECTURE").as_deref().unwrap_or("") == "riscv64" {
        return Ok(());
    }

    if kernel_args::get_arg("ubuntu_core.bootchart").is_none() {
        return Ok(());
    }

    let modeenv_path = "/run/mnt/data/system-data/var/lib/snapd/modeenv";
    let mode =
        modeenv::get_mode("mode", Some(modeenv_path)).unwrap_or_else(|| "unknown".to_string());

    enable(
        normal_dir,
        "/lib/systemd/system/systemd-bootchart.service",
        "sysinit.target",
        "wants",
    )?;

    if mode == "run" {
        enable(
            normal_dir,
            "/lib/systemd/system/systemd-bootchart-quit.service",
            "multi-user.target",
            "wants",
        )?;
    }

    // Folder where systemd-bootchart from the base stores the plot. Files here
    // are copied over when systemd-bootchart.service is stopped.
    fs::create_dir_all("/run/log/base")?;

    Ok(())
}

fn enable(normal_dir: &str, unit: &str, target: &str, type_: &str) -> std::io::Result<()> {
    let target_dir = format!("{}/{}.{}", normal_dir, target, type_);
    fs::create_dir_all(&target_dir)?;
    let unit_name = Path::new(unit).file_name().unwrap().to_str().unwrap();
    let link = format!("{}/{}", target_dir, unit_name);
    util::symlink_force(unit, &link)
}

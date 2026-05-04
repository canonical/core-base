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

    if mode != "run" {
        return Ok(());
    }

    let wants = format!("{}/local-fs.target.wants", normal_dir);
    fs::create_dir_all(&wants)?;

    if Path::new("/run/mnt/ubuntu-boot/EFI/ubuntu/grub.cfg").exists() {
        enable(&wants, "boot-grub.mount")?;
        // ensure ESP efi dir is available for fwupdate (LP: 1892392)
        enable(&wants, "boot-efi.mount")?;
    } else if Path::new("/run/mnt/ubuntu-boot/uboot/ubuntu").is_dir() {
        // uboot and ubootpart bootloaders
        enable(&wants, "boot-uboot.mount")?;
    } else if Path::new("/run/mnt/ubuntu-seed/piboot/ubuntu/piboot.conf").exists() {
        enable(&wants, "boot-piboot.mount")?;
    }

    Ok(())
}

fn enable(wants_dir: &str, unit: &str) -> std::io::Result<()> {
    let src = format!("/usr/lib/systemd/system/{}", unit);
    let dst = format!("{}/{}", wants_dir, unit);
    util::symlink_force(&src, &dst)
}

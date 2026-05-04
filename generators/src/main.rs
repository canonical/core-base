use std::env;
use std::path::Path;
use std::process;

mod generators;
mod kernel_args;
mod modeenv;
mod util;

fn main() {
    let args: Vec<String> = env::args().collect();

    let argv0 = args.first().map(String::as_str).unwrap_or("");
    let generator_name = Path::new(argv0)
        .file_name()
        .and_then(|n| n.to_str())
        .unwrap_or(argv0);

    let exit_wrong_args = || {
        // Print to stdout as this would happen only when debugging.
        println!("Unexpected number of arguments for a generator");
        process::exit(1);
    };
    let normal_dir = args
        .get(1)
        .map(String::as_str)
        .unwrap_or_else(exit_wrong_args);
    let early_dir = args
        .get(2)
        .map(String::as_str)
        .unwrap_or_else(exit_wrong_args);
    let late_dir = args
        .get(3)
        .map(String::as_str)
        .unwrap_or_else(exit_wrong_args);

    let result = match generator_name {
        "bootchart" => generators::bootchart::run(normal_dir, early_dir, late_dir),
        "bootloaders" => generators::bootloaders::run(normal_dir, early_dir, late_dir),
        "hybrid-users" => generators::hybrid_users::run(normal_dir, early_dir, late_dir),
        "console-conf-generator" => generators::console_conf::run(normal_dir, early_dir, late_dir),
        "rtc-sys-time-init-generator" => {
            generators::rtc_sys_time_init::run(normal_dir, early_dir, late_dir)
        }
        _ => {
            kprint!("Unknown generator: {}", generator_name);
            process::exit(1);
        }
    };

    if let Err(e) = result {
        kprint!("Generator {} failed: {}", generator_name, e);
        process::exit(1);
    }
}

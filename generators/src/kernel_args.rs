use std::env;
use std::fs;

/// Look up a kernel command line parameter by name.
///
/// Returns `Some(value)` if found (value is an empty string for flag
/// parameters without `=value`), or `None` if not found.
///
/// Both `-` and `_` in parameter names are treated as equivalent, matching
/// Linux kernel cmdline conventions.
pub fn get_arg(name: &str) -> Option<String> {
    let looking_for = name.replace('_', "-");

    // SYSTEMD_PROC_CMDLINE is just for testing (this debug var name is used also by systemd)
    let cmdline = if let Ok(val) = env::var("SYSTEMD_PROC_CMDLINE") {
        val
    } else {
        fs::read_to_string("/proc/cmdline").ok()?
    };

    for param in parse_cmdline(&cmdline) {
        let name_part = param.split('=').next().unwrap_or(&param);
        if name_part.replace('_', "-") == looking_for {
            let value = param
                .find('=')
                .map(|i| param[i + 1..].to_string())
                .unwrap_or_default();
            return Some(value);
        }
    }

    None
}

fn parse_cmdline(cmdline: &str) -> Vec<String> {
    // Whitespace characters that separate kernel parameters (mirrors Linux's
    // next_arg() in lib/cmdline.c).
    let is_ws = |c: char| matches!(c, ' ' | '\t' | '\n' | '\x0b' | '\x0c' | '\r' | '\u{00a0}');

    let mut params = Vec::new();
    let mut current = String::new();
    let mut in_quote = false;

    for ch in cmdline.chars() {
        match ch {
            '"' => in_quote = !in_quote,
            c if !in_quote && is_ws(c) => {
                if !current.is_empty() {
                    params.push(current.clone());
                    current.clear();
                }
            }
            c => current.push(c),
        }
    }
    if !current.is_empty() {
        params.push(current);
    }

    params
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_parse_cmdline_simple() {
        let params = parse_cmdline("foo bar=baz");
        assert_eq!(params, ["foo", "bar=baz"]);
    }

    #[test]
    fn test_parse_cmdline_quoted() {
        let params = parse_cmdline(r#"foo "bar baz" qux"#);
        assert_eq!(params, ["foo", "bar baz", "qux"]);
    }

    #[test]
    fn test_parse_cmdline_trailing_newline() {
        let params = parse_cmdline("foo bar\n");
        assert_eq!(params, ["foo", "bar"]);
    }
}

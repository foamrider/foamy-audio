//! The bits of Python's string and JSON semantics the old helpers relied on,
//! so parsing pactl, avahi, ip and ufw output gives the same answers, and a
//! small argv parser shaped like their argparse use.

use std::ffi::OsString;

use serde_json::Value;

/// `str.isspace()` for one character: Unicode White_Space plus the
/// separators U+001C–U+001F, which Python also counts.
pub fn is_space(c: char) -> bool {
    c.is_whitespace() || ('\u{1c}'..='\u{1f}').contains(&c)
}

/// `str.strip()`.
pub fn strip(text: &str) -> &str {
    text.trim_matches(is_space)
}

/// `str.split()` without arguments.
pub fn split_whitespace(text: &str) -> impl Iterator<Item = &str> {
    text.split(is_space).filter(|part| !part.is_empty())
}

/// `str.splitlines()`: lines without their terminators (`\n`, `\r\n`, `\r`,
/// `\v`, `\f`, U+001C–U+001E, U+0085, U+2028, U+2029); no empty last line
/// after a final terminator.
pub fn splitlines(text: &str) -> Vec<&str> {
    let mut lines = Vec::new();
    let mut start = 0;
    let mut chars = text.char_indices().peekable();
    while let Some((at, c)) = chars.next() {
        let breaks = matches!(
            c,
            '\n' | '\r'
                | '\u{0b}'
                | '\u{0c}'
                | '\u{1c}'
                | '\u{1d}'
                | '\u{1e}'
                | '\u{85}'
                | '\u{2028}'
                | '\u{2029}'
        );
        if !breaks {
            continue;
        }
        lines.push(&text[start..at]);
        let mut end = at + c.len_utf8();
        if c == '\r'
            && let Some(&(next, '\n')) = chars.peek()
        {
            chars.next();
            end = next + 1;
        }
        start = end;
    }
    if start < text.len() {
        lines.push(&text[start..]);
    }
    lines
}

/// `int(text)` for base 10: surrounding whitespace, an optional sign, ASCII
/// digits with single underscores between them. `None` where Python raises
/// `ValueError` (or the value does not fit in an `i128`).
pub fn int(text: &str) -> Option<i128> {
    let text = strip(text);
    let (negative, digits) = match text.as_bytes().first() {
        Some(b'-') => (true, &text[1..]),
        Some(b'+') => (false, &text[1..]),
        _ => (false, text),
    };
    if digits.is_empty()
        || digits.starts_with('_')
        || digits.ends_with('_')
        || digits.contains("__")
    {
        return None;
    }
    let mut value: i128 = 0;
    for byte in digits.bytes() {
        match byte {
            b'_' => {}
            b'0'..=b'9' => {
                value = value
                    .checked_mul(10)?
                    .checked_add(i128::from(byte - b'0'))?;
            }
            _ => return None,
        }
    }
    Some(if negative { -value } else { value })
}

/// `str(value)` for a value from JSON.
pub fn str_of(value: &Value) -> String {
    match value {
        Value::String(text) => text.clone(),
        Value::Null => "None".into(),
        Value::Bool(true) => "True".into(),
        Value::Bool(false) => "False".into(),
        Value::Number(number) => match (number.as_i64(), number.as_u64(), number.as_f64()) {
            (Some(n), _, _) => n.to_string(),
            (_, Some(n), _) => n.to_string(),
            (_, _, Some(f)) => format!("{f:?}"),
            _ => number.to_string(),
        },
        other => other.to_string(),
    }
}

/// Python truthiness of a value from JSON.
pub fn truthy(value: &Value) -> bool {
    match value {
        Value::Null => false,
        Value::Bool(b) => *b,
        Value::Number(number) => number.as_f64().is_some_and(|f| f != 0.0),
        Value::String(text) => !text.is_empty(),
        Value::Array(items) => !items.is_empty(),
        Value::Object(map) => !map.is_empty(),
    }
}

/// `x or y`: `value` when truthy, else `None`.
pub fn or_value(value: Option<&Value>) -> Option<&Value> {
    value.filter(|value| truthy(value))
}

/// An integer from JSON (Python `isinstance(x, int)`, booleans excluded).
pub fn integer(value: Option<&Value>) -> Option<i64> {
    value.and_then(Value::as_i64)
}

/// A usage error: the message for the reply, exit 2.
#[derive(Debug, PartialEq, Eq)]
pub struct Usage(pub String);

/// Parsed arguments: positionals in order, and options with their values.
#[derive(Debug, Default, PartialEq, Eq)]
pub struct Args {
    pub positional: Vec<String>,
    options: Vec<(String, String)>,
    pub help: bool,
}

impl Args {
    /// The last value of `--name`.
    pub fn value(&self, name: &str) -> Option<&str> {
        self.options
            .iter()
            .rev()
            .find(|(option, _)| option == name)
            .map(|(_, value)| value.as_str())
    }

    /// Every value of `--name`, in order.
    pub fn values(&self, name: &str) -> Vec<String> {
        self.options
            .iter()
            .filter(|(option, _)| option == name)
            .map(|(_, value)| value.clone())
            .collect()
    }

    /// Whether the flag `--name` was given.
    pub fn flag(&self, name: &str) -> bool {
        self.options.iter().any(|(option, _)| option == name)
    }
}

/// Parses `args`: `with_value` options take `--name value` or
/// `--name=value`, `flags` take none; `--` ends the options; `-h`/`--help`
/// sets `help`. Unknown options and non-UTF-8 arguments are usage errors.
pub fn parse(args: Vec<OsString>, with_value: &[&str], flags: &[&str]) -> Result<Args, Usage> {
    let mut parsed = Args::default();
    let mut args = args.into_iter();
    let mut options_done = false;
    while let Some(arg) = args.next() {
        let arg = arg
            .into_string()
            .map_err(|_| Usage("arguments must be UTF-8".into()))?;
        if options_done || arg == "-" || !arg.starts_with('-') {
            parsed.positional.push(arg);
            continue;
        }
        if arg == "--" {
            options_done = true;
            continue;
        }
        if arg == "-h" || arg == "--help" {
            parsed.help = true;
            continue;
        }
        let (name, inline) = match arg.split_once('=') {
            Some((name, value)) => (name.to_string(), Some(value.to_string())),
            None => (arg.clone(), None),
        };
        if with_value.contains(&name.as_str()) {
            let value = match inline {
                Some(value) => value,
                None => args
                    .next()
                    .ok_or_else(|| Usage(format!("argument {name}: expected one argument")))?
                    .into_string()
                    .map_err(|_| Usage("arguments must be UTF-8".into()))?,
            };
            parsed.options.push((name, value));
        } else if flags.contains(&name.as_str()) && inline.is_none() {
            parsed.options.push((name, String::new()));
        } else {
            return Err(Usage(format!("unrecognized arguments: {arg}")));
        }
    }
    Ok(parsed)
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn whitespace_and_lines_follow_python() {
        assert_eq!(strip("\u{1f} a b\u{a0}\n"), "a b");
        assert_eq!(
            split_whitespace(" 1\t2\u{1c}3  ").collect::<Vec<_>>(),
            ["1", "2", "3"]
        );
        assert_eq!(
            splitlines("a\r\nb\rc\n\nd\u{2028}e\n"),
            ["a", "b", "c", "", "d", "e"]
        );
        assert_eq!(splitlines(""), Vec::<&str>::new());
        assert_eq!(splitlines("\n"), [""]);
        assert_eq!(splitlines("x\u{1f}y"), ["x\u{1f}y"]);
    }

    #[test]
    fn int_accepts_what_python_accepts() {
        assert_eq!(int(" 7000\n"), Some(7000));
        assert_eq!(int("+7_000"), Some(7000));
        assert_eq!(int("-3"), Some(-3));
        assert_eq!(int("007"), Some(7));
        for bad in [
            "", " ", "7.0", "_7", "7_", "7__0", "0x10", "1e3", "++1", "7 0",
        ] {
            assert_eq!(int(bad), None, "{bad:?}");
        }
        assert_eq!(int(&"9".repeat(60)), None);
    }

    #[test]
    fn json_values_print_and_test_like_python() {
        assert_eq!(str_of(&json!(62)), "62");
        assert_eq!(str_of(&json!("62")), "62");
        assert_eq!(str_of(&json!(null)), "None");
        assert_eq!(str_of(&json!(true)), "True");
        assert_eq!(str_of(&json!(1.5)), "1.5");
        assert!(
            !truthy(&json!(""))
                && !truthy(&json!(0))
                && !truthy(&json!([]))
                && !truthy(&json!(null))
        );
        assert!(truthy(&json!("x")) && truthy(&json!(0.5)) && truthy(&json!({"a": 1})));
        assert_eq!(integer(Some(&json!(5))), Some(5));
        assert_eq!(integer(Some(&json!(true))), None);
        assert_eq!(integer(Some(&json!(5.0))), None);
    }

    fn os(args: &[&str]) -> Vec<OsString> {
        args.iter().map(OsString::from).collect()
    }

    #[test]
    fn argv_parsing() {
        let args = parse(
            os(&[
                "a",
                "--local-name",
                "x",
                "b",
                "--local-name=y",
                "--skip",
                "--",
                "--z",
            ]),
            &["--local-name"],
            &["--skip"],
        )
        .unwrap();
        assert_eq!(args.positional, ["a", "b", "--z"]);
        assert_eq!(args.value("--local-name"), Some("y"));
        assert_eq!(args.values("--local-name"), ["x", "y"]);
        assert!(args.flag("--skip") && !args.help);
        assert!(parse(os(&["-h"]), &[], &[]).unwrap().help);
        assert!(parse(os(&["--nope"]), &[], &[]).is_err());
        assert!(parse(os(&["--skip=1"]), &[], &["--skip"]).is_err());
        assert!(parse(os(&["--local-name"]), &["--local-name"], &[]).is_err());
        assert_eq!(
            parse(os(&["--local-name", "--x"]), &["--local-name"], &[])
                .unwrap()
                .value("--local-name"),
            Some("--x")
        );
        assert_eq!(parse(os(&["-"]), &[], &[]).unwrap().positional, ["-"]);
        use std::os::unix::ffi::OsStringExt;
        assert!(parse(vec![OsString::from_vec(vec![0xff])], &[], &[]).is_err());
    }
}

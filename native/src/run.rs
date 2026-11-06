//! Running the system tools: one trait, so the AirPlay and UFW logic can be
//! unit-tested with scripted answers, and the real runner on
//! `foamy_helper::child::Bounded`.

use std::io;
use std::os::unix::process::ExitStatusExt;
use std::time::Duration;

use foamy_helper::child::Bounded;

use crate::py;

/// Most a tool may print on one stream (pactl's JSON lists, ufw's rules).
pub const MAX_OUTPUT: usize = 4 << 20;

/// A finished tool: Python's `CompletedProcess` with text output.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Completed {
    /// Exit status; minus the signal number when a signal ended it.
    pub code: i32,
    pub stdout: String,
    pub stderr: String,
}

impl Completed {
    /// `stderr or stdout`: stderr when not empty (even if only
    /// whitespace), else stdout.
    pub fn diagnostics(&self) -> &str {
        if self.stderr.is_empty() {
            &self.stdout
        } else {
            &self.stderr
        }
    }
}

/// Runs a tool to completion. `Err` when it could not run at all, timed out
/// or printed too much (Python's `OSError` and `SubprocessError`).
pub trait Runner {
    fn run(&mut self, argv: &[&str]) -> Result<Completed, String>;
}

/// The real tools, each within `timeout`, optionally in the C locale.
pub struct System {
    pub timeout: Duration,
    pub c_locale: bool,
}

/// Python's `repr()` of an argv list, for the timeout message.
fn argv_repr(argv: &[&str]) -> String {
    let parts: Vec<String> = argv.iter().map(|arg| format!("'{arg}'")).collect();
    format!("[{}]", parts.join(", "))
}

/// An `OSError` the way Python prints it: `[Errno 2] No such file or
/// directory: 'pactl'`.
pub fn os_error(error: &io::Error, program: &str) -> String {
    match error.raw_os_error() {
        Some(code) => {
            let text = error.to_string();
            let text = text
                .strip_suffix(&format!(" (os error {code})"))
                .unwrap_or(&text);
            format!("[Errno {code}] {text}: '{program}'")
        }
        None => format!("{error}: '{program}'"),
    }
}

impl Runner for System {
    fn run(&mut self, argv: &[&str]) -> Result<Completed, String> {
        let mut command = Bounded::new(argv[0])
            .args(&argv[1..])
            .timeout(self.timeout)
            .max_output(MAX_OUTPUT);
        if self.c_locale {
            command = command.env("LC_ALL", "C");
        }
        let output = command.run().map_err(|error| os_error(&error, argv[0]))?;
        if output.timed_out {
            return Err(format!(
                "Command '{}' timed out after {} seconds",
                argv_repr(argv),
                self.timeout.as_secs()
            ));
        }
        if output.overflowed {
            return Err(format!("{} printed more than {MAX_OUTPUT} bytes", argv[0]));
        }
        let code = output
            .status
            .code()
            .unwrap_or_else(|| -output.status.signal().unwrap_or(0));
        Ok(Completed {
            code,
            stdout: String::from_utf8_lossy(&output.stdout).into_owned(),
            stderr: String::from_utf8_lossy(&output.stderr).into_owned(),
        })
    }
}

/// The AirPlay helper's `command_error`: the last line of the stripped
/// diagnostics, else `fallback`.
pub fn last_line(result: &Completed, fallback: &str) -> String {
    let detail = py::strip(result.diagnostics());
    match py::splitlines(detail).last() {
        Some(line) if !detail.is_empty() => (*line).to_string(),
        _ => fallback.to_string(),
    }
}

#[cfg(test)]
pub mod tests {
    use super::*;
    use std::collections::VecDeque;

    /// Answers calls in order and records them.
    #[derive(Default)]
    pub struct Script {
        pub answers: VecDeque<Result<Completed, String>>,
        pub calls: Vec<Vec<String>>,
    }

    impl Script {
        pub fn new() -> Script {
            Script::default()
        }

        pub fn ok(mut self, stdout: &str) -> Script {
            self.answers.push_back(Ok(Completed {
                code: 0,
                stdout: stdout.into(),
                stderr: String::new(),
            }));
            self
        }

        pub fn fail(mut self, code: i32, stderr: &str) -> Script {
            self.answers.push_back(Ok(Completed {
                code,
                stdout: String::new(),
                stderr: stderr.into(),
            }));
            self
        }

        pub fn error(mut self, message: &str) -> Script {
            self.answers.push_back(Err(message.into()));
            self
        }
    }

    impl Runner for Script {
        fn run(&mut self, argv: &[&str]) -> Result<Completed, String> {
            self.calls
                .push(argv.iter().map(|arg| arg.to_string()).collect());
            self.answers
                .pop_front()
                .unwrap_or_else(|| panic!("unexpected call {argv:?}"))
        }
    }

    #[test]
    fn diagnostics_and_last_line() {
        let result = Completed {
            code: 1,
            stdout: "out\n".into(),
            stderr: "a\nb\n".into(),
        };
        assert_eq!(last_line(&result, "x"), "b");
        let blank = Completed {
            code: 1,
            stdout: "out".into(),
            stderr: " \n".into(),
        };
        // Python's `stderr or stdout` takes whitespace-only stderr, which strips to nothing.
        assert_eq!(last_line(&blank, "fallback"), "fallback");
        assert_eq!(last_line(&Completed::default(), "fallback"), "fallback");
    }

    #[test]
    fn os_errors_read_like_python() {
        let error = io::Error::from_raw_os_error(2);
        assert_eq!(
            os_error(&error, "pactl"),
            "[Errno 2] No such file or directory: 'pactl'"
        );
        assert_eq!(argv_repr(&["ip", "-j"]), "['ip', '-j']");
    }

    #[test]
    fn system_runner_bounds_and_reports() {
        let mut runner = System {
            timeout: Duration::from_millis(300),
            c_locale: true,
        };
        let done = runner
            .run(&["/bin/sh", "-c", "printf \"$LC_ALL\"; echo err >&2; exit 3"])
            .unwrap();
        assert_eq!(
            (done.code, done.stdout.as_str(), done.stderr.as_str()),
            (3, "C", "err\n")
        );
        let slow = runner.run(&["/bin/sh", "-c", "sleep 5"]).unwrap_err();
        assert_eq!(
            slow,
            "Command '['/bin/sh', '-c', 'sleep 5']' timed out after 0 seconds"
        );
        let missing = runner.run(&["/nonexistent/tool"]).unwrap_err();
        assert!(missing.starts_with("[Errno 2] "), "{missing}");
        let killed = runner.run(&["/bin/sh", "-c", "kill -9 $$"]).unwrap();
        assert_eq!(killed.code, -9);
    }
}

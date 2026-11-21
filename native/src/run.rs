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

    /// Set in the copy of the test binary that the C-locale test starts.
    const LOCALE_CHILD: &str = "FOAMY_AUDIO_TEST_LOCALE_CHILD";
    /// That copy's starting locale: a real one that is not C, so its tools
    /// print C only when the runner sets it.
    const START_LOCALE: &str = "C.UTF-8";

    #[test]
    fn a_finished_tool_gives_its_status_and_output_in_the_c_locale() {
        if std::env::var_os(LOCALE_CHILD).is_some() {
            return finished_tool_in_the_c_locale();
        }
        // A tool inherits this process's environment, and the caller's LC_ALL
        // can already be C: then a runner that forgets the C locale would
        // pass. So the check runs in a copy of this test binary that starts
        // from another locale. std::env::set_var here would race the test
        // threads.
        let path = module_path!();
        let name = format!(
            "{}::a_finished_tool_gives_its_status_and_output_in_the_c_locale",
            path.split_once("::").map_or(path, |(_, rest)| rest)
        );
        let child = std::process::Command::new(std::env::current_exe().unwrap())
            .args([name.as_str(), "--exact", "--test-threads=1"])
            .env(LOCALE_CHILD, "1")
            .env("LC_ALL", START_LOCALE)
            .output()
            .unwrap();
        let report = format!(
            "{}{}",
            String::from_utf8_lossy(&child.stdout),
            String::from_utf8_lossy(&child.stderr)
        );
        // " 1 passed;": the name matched, so the copy really ran the check.
        assert!(
            child.status.success() && report.contains(" 1 passed;"),
            "the check, started with LC_ALL={START_LOCALE}:\n{report}"
        );
    }

    fn finished_tool_in_the_c_locale() {
        assert_eq!(
            std::env::var("LC_ALL").as_deref(),
            Ok(START_LOCALE),
            "fixture: the copy's starting locale"
        );
        // A generous deadline: these tools must finish, also on a loaded machine.
        let mut runner = System {
            timeout: Duration::from_secs(30),
            c_locale: true,
        };
        let done = runner
            .run(&["/bin/sh", "-c", "printf \"$LC_ALL\"; echo err >&2; exit 3"])
            .unwrap();
        assert_eq!(
            (done.code, done.stdout.as_str(), done.stderr.as_str()),
            (3, "C", "err\n")
        );
        // Ended by a signal: a failure for every caller, never status 0.
        let killed = runner.run(&["/bin/sh", "-c", "kill -9 $$"]).unwrap();
        assert_eq!(killed.code, -9);
    }

    #[test]
    fn a_tool_without_an_answer_is_an_error() {
        // Past its deadline. Only this case uses a short one.
        let mut short = System {
            timeout: Duration::from_millis(300),
            c_locale: false,
        };
        let slow = short.run(&["/bin/sh", "-c", "sleep 5"]).unwrap_err();
        assert!(slow.contains("timed out"), "{slow}");
        let mut runner = System {
            timeout: Duration::from_secs(30),
            c_locale: false,
        };
        // A tool that cannot start: the message names it.
        let missing = runner.run(&["/nonexistent/tool"]).unwrap_err();
        assert!(missing.contains("/nonexistent/tool"), "{missing}");
    }

    /// Up to MAX_OUTPUT on one stream is a whole answer (pactl's JSON lists,
    /// ufw's rules); one byte more is an error, never a shortened answer.
    #[test]
    fn output_up_to_the_bound_is_whole_and_one_byte_more_is_an_error() {
        let mut runner = System {
            timeout: Duration::from_secs(30),
            c_locale: false,
        };
        // On failure, show the length of the output, not the output.
        let mut printed = |bytes: usize| {
            let script = format!("head -c {bytes} /dev/zero");
            runner
                .run(&["/bin/sh", "-c", &script])
                .map(|done| done.stdout.len())
        };
        assert_eq!(printed(MAX_OUTPUT), Ok(MAX_OUTPUT));
        let over = printed(MAX_OUTPUT + 1);
        assert!(
            over.as_ref()
                .is_err_and(|error| error.contains("printed more than")),
            "{over:?}"
        );
    }
}

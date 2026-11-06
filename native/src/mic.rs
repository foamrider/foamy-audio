//! `microphone-peak`: microphone levels only; audio samples stay in memory
//! and are never saved (was `microphone_peak.py`; the contract is in
//! `main.rs`).

use std::ffi::OsString;
use std::io::{self, ErrorKind, PipeReader, Read, Write};
use std::os::fd::{AsFd, IntoRawFd};
use std::os::unix::process::CommandExt;
use std::process::{Child, ChildStdout, Command, ExitCode, Stdio};
use std::sync::atomic::{AtomicI32, Ordering};
use std::thread;
use std::time::{Duration, Instant};

use rustix::event::{PollFd, PollFlags, Timespec, poll};
use rustix::io::Errno;
use rustix::process::{Pid, Signal};

use crate::py;

const USAGE: &str = "usage: foamy-audio-helper microphone-peak [-h] [--passive] target channels";
const POSITIONS: [&str; 19] = [
    "MONO", "FL", "FR", "FC", "LFE", "RL", "RR", "SL", "SR", "RC", "FLC", "FRC", "TC", "TFL",
    "TFC", "TFR", "TRL", "TRC", "TRR",
];
/// Wait per poll; an idle passive meter reports a zero level this often.
const TICK: Duration = Duration::from_millis(250);
/// An active capture that sends nothing for this long has failed.
const STALL: Duration = Duration::from_secs(5);

pub fn main(args: Vec<OsString>) -> ExitCode {
    let args = match py::parse(args, &[], &["--passive"]) {
        Ok(args) if args.help => {
            println!("{USAGE}");
            return ExitCode::SUCCESS;
        }
        Ok(args) if args.positional.len() == 2 => args,
        Ok(args) if args.positional.len() < 2 => {
            return usage("the following arguments are required: target, channels");
        }
        Ok(args) => {
            return usage(&format!(
                "unrecognized arguments: {}",
                args.positional[2..].join(" ")
            ));
        }
        Err(py::Usage(message)) => return usage(&message),
    };
    match monitor(
        &args.positional[0],
        &args.positional[1],
        args.flag("--passive"),
    ) {
        Ok(()) => ExitCode::SUCCESS,
        Err(error) => {
            eprintln!("Microphone level unavailable: {error}");
            ExitCode::from(1)
        }
    }
}

fn usage(message: &str) -> ExitCode {
    eprintln!("{USAGE}\nfoamy-audio-helper microphone-peak: error: {message}");
    ExitCode::from(2)
}

fn position(name: &str) -> bool {
    if POSITIONS.contains(&name) {
        return true;
    }
    let Some(number) = name.strip_prefix("AUX") else {
        return false;
    };
    // AUX0–AUX63, no leading zeros.
    match number.as_bytes() {
        [d] => d.is_ascii_digit(),
        [b'1'..=b'5', d] => d.is_ascii_digit(),
        [b'6', b'0'..=b'3'] => true,
        _ => false,
    }
}

pub fn channel_map(value: &str) -> Result<Vec<&str>, String> {
    let channels: Vec<&str> = value.split(',').collect();
    if !(1..=64).contains(&channels.len()) || !channels.iter().all(|channel| position(channel)) {
        return Err("unsupported microphone channel map".into());
    }
    Ok(channels)
}

/// A level meter needs no more than 8 kHz; wide AUX devices halve the work per second.
pub fn sample_rate(channels: usize) -> usize {
    if channels <= 8 { 16000 } else { 8000 }
}

/// The block's peak, `min(1, cbrt(max(max, -min)))` over little-endian
/// float32 samples, with Python's `max`/`min` (the first of equal values).
pub fn peak_level(data: &[u8]) -> Result<f64, String> {
    let mut samples = data
        .as_chunks::<4>()
        .0
        .iter()
        .map(|chunk| f64::from(f32::from_le_bytes(*chunk)));
    let Some(first) = samples.next() else {
        return Ok(0.0);
    };
    let (mut high, mut low, mut finite) = (first, first, first.is_finite());
    for sample in samples {
        finite &= sample.is_finite();
        if sample > high {
            high = sample;
        }
        if sample < low {
            low = sample;
        }
    }
    if !finite {
        return Err("invalid microphone sample".into());
    }
    let peak = if -low > high { -low } else { high };
    let level = peak.cbrt();
    Ok(if level < 1.0 { level } else { 1.0 })
}

// ---- stop signals ------------------------------------------------------------

/// Write end of the self-pipe the TERM/INT handler writes to.
static WAKE: AtomicI32 = AtomicI32::new(-1);

extern "C" fn on_stop(_: libc::c_int) {
    let fd = WAKE.load(Ordering::SeqCst);
    if fd >= 0 {
        // SAFETY: write(2) is async-signal-safe; the fd stays open for the
        // life of the process and is non-blocking, so a full pipe just drops
        // the byte (one is enough).
        unsafe {
            libc::write(fd, b"x".as_ptr().cast(), 1);
        }
    }
}

/// SIGTERM and SIGINT make the returned pipe readable instead of ending the
/// process, so the capture is always stopped and reaped first.
fn stop_signals() -> io::Result<PipeReader> {
    let (reader, writer) = io::pipe()?;
    rustix::fs::fcntl_setfl(&writer, rustix::fs::OFlags::NONBLOCK)?;
    WAKE.store(writer.into_raw_fd(), Ordering::SeqCst);
    // SAFETY: a zeroed sigaction is valid; the handler only reads an atomic
    // and calls write(2). No SA_RESTART, so a blocked poll or read returns.
    unsafe {
        let mut action: libc::sigaction = std::mem::zeroed();
        action.sa_sigaction = on_stop as *const () as libc::sighandler_t;
        libc::sigemptyset(&mut action.sa_mask);
        for signal in [libc::SIGTERM, libc::SIGINT] {
            if libc::sigaction(signal, &action, std::ptr::null_mut()) != 0 {
                return Err(io::Error::last_os_error());
            }
        }
    }
    Ok(reader)
}

// ---- capture -----------------------------------------------------------------

enum Ready {
    Data,
    Stop,
    Idle,
}

fn wait(stdout: &ChildStdout, wake: &PipeReader) -> io::Result<Ready> {
    let timeout = Timespec {
        tv_sec: 0,
        tv_nsec: TICK.as_nanos() as _,
    };
    let mut fds = [
        PollFd::from_borrowed_fd(stdout.as_fd(), PollFlags::IN),
        PollFd::from_borrowed_fd(wake.as_fd(), PollFlags::IN),
    ];
    match poll(&mut fds, Some(&timeout)) {
        // A signal interrupted the wait: its byte is in the pipe now.
        Err(Errno::INTR) => return Ok(Ready::Stop),
        Err(error) => return Err(error.into()),
        Ok(_) => {}
    }
    let ready = |fd: &PollFd| {
        fd.revents()
            .intersects(PollFlags::IN | PollFlags::HUP | PollFlags::ERR)
    };
    Ok(if ready(&fds[1]) {
        Ready::Stop
    } else if ready(&fds[0]) {
        Ready::Data
    } else {
        Ready::Idle
    })
}

fn spawn(command: &[String]) -> io::Result<Child> {
    let mut child = Command::new(&command[0]);
    child
        .args(&command[1..])
        .stdin(Stdio::null())
        .stdout(Stdio::piped());
    // SAFETY: only prctl(2) runs between fork and exec (no allocation, no
    // locks). The capture dies with this helper: the thread that spawns it
    // is the main thread, which lives as long as the process.
    unsafe {
        child.pre_exec(|| {
            rustix::process::set_parent_process_death_signal(Some(Signal::KILL))?;
            Ok(())
        });
    }
    child.spawn()
}

/// Closing the panel or switching sources must release capture promptly:
/// SIGTERM, up to 1 s, then SIGKILL; always reaped.
fn release(child: &mut Child) {
    if let Ok(None) = child.try_wait() {
        if let Some(pid) = Pid::from_raw(child.id() as i32) {
            let _ = rustix::process::kill_process(pid, Signal::TERM);
        }
        let deadline = Instant::now() + Duration::from_secs(1);
        while Instant::now() < deadline {
            if let Ok(Some(_)) = child.try_wait() {
                return;
            }
            thread::sleep(Duration::from_millis(10));
        }
        let _ = child.kill();
    }
    let _ = child.wait();
}

fn monitor(target: &str, layout: &str, passive: bool) -> Result<(), String> {
    let channels = channel_map(layout)?;
    let wake = stop_signals().map_err(|error| error.to_string())?;
    let mut properties = String::from("media.category=Monitor stream.monitor=true");
    if passive {
        // Do not wake an idle microphone and move network playback to its clock.
        properties.push_str(" node.passive=true");
    }
    let rate = sample_rate(channels.len());
    // Match the source layout explicitly: unconstrained captures negotiate stereo
    // even for Pro Audio AUX microphones. This does not reconfigure the device.
    let command: Vec<String> = [
        "pw-record",
        "--raw",
        "--format",
        "f32",
        "--rate",
        &rate.to_string(),
        "--channels",
        &channels.len().to_string(),
        "--channel-map",
        &format!("[ {} ]", channels.join(" ")),
        "--target",
        target,
        "--properties",
        &properties,
        "-",
    ]
    .iter()
    .map(|arg| arg.to_string())
    .collect();
    let mut child = spawn(&command).map_err(|error| crate::run::os_error(&error, "pw-record"))?;
    let mut stdout = child.stdout.take().expect("piped stdout");
    let result = capture(
        &mut stdout,
        &wake,
        &mut child,
        rate / 20 * channels.len() * 4,
        passive,
    );
    drop(stdout);
    release(&mut child);
    result
}

fn capture(
    stdout: &mut ChildStdout,
    wake: &PipeReader,
    child: &mut Child,
    block_size: usize,
    passive: bool,
) -> Result<(), String> {
    let mut out = io::stdout().lock();
    let mut emit = |level: f64| -> Result<(), String> {
        writeln!(out, "{level:.6}")
            .and_then(|()| out.flush())
            .map_err(|error| error.to_string())
    };
    // 20 level updates per second whatever the rate.
    let mut pending: Vec<u8> = Vec::with_capacity(block_size * 2);
    let mut chunk = vec![0u8; block_size];
    let mut last_data = Instant::now();
    loop {
        match wait(stdout, wake).map_err(|error| error.to_string())? {
            Ready::Stop => return Ok(()),
            Ready::Idle => {
                if !matches!(child.try_wait(), Ok(None)) {
                    return Err("microphone capture exited".into());
                }
                if passive {
                    // An unused microphone produces no samples; clear the last level.
                    pending.clear();
                    emit(0.0)?;
                } else if last_data.elapsed() > STALL {
                    return Err("microphone capture timed out".into());
                }
            }
            Ready::Data => {
                let read = match stdout.read(&mut chunk) {
                    Ok(read) => read,
                    Err(error) if error.kind() == ErrorKind::Interrupted => continue,
                    Err(error) => return Err(error.to_string()),
                };
                if read == 0 {
                    return Err("microphone capture ended".into());
                }
                pending.extend_from_slice(&chunk[..read]);
                last_data = Instant::now();
                let mut start = 0;
                while pending.len() - start >= block_size {
                    emit(peak_level(&pending[start..start + block_size])?)?;
                    start += block_size;
                }
                pending.drain(..start);
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn floats(values: &[f32]) -> Vec<u8> {
        values
            .iter()
            .flat_map(|value| value.to_le_bytes())
            .collect()
    }

    #[test]
    fn aux_mono_stereo_and_invalid_maps() {
        for value in [
            "AUX0",
            "MONO",
            "FL,FR",
            "AUX0,AUX1",
            "AUX63",
            "AUX10",
            "TRR",
        ] {
            assert_eq!(
                channel_map(value).unwrap(),
                value.split(',').collect::<Vec<_>>()
            );
        }
        for value in [
            "", "AUX64", "AUX01", "AUX", "AUX6a", "FL,", "--help", "FL;exit", "AUX0\n", "fl", " FL",
        ] {
            assert!(channel_map(value).is_err(), "{value:?}");
        }
        assert!(channel_map(&vec!["MONO"; 64].join(",")).is_ok());
        assert!(channel_map(&vec!["MONO"; 65].join(",")).is_err());
    }

    #[test]
    fn peak_scaling_and_bad_samples() {
        assert!((peak_level(&floats(&[0.0, -0.125, 0.01])).unwrap() - 0.5).abs() < 1e-12);
        assert_eq!(peak_level(&floats(&[0.0])).unwrap(), 0.0);
        assert_eq!(peak_level(&floats(&[8.0])).unwrap(), 1.0);
        assert_eq!(peak_level(&[]).unwrap(), 0.0);
        for bad in [f32::NAN, f32::INFINITY, f32::NEG_INFINITY] {
            assert!(peak_level(&floats(&[0.1, bad, 0.2])).is_err());
            assert!(peak_level(&floats(&[bad])).is_err());
        }
        // Python's max() keeps the first of equal values: all -0.0 gives -0.0.
        assert_eq!(
            format!("{:.6}", peak_level(&floats(&[-0.0, -0.0])).unwrap()),
            "-0.000000"
        );
        assert_eq!(
            format!("{:.6}", peak_level(&floats(&[0.0, -0.0])).unwrap()),
            "0.000000"
        );
    }

    #[test]
    fn wide_devices_capture_at_a_lower_rate() {
        assert_eq!(sample_rate(2), 16000);
        assert_eq!(sample_rate(8), 16000);
        assert_eq!(sample_rate(9), 8000);
        assert_eq!(sample_rate(64), 8000);
    }
}

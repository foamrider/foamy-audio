//! `airplay`: lifecycle-safe PipeWire AirPlay (RAOP) discovery and routing
//! (was `airplay_bridge.py`; the contract is in `main.rs`).

use std::ffi::OsString;
use std::io::ErrorKind;
use std::path::{Path, PathBuf};
use std::process::ExitCode;
use std::thread;
use std::time::Duration;

use foamy_helper::{Failure, json};
use serde_json::{Map, Value, json};

use crate::py;
use crate::run::{Completed, Runner, System, last_line};

const PULSE_MODULE: &str = "module-raop-discover";
const PIPEWIRE_MODULE: &str = "libpipewire-module-raop-discover";
const MODULE_PATH: &str = "/usr/lib/pipewire-0.3/libpipewire-module-raop-discover.so";
const TIMEOUT: Duration = Duration::from_secs(12);
/// Largest state file read; a bigger one reads as no session.
const MAX_STATE: u64 = 1 << 20;
const GROUP_PREFIX: &str = "foamy_airplay_group_";

type State = Map<String, Value>;
/// A reply and its exit code.
type Outcome = (Value, u8);

const USAGE: &str = "usage: foamy-audio-helper airplay {start,stop,status,select} …";
/// Marks a failure whose message is a whole reply (see `render`).
const REPLY: &str = "REPLY";

pub fn main(args: Vec<OsString>) -> ExitCode {
    if args.iter().any(|arg| {
        arg.to_str()
            .is_some_and(|arg| arg == "-h" || arg == "--help")
    }) {
        println!("{USAGE}");
        return ExitCode::SUCCESS;
    }
    json::run(
        move || match dispatch(args) {
            (reply, 0) => Ok(reply),
            (reply, code) => Err(Failure::coded(REPLY, reply.to_string()).with_exit_code(code)),
        },
        render,
    )
}

/// The JSON for a failure: a whole reply carried through `Failure`, or an
/// unexpected one (a panic).
fn render(failure: &Failure) -> Value {
    if failure.code == REPLY
        && let Ok(reply) = serde_json::from_str(&failure.message)
    {
        return reply;
    }
    failed(&failure.message)
}

fn failed(detail: &str) -> Value {
    json!({"ok": false, "error": format!("AirPlay helper failed: {detail}")})
}

fn dispatch(args: Vec<OsString>) -> Outcome {
    let mut args = args.into_iter();
    let command = args.next().and_then(|arg| arg.into_string().ok());
    let rest: Vec<OsString> = args.collect();
    let parsed = match command.as_deref() {
        Some("start" | "stop") => py::parse(
            rest,
            &["--restore-id", "--restore-name"],
            &["--skip-restore"],
        )
        .and_then(|args| {
            if command.as_deref() == Some("start") && args.flag("--skip-restore") {
                Err(py::Usage("unrecognized arguments: --skip-restore".into()))
            } else {
                Ok(args)
            }
        }),
        Some("status") => py::parse(rest, &[], &[]),
        Some("select") => py::parse(rest, &["--local-name"], &[]),
        _ => Err(py::Usage("argument command: invalid choice".into())),
    };
    let args = match parsed {
        Ok(args) if command.as_deref() != Some("select") && !args.positional.is_empty() => {
            return usage(&format!(
                "unrecognized arguments: {}",
                args.positional.join(" ")
            ));
        }
        Ok(args) => args,
        Err(py::Usage(message)) => return usage(&message),
    };
    let mut runner = System {
        timeout: TIMEOUT,
        c_locale: false,
    };
    let path = state_path();
    let outcome = match command.as_deref() {
        Some("start") => start(
            args.value("--restore-id").unwrap_or(""),
            args.value("--restore-name").unwrap_or(""),
            &mut runner,
            &path,
            Path::new(MODULE_PATH),
        ),
        Some("stop") => stop(
            args.value("--restore-name").unwrap_or(""),
            args.flag("--skip-restore"),
            &mut runner,
            &path,
        ),
        Some("select") => select(
            &args.positional,
            args.value("--local-name").unwrap_or(""),
            &mut runner,
            &path,
        ),
        _ => status(&mut runner, &path),
    };
    outcome.unwrap_or_else(|detail| (failed(&detail), 1))
}

fn usage(message: &str) -> Outcome {
    (
        json!({"ok": false, "error": format!("{USAGE}: {message}")}),
        2,
    )
}

fn state_path() -> PathBuf {
    if let Some(path) =
        std::env::var_os("FOAMY_AUDIO_AIRPLAY_STATE").filter(|path| !path.is_empty())
    {
        return PathBuf::from(path);
    }
    let runtime = std::env::var_os("XDG_RUNTIME_DIR")
        .filter(|dir| !dir.is_empty())
        .map(PathBuf::from)
        .unwrap_or_else(|| {
            PathBuf::from(format!("/run/user/{}", rustix::process::getuid().as_raw()))
        });
    runtime.join("foamy-audio-airplay.json")
}

fn read_state(path: &Path) -> State {
    foamy_helper::fs::read_file_limited(path, MAX_STATE)
        .ok()
        .and_then(|bytes| serde_json::from_slice::<Value>(&bytes).ok())
        .and_then(|value| match value {
            Value::Object(map) => Some(map),
            _ => None,
        })
        .unwrap_or_default()
}

fn write_state(path: &Path, state: &State) -> Result<(), String> {
    if let Some(parent) = path
        .parent()
        .filter(|parent| !parent.as_os_str().is_empty())
    {
        std::fs::create_dir_all(parent)
            .map_err(|error| format!("cannot create {}: {error}", parent.display()))?;
    }
    let data = serde_json::to_vec(state).map_err(|error| error.to_string())?;
    foamy_helper::fs::write_atomic(path, &data, 0o600).map_err(|error| error.to_string())
}

fn remove_state(path: &Path) -> std::io::Result<()> {
    match std::fs::remove_file(path) {
        Err(error) if error.kind() == ErrorKind::NotFound => Ok(()),
        other => other,
    }
}

/// Runs a pactl step that must succeed: its stripped stdout, or its last
/// diagnostic line as the error.
fn checked(runner: &mut dyn Runner, argv: &[&str]) -> Result<String, String> {
    let result = runner.run(argv)?;
    if result.code != 0 {
        return Err(last_line(&result, &format!("{} failed", argv[0])));
    }
    Ok(py::strip(&result.stdout).to_string())
}

fn parse_json(text: &str, what: &str) -> Result<Value, String> {
    serde_json::from_str(text).map_err(|error| format!("{what}: {error}"))
}

// ---- parsing ---------------------------------------------------------------

pub fn parse_module_ids(output: &str) -> Vec<i64> {
    py::splitlines(output)
        .into_iter()
        .filter_map(|line| {
            let fields: Vec<&str> = py::split_whitespace(line).collect();
            if fields.len() < 2 || (fields[1] != PULSE_MODULE && fields[1] != PIPEWIRE_MODULE) {
                return None;
            }
            py::int(fields[0]).and_then(|id| i64::try_from(id).ok())
        })
        .collect()
}

/// Avahi's `\ddd` byte escapes, then UTF-8 with invalid bytes replaced.
pub fn decode_avahi(text: &str) -> String {
    let bytes = text.as_bytes();
    let mut decoded = Vec::with_capacity(bytes.len());
    let mut at = 0;
    while at < bytes.len() {
        if bytes[at] == b'\\'
            && at + 4 <= bytes.len()
            && bytes[at + 1..at + 4].iter().all(u8::is_ascii_digit)
        {
            let value = (bytes[at + 1] - b'0') as u32 * 100
                + (bytes[at + 2] - b'0') as u32 * 10
                + (bytes[at + 3] - b'0') as u32;
            if value <= 255 {
                decoded.push(value as u8);
            } else {
                decoded.extend_from_slice(&bytes[at..at + 4]);
            }
            at += 4;
        } else {
            decoded.push(bytes[at]);
            at += 1;
        }
    }
    String::from_utf8_lossy(&decoded).into_owned()
}

/// `TXT_FIELD.findall`: `"key=value"` pairs, the value with `\x` escapes
/// kept as written; later keys win.
pub fn txt_fields(text: &str) -> Map<String, Value> {
    let chars: Vec<char> = text.chars().collect();
    let mut fields = Map::new();
    let mut at = 0;
    while at < chars.len() {
        if chars[at] != '"' {
            at += 1;
            continue;
        }
        let key_start = at + 1;
        let mut cursor = key_start;
        while cursor < chars.len() && chars[cursor] != '"' && chars[cursor] != '=' {
            cursor += 1;
        }
        if cursor == key_start || cursor >= chars.len() || chars[cursor] != '=' {
            at += 1;
            continue;
        }
        let key: String = chars[key_start..cursor].iter().collect();
        let value_start = cursor + 1;
        cursor = value_start;
        let end = loop {
            match chars.get(cursor) {
                Some('"') => break Some(cursor),
                Some('\\') => match chars.get(cursor + 1) {
                    Some(next) if *next != '\n' => cursor += 2,
                    _ => break None,
                },
                Some(_) => cursor += 1,
                None => break None,
            }
        };
        match end {
            Some(end) => {
                let value: String = chars[value_start..end].iter().collect();
                fields.insert(key, Value::String(decode_avahi(&value)));
                at = end + 1;
            }
            None => at += 1,
        }
    }
    fields
}

fn parse_record(fields: &[&str]) -> Option<(String, Map<String, Value>)> {
    let port = py::int(fields[8])?;
    if !(1..65536).contains(&port) {
        return None;
    }
    let service = decode_avahi(fields[3]);
    let hostname = decode_avahi(fields[6]);
    let txt = txt_fields(fields[9]);
    let name = match service.split_once('@') {
        Some((_, after)) => after.to_string(),
        None => service.clone(),
    };
    let vendor = if hostname.to_lowercase().starts_with("sonos-") {
        "Sonos"
    } else {
        ""
    };
    let mut receiver = Map::new();
    receiver.insert("name".into(), name.into());
    receiver.insert("hostname".into(), hostname.into());
    receiver.insert("address".into(), fields[7].into());
    receiver.insert("port".into(), (port as i64).into());
    receiver.insert("vendor".into(), vendor.into());
    receiver.insert(
        "model".into(),
        txt.get("am").cloned().unwrap_or_else(|| "".into()),
    );
    Some((service.to_lowercase(), receiver))
}

pub fn parse_avahi_receivers(output: &str) -> Vec<Value> {
    let mut receivers: Vec<(String, Map<String, Value>)> = Vec::new();
    for line in py::splitlines(output) {
        let fields: Vec<&str> = line.splitn(10, ';').collect();
        if fields.len() < 10 || fields[0] != "=" {
            continue;
        }
        // One malformed record must not hide every other speaker.
        let Some((key, receiver)) = parse_record(&fields) else {
            continue;
        };
        let address = |receiver: &Map<String, Value>| {
            receiver["address"].as_str().unwrap_or("").contains(':')
        };
        match receivers.iter_mut().find(|(known, _)| *known == key) {
            // Prefer the IPv4 record: PipeWire puts that address in the RAOP node name.
            Some((_, current)) => {
                if address(current) && !address(&receiver) {
                    *current = receiver;
                }
            }
            None => receivers.push((key, receiver)),
        }
    }
    receivers
        .into_iter()
        .map(|(_, receiver)| Value::Object(receiver))
        .collect()
}

// ---- steps -----------------------------------------------------------------

fn discover(runner: &mut dyn Runner) -> Result<Vec<Value>, String> {
    let result = runner.run(&["avahi-browse", "-rtp", "_raop._tcp"])?;
    Ok(if result.code == 0 {
        parse_avahi_receivers(&result.stdout)
    } else {
        Vec::new()
    })
}

fn module_ids(runner: &mut dyn Runner) -> Result<Result<Vec<i64>, String>, String> {
    let result = runner.run(&["pactl", "list", "modules", "short"])?;
    Ok(if result.code != 0 {
        Err(last_line(&result, "Could not inspect PipeWire modules"))
    } else {
        Ok(parse_module_ids(&result.stdout))
    })
}

fn route(name: &str, runner: &mut dyn Runner) -> Result<(), String> {
    checked(runner, &["pactl", "set-default-sink", name])?;
    // WirePlumber applies default metadata asynchronously after pactl returns.
    let mut applied = false;
    for _ in 0..20 {
        if checked(runner, &["pactl", "get-default-sink"])? == name {
            applied = true;
            break;
        }
        thread::sleep(Duration::from_millis(100));
    }
    if !applied {
        return Err("The selected output did not become the default".into());
    }
    let streams = parse_json(
        &checked(runner, &["pactl", "-f", "json", "list", "sink-inputs"])?,
        "invalid sink-input list",
    )?;
    let streams = streams
        .as_array()
        .ok_or("invalid sink-input list: not a list")?;
    for stream in streams {
        let stream = stream
            .as_object()
            .ok_or("invalid sink-input list: not an object")?;
        let app = match stream.get("properties") {
            None => None,
            Some(Value::Object(properties)) => properties.get("application.name"),
            Some(_) => return Err("invalid sink-input list: properties is not an object".into()),
        };
        // Processing and combine streams must stay on their physical targets.
        if let Some(app) = app
            && py::truthy(app)
            && *app != "EasyEffects"
        {
            let index = stream
                .get("index")
                .ok_or("invalid sink-input list: a stream has no index")?;
            checked(
                runner,
                &["pactl", "move-sink-input", &py::str_of(index), name],
            )?;
        }
    }
    Ok(())
}

fn remove_group(state: &State, runner: &mut dyn Runner) -> Result<(), String> {
    let Some(module_id) = py::integer(state.get("groupModuleId")) else {
        return Ok(());
    };
    let id = module_id.to_string();
    let sink = format!(
        "sink_name={}",
        py::str_of(state.get("groupName").unwrap_or(&Value::Null))
    );
    let modules = checked(runner, &["pactl", "list", "modules", "short"])?;
    // IDs can be reused after a server restart; verify our unique sink name too.
    for line in py::splitlines(&modules) {
        let fields: Vec<&str> = line.split('\t').collect();
        if fields.len() >= 3
            && fields[0] == id
            && fields[1] == "module-combine-sink"
            && py::split_whitespace(fields[2]).any(|argument| argument == sink)
        {
            checked(runner, &["pactl", "unload-module", &id])?;
        }
    }
    Ok(())
}

fn sink_name(sink: &Value) -> Result<&str, String> {
    sink.get("name")
        .and_then(Value::as_str)
        .ok_or_else(|| "invalid sink list: a sink has no name".to_string())
}

fn refuse(message: &str) -> Result<Outcome, String> {
    Ok((json!({"ok": false, "error": message}), 1))
}

pub fn select(
    names: &[String],
    local_name: &str,
    runner: &mut dyn Runner,
    path: &Path,
) -> Result<Outcome, String> {
    let mut state = read_state(path);
    let mut unique: Vec<String> = Vec::new();
    for name in names {
        if !unique.contains(name) {
            unique.push(name.clone());
        }
    }
    let names = unique;
    if !local_name.is_empty() && !names.is_empty() {
        return refuse("Choose a local output or AirPlay speakers, not both.");
    }
    let sinks = parse_json(
        &checked(runner, &["pactl", "-f", "json", "list", "sinks"])?,
        "invalid sink list",
    )?;
    let sinks = sinks.as_array().ok_or("invalid sink list: not a list")?;
    let mut sink_names = Vec::with_capacity(sinks.len());
    for sink in sinks {
        sink_names.push(sink_name(sink)?);
    }
    let airplay_name = local_name.starts_with("raop_sink.") || local_name.starts_with(GROUP_PREFIX);
    if !local_name.is_empty() && (airplay_name || !sink_names.contains(&local_name)) {
        return refuse("The local output is no longer available.");
    }
    if names.iter().any(|name| {
        !sink_names
            .iter()
            .any(|sink| sink.starts_with("raop_sink.") && sink == name)
    }) {
        return refuse("An AirPlay speaker is no longer available. Reopen the panel.");
    }
    let mut target = match names.first() {
        Some(name) => name.clone(),
        None if !local_name.is_empty() => local_name.to_string(),
        None => py::or_value(state.get("restoreName"))
            .map(py::str_of)
            .unwrap_or_default(),
    };
    if target.is_empty() {
        return refuse("No local output is available");
    }
    let mut group = State::new();
    if names.len() > 1 {
        let group_name = format!("{GROUP_PREFIX}{}", std::process::id());
        let sink_name = format!("sink_name={group_name}");
        let sinks = format!("sinks={}", names.join(","));
        let id = checked(
            runner,
            &[
                "pactl",
                "load-module",
                "module-combine-sink",
                &sink_name,
                &sinks,
                "latency_compensate=true",
                "sink_properties=device.description=\"AirPlay group\"",
            ],
        )?;
        let module_id = py::int(&id)
            .and_then(|id| i64::try_from(id).ok())
            .ok_or_else(|| format!("invalid literal for int() with base 10: '{id}'"))?;
        group.insert("groupModuleId".into(), module_id.into());
        group.insert("groupName".into(), group_name.clone().into());
        target = group_name;
    }
    let previous = checked(runner, &["pactl", "get-default-sink"])?;
    if let Err(error) = route(&target, runner) {
        // Roll back before removing a new group so apps never target a dead sink.
        let mut error = error;
        if let Err(rollback) = route(&previous, runner) {
            error = rollback;
        }
        if let Err(cleanup) = remove_group(&group, runner) {
            error = cleanup;
        }
        return Err(error);
    }
    remove_group(&state, runner)?;
    state.remove("groupModuleId");
    state.remove("groupName");
    state.extend(group);
    state.insert("selectedNames".into(), json!(names));
    if !local_name.is_empty() {
        state.insert("restoreName".into(), local_name.into());
        let index = sinks
            .iter()
            .find(|sink| sink.get("name").and_then(Value::as_str) == Some(local_name))
            .and_then(|sink| sink.get("index"))
            .ok_or("invalid sink list: the local output has no index")?;
        state.insert("restoreId".into(), py::str_of(index).into());
    }
    write_state(path, &state)?;
    Ok((
        json!({"ok": true, "error": "", "selectedNames": names, "target": target}),
        0,
    ))
}

pub fn start(
    restore_id: &str,
    restore_name: &str,
    runner: &mut dyn Runner,
    path: &Path,
    module_path: &Path,
) -> Result<Outcome, String> {
    let current = read_state(path);
    let existing = match module_ids(runner)? {
        Ok(ids) => ids,
        Err(error) => return Ok((json!({"ok": false, "error": error}), 1)),
    };
    let remembered = py::integer(current.get("moduleId"));
    let (module_id, owned) = match remembered {
        Some(id) if existing.contains(&id) => {
            (id, current.get("owned") == Some(&Value::Bool(true)))
        }
        // Reuse a module enabled elsewhere, but never unload what this panel did not create.
        _ if !existing.is_empty() => (existing[0], false),
        _ => {
            if !std::fs::metadata(module_path).is_ok_and(|meta| meta.is_file()) {
                return Ok((
                    json!({"ok": false, "error": "AirPlay support is not installed (pipewire-zeroconf)"}),
                    2,
                ));
            }
            let result = runner.run(&["pactl", "load-module", PULSE_MODULE])?;
            if result.code != 0 {
                let code = u8::try_from(result.code)
                    .ok()
                    .filter(|&code| code != 0)
                    .unwrap_or(1);
                return Ok((
                    json!({"ok": false, "error": last_line(&result, "Could not start AirPlay discovery")}),
                    code,
                ));
            }
            match py::int(&result.stdout).and_then(|id| i64::try_from(id).ok()) {
                Some(id) => (id, true),
                None => {
                    return Ok((
                        json!({"ok": false, "error": "PipeWire returned an invalid AirPlay module id"}),
                        1,
                    ));
                }
            }
        }
    };
    let peers = discover(runner)?;
    let remembered_or = |argument: &str, key: &str| -> String {
        if !argument.is_empty() {
            argument.to_string()
        } else {
            py::or_value(current.get(key))
                .map(py::str_of)
                .unwrap_or_default()
        }
    };
    let mut payload = State::new();
    payload.insert("moduleId".into(), module_id.into());
    payload.insert("owned".into(), owned.into());
    payload.insert(
        "restoreId".into(),
        remembered_or(restore_id, "restoreId").into(),
    );
    payload.insert(
        "restoreName".into(),
        remembered_or(restore_name, "restoreName").into(),
    );
    payload.insert("peers".into(), Value::Array(peers));
    for key in ["groupModuleId", "groupName", "selectedNames"] {
        if let Some(value) = current.get(key) {
            payload.insert(key.into(), value.clone());
        }
    }
    write_state(path, &payload)?;
    let mut reply = State::new();
    reply.insert("ok".into(), true.into());
    reply.insert("error".into(), "".into());
    reply.extend(payload);
    Ok((Value::Object(reply), 0))
}

pub fn stop(
    restore_name: &str,
    skip_restore: bool,
    runner: &mut dyn Runner,
    path: &Path,
) -> Result<Outcome, String> {
    let current = read_state(path);
    let target = if !restore_name.is_empty() {
        restore_name.to_string()
    } else {
        py::or_value(current.get("restoreName"))
            .map(py::str_of)
            .unwrap_or_default()
    };
    let mut errors: Vec<String> = Vec::new();
    if !skip_restore && !target.is_empty() {
        route(&target, runner)?;
    }
    remove_group(&current, runner)?;
    let module_id = py::integer(current.get("moduleId"));
    if current.get("owned") == Some(&Value::Bool(true))
        && let Some(module_id) = module_id
    {
        match module_ids(runner)? {
            Err(error) => errors.push(error),
            Ok(existing) if existing.contains(&module_id) => {
                let result: Completed =
                    runner.run(&["pactl", "unload-module", &module_id.to_string()])?;
                if result.code != 0 {
                    errors.push(last_line(&result, "Could not stop AirPlay discovery"));
                }
            }
            Ok(_) => {}
        }
    }
    // Keep ownership information when teardown fails so a retry can clean up.
    if errors.is_empty()
        && let Err(error) = remove_state(path)
    {
        errors.push(format!("Could not clear AirPlay session state: {error}"));
    }
    let ok = errors.is_empty();
    Ok((
        json!({"ok": ok, "error": errors.join("; "), "restoreName": target}),
        if ok { 0 } else { 1 },
    ))
}

pub fn status(runner: &mut dyn Runner, path: &Path) -> Result<Outcome, String> {
    let mut current = read_state(path);
    let existing = match module_ids(runner)? {
        Ok(ids) => ids,
        Err(error) => return Ok((json!({"ok": false, "active": false, "error": error}), 1)),
    };
    let active = py::integer(current.get("moduleId")).is_some_and(|id| existing.contains(&id));
    if !current.is_empty() && !active {
        remove_state(path).map_err(|error| error.to_string())?;
        current = State::new();
    }
    let mut reply = State::new();
    reply.insert("ok".into(), true.into());
    reply.insert("active".into(), active.into());
    reply.insert("error".into(), "".into());
    reply.extend(current);
    Ok((Value::Object(reply), 0))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::run::tests::Script;
    use std::sync::atomic::{AtomicU32, Ordering};

    struct Dir(PathBuf);

    impl Dir {
        fn new() -> Dir {
            static COUNT: AtomicU32 = AtomicU32::new(0);
            let dir = std::env::temp_dir().join(format!(
                "foamy-audio-airplay-{}-{}",
                std::process::id(),
                COUNT.fetch_add(1, Ordering::Relaxed)
            ));
            std::fs::create_dir_all(&dir).unwrap();
            Dir(dir)
        }
    }

    impl Drop for Dir {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.0);
        }
    }

    #[test]
    fn module_listing_accepts_pulse_and_native_raop_names() {
        let output = "\n536870916\tmodule-raop-discover\n27 libpipewire-module-raop-discover { }\nnot-an-id module-raop-discover\n9 module-null-sink\n";
        assert_eq!(parse_module_ids(output), [536870916, 27]);
    }

    #[test]
    fn avahi_escapes() {
        assert_eq!(decode_avahi(r"Kj\195\184kken"), "Kjøkken");
        assert_eq!(decode_avahi(r"a\064b"), "a@b");
        assert_eq!(decode_avahi(r"x\999y\12"), r"x\999y\12");
        assert_eq!(decode_avahi(r"\255"), "\u{fffd}");
        assert_eq!(decode_avahi(r"end\046"), "end.");
    }

    #[test]
    fn txt_records() {
        let fields = txt_fields(r#""cn=0,1" "am=Beam" "q=a\"b" "=x" "am=One" junk "k=v"#);
        assert_eq!(fields.get("am"), Some(&json!("One")));
        assert_eq!(fields.get("cn"), Some(&json!("0,1")));
        assert_eq!(fields.get("q"), Some(&json!(r#"a\"b"#)));
        assert!(!fields.contains_key("k") && !fields.contains_key(""));
        // An unterminated pair does not stop later ones from matching.
        assert_eq!(txt_fields(r#""bad "am=X""#).get("am"), Some(&json!("X")));
    }

    #[test]
    fn avahi_records_become_deduplicated_receivers() {
        let output = "=;eth0;IPv6;020000000002\\064Stue;AirTunes Remote Audio;local;Sonos-020000000002.local;192.0.2.17;7000;\"cn=0,1\" \"am=Beam\"\n\
=;eth0;IPv4;020000000002\\064Stue;AirTunes Remote Audio;local;Sonos-020000000002.local;192.0.2.17;7000;\"cn=0,1\" \"am=Beam\"\n";
        assert_eq!(
            parse_avahi_receivers(output),
            [
                json!({"name": "Stue", "hostname": "Sonos-020000000002.local", "address": "192.0.2.17",
                    "port": 7000, "vendor": "Sonos", "model": "Beam"})
            ]
        );
        let malformed = "=;eth0;IPv4;Kitchen;AirTunes Remote Audio;local;kitchen.local;192.0.2.20;notaport;\"am=One\"\n\
=;eth0;IPv4;Hall;AirTunes Remote Audio;local;hall.local;192.0.2.21;99999;\"am=One\"\n\
=;eth0;IPv4;Stue;AirTunes Remote Audio;local;stue.local;192.0.2.17;7000;\"am=Beam\"\n";
        let receivers = parse_avahi_receivers(malformed);
        assert_eq!(receivers.len(), 1);
        assert_eq!(receivers[0]["name"], "Stue");
    }

    #[test]
    fn failed_default_verification_is_reported_before_moving_apps() {
        let mut runner = Script::new().ok("");
        for _ in 0..20 {
            runner = runner.ok("some_other_sink");
        }
        assert_eq!(
            route("raop_sink.test", &mut runner).unwrap_err(),
            "The selected output did not become the default"
        );
        assert_eq!(runner.calls.len(), 21);
    }

    #[test]
    fn route_preserves_processing_streams() {
        let streams = json!([{"index": 1, "properties": {}},
                             {"index": 2, "properties": {"application.name": "EasyEffects"}},
                             {"index": 3, "properties": {"application.name": "Music"}}]);
        let mut runner = Script::new()
            .ok("")
            .ok("speaker")
            .ok(&streams.to_string())
            .ok("");
        route("speaker", &mut runner).unwrap();
        assert_eq!(
            runner.calls[3],
            ["pactl", "move-sink-input", "3", "speaker"]
        );
    }

    #[test]
    fn group_cleanup_never_unloads_reused_module_id() {
        let mut state = State::new();
        state.insert("groupModuleId".into(), 42.into());
        state.insert("groupName".into(), "foamy_airplay_group_1".into());
        let mut runner = Script::new().ok("42\tmodule-combine-sink\tsink_name=someone_else\n");
        remove_group(&state, &mut runner).unwrap();
        assert_eq!(runner.calls.len(), 1);
        // Not an integer: nothing to look up.
        state.insert("groupModuleId".into(), "42".into());
        let mut runner = Script::new();
        remove_group(&state, &mut runner).unwrap();
        assert!(runner.calls.is_empty());
    }

    #[test]
    fn missing_pipewire_support_is_actionable() {
        let dir = Dir::new();
        let mut runner = Script::new().ok("");
        let (reply, code) = start(
            "",
            "",
            &mut runner,
            &dir.0.join("state.json"),
            &dir.0.join("missing.so"),
        )
        .unwrap();
        assert_eq!(code, 2);
        assert_eq!(
            reply["error"],
            "AirPlay support is not installed (pipewire-zeroconf)"
        );
    }

    #[test]
    fn start_loads_one_owned_module_and_remembers_local_output() {
        let dir = Dir::new();
        let module = dir.0.join("libpipewire-module-raop-discover.so");
        std::fs::write(&module, b"").unwrap();
        let state = dir.0.join("state.json");
        let mut runner = Script::new().ok("").ok("536870916\n").ok("");
        let (reply, code) =
            start("62", "alsa_output.creative", &mut runner, &state, &module).unwrap();
        assert_eq!(code, 0);
        assert_eq!(reply["owned"], true);
        assert_eq!(reply["moduleId"], 536870916);
        assert_eq!(
            runner.calls[1],
            ["pactl", "load-module", "module-raop-discover"]
        );
        assert_eq!(read_state(&state)["restoreName"], "alsa_output.creative");
        // A failed load passes pactl's status on, never as 126/127 or 0.
        for (status, expected) in [(3, 3), (127, 127), (-9, 1)] {
            let mut runner = Script::new().ok("").fail(status, "Failure: nope\n");
            let (reply, code) =
                start("", "", &mut runner, &dir.0.join("other.json"), &module).unwrap();
            assert_eq!(
                (reply["error"].as_str(), code),
                (Some("Failure: nope"), expected)
            );
        }
    }

    #[test]
    fn rollback_reports_the_last_failure_and_removes_the_new_group() {
        let dir = Dir::new();
        let sinks =
            json!([{"index": 1, "name": "raop_sink.a"}, {"index": 2, "name": "raop_sink.b"}]);
        let mut runner = Script::new()
            .ok(&sinks.to_string())
            .ok("77")
            .ok("local")
            .fail(1, "first\n")
            .fail(1, "second\n")
            .error("third");
        let error = select(
            &["raop_sink.a".into(), "raop_sink.b".into()],
            "",
            &mut runner,
            &dir.0.join("s.json"),
        )
        .unwrap_err();
        assert_eq!(error, "third");
        assert_eq!(runner.calls[5], ["pactl", "list", "modules", "short"]);
    }

    #[test]
    fn tool_errors_propagate() {
        let dir = Dir::new();
        let mut runner = Script::new().error("[Errno 2] No such file or directory: 'pactl'");
        assert_eq!(
            status(&mut runner, &dir.0.join("s.json")).unwrap_err(),
            "[Errno 2] No such file or directory: 'pactl'"
        );
    }
}

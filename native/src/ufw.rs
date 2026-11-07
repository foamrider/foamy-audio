//! `ufw`: check, add and remove UFW rules that let AirPlay speakers reach
//! PipeWire (was `ufw_check.py`; the contract is in `main.rs`).
//!
//! PipeWire's RAOP sink receives timing and control traffic from each speaker
//! on UDP 6001-6002. The rule added here is scoped to the speakers' network:
//! only the local subnet (on the interface that reaches them) may send to
//! those ports, so they stay closed on any other network the computer joins
//! later. Only `/usr/bin/ufw` is elevated (`/usr/bin/pkexec`), always with
//! arguments built here.

use std::ffi::OsString;
use std::net::IpAddr;
use std::path::{Path, PathBuf};
use std::process::ExitCode;
use std::time::Duration;

use foamy_helper::{Failure, json};
use serde_json::{Map, Value, json};

use crate::py;
use crate::run::{Runner, System};

const PORTS: [u16; 2] = [6001, 6002];
const ALL_PORTS: u8 = 0b11;
const PORT_RANGE: &str = "6001:6002";
const COMMENT: &str = "Foamy Audio AirPlay";
const PKEXEC: &str = "/usr/bin/pkexec";
const UFW: &str = "/usr/bin/ufw";
const CANCELLED: &str = "Administrator authorization was cancelled or denied.";
const MAX_RECORD: u64 = 1 << 20;
const USAGE: &str = "usage: foamy-audio-helper ufw {verify,open,remove} [--peer PEER] [--legacy]";
const REPLY: &str = "REPLY";

// ---- networks --------------------------------------------------------------

/// An IP network with its host bits cleared (Python's `ip_network`).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Net {
    pub addr: IpAddr,
    pub prefix: u8,
}

fn max_prefix(addr: IpAddr) -> u8 {
    if addr.is_ipv4() { 32 } else { 128 }
}

fn masked(addr: IpAddr, prefix: u8) -> IpAddr {
    match addr {
        IpAddr::V4(v4) => {
            let mask = u32::MAX.checked_shl(32 - u32::from(prefix)).unwrap_or(0);
            IpAddr::V4((u32::from(v4) & mask).into())
        }
        IpAddr::V6(v6) => {
            let mask = u128::MAX.checked_shl(128 - u32::from(prefix)).unwrap_or(0);
            IpAddr::V6((u128::from(v6) & mask).into())
        }
    }
}

impl Net {
    pub fn host(addr: IpAddr) -> Net {
        Net {
            addr,
            prefix: max_prefix(addr),
        }
    }

    pub fn contains(&self, addr: IpAddr) -> bool {
        addr.is_ipv4() == self.addr.is_ipv4() && masked(addr, self.prefix) == self.addr
    }
}

impl std::fmt::Display for Net {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{}/{}", self.addr, self.prefix)
    }
}

/// `ip_address(text)`: IPv4 dotted quads or IPv6 (no zone IDs).
pub fn address(text: &str) -> Option<IpAddr> {
    text.parse().ok()
}

/// A prefix from an IPv4 netmask (`255.255.255.0`) or hostmask (`0.0.0.255`).
fn mask_prefix(text: &str) -> Option<u8> {
    let IpAddr::V4(mask) = address(text)? else {
        return None;
    };
    let contiguous = |bits: u32| {
        let zeros = bits.trailing_zeros();
        let prefix = 32 - zeros;
        let ones = bits.checked_shr(zeros).unwrap_or(0);
        let all = 1u64.checked_shl(prefix).map_or(u64::MAX, |v| v - 1);
        (u64::from(ones) == all).then_some(prefix as u8)
    };
    let bits = u32::from(mask);
    contiguous(bits).or_else(|| contiguous(!bits))
}

/// `ip_network(text, strict)`: `address[/prefix]`; IPv4 also takes a
/// netmask or hostmask. `strict` refuses host bits.
pub fn network(text: &str, strict: bool) -> Option<Net> {
    let mut parts = text.split('/');
    let addr = address(parts.next()?)?;
    let prefix = match parts.next() {
        None => max_prefix(addr),
        Some(prefix) if !prefix.is_empty() && prefix.bytes().all(|b| b.is_ascii_digit()) => {
            let value: u64 = prefix.parse().ok()?;
            u8::try_from(value)
                .ok()
                .filter(|&p| p <= max_prefix(addr))?
        }
        Some(prefix) if addr.is_ipv4() => mask_prefix(prefix)?,
        Some(_) => return None,
    };
    if parts.next().is_some() {
        return None;
    }
    let net = masked(addr, prefix);
    if strict && net != addr {
        return None;
    }
    Some(Net { addr: net, prefix })
}

/// Python's `repr()` of a string, for error messages.
fn repr(text: &str) -> String {
    let quote = if text.contains('\'') && !text.contains('"') {
        '"'
    } else {
        '\''
    };
    let mut out = String::from(quote);
    for c in text.chars() {
        match c {
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            c if c == quote => {
                out.push('\\');
                out.push(c);
            }
            c if (c as u32) < 0x20 || c as u32 == 0x7f => {
                out.push_str(&format!("\\x{:02x}", c as u32))
            }
            c => out.push(c),
        }
    }
    out.push(quote);
    out
}

/// `[A-Za-z0-9_.-]{1,15}`.
pub fn valid_interface(name: &str) -> bool {
    (1..=15).contains(&name.len())
        && name
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b == b'_' || b == b'.' || b == b'-')
}

// ---- record ----------------------------------------------------------------

/// One rule this helper added: an interface and a network.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Scope {
    pub interface: String,
    pub network: String,
}

impl Scope {
    fn to_json(&self) -> Value {
        json!({"interface": self.interface, "network": self.network})
    }

    fn rule_arguments(&self) -> Vec<String> {
        [
            "in",
            "on",
            &self.interface,
            "proto",
            "udp",
            "from",
            &self.network,
            "to",
            "any",
            "port",
            PORT_RANGE,
        ]
        .iter()
        .map(|s| s.to_string())
        .collect()
    }

    pub fn allow_command(&self) -> Vec<String> {
        let mut argv = vec![PKEXEC.to_string(), UFW.to_string(), "allow".to_string()];
        argv.extend(self.rule_arguments());
        argv.extend(["comment".to_string(), COMMENT.to_string()]);
        argv
    }

    pub fn delete_command(&self) -> Vec<String> {
        let mut argv = vec![
            PKEXEC.to_string(),
            UFW.to_string(),
            "delete".to_string(),
            "allow".to_string(),
        ];
        argv.extend(self.rule_arguments());
        argv
    }
}

const STATUS_COMMAND: [&str; 4] = [PKEXEC, UFW, "status", "verbose"];
/// The unrestricted rule earlier versions added (from anywhere, every interface).
const LEGACY_DELETE_COMMAND: [&str; 5] = [PKEXEC, UFW, "delete", "allow", "6001:6002/udp"];

fn record_path() -> PathBuf {
    let set = |name: &str| std::env::var_os(name).filter(|value| !value.is_empty());
    if let Some(path) = set("FOAMY_AUDIO_FIREWALL_STATE") {
        return PathBuf::from(path);
    }
    let base = set("XDG_STATE_HOME").map(PathBuf::from).unwrap_or_else(|| {
        PathBuf::from(set("HOME").unwrap_or_else(|| "/".into())).join(".local/state")
    });
    base.join("foamy-audio/firewall.json")
}

fn valid_scope(rule: &Value) -> Option<Scope> {
    let interface = rule.get("interface")?.as_str()?;
    let net = rule.get("network")?.as_str()?;
    (valid_interface(interface) && network(net, true).is_some()).then(|| Scope {
        interface: interface.into(),
        network: net.into(),
    })
}

pub fn read_rules(path: &Path) -> Vec<Scope> {
    let Some(payload) = foamy_helper::fs::read_file_limited(path, MAX_RECORD)
        .ok()
        .and_then(|bytes| serde_json::from_slice::<Value>(&bytes).ok())
    else {
        return Vec::new();
    };
    match payload.get("rules") {
        Some(Value::Array(rules)) => rules.iter().filter_map(valid_scope).collect(),
        _ => Vec::new(),
    }
}

fn write_rules(path: &Path, rules: &[Scope]) -> Result<(), String> {
    if let Some(parent) = path
        .parent()
        .filter(|parent| !parent.as_os_str().is_empty())
    {
        std::fs::create_dir_all(parent)
            .map_err(|error| format!("cannot create {}: {error}", parent.display()))?;
    }
    let payload = json!({"rules": rules.iter().map(Scope::to_json).collect::<Vec<_>>()});
    foamy_helper::fs::write_atomic(path, payload.to_string().as_bytes(), 0o600)
        .map_err(|error| error.to_string())
}

// ---- tools -----------------------------------------------------------------

fn run_local(runner: &mut dyn Runner, argv: &[&str]) -> Result<String, String> {
    let result = runner.run(argv)?;
    if result.code != 0 {
        let detail = py::strip(result.diagnostics());
        return Err(if detail.is_empty() {
            format!("{} failed", argv[0])
        } else {
            detail.to_string()
        });
    }
    Ok(result.stdout)
}

fn run_ufw(runner: &mut dyn Runner, argv: &[&str]) -> Result<String, String> {
    // Elevate only the system-owned UFW executable, never this helper.
    debug_assert!(argv[0] == PKEXEC && argv[1] == UFW);
    let result = runner.run(argv)?;
    if result.code == 126 || result.code == 127 {
        return Err(CANCELLED.into());
    }
    if result.code != 0 {
        let detail = py::strip(result.diagnostics());
        return Err(if detail.is_empty() {
            "UFW failed.".into()
        } else {
            detail.to_string()
        });
    }
    Ok(result.stdout)
}

fn strings(argv: &[String]) -> Vec<&str> {
    argv.iter().map(String::as_str).collect()
}

fn parse_json(text: &str) -> Result<Value, String> {
    serde_json::from_str(text).map_err(|error| error.to_string())
}

/// The interface and network through which this computer reaches a speaker.
pub fn scope_for(peer: IpAddr, runner: &mut dyn Runner) -> Result<Scope, String> {
    let shown = peer.to_string();
    let routes = parse_json(&run_local(runner, &["ip", "-j", "route", "get", &shown])?)?;
    let empty = Map::new();
    let route = match &routes {
        routes if !py::truthy(routes) => &empty,
        Value::Array(routes) => routes[0]
            .as_object()
            .ok_or("ip returned an unexpected route")?,
        _ => return Err("ip returned an unexpected route".into()),
    };
    let dev = py::str_of(route.get("dev").unwrap_or(&Value::String(String::new())));
    let interface = dev.split('@').next().unwrap_or("").to_string();
    if !valid_interface(&interface) {
        return Err(format!("No local interface reaches {shown}."));
    }
    // A routed speaker (not on the local subnet) gets a rule for its address only.
    let mut net = Net::host(peer);
    if !route.contains_key("gateway") {
        let family = if peer.is_ipv6() { "-6" } else { "-4" };
        let links = parse_json(&run_local(
            runner,
            &["ip", "-j", family, "addr", "show", "dev", &interface],
        )?)?;
        let unexpected = || "ip returned an unexpected address list".to_string();
        for link in links.as_array().ok_or_else(unexpected)? {
            let link = link.as_object().ok_or_else(unexpected)?;
            let infos = match link.get("addr_info") {
                None => continue,
                Some(Value::Array(infos)) => infos,
                Some(_) => return Err(unexpected()),
            };
            for info in infos {
                let info = info.as_object().ok_or_else(unexpected)?;
                let (Some(local), Some(prefix)) = (info.get("local"), info.get("prefixlen")) else {
                    continue;
                };
                let Some(local) = network(
                    &format!("{}/{}", py::str_of(local), py::str_of(prefix)),
                    false,
                ) else {
                    continue;
                };
                if local.contains(peer) {
                    net = local;
                }
            }
        }
    }
    Ok(Scope {
        interface,
        network: net.to_string(),
    })
}

// ---- status analysis -------------------------------------------------------

#[derive(Debug, Clone, PartialEq, Eq)]
struct Rule {
    action: String,
    ports: u8,
    interface: String,
    network: Option<Net>,
    v6: bool,
    plain_destination: bool,
    owned: bool,
}

/// The ports of PORTS a rule destination covers, and its interface ("" = any).
fn covers_ports(destination: &str) -> (u8, String) {
    let value = destination.replace(" (v6)", "");
    let (mut value, interface) = match value.split_once(" on ") {
        Some((value, interface)) => (value.to_string(), py::strip(interface).to_string()),
        None => (value, String::new()),
    };
    // A destination address can precede the port; it still matters for denies.
    if let Some((_, last)) = value.rsplit_once(' ') {
        value = last.to_string();
    }
    if value.ends_with("/tcp") {
        return (0, interface);
    }
    let value = value.strip_suffix("/udp").unwrap_or(&value);
    if value == "Anywhere" {
        return (ALL_PORTS, interface);
    }
    let digits = |text: &str| !text.is_empty() && text.bytes().all(|b| b.is_ascii_digit());
    let number = |text: &str| text.parse::<u64>().unwrap_or(u64::MAX);
    let mut ports = 0;
    for part in value.split(',') {
        let (low, high) = match part.split_once(':') {
            Some((low, high)) if digits(low) && digits(high) => (number(low), number(high)),
            None if digits(part) => (number(part), number(part)),
            _ => continue,
        };
        for (bit, port) in PORTS.iter().enumerate() {
            if low <= u64::from(*port) && u64::from(*port) <= high {
                ports |= 1 << bit;
            }
        }
    }
    (ports, interface)
}

/// `(.+?)\s+(ALLOW|DENY|REJECT|LIMIT)\s+(IN|OUT|FWD)\s+(.+)`, the whole rule.
fn split_rule(rule: &str) -> Option<(&str, &str, &str, &str)> {
    fn spaces(text: &str) -> Option<&str> {
        let rest = text.trim_start_matches(py::is_space);
        (rest.len() < text.len()).then_some(rest)
    }
    fn word<'a>(text: &'a str, words: &[&'static str]) -> Option<(&'static str, &'a str)> {
        words
            .iter()
            .find(|word| text.starts_with(**word))
            .map(|word| (*word, &text[word.len()..]))
    }
    let tail = |rest: &str| -> Option<(&'static str, &'static str, usize)> {
        let rest = spaces(rest)?;
        let (action, rest) = word(rest, &["ALLOW", "DENY", "REJECT", "LIMIT"])?;
        let (direction, rest) = word(spaces(rest)?, &["IN", "OUT", "FWD"])?;
        let source = spaces(rest)?;
        (!source.is_empty()).then_some((action, direction, source.len()))
    };
    let mut previous_space = true;
    for (at, c) in rule.char_indices() {
        let space = py::is_space(c);
        // The shortest destination ends where a whitespace run starts.
        if space
            && !previous_space
            && let Some((action, direction, source)) = tail(&rule[at..])
        {
            return Some((&rule[..at], action, direction, &rule[rule.len() - source..]));
        }
        previous_space = space;
    }
    None
}

/// `(?:Anywhere|[\d:,]+)(?:/udp)?(?: on \S+)?(?: \(v6\))?`, the whole text.
fn plain_destination(text: &str) -> bool {
    let rest = if let Some(rest) = text.strip_prefix("Anywhere") {
        rest
    } else {
        let end = text
            .find(|c: char| !(c.is_ascii_digit() || c == ':' || c == ','))
            .unwrap_or(text.len());
        if end == 0 {
            return false;
        }
        &text[end..]
    };
    let rest = rest.strip_prefix("/udp").unwrap_or(rest);
    let rest = match rest.strip_prefix(" on ") {
        Some(name) => {
            let end = name.find(py::is_space).unwrap_or(name.len());
            if end == 0 {
                return false;
            }
            &name[end..]
        }
        None => rest,
    };
    let rest = rest.strip_prefix(" (v6)").unwrap_or(rest);
    rest.is_empty()
}

fn parse_rules(output: &str) -> Vec<Rule> {
    let mut rules = Vec::new();
    for line in py::splitlines(output) {
        let (rule, comment) = line.split_once(" # ").unwrap_or((line, ""));
        let Some((destination, action, direction, source)) = split_rule(py::strip(rule)) else {
            continue;
        };
        if direction != "IN" {
            continue;
        }
        let (ports, interface) = covers_ports(destination);
        if ports == 0 {
            continue;
        }
        let source_value = source.replace(" (v6)", "");
        let source_value = py::strip(&source_value);
        let network = if source_value == "Anywhere" {
            None
        } else {
            match network(source_value, false) {
                Some(net) => Some(net),
                None => continue,
            }
        };
        rules.push(Rule {
            action: action.into(),
            ports,
            interface,
            network,
            v6: destination.contains("(v6)") || source.contains("(v6)"),
            // A destination address limits which local address is reachable.
            plain_destination: plain_destination(py::strip(destination)),
            owned: py::strip(comment) == COMMENT,
        });
    }
    rules
}

/// A speaker to check: its address and the interface that reaches it.
pub struct Peer {
    pub address: IpAddr,
    pub interface: String,
}

fn rule_applies(rule: &Rule, peer: &Peer) -> bool {
    if !rule.interface.is_empty() && rule.interface != peer.interface {
        return false;
    }
    match rule.network {
        None => rule.v6 == peer.address.is_ipv6(),
        Some(net) => net.contains(peer.address),
    }
}

pub fn inspect_status(output: &str, peers: &[Peer]) -> Result<Value, String> {
    let details = py::strip(output);
    if output.contains("Status: inactive") {
        return Ok(
            json!({"state": "inactive", "message": "UFW is inactive.", "details": details, "legacy": false}),
        );
    }
    if !output.contains("Status: active") {
        return Err("UFW returned an unrecognized status.".into());
    }
    let rules = parse_rules(output);
    let legacy = rules
        .iter()
        .any(|rule| rule.owned && rule.network.is_none());
    let owned = rules
        .iter()
        .any(|rule| rule.owned && rule.network.is_some());
    let (mut state, mut message) = ("missing", "No rule lets the speakers reach UDP 6001–6002.");
    // An ALLOW from anywhere exposes the ports on every network the computer
    // joins, whatever scoped rules sit next to it, so it is always reported.
    let wide_exposure = rules
        .iter()
        .any(|rule| rule.action == "ALLOW" && rule.network.is_none() && rule.plain_destination);
    if peers.is_empty() {
        if rules.iter().any(|rule| rule.action != "ALLOW") {
            (state, message) = ("conflict", "A blocking UFW rule may affect AirPlay.");
        } else if wide_exposure {
            (state, message) = ("wide", "UDP 6001–6002 is open to every network.");
        } else if owned {
            (state, message) = (
                "present",
                "A Foamy Audio rule exists. Find speakers to check it.",
            );
        }
    } else {
        let (mut scoped_ok, mut wide_ok, mut blocked) = (true, true, false);
        for peer in peers {
            let (mut scoped, mut wide) = (0u8, 0u8);
            for rule in rules.iter().filter(|rule| rule_applies(rule, peer)) {
                if rule.action != "ALLOW" {
                    // Do not promise access when a deny/limit may precede an allow.
                    blocked = true;
                } else if rule.plain_destination {
                    if rule.network.is_none() {
                        wide |= rule.ports;
                    } else {
                        scoped |= rule.ports;
                    }
                }
            }
            scoped_ok = scoped_ok && scoped == ALL_PORTS;
            wide_ok = wide_ok && (scoped | wide) == ALL_PORTS;
        }
        if blocked {
            (state, message) = ("conflict", "A blocking UFW rule may affect AirPlay.");
        } else if wide_ok && wide_exposure {
            (state, message) = ("wide", "UDP 6001–6002 is open to every network.");
        } else if scoped_ok {
            (state, message) = ("open", "The speakers can reach UDP 6001–6002.");
        }
    }
    Ok(json!({"state": state, "message": message, "details": details, "legacy": legacy}))
}

// ---- actions ---------------------------------------------------------------

pub fn verify(
    peers: &[IpAddr],
    local: &mut dyn Runner,
    ufw: &mut dyn Runner,
) -> Result<Value, String> {
    let mut checked = Vec::with_capacity(peers.len());
    for &address in peers {
        checked.push(Peer {
            address,
            interface: scope_for(address, local)?.interface,
        });
    }
    inspect_status(&run_ufw(ufw, &STATUS_COMMAND)?, &checked)
}

pub fn apply(
    peers: &[IpAddr],
    local: &mut dyn Runner,
    ufw: &mut dyn Runner,
    path: &Path,
) -> Result<Value, String> {
    if peers.is_empty() {
        return Ok(
            json!({"state": "nopeers", "message": "No AirPlay speakers found.", "details": ""}),
        );
    }
    let mut scopes: Vec<Scope> = Vec::new();
    for &address in peers {
        let scope = scope_for(address, local)?;
        if !scopes.contains(&scope) {
            scopes.push(scope);
        }
    }
    let mut recorded = read_rules(path);
    let mut details = Vec::new();
    // One authorization per network; nearly always a single home subnet.
    for scope in &scopes {
        details.push(py::strip(&run_ufw(ufw, &strings(&scope.allow_command()))?).to_string());
        if !recorded.contains(scope) {
            recorded.push(scope.clone());
            write_rules(path, &recorded)?;
        }
    }
    Ok(
        json!({"state": "applied", "message": "Rules applied. Verify to check.", "details": details.join("\n"),
              "rules": scopes.iter().map(Scope::to_json).collect::<Vec<_>>()}),
    )
}

pub fn remove(legacy: bool, ufw: &mut dyn Runner, path: &Path) -> Result<Value, String> {
    let mut recorded = read_rules(path);
    if recorded.is_empty() && !legacy {
        return Ok(
            json!({"state": "none", "message": "No Foamy Audio rules to remove.", "details": ""}),
        );
    }
    let mut details = Vec::new();
    for scope in recorded.clone() {
        // "Could not delete non-existent rule" exits 0 too: the rule is gone either way.
        details.push(py::strip(&run_ufw(ufw, &strings(&scope.delete_command()))?).to_string());
        if let Some(at) = recorded.iter().position(|known| *known == scope) {
            recorded.remove(at);
        }
        write_rules(path, &recorded)?;
    }
    if legacy {
        details.push(py::strip(&run_ufw(ufw, &LEGACY_DELETE_COMMAND)?).to_string());
    }
    Ok(json!({"state": "removed", "message": "Rules removed.", "details": details.join("\n")}))
}

// ---- entry -----------------------------------------------------------------

fn error_message(action: &str) -> &'static str {
    match action {
        "open" => "Could not apply UFW rules.",
        "remove" => "Could not remove UFW rules.",
        _ => "Could not complete the UFW check.",
    }
}

pub fn main(args: Vec<OsString>) -> ExitCode {
    if args.iter().any(|arg| {
        arg.to_str()
            .is_some_and(|arg| arg == "-h" || arg == "--help")
    }) {
        println!("{USAGE}");
        return ExitCode::SUCCESS;
    }
    let action = args
        .iter()
        .find_map(|arg| {
            arg.to_str()
                .filter(|arg| ["verify", "open", "remove"].contains(arg))
        })
        .unwrap_or("")
        .to_string();
    let message = error_message(&action);
    json::run(
        move || match dispatch(args) {
            (reply, 0) => Ok(reply),
            (reply, code) => Err(Failure::coded(REPLY, reply.to_string()).with_exit_code(code)),
        },
        move |failure: &Failure| {
            if failure.code == REPLY
                && let Ok(reply) = serde_json::from_str(&failure.message)
            {
                return reply;
            }
            json!({"state": "error", "message": message, "details": failure.message})
        },
    )
}

fn dispatch(args: Vec<OsString>) -> (Value, u8) {
    let args = match py::parse(args, &["--peer"], &["--legacy"]) {
        Ok(args) => args,
        Err(py::Usage(detail)) => return usage(&detail),
    };
    let action = match args.positional.as_slice() {
        [action] if ["verify", "open", "remove"].contains(&action.as_str()) => action.as_str(),
        [] => return usage("the following arguments are required: action"),
        [action] => {
            return usage(&format!(
                "argument action: invalid choice: {}",
                repr(action)
            ));
        }
        [_, extra @ ..] => return usage(&format!("unrecognized arguments: {}", extra.join(" "))),
    };
    let fail = |detail: String| {
        (
            json!({"state": "error", "message": error_message(action), "details": detail}),
            1,
        )
    };
    let mut raw: Vec<String> = Vec::new();
    for peer in args.values("--peer") {
        if !raw.contains(&peer) {
            raw.push(peer);
        }
    }
    let mut peers = Vec::with_capacity(raw.len());
    for peer in &raw {
        match address(peer) {
            Some(addr) => peers.push(addr),
            None => {
                return fail(format!(
                    "{} does not appear to be an IPv4 or IPv6 address",
                    repr(peer)
                ));
            }
        }
    }
    let mut local = System {
        timeout: Duration::from_secs(10),
        c_locale: true,
    };
    let mut ufw = System {
        timeout: Duration::from_secs(120),
        c_locale: true,
    };
    let outcome = match action {
        // Verification is a separate action so applying asks for authorization once.
        "open" => apply(&peers, &mut local, &mut ufw, &record_path()),
        "remove" => remove(args.flag("--legacy"), &mut ufw, &record_path()),
        _ => verify(&peers, &mut local, &mut ufw),
    };
    match outcome {
        Ok(reply) => (reply, 0),
        Err(detail) => fail(detail),
    }
}

fn usage(detail: &str) -> (Value, u8) {
    (
        json!({"state": "error", "message": "Could not complete the UFW check.", "details": format!("{USAGE}: {detail}")}),
        2,
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::run::tests::Script;

    fn ip(text: &str) -> IpAddr {
        text.parse().unwrap()
    }

    fn status(rules: &[&str]) -> String {
        format!(
            "Status: active\nTo                         Action      From\n--                         ------      ----\n{}",
            rules.join("\n")
        )
    }

    fn speaker() -> Peer {
        Peer {
            address: ip("192.0.2.39"),
            interface: "wlan0".into(),
        }
    }

    fn state(rules: &[&str], peers: &[Peer]) -> String {
        inspect_status(&status(rules), peers).unwrap()["state"]
            .as_str()
            .unwrap()
            .to_string()
    }

    #[test]
    fn networks_parse_like_ipaddress() {
        assert_eq!(
            network("192.0.2.5/24", false).unwrap().to_string(),
            "192.0.2.0/24"
        );
        assert_eq!(network("192.0.2.5/24", true), None);
        assert_eq!(
            network("192.0.2.0/024", true).unwrap().to_string(),
            "192.0.2.0/24"
        );
        assert_eq!(
            network("192.0.2.39", true).unwrap().to_string(),
            "192.0.2.39/32"
        );
        assert_eq!(
            network("10.1.2.3/255.255.0.0", false).unwrap().to_string(),
            "10.1.0.0/16"
        );
        assert_eq!(
            network("10.1.2.3/0.0.255.255", false).unwrap().to_string(),
            "10.1.0.0/16"
        );
        assert_eq!(network("0.0.0.0/0", true).unwrap().to_string(), "0.0.0.0/0");
        assert_eq!(
            network("2001:DB8::1/64", false).unwrap().to_string(),
            "2001:db8::/64"
        );
        for bad in [
            "",
            "x",
            "192.0.2.0/33",
            "192.0.2.0/",
            "192.0.2.0/24/1",
            "2001:db8::/ffff::",
            "192.0.2.0/+24",
            "10.0.0.0/255.0.255.0",
            "01.2.3.4",
            "fe80::1%eth0",
        ] {
            assert_eq!(network(bad, false), None, "{bad}");
        }
        assert!(
            network("192.0.2.0/24", true)
                .unwrap()
                .contains(ip("192.0.2.200"))
        );
        assert!(
            !network("192.0.2.0/24", true)
                .unwrap()
                .contains(ip("::ffff:192.0.2.1"))
        );
        assert_eq!(ip("::ffff:192.0.2.1").to_string(), "::ffff:192.0.2.1");
    }

    #[test]
    fn interfaces_and_repr() {
        assert!(
            valid_interface("wlan0")
                && valid_interface("br-1.2_x")
                && !valid_interface("wlan0 from any")
        );
        assert!(!valid_interface("") && !valid_interface("abcdefghijklmnop"));
        assert_eq!(repr("0.0.0.0/0"), "'0.0.0.0/0'");
        assert_eq!(repr("it's"), "\"it's\"");
        assert_eq!(repr("a\nb\\"), "'a\\nb\\\\'");
    }

    #[test]
    fn allow_and_delete_commands_elevate_only_ufw_with_a_scoped_rule() {
        let lan = Scope {
            interface: "wlan0".into(),
            network: "192.0.2.0/24".into(),
        };
        let rule = [
            "in",
            "on",
            "wlan0",
            "proto",
            "udp",
            "from",
            "192.0.2.0/24",
            "to",
            "any",
            "port",
            "6001:6002",
        ];
        let mut allow = vec!["/usr/bin/pkexec", "/usr/bin/ufw", "allow"];
        allow.extend(rule);
        allow.extend(["comment", "Foamy Audio AirPlay"]);
        assert_eq!(lan.allow_command(), allow);
        let mut delete = vec!["/usr/bin/pkexec", "/usr/bin/ufw", "delete", "allow"];
        delete.extend(rule);
        assert_eq!(lan.delete_command(), delete);
    }

    #[test]
    fn rules_split_like_the_regex() {
        assert_eq!(
            split_rule("6001:6002/udp on wlan0      ALLOW IN    192.0.2.0/24"),
            Some(("6001:6002/udp on wlan0", "ALLOW", "IN", "192.0.2.0/24"))
        );
        assert_eq!(
            split_rule("Anywhere (v6) DENY OUT Anywhere (v6)"),
            Some(("Anywhere (v6)", "DENY", "OUT", "Anywhere (v6)"))
        );
        assert_eq!(split_rule("a ALLOWIN b"), None);
        assert_eq!(split_rule("a ALLOW IN"), None);
        assert_eq!(split_rule("ALLOW IN b"), None);
        assert_eq!(
            split_rule("x ALLOW IN y LIMIT OUT z"),
            Some(("x", "ALLOW", "IN", "y LIMIT OUT z"))
        );
        let long = format!("a{}b", " ".repeat(1 << 20));
        assert_eq!(split_rule(&long), None);
    }

    #[test]
    fn destinations() {
        assert_eq!(
            covers_ports("6001:6002/udp on wlan0"),
            (ALL_PORTS, "wlan0".into())
        );
        assert_eq!(covers_ports("6002/udp (v6)"), (0b10, "".into()));
        assert_eq!(covers_ports("192.0.2.10 6001/udp"), (0b01, "".into()));
        assert_eq!(covers_ports("6001:6002/tcp"), (0, "".into()));
        assert_eq!(covers_ports("Anywhere"), (ALL_PORTS, "".into()));
        assert_eq!(
            covers_ports("1:99999999999999999999999"),
            (ALL_PORTS, "".into())
        );
        assert_eq!(covers_ports("6002:6001,x,6001:"), (0, "".into()));
        assert!(plain_destination("6001:6002/udp on wlan0 (v6)"));
        assert!(plain_destination("Anywhere"));
        assert!(!plain_destination("192.0.2.10 6001:6002/udp"));
        assert!(!plain_destination("6001/tcp"));
    }

    #[test]
    fn inspect_cases() {
        let one = || [speaker()];
        assert_eq!(
            state(
                &[
                    "6001:6002/udp on wlan0      ALLOW IN    192.0.2.0/24               # Foamy Audio AirPlay"
                ],
                &one()
            ),
            "open"
        );
        assert_eq!(
            state(
                &[
                    "6001/udp                   ALLOW IN    192.0.2.39",
                    "6002/udp on wlan0          ALLOW IN    192.0.2.0/25"
                ],
                &one()
            ),
            "open"
        );
        let legacy = [
            "6001:6002/udp              ALLOW IN    Anywhere                   # Foamy Audio AirPlay",
            "6001:6002/udp (v6)         ALLOW IN    Anywhere (v6)              # Foamy Audio AirPlay",
        ];
        let result = inspect_status(&status(&legacy), &one()).unwrap();
        assert_eq!(
            (result["state"].as_str(), result["legacy"].as_bool()),
            (Some("wide"), Some(true))
        );
        assert_eq!(state(&legacy, &[]), "wide");
        for rule in [
            "6001:6002/udp on eth0       ALLOW IN    192.0.2.0/24",
            "6001:6002/udp              ALLOW IN    198.51.100.0/24",
            "6001:6002/udp (v6)         ALLOW IN    Anywhere (v6)",
            "192.0.2.10 6001:6002/udp   ALLOW IN    192.0.2.0/24",
        ] {
            assert_eq!(state(&[rule], &one()), "missing", "{rule}");
        }
        let other = Peer {
            address: ip("192.0.2.40"),
            interface: "wlan0".into(),
        };
        assert_eq!(
            state(
                &["6001:6002/udp on wlan0      ALLOW IN    192.0.2.39"],
                &[speaker(), other]
            ),
            "missing"
        );
        assert_eq!(
            state(
                &[
                    "6002/udp                   DENY IN     192.0.2.0/24",
                    "6001:6002/udp on wlan0     ALLOW IN    192.0.2.0/24"
                ],
                &one()
            ),
            "conflict"
        );
        assert_eq!(
            state(
                &[
                    "6002/udp                   DENY IN     198.51.100.0/24",
                    "6001:6002/udp on wlan0     ALLOW IN    192.0.2.0/24"
                ],
                &one()
            ),
            "open"
        );
        assert_eq!(
            state(
                &[
                    "6001:6002/tcp              ALLOW IN    192.0.2.0/24",
                    "6001:6002/udp              ALLOW OUT   192.0.2.0/24"
                ],
                &one()
            ),
            "missing"
        );
        assert_eq!(
            state(
                &[
                    "6001:6002/udp on wlan0      ALLOW IN    192.0.2.0/24               # Foamy Audio AirPlay"
                ],
                &[]
            ),
            "present"
        );
        assert_eq!(state(&[], &[]), "missing");
        assert_eq!(
            inspect_status("Status: inactive", &[]).unwrap()["state"],
            "inactive"
        );
        assert_eq!(
            inspect_status("permission denied", &[]).unwrap_err(),
            "UFW returned an unrecognized status."
        );
    }

    #[test]
    fn scopes() {
        let mut run = Script::new()
            .ok(r#"[{"dst":"192.0.2.39","dev":"wlan0","prefsrc":"192.0.2.10"}]"#)
            .ok(r#"[{"ifname":"wlan0","addr_info":[{"family":"inet","local":"192.0.2.10","prefixlen":24}]}]"#);
        let scope = scope_for(ip("192.0.2.39"), &mut run).unwrap();
        assert_eq!(
            (scope.interface.as_str(), scope.network.as_str()),
            ("wlan0", "192.0.2.0/24")
        );
        assert_eq!(
            run.calls[1],
            ["ip", "-j", "-4", "addr", "show", "dev", "wlan0"]
        );
        let mut run =
            Script::new().ok(r#"[{"dst":"198.51.100.7","gateway":"192.0.2.1","dev":"wlan0"}]"#);
        assert_eq!(
            scope_for(ip("198.51.100.7"), &mut run).unwrap().network,
            "198.51.100.7/32"
        );
        let mut run = Script::new().ok(r#"[{"dst":"192.0.2.39","dev":"wlan0 from any"}]"#);
        assert_eq!(
            scope_for(ip("192.0.2.39"), &mut run).unwrap_err(),
            "No local interface reaches 192.0.2.39."
        );
        let mut run = Script::new().ok("[]");
        assert_eq!(
            scope_for(ip("192.0.2.39"), &mut run).unwrap_err(),
            "No local interface reaches 192.0.2.39."
        );
        let mut run = Script::new().fail(2, "RTNETLINK answers: Network is unreachable\n");
        assert_eq!(
            scope_for(ip("192.0.2.39"), &mut run).unwrap_err(),
            "RTNETLINK answers: Network is unreachable"
        );
    }

    #[test]
    fn ufw_failures() {
        for code in [126, 127] {
            let mut ufw = Script::new().fail(code, "");
            assert_eq!(run_ufw(&mut ufw, &STATUS_COMMAND).unwrap_err(), CANCELLED);
        }
        let mut ufw = Script::new().fail(1, "");
        assert_eq!(
            run_ufw(&mut ufw, &STATUS_COMMAND).unwrap_err(),
            "UFW failed."
        );
        let mut ufw = Script::new().error("Command '[...]' timed out after 120 seconds");
        assert!(
            run_ufw(&mut ufw, &STATUS_COMMAND)
                .unwrap_err()
                .contains("timed out")
        );
        let mut nothing = Script::new();
        assert_eq!(
            apply(
                &[],
                &mut Script::new(),
                &mut nothing,
                Path::new("/nonexistent")
            )
            .unwrap()["state"],
            "nopeers"
        );
        assert!(nothing.calls.is_empty());
    }
}

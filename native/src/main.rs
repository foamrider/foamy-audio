//! `foamy-audio-helper`: Foamy Audio's native helper, one binary with three
//! tools. It replaces `airplay_bridge.py`, `ufw_check.py` and
//! `microphone_peak.py` with the same contracts:
//!
//! ```text
//! foamy-audio-helper airplay start [--restore-id ID] [--restore-name NAME]
//! foamy-audio-helper airplay stop [--restore-id ID] [--restore-name NAME] [--skip-restore]
//! foamy-audio-helper airplay status
//! foamy-audio-helper airplay select [NAME…] [--local-name NAME]
//! foamy-audio-helper ufw verify|open|remove [--peer ADDRESS]… [--legacy]
//! foamy-audio-helper microphone-peak TARGET CHANNELS [--passive]
//! ```
//!
//! Options take `--name value` or `--name=value`, may repeat (the last
//! wins; `--peer` collects), `--` ends them and `-h`/`--help` prints usage
//! (exit 0). Anything else that starts with `-`, a missing or extra argument
//! or a non-UTF-8 argument is a usage error, exit 2: `airplay` and `ufw` then
//! still print their JSON error reply (see below), `microphone-peak` prints
//! usage on stderr. (Python's argparse printed usage on stderr and nothing on
//! stdout, and accepted abbreviated option names.) An unknown tool prints
//! usage on stderr, exit 2.
//!
//! Every child runs with a deadline (`child::Bounded`: its own process
//! group, killed with it on the deadline, `PR_SET_PDEATHSIG`, standard input
//! `/dev/null`, at most 4 MiB per output stream) and the same argv as the
//! Python helpers; PATH lookup for every tool but pkexec/ufw.
//!
//! # `airplay`: PipeWire AirPlay (RAOP) discovery and routing
//!
//! One compact JSON line on stdout for every outcome. Children: `pactl` and
//! `avahi-browse`, 12 s each, with the caller's environment.
//!
//! - `start`: `pactl list modules short`; a line whose second field is
//!   `module-raop-discover` or `libpipewire-module-raop-discover` and whose
//!   first is an integer is a discovery module. The remembered `moduleId` if
//!   listed (its `owned` kept), else the first listed (`owned: false`, never
//!   unloaded by us), else, when
//!   `/usr/lib/pipewire-0.3/libpipewire-module-raop-discover.so` is a file,
//!   `pactl load-module module-raop-discover` (its stdout is the id;
//!   `owned: true`). Then `avahi-browse -rtp _raop._tcp` (a failure is no
//!   peers). The state becomes `{moduleId, owned, restoreId, restoreName,
//!   peers}` plus the remembered `groupModuleId`, `groupName` and
//!   `selectedNames`; the reply is `{"ok":true,"error":"",…state}`.
//!   `restoreId`/`restoreName`: the argument, else the remembered value,
//!   else `""`.
//!   Errors: module listing failed → `{"ok":false,"error":<last line of
//!   stderr, else stdout, else "Could not inspect PipeWire modules">}` exit
//!   1; module file missing → `"AirPlay support is not installed
//!   (pipewire-zeroconf)"` exit 2; load failed → its last output line (else
//!   `"Could not start AirPlay discovery"`), exit = pactl's status (1 if
//!   that is 0, 126 or 127 or a signal); a non-integer id → `"PipeWire
//!   returned an invalid AirPlay module id"` exit 1.
//! - Peers from `avahi-browse -p` lines `=;if;proto;name;type;domain;host;
//!   address;port;txt` (split at the first nine `;`): `\ddd` escapes decoded
//!   as bytes, then UTF-8 (invalid bytes replaced); port 1–65535 (Python
//!   `int()` syntax) or the record is skipped; `name` after the first `@`;
//!   `vendor` `"Sonos"` for a `sonos-` host; `model` the TXT `am`. One peer
//!   per lowercased service name, the IPv4 record preferred, first-seen order:
//!   `{name, hostname, address, port, vendor, model}`.
//! - `stop`: unless `--skip-restore`, route to `--restore-name` or the
//!   remembered `restoreName` (see routing); remove our group (below); if
//!   `owned` and the module is still listed, `pactl unload-module <id>`.
//!   Errors are joined with `"; "`; without errors the state file is
//!   removed. Reply `{"ok", "error", "restoreName"}`, exit 0 or 1.
//! - `status`: `{"ok":true,"active":<remembered moduleId is listed>,
//!   "error":"",…state}`; a remembered session that is not active is
//!   removed (state file deleted). Listing failed: `{"ok":false,
//!   "active":false,"error":…}` exit 1.
//! - `select NAME…` routes to one `raop_sink.*` speaker, or to a new
//!   `pactl load-module module-combine-sink sink_name=foamy_airplay_group_<pid>
//!   sinks=<a,b,…> latency_compensate=true
//!   sink_properties=device.description="AirPlay group"` for several;
//!   `select --local-name NAME` routes to a local sink (not `raop_sink.*`
//!   or `foamy_airplay_group_*`) and remembers it as `restoreName`/`restoreId`;
//!   no names and no local name routes to the remembered `restoreName`.
//!   Names are deduplicated in order. Checks against `pactl -f json list
//!   sinks` before anything changes: both kinds → "Choose a local output or
//!   AirPlay speakers, not both."; local missing → "The local output is no
//!   longer available."; a speaker missing → "An AirPlay speaker is no
//!   longer available. Reopen the panel."; no target → "No local output is
//!   available" (all exit 1, state untouched). Then `pactl get-default-sink`
//!   (the previous output), route; on failure route back to the previous
//!   output, remove the new group and report the failure (as in Python, a
//!   failing rollback's error, then a failing cleanup's, replaces it; any
//!   failure rolls back, where Python skipped it for malformed pactl JSON);
//!   on success remove the
//!   previous group and save `groupModuleId`/`groupName` (or drop them) and
//!   `selectedNames`. Reply `{"ok":true,"error":"","selectedNames","target"}`.
//! - Routing to a sink: `pactl set-default-sink <sink>`, then up to 20 times
//!   `pactl get-default-sink` 100 ms apart until it answers the sink (else
//!   "The selected output did not become the default"), then `pactl -f
//!   json list sink-inputs` and `pactl move-sink-input <index> <sink>` for
//!   each stream with a truthy `application.name` other than `EasyEffects`.
//! - Removing a group: only when `groupModuleId` is an integer and `pactl
//!   list modules short` shows it as `module-combine-sink` with
//!   `sink_name=<groupName>` in its arguments: `pactl unload-module <id>`.
//! - Any other failure (a tool missing, a timeout, a pactl error inside a
//!   step, malformed pactl JSON, a state write): `{"ok":false,"error":
//!   "AirPlay helper failed: <detail>"}` exit 1. A pactl failure's detail is
//!   its last stderr (else stdout) line, else `"pactl failed"`.
//!
//! State: `$FOAMY_AUDIO_AIRPLAY_STATE` (test override; empty = unset), else
//! `${XDG_RUNTIME_DIR:-/run/user/<uid>}/foamy-audio-airplay.json`, a JSON
//! object; unreadable, a symlink, over 1 MiB or not an object reads as `{}`.
//! Written atomically (`fs::write_atomic`, mode 0600), missing parents
//! created.
//!
//! # `ufw`: UFW rules for UDP 6001–6002 scoped to the speakers' network
//!
//! Only `/usr/bin/pkexec /usr/bin/ufw` is ever elevated, always with argv
//! built here, `LC_ALL=C`, 120 s. `ip` runs with `LC_ALL=C`, 10 s. `--peer`
//! values are deduplicated, then each must be an IP address (no zone ID) and
//! is used in its canonical form.
//!
//! - `verify`: for each peer its scope (below), then `pkexec ufw status
//!   verbose` and the analysis; reply `{state, message, details, legacy}`
//!   (`details` = the status output, stripped). States: `inactive`,
//!   `conflict` (a DENY/REJECT/LIMIT that applies), `wide` (an ALLOW from
//!   Anywhere on the ports), `open` (scoped ALLOWs cover every speaker),
//!   `present` (no speakers, but a rule commented `Foamy Audio AirPlay`),
//!   `missing`. `legacy`: a `Foamy Audio AirPlay` rule from Anywhere exists.
//! - `open`: no peers → `{"state":"nopeers",…}` without elevation. Else the
//!   scope of every peer first, then one `pkexec ufw allow in on <if> proto
//!   udp from <net> to any port 6001:6002 comment "Foamy Audio AirPlay"` per
//!   distinct scope, each recorded after it succeeded; reply
//!   `{"state":"applied","message":"Rules applied. Verify to check.",
//!   "details":<outputs joined by \n>,"rules":[scopes]}`.
//! - `remove`: nothing recorded and no `--legacy` → `{"state":"none",…}`.
//!   Else `pkexec ufw delete allow in on <if> proto udp from <net> to any port
//!   6001:6002` per recorded scope (dropped from the record after each), then
//!   with `--legacy` `pkexec ufw delete allow 6001:6002/udp`; `removed`.
//! - Scope of a peer: `ip -j route get <peer>`; `dev` (before any `@`) must
//!   match `[A-Za-z0-9_.-]{1,15}` ("No local interface reaches <peer>.").
//!   With a `gateway`, the peer's own /32 or /128. Without, `ip -j -4|-6 addr
//!   show dev <if>` and the last local network that contains the peer.
//! - pkexec exit 126/127 → "Administrator authorization was cancelled or
//!   denied."; other failures → stderr (else stdout) stripped, else "UFW
//!   failed." (`ip`: else "ip failed").
//! - Errors: `{"state":"error","message":<"Could not apply UFW rules." for
//!   open, "Could not remove UFW rules." for remove, "Could not complete the
//!   UFW check." otherwise>,"details":<detail>}` exit 1 (usage: exit 2).
//!
//! Record: `$FOAMY_AUDIO_FIREWALL_STATE` (test override; empty = unset), else
//! `${XDG_STATE_HOME:-$HOME/.local/state}/foamy-audio/firewall.json`,
//! `{"rules":[{"interface","network"}]}`; entries with an invalid interface
//! or a network that is not a strict CIDR are ignored. Written like the
//! AirPlay state.
//!
//! # `microphone-peak`: levels only, samples stay in memory
//!
//! `CHANNELS` is 1–64 comma-separated positions (`MONO FL FR FC LFE RL RR SL
//! SR RC FLC FRC TC TFL TFC TFR TRL TRC TRR AUX0`…`AUX63`), else stderr
//! "Microphone level unavailable: unsupported microphone channel map" (exit
//! 1). Runs `pw-record --raw --format f32 --rate <16000, or 8000 above 8
//! channels> --channels <n> --channel-map "[ <positions> ]" --target <TARGET>
//! --properties "media.category=Monitor stream.monitor=true[ node.passive=true]"
//! -` (stdin `/dev/null`, stderr passed through, `PR_SET_PDEATHSIG`) and
//! prints the peak of every 50 ms block (`rate/20 × channels` float32
//! samples) as `%.6f` lines: `min(1, cbrt(max(|sample|)))`. Samples are only
//! ever held in memory. Waits 250 ms at a time: an exited capture ends the
//! meter ("microphone capture exited"); `--passive` prints `0.000000` and
//! drops a partial block on every idle wait; otherwise 5 s without samples
//! ends it ("microphone capture timed out"). End of stream: "microphone
//! capture ended"; a NaN or infinite sample: "invalid microphone sample".
//! Failures print "Microphone level unavailable: <detail>" on stderr (exit
//! 1). SIGTERM or SIGINT ends it with exit 0. In every case the capture gets
//! SIGTERM, 1 s, then SIGKILL, and is reaped.
//!
//! A helper bug exits 101 (with the tool's JSON error reply for `airplay`
//! and `ufw`), never 126 or 127.

mod airplay;
mod mic;
mod py;
mod run;
mod ufw;

use std::ffi::OsString;
use std::process::ExitCode;

const USAGE: &str = "usage: foamy-audio-helper airplay|ufw|microphone-peak …";

fn main() -> ExitCode {
    foamy_helper::process::exit_on_panic(101);
    let mut args: Vec<OsString> = std::env::args_os().skip(1).collect();
    let tool = if args.is_empty() {
        None
    } else {
        Some(args.remove(0))
    };
    match tool.as_ref().and_then(|tool| tool.to_str()) {
        Some("airplay") => airplay::main(args),
        Some("ufw") => ufw::main(args),
        Some("microphone-peak") => mic::main(args),
        _ => {
            eprintln!("{USAGE}");
            ExitCode::from(2)
        }
    }
}

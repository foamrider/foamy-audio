"""Black-box harness: the tests run Foamy Audio's helpers as processes.

FOAMY_HELPER is the native helper's argv prefix as a JSON list; the tool
(`airplay`, `ufw`, `microphone-peak`) and its arguments follow it, e.g. the
aarch64 build through qemu binfmt:

  FOAMY_HELPER='["bin/aarch64/foamy-audio-helper"]' python3 -I -m unittest discover -s tests -p 'test_*.py'

The default is this machine's build, bin/<machine>/foamy-audio-helper.

Every external tool is a fake. `pactl`, `avahi-browse`, `ip` and `pw-record`
are scripts on a PATH that holds nothing else, so the real tools (and with
them the live PipeWire graph, the default output, loaded modules and the
microphone) are out of reach; PULSE_SERVER and PIPEWIRE_REMOTE point nowhere
for good measure. Each fake logs its argv (and LC_ALL) to calls.jsonl and
answers from a per-tool queue in queue.json.

The helpers also use absolute paths that no environment variable overrides:
`/usr/bin/pkexec /usr/bin/ufw` and the RAOP module file
`/usr/lib/pipewire-0.3/libpipewire-module-raop-discover.so`. Tests that can
reach them run the helper in a private user and mount namespace
(`unshare --user --map-root-user --mount`) in which fakes are bind-mounted
over exactly those paths; the namespace script checks that each bind took
effect before it execs the helper, so the real pkexec and ufw are never run.
Without unprivileged user namespaces those tests are skipped, never run
against the real paths.
"""

import json
import os
from pathlib import Path
import platform
import shlex
import shutil
import subprocess
import sys
import tempfile
import unittest

PLUGIN = Path(__file__).resolve().parents[1]
PKEXEC = "/usr/bin/pkexec"
UFW = "/usr/bin/ufw"
RAOP_DIR = "/usr/lib/pipewire-0.3"
RAOP_MODULE = "libpipewire-module-raop-discover.so"


def _prefix():
    raw = os.environ.get("FOAMY_HELPER")
    prefix = json.loads(raw) if raw else [str(PLUGIN / "bin" / platform.machine() / "foamy-audio-helper")]
    program = prefix[0] if "/" in prefix[0] else shutil.which(prefix[0])
    if not program:
        raise RuntimeError(f"helper program not found: {prefix[0]}")
    # Absolute: the helper runs with a PATH of fakes only.
    return [str(Path(program).resolve()), *prefix[1:]]


PREFIX = _prefix()


def helper(tool):
    """The argv that runs `tool`."""
    return [*PREFIX, tool]


def _namespaces_work():
    try:
        result = subprocess.run(
            ["/usr/bin/unshare", "--user", "--map-root-user", "--mount", "--", "/bin/true"],
            capture_output=True,
            timeout=10,
        )
    except (OSError, subprocess.SubprocessError):
        return False
    return result.returncode == 0


NAMESPACES = _namespaces_work()


def needs_namespace(*paths):
    """Skip (never fall back to the real paths) without user namespaces or targets."""
    missing = [path for path in paths if not os.path.exists(path)]
    if not NAMESPACES:
        return unittest.skip("unprivileged user namespaces are unavailable")
    if missing:
        return unittest.skip("bind target missing: " + ", ".join(missing))
    return lambda test: test


# One script for every queued fake: log the call, answer with the tool's next
# queued response ({"stdout", "stderr", "code", "sleep"}).
QUEUED = """#!{python} -I
import fcntl, json, os, sys, time
here = {here!r}
name = os.path.basename(sys.argv[0])
with open(os.path.join(here, "lock"), "a") as lock:
    fcntl.flock(lock, fcntl.LOCK_EX)
    with open(os.path.join(here, "calls.jsonl"), "a") as log:
        log.write(json.dumps({{"argv": [name, *sys.argv[1:]], "path": sys.argv[0],
                               "lc_all": os.environ.get("LC_ALL")}}) + "\\n")
    with open(os.path.join(here, "queue.json")) as source:
        queue = json.load(source)
    pending = queue.get(name, [])
    response = pending.pop(0) if pending else None
    with open(os.path.join(here, "queue.json"), "w") as sink:
        json.dump(queue, sink)
    default = os.path.join(here, "default-sink")
    if name == "pactl" and sys.argv[1:2] == ["set-default-sink"]:
        with open(default, "w") as sink:
            sink.write(sys.argv[2])
    group = os.path.join(here, "group-sink")
    if name == "pactl" and sys.argv[1:3] == ["load-module", "module-combine-sink"]:
        with open(group, "w") as sink:
            sink.write(sys.argv[3])
if response is None:
    print("fake " + name + ": no response queued", file=sys.stderr)
    sys.exit(99)
if response.get("echo_default"):
    # Like WirePlumber once it applied the change: the sink set last.
    response["stdout"] = open(default).read() + "\\n"
if "group_listing" in response:
    # `pactl list modules short` with the combine sink this helper loaded.
    response["stdout"] = "%d\\tmodule-combine-sink\\t%s sinks=raop_sink.a\\n" % (response["group_listing"], open(group).read())
sys.stdout.write(response.get("stdout", ""))
sys.stderr.write(response.get("stderr", ""))
sys.stdout.flush()
time.sleep(response.get("sleep", 0))
sys.exit(response.get("code", 0))
"""

# `ip -j route get <peer>` answers from routes.json (a missing peer is
# unreachable), `ip -j -4|-6 addr show dev <if>` with addresses.json.
IP = """#!{python} -I
import json, os, sys
here = {here!r}
with open(os.path.join(here, "calls.jsonl"), "a") as log:
    log.write(json.dumps({{"argv": ["ip", *sys.argv[1:]], "path": sys.argv[0],
                           "lc_all": os.environ.get("LC_ALL")}}) + "\\n")
args = sys.argv[1:]
if args[:3] == ["-j", "route", "get"]:
    routes = json.load(open(os.path.join(here, "routes.json")))
    if args[-1] not in routes:
        print("RTNETLINK answers: Network is unreachable", file=sys.stderr)
        sys.exit(2)
    print(json.dumps([routes[args[-1]]]))
else:
    print(open(os.path.join(here, "addresses.json")).read())
"""

# Stands in for /usr/bin/ufw: the fake pkexec never runs it, so a call is a bug.
UFW_TRAP = """#!{python} -I
import json, os, sys
with open(os.path.join({here!r}, "calls.jsonl"), "a") as log:
    log.write(json.dumps({{"argv": ["ufw-direct", *sys.argv[1:]], "path": sys.argv[0], "lc_all": None}}) + "\\n")
sys.exit(98)
"""

WLAN = [{"ifname": "wlan0", "addr_info": [{"family": "inet", "local": "192.0.2.10", "prefixlen": 24}]}]


class Fakes:
    """A temporary world: fake tools, queues, HOME and XDG directories."""

    def __init__(self, tools=("pactl", "avahi-browse")):
        self._temp = tempfile.TemporaryDirectory(prefix="foamy-audio-test-")
        self.root = Path(self._temp.name)
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.fake = self.root / "fake"
        self.fake.mkdir()
        self.home = self.root / "home"
        self.runtime = self.root / "runtime"
        self.state = self.root / "state"
        for directory in (self.home, self.runtime, self.state):
            directory.mkdir(mode=0o700)
        (self.fake / "queue.json").write_text("{}")
        (self.fake / "calls.jsonl").write_text("")
        (self.fake / "routes.json").write_text("{}")
        (self.fake / "addresses.json").write_text(json.dumps(WLAN))
        for tool in tools:
            self.script(self.bin / tool, QUEUED)
        self.script(self.bin / "ip", IP)
        self.pkexec = self.script(self.fake / "pkexec", QUEUED)
        self.ufw_trap = self.script(self.fake / "ufw", UFW_TRAP)
        self.binds = []
        self.env = {
            "PATH": str(self.bin),
            "HOME": str(self.home),
            "XDG_RUNTIME_DIR": str(self.runtime),
            "XDG_STATE_HOME": str(self.state),
            "LANG": "C.UTF-8",
            "PULSE_SERVER": "unix:" + str(self.root / "no-pulse"),
            "PIPEWIRE_REMOTE": str(self.root / "no-pipewire"),
        }

    def script(self, path, template):
        path.write_text(template.format(python=sys.executable, here=str(self.fake)))
        path.chmod(0o755)
        return path

    def close(self):
        self._temp.cleanup()

    def __enter__(self):
        return self

    def __exit__(self, *_):
        self.close()

    def queue(self, tool, *responses):
        queue = json.loads((self.fake / "queue.json").read_text())
        queue.setdefault(tool, []).extend(
            response if isinstance(response, dict) else {"stdout": response} for response in responses
        )
        (self.fake / "queue.json").write_text(json.dumps(queue))

    def leftover(self, tool):
        return json.loads((self.fake / "queue.json").read_text()).get(tool, [])

    def routes(self, routes, addresses=None):
        (self.fake / "routes.json").write_text(json.dumps(routes))
        if addresses is not None:
            (self.fake / "addresses.json").write_text(json.dumps(addresses))

    def calls(self, tool=None):
        rows = [json.loads(line) for line in (self.fake / "calls.jsonl").read_text().splitlines() if line]
        return [row for row in rows if tool is None or row["argv"][0] == tool]

    def argvs(self, tool=None):
        return [row["argv"] for row in self.calls(tool)]

    def bind_ufw(self):
        """pkexec and ufw at their absolute paths become the fakes."""
        self.binds += [(self.pkexec, PKEXEC), (self.ufw_trap, UFW)]

    def bind_raop(self, installed):
        """The RAOP module directory: a fake module file, or none at all."""
        directory = self.root / "pipewire-0.3"
        directory.mkdir(exist_ok=True)
        if installed:
            (directory / RAOP_MODULE).write_bytes(b"\x7fELF fake module")
        self.binds.append((directory, RAOP_DIR))

    def run(self, tool, *args, env=None, timeout=60):
        argv = helper(tool) + list(args)
        if self.binds:
            steps = [
                f"/usr/bin/mount --bind {shlex.quote(str(source))} {shlex.quote(target)}"
                for source, target in self.binds
            ]
            # Refuse to start the helper unless every bind is in place.
            steps += [
                f'[ "$(/usr/bin/stat -Lc %d:%i {shlex.quote(str(source))})" = '
                f'"$(/usr/bin/stat -Lc %d:%i {shlex.quote(target)})" ]'
                for source, target in self.binds
            ]
            argv = [
                "/usr/bin/unshare",
                "--user",
                "--map-root-user",
                "--mount",
                "--",
                "/bin/sh",
                "-c",
                " && ".join(steps) + ' && exec "$@"',
                "sh",
                *argv,
            ]
        return subprocess.run(
            argv, env={**self.env, **(env or {})}, capture_output=True, text=True, timeout=timeout, cwd=self.root
        )


def reply(result):
    """The helper's one JSON line on stdout."""
    lines = result.stdout.splitlines()
    if len(lines) != 1:
        raise AssertionError(f"expected one JSON line, got {result.stdout!r} (stderr {result.stderr!r})")
    return json.loads(lines[0])

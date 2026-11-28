#!/usr/bin/env python3
"""Litmus benchmark: a matrix of mutation-testing tools x scenarios over the Transit subject (bench/Transit).

Each cell runs on a fresh git copy of the subject, under a watchdog that ends a step only when it has shown no
activity (output, CPU time of its process group, files written in its output) for --idle-timeout seconds, or when
it reaches --hard-timeout. Results go to <output>/results.json and <output>/results.md, with every step's log, in
four parts: correctness (probe mutants whose right verdict is known), completeness, speed and resource usage.

Standard library only. See docs/benchmark.md.
"""

from __future__ import annotations

import argparse
import concurrent.futures
import datetime
import json
import os
import resource
import shutil
import signal
import subprocess
import sys
import tempfile
import threading
import time
from collections.abc import Callable
from dataclasses import dataclass, field
from pathlib import Path

HERE = Path(__file__).resolve().parent
SUBJECT = HERE / "Transit"
PROBES = json.loads((HERE / "probes.json").read_text())["probes"]

# ---------------------------------------------------------------------------------------------------------------------
# Watchdog


@dataclass
class StepResult:
    name: str
    command: list[str]
    status: str  # ok, failed, idle-timeout, hard-timeout, error
    exit_code: int | None
    seconds: float
    cpu_seconds: float
    log: str
    peak_rss_mib: float = 0.0
    disk_mib: float = 0.0


# The process groups of the steps running now: ended with the runner, so a stopped benchmark leaves nothing behind.
ACTIVE_GROUPS: set[int] = set()
ACTIVE_LOCK = threading.Lock()


def end_active_groups(signum: int, _frame: object) -> None:
    with ACTIVE_LOCK:
        groups = list(ACTIVE_GROUPS)
    for sig in (signal.SIGTERM, signal.SIGKILL):
        for group in groups:
            signal_step(group, sig)
        if sig == signal.SIGTERM and groups:
            time.sleep(5)
    os._exit(128 + signum)


def step_processes(root: int) -> dict[int, float]:
    """CPU seconds of each live process of a step: its process group, and every descendant of its first process,
    which a tool may start in a group of its own (ps reports time as [[dd-]hh:]mm:ss.cc)."""
    try:
        listing = subprocess.run(
            ["ps", "-A", "-o", "pid=,ppid=,pgid=,time="], capture_output=True, text=True, timeout=10
        ).stdout
    except (OSError, subprocess.TimeoutExpired):
        return {}
    rows: dict[int, tuple[int, int, float]] = {}
    for line in listing.splitlines():
        parts = line.split()
        if len(parts) != 4:
            continue
        clock, days = parts[3], 0
        if "-" in clock:
            day, clock = clock.split("-", 1)
            days = int(day)
        seconds = 0.0
        for piece in clock.split(":"):
            seconds = seconds * 60 + float(piece)
        rows[int(parts[0])] = (int(parts[1]), int(parts[2]), days * 86400 + seconds)
    members = {pid for pid, (_, group, _) in rows.items() if group == root}
    members.add(root)
    grew = True
    while grew:
        found = {pid for pid, (parent, _, _) in rows.items() if parent in members} - members
        members |= found
        grew = bool(found)
    return {pid: rows[pid][2] for pid in members if pid in rows}


def signal_step(root: int, sig: int) -> bool:
    """Sends `sig` to a step's process group and to its descendants in other groups; False when none was left."""
    # Listed before any signal: a parent that ends first leaves its children to launchd, out of the tree.
    processes = step_processes(root)
    sent = False
    try:
        os.killpg(root, sig)
        sent = True
    except ProcessLookupError:
        pass
    for pid in processes:
        try:
            os.kill(pid, sig)
            sent = True
        except ProcessLookupError:
            pass
    return sent


def newest_change(paths: list[Path], cap: int = 20000) -> float:
    """The latest modification time under `paths`, looking at no more than `cap` entries."""
    newest, seen = 0.0, 0
    for root in paths:
        if not root.exists():
            continue
        stack = [root]
        while stack and seen < cap:
            current = stack.pop()
            try:
                with os.scandir(current) as entries:
                    for entry in entries:
                        seen += 1
                        try:
                            info = entry.stat(follow_symlinks=False)
                        except OSError:
                            continue
                        newest = max(newest, info.st_mtime)
                        if entry.is_dir(follow_symlinks=False):
                            stack.append(Path(entry.path))
            except OSError:
                continue
    return newest


def disk_mib(paths: list[Path]) -> float:
    """What `paths` hold on disk, in MiB (`du`)."""
    existing = [str(p) for p in paths if p.exists()]
    if not existing:
        return 0.0
    try:
        listing = subprocess.run(["du", "-sk", *existing], capture_output=True, text=True, timeout=120).stdout
    except (OSError, subprocess.TimeoutExpired):
        return 0.0
    return round(sum(int(line.split()[0]) for line in listing.splitlines() if line.split()) / 1024, 1)


def rss_mib(usage: resource.struct_rusage) -> float:
    """Peak resident memory of the largest process the step waited for: bytes on macOS, KiB on Linux."""
    return round(usage.ru_maxrss / (1024 * 1024 if sys.platform == "darwin" else 1024), 1)


def run_step(
    name: str,
    command: list[str],
    cwd: Path,
    log: Path,
    idle_timeout: float,
    hard_timeout: float,
    watch: list[Path],
    env: dict[str, str] | None = None,
    measure: list[Path] = (),
) -> StepResult:
    """Runs `command` in its own process group, ending it only when idle or past the hard limit. `measure` are the
    directories whose size is the step's disk use (sampled every 30 s; the peak is kept)."""
    log.parent.mkdir(parents=True, exist_ok=True)
    start = time.monotonic()
    last_activity = start
    lock = threading.Lock()
    with open(log, "wb") as sink:
        sink.write(("$ " + " ".join(command) + "\n").encode())
        sink.flush()
        try:
            process = subprocess.Popen(
                command,
                cwd=cwd,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                stdin=subprocess.DEVNULL,
                env={**os.environ, **(env or {})},
                start_new_session=True,
            )
        except OSError as error:
            sink.write(f"cannot start: {error}\n".encode())
            return StepResult(name, command, "error", None, 0.0, 0.0, str(log))

        def pump() -> None:
            nonlocal last_activity
            assert process.stdout is not None
            for chunk in iter(lambda: process.stdout.read1(65536), b""):
                sink.write(chunk)
                sink.flush()
                with lock:
                    last_activity = time.monotonic()

        reader = threading.Thread(target=pump, daemon=True)
        reader.start()
        pgid = process.pid
        with ACTIVE_LOCK:
            ACTIVE_GROUPS.add(pgid)
        cpu, files = step_processes(pgid), newest_change(watch)
        peak_disk, last_disk = 0.0, time.monotonic()
        status = None
        # This step's own child is reaped with wait4: its resource usage (descendants it waited for included) is the
        # step's CPU time and memory, whatever other steps run at once.
        reaped = None
        while True:
            pid, wait_status, usage = os.wait4(process.pid, os.WNOHANG)
            if pid:
                reaped = (pid, wait_status, usage)
                break
            time.sleep(2)
            now = time.monotonic()
            if now - last_disk >= 30:
                peak_disk, last_disk = max(peak_disk, disk_mib(list(measure))), now
            current_cpu = step_processes(pgid)
            current_files = newest_change(watch)
            # Activity: a new process, or more CPU time among the processes seen last time (one that ended no longer
            # counts against the others).
            busier = sum(max(0.0, used - cpu.get(pid, 0.0)) for pid, used in current_cpu.items())
            with lock:
                if busier > 0.5 or current_files > files or set(current_cpu) - set(cpu):
                    last_activity = now
                idle = now - last_activity
            cpu, files = current_cpu, max(files, current_files)
            if now - start > hard_timeout:
                status = "hard-timeout"
            elif idle > idle_timeout:
                status = "idle-timeout"
            if status:
                sink.write(f"\n[bench] {status}: ending the process group after {now - start:.0f} s\n".encode())
                for sig, grace in ((signal.SIGTERM, 15), (signal.SIGKILL, 5)):
                    if not signal_step(pgid, sig):
                        break
                    deadline = time.monotonic() + grace
                    while time.monotonic() < deadline:
                        pid, wait_status, usage = os.wait4(process.pid, os.WNOHANG)
                        if pid:
                            reaped = (pid, wait_status, usage)
                            break
                        time.sleep(0.5)
                    if reaped:
                        break
                break
        if reaped is None:
            reaped = os.wait4(process.pid, 0)
        _, wait_status, usage = reaped
        code = os.waitstatus_to_exitcode(wait_status)
        process.returncode = code  # reaped here: Popen must not wait for it again
        with ACTIVE_LOCK:
            ACTIVE_GROUPS.discard(pgid)
        reader.join(5)
        seconds = time.monotonic() - start
        spent = usage.ru_utime + usage.ru_stime
        peak_disk = max(peak_disk, disk_mib(list(measure)))
        if status is None:
            status = "ok" if code == 0 else "failed"
        return StepResult(
            name, command, status, code, round(seconds, 1), round(spent, 1), str(log), rss_mib(usage), peak_disk
        )


# ---------------------------------------------------------------------------------------------------------------------
# Reports: every tool's mutants, as {"file", "line", "original", "replacement", "verdict"}

VERDICTS = ["killed", "survived", "noCoverage", "timeout", "crashed", "unviable", "ignored", "other"]
DETECTED = {"killed", "timeout", "crashed"}
UNDETECTED = {"survived", "noCoverage"}

Mutant = dict


def normalise(status: str) -> str:
    text = status.lower().replace("_", "").replace(" ", "").replace("-", "")
    table = [
        (("nocoverage", "notcovered", "uncovered", "notreached"), "noCoverage"),
        (("timeout", "timedout"), "timeout"),
        (("compile", "unviable", "builderror", "unbuildable"), "unviable"),
        (("crash", "runtimeerror", "signal"), "crashed"),
        (("surviv", "passed", "undetected"), "survived"),
        (("kill", "failed", "detected"), "killed"),
        (("ignored", "accepted", "skipped", "notrun", "disabled", "suppressed"), "ignored"),
    ]
    for needles, verdict in table:
        if any(needle in text for needle in needles):
            return verdict
    return "other"


def record(file: str, line: object, original: object, replacement: object, status: str) -> Mutant:
    return {
        "file": file or "",
        "line": int(line) if isinstance(line, (int, float)) or (isinstance(line, str) and line.isdigit()) else None,
        "original": original if isinstance(original, str) else "",
        "replacement": replacement if isinstance(replacement, str) else "",
        "verdict": normalise(status),
    }


def litmus_mutants(run_json: Path) -> list[Mutant] | None:
    if not run_json.exists():
        return None
    return [
        record(
            r["mutation"]["path"],
            r["mutation"]["line"],
            r["mutation"]["original"],
            r["mutation"]["replacement"],
            r["verdict"],
        )
        for r in json.loads(run_json.read_text()).get("results", [])
    ]


def stryker_mutants(report: Path) -> list[Mutant] | None:
    """swift-mutation-testing's Stryker JSON (it adds `originalText`)."""
    if not report.exists():
        return None
    data = json.loads(report.read_text())
    return [
        record(
            path,
            mutant.get("location", {}).get("start", {}).get("line"),
            mutant.get("originalText"),
            mutant.get("replacement"),
            mutant.get("status", ""),
        )
        for path, file in data.get("files", {}).items()
        for mutant in file.get("mutants", [])
    ]


def mutest_mutants(reports: Path) -> list[Mutant] | None:
    """mutest-swift's report.json: `mutants` with `source`, `line`, `original`, `replacement` and `status`."""
    report = reports / "report.json"
    if not report.exists():
        return None
    return [
        record(m.get("source", ""), m.get("line"), m.get("original"), m.get("replacement"), m.get("status", ""))
        for m in json.loads(report.read_text()).get("mutants", [])
    ]


def muter_mutants(report: Path) -> list[Mutant] | None:
    """Muter's JSON report: `fileReports[].appliedOperators[]`, each with its mutation point, snapshot and outcome."""
    if not report.exists():
        return None
    mutants = []
    for file in json.loads(report.read_text()).get("fileReports", []):
        for applied in file.get("appliedOperators", []):
            point, snapshot = applied.get("mutationPoint", {}), applied.get("mutationSnapshot", {})
            mutants.append(
                record(
                    point.get("filePath", file.get("path", "")),
                    point.get("position", {}).get("line"),
                    snapshot.get("before"),
                    snapshot.get("after"),
                    applied.get("testSuiteOutcome", ""),
                )
            )
    return mutants


def xcmutate_mutants(report: Path) -> list[Mutant] | None:
    """xcmutate's JSON report (`--json-output`): `results` with their mutant and status, and the `ignored` mutants."""
    if not report.exists():
        return None
    data = json.loads(report.read_text())
    mutants = []
    for result in data.get("results", []):
        mutant = result.get("mutant", {})
        mutants.append(
            record(
                mutant.get("file", ""),
                mutant.get("start", {}).get("line"),
                mutant.get("originalExpression") or mutant.get("original"),
                mutant.get("mutatedExpression") or mutant.get("replacement"),
                result.get("status", ""),
            )
        )
    for ignored in data.get("ignored", []):
        mutants.append(
            record(
                ignored.get("file", ""),
                ignored.get("start", {}).get("line"),
                ignored.get("original"),
                ignored.get("replacement"),
                "ignored",
            )
        )
    return mutants


def dlitmus_mutants(report: Path) -> list[Mutant] | None:
    """debugholic/litmus's JSON report (`--format json`): `mutants` with a file name, a line, a verdict and a
    description such as "changed > to <=", from which the original and the replacement are read."""
    if not report.exists():
        return None
    mutants = []
    for mutant in json.loads(report.read_text()).get("mutants", []):
        description = mutant.get("description", "")
        original, replacement = "", description
        if description.startswith("changed ") and " to " in description:
            original, replacement = description[len("changed ") :].split(" to ", 1)
        mutants.append(
            record(mutant.get("file", ""), mutant.get("line"), original, replacement, mutant.get("verdict", ""))
        )
    return mutants


def count(mutants: list[Mutant] | None) -> dict[str, int] | None:
    if mutants is None:
        return None
    counts = {verdict: 0 for verdict in VERDICTS}
    for mutant in mutants:
        counts[mutant["verdict"]] += 1
    return counts


def score(counts: dict[str, int] | None) -> float | None:
    """Detected over detected plus undetected: the same formula for every tool."""
    if not counts:
        return None
    detected = sum(counts[v] for v in DETECTED)
    undetected = sum(counts[v] for v in UNDETECTED)
    return round(100 * detected / (detected + undetected), 1) if detected + undetected else None


def probe_line(probe: dict) -> int | None:
    """The probe's line in the pristine subject, found by its anchor."""
    lines = (SUBJECT / probe["file"]).read_text().splitlines()
    return next((number for number, text in enumerate(lines, 1) if probe["anchor"] in text), None)


PROBE_LINES = {probe["id"]: probe_line(probe) for probe in PROBES}


def same_file(reported: str, subject_path: str) -> bool:
    """A tool reports paths absolute, relative to the workspace, or relative to a package: compare the tails."""
    reported = reported.replace("\\", "/")
    return reported.endswith(subject_path) or subject_path.endswith(reported.lstrip("./")) and bool(reported)


def evaluate_probes(mutants: list[Mutant] | None) -> dict[str, dict]:
    """Each probe's outcome in one report: correct, false-kill, false-survivor, undecided, not-generated (its file
    was mutated, that site was not), or out-of-scope (the report has no mutant in its file)."""
    outcomes = {}
    for probe in PROBES:
        matches = [
            m
            for m in mutants or []
            if m["line"] == PROBE_LINES[probe["id"]]
            and same_file(m["file"], probe["file"])
            and any(spelling in m["replacement"] for spelling in probe["replacements"])
        ]
        if not matches:
            in_scope = any(same_file(m["file"], probe["file"]) for m in mutants or [])
            outcomes[probe["id"]] = {"result": "not-generated" if in_scope else "out-of-scope"}
            continue
        verdicts = sorted({m["verdict"] for m in matches})
        if all(v in DETECTED for v in verdicts):
            result = "correct" if probe["expect"] == "detected" else "false-kill"
        elif all(v in UNDETECTED for v in verdicts):
            result = "correct" if probe["expect"] == "undetected" else "false-survivor"
        elif any(v in DETECTED for v in verdicts) and any(v in UNDETECTED for v in verdicts):
            result = "false-kill" if probe["expect"] == "undetected" else "false-survivor"
        else:
            result = "undecided"
        outcomes[probe["id"]] = {"result": result, "verdicts": verdicts}
    return outcomes


# ---------------------------------------------------------------------------------------------------------------------
# Tools and scenarios


@dataclass
class Context:
    """What a scenario's steps get: the subject copy, the output directory, the simulator, the tool binary."""

    work: Path
    out: Path
    destination: str
    binary: str
    base: str  # the subject copy's first commit
    run: Callable[..., StepResult]
    notes: list[str] = field(default_factory=list)


@dataclass
class Tool:
    id: str
    name: str
    env: str
    names: tuple[str, ...]


TOOLS = [
    Tool("litmus", "Litmus", "LITMUS_BIN", ("litmus",)),
    Tool("smt", "swift-mutation-testing (ericodx)", "SMT_BIN", ("swift-mutation-testing",)),
    Tool("mutest", "mutest-swift (j-khn)", "MUTEST_BIN", ("mutest-swift",)),
    Tool("muter", "Muter", "MUTER_BIN", ("muter",)),
    Tool("xcmutate", "xcmutate (RyoHirota68)", "XCMUTATE_BIN", ("xcmutate",)),
    # Its executable is also named litmus: only DLITMUS_BIN names it.
    Tool("dlitmus", "litmus (debugholic)", "DLITMUS_BIN", ()),
]


# Tools whose simulator runs delete simulators that are not theirs: run only on a throwaway CI runner (CI is set).
DELETES_SIMULATORS = {
    "smt": "skipped outside CI: swift-mutation-testing 1.7.1 deleted the destination and every other simulator of the "
    "machine when it started (2026-11-28); set CI=1 to run it on a machine whose simulators may be lost",
}


def resolve(tool: Tool) -> str | None:
    """The tool's executable: its environment variable, else its name on PATH. mutest-swift's executable is also
    named swift-mutation-testing, so set MUTEST_BIN (and SMT_BIN) rather than rely on PATH for those two."""
    explicit = os.environ.get(tool.env)
    if explicit:
        return explicit if os.access(explicit, os.X_OK) else None
    return next((found for name in tool.names if (found := shutil.which(name))), None)


def tool_version(binary: str) -> str:
    for arguments in (["--version"], ["version"]):
        try:
            done = subprocess.run([binary, *arguments], capture_output=True, text=True, timeout=30)
        except (OSError, subprocess.TimeoutExpired):
            continue
        text = (done.stdout or done.stderr).strip().splitlines()
        if done.returncode == 0 and text:
            return text[0][:80]
    return "unknown"


WORKSPACE = ["--project", "Transit.xcworkspace", "--scheme", "Transit"]
# Each tool's broadest standard operator set: Litmus's and ericodx's experimental tiers; mutest-swift and Muter run
# all their operators by default.
LITMUS_TIER = ["--operator-tier", "experimental"]
SMT_TIER = ["--operator-tier", "experimental"]
XCODEBUILD_TEST = ["/usr/bin/xcodebuild", "-workspace", "Transit.xcworkspace", "-scheme", "Transit"]


def litmus_ios(ctx: Context, extra: list[str] = (), name: str = "run") -> Path:
    run_dir = ctx.out / name
    ctx.run(
        name,
        [
            ctx.binary,
            "run",
            str(ctx.work),
            "--trust-project",
            *WORKSPACE,
            "--destination",
            ctx.destination,
            "--output",
            str(run_dir),
            *LITMUS_TIER,
            *extra,
        ],
        run_dir,
    )
    return run_dir / "run.json"


def litmus_package(ctx: Context, package: str, extra: list[str] = (), name: str = "run") -> Path:
    run_dir = ctx.out / name
    ctx.run(
        name,
        [
            ctx.binary,
            "run",
            str(ctx.work / "Modules" / package),
            "--trust-project",
            "--output",
            str(run_dir),
            *LITMUS_TIER,
            *extra,
        ],
        run_dir,
    )
    return run_dir / "run.json"


def git(directory: Path, *arguments: str) -> str:
    return subprocess.run(
        ["git", "-C", str(directory), *arguments], check=True, capture_output=True, text=True
    ).stdout.strip()


def commit(ctx: Context, message: str) -> None:
    git(ctx.work, "add", "-A")
    git(ctx.work, "commit", "-q", "-m", message)


def edit(ctx: Context, relative: str, old: str, new: str) -> None:
    path = ctx.work / relative
    text = path.read_text()
    if old not in text:
        raise RuntimeError(f"{relative}: the scenario's edit no longer applies")
    path.write_text(text.replace(old, new, 1))


def change_production(ctx: Context) -> str:
    """A pull request's change: the rounding rule and the peak surcharge are rewritten (same behaviour, so the tests
    still pass), and the changed lines carry mutable comparisons, a ternary and arithmetic."""
    path = "Modules/FareKit/Sources/FareKit/Fare.swift"
    edit(
        ctx,
        path,
        "return remainder >= 3 ? cents + (5 - remainder) : cents - remainder",
        "return remainder > 2 ? cents - remainder + 5 : cents - remainder",
    )
    edit(ctx, path, "cents += cents * peakSurchargePercent / 100", "cents = cents + cents * peakSurchargePercent / 100")
    commit(ctx, "rounding and surcharge rewritten")
    return path


def weaken_test(ctx: Context) -> None:
    """A pull request that only weakens a test: the window's upper bound is no longer checked."""
    edit(
        ctx,
        "Modules/FareKit/Tests/FareKitTests/TransferTests.swift",
        "#expect(!policy.isFreeTransfer(start: 0, minute: 61, transfers: 0))\n",
        "",
    )
    commit(ctx, "drop a transfer check")


def add_failing_target_test(ctx: Context) -> None:
    edit(
        ctx,
        "AppExtraTests/ExtraTests.swift",
        "@Test func `two changes are pluralised`",
        "@Test func `a known failure`() { #expect(1 == 2) }\n\n    @Test func `two changes are pluralised`",
    )
    commit(ctx, "a failing test in the target the scheme leaves out")


def write_muter_configuration(ctx: Context, test_command: list[str], directory: Path | None = None) -> None:
    executable, *arguments = test_command
    lines = [f"executable: {executable}", "arguments:"] + [f"- {json.dumps(a)}" for a in arguments]
    lines += ["exclude:", "- Tests", "- AppTests", "- AppExtraTests", "- AppUITests"]
    (directory or ctx.work).joinpath("muter.conf.yml").write_text("\n".join(lines) + "\n")


def results_of(run_json: Path) -> list[dict]:
    return json.loads(run_json.read_text()).get("results", []) if run_json.exists() else []


# Common scenarios: every tool that can run them.


def common_ios(tool: str, ctx: Context) -> list[Mutant] | None:
    if tool == "litmus":
        return litmus_mutants(litmus_ios(ctx))
    if tool == "smt":
        report = ctx.out / "report.json"
        ctx.run(
            "run",
            [
                ctx.binary,
                str(ctx.work),
                "--workspace",
                "Transit.xcworkspace",
                "--scheme",
                "Transit",
                "--destination",
                ctx.destination,
                "--no-cache",
                *SMT_TIER,
                "--output",
                str(report),
            ],
            ctx.out,
        )
        return stryker_mutants(report)
    if tool == "mutest":
        reports = ctx.out / "reports"
        ctx.run(
            "run",
            [
                ctx.binary,
                "run",
                "--project",
                str(ctx.work / "Transit.xcworkspace"),
                "--project-kind",
                "xcode-workspace",
                "--scheme",
                "Transit",
                "--destination-simulator",
                ctx.destination,
                "--no-cache",
                "--output",
                str(reports),
            ],
            reports,
        )
        return mutest_mutants(reports)
    if tool == "muter":
        write_muter_configuration(
            ctx, [*XCODEBUILD_TEST, "-destination", ctx.destination, "CODE_SIGNING_ALLOWED=NO", "test"]
        )
        report = ctx.out / "muter.json"
        ctx.run("run", [ctx.binary, "run", "--skip-update-check", "--format", "json", "--output", str(report)], ctx.out)
        return muter_mutants(report)
    if tool == "xcmutate":
        report = ctx.out / "xcmutate.json"
        ctx.run(
            "run",
            [
                ctx.binary,
                "run",
                "--workspace",
                "Transit.xcworkspace",
                "--scheme",
                "Transit",
                "--destination",
                ctx.destination,
                "--json-output",
                str(report),
                # Its copy and build inside the cell's scratch, so the cell's disk use counts them.
                "--work-dir",
                str(ctx.work.parent / "xcmutate-work"),
            ],
            ctx.out,
        )
        return xcmutate_mutants(report)
    if tool == "dlitmus":
        report = ctx.out / "dlitmus.json"
        ctx.run(
            "run",
            [
                ctx.binary,
                "run",
                "--project",
                ".",
                "--scheme",
                "Transit",
                "--destination",
                ctx.destination,
                "--format",
                "json",
                "--output",
                str(report),
            ],
            ctx.out,
        )
        return dlitmus_mutants(report)
    return None


def common_package(tool: str, ctx: Context) -> list[Mutant] | None:
    package = ctx.work / "Modules" / "WalletKit"
    if tool == "litmus":
        return litmus_mutants(litmus_package(ctx, "WalletKit"))
    if tool == "smt":
        report = ctx.out / "report.json"
        ctx.run("run", [ctx.binary, str(package), "--no-cache", *SMT_TIER, "--output", str(report)], ctx.out)
        return stryker_mutants(report)
    if tool == "mutest":
        reports = ctx.out / "reports"
        ctx.run(
            "run",
            [
                ctx.binary,
                "run",
                "--project",
                str(package),
                "--project-kind",
                "swift-package",
                "--no-cache",
                "--output",
                str(reports),
            ],
            reports,
        )
        return mutest_mutants(reports)
    if tool == "muter":
        write_muter_configuration(ctx, ["/usr/bin/swift", "test"], directory=package)
        report = ctx.out / "muter.json"
        ctx.run(
            "run",
            [ctx.binary, "run", "--skip-update-check", "--format", "json", "--output", str(report)],
            ctx.out,
            cwd=package,
        )
        return muter_mutants(report)
    if tool == "xcmutate":
        report = ctx.out / "xcmutate.json"
        ctx.run(
            "run",
            [
                ctx.binary,
                "run",
                "--package",
                ".",
                "--scheme",
                "WalletKit",
                "--destination",
                "platform=macOS",
                "--json-output",
                str(report),
                # Its copy and build inside the cell's scratch, so the cell's disk use counts them.
                "--work-dir",
                str(ctx.work.parent / "xcmutate-work"),
            ],
            ctx.out,
            cwd=package,
        )
        return xcmutate_mutants(report)
    if tool == "dlitmus":
        report = ctx.out / "dlitmus.json"
        ctx.run(
            "run",
            [ctx.binary, "run", "--project", ".", "--format", "json", "--output", str(report)],
            ctx.out,
            cwd=package,
        )
        return dlitmus_mutants(report)
    return None


def common_diff(tool: str, ctx: Context) -> list[Mutant] | None:
    changed = change_production(ctx)
    if tool == "litmus":
        return litmus_mutants(litmus_ios(ctx, ["--diff-base", ctx.base]))
    if tool == "smt":
        report = ctx.out / "report.json"
        ctx.run(
            "run",
            [
                ctx.binary,
                str(ctx.work),
                "--workspace",
                "Transit.xcworkspace",
                "--scheme",
                "Transit",
                "--destination",
                ctx.destination,
                "--no-cache",
                *SMT_TIER,
                "--sources-path",
                changed,
                "--output",
                str(report),
            ],
            ctx.out,
        )
        ctx.notes.append("no diff mode: --sources-path names the changed file")
        return stryker_mutants(report)
    if tool == "mutest":
        reports = ctx.out / "reports"
        ctx.run(
            "run",
            [
                ctx.binary,
                "run",
                "--project",
                str(ctx.work / "Transit.xcworkspace"),
                "--project-kind",
                "xcode-workspace",
                "--scheme",
                "Transit",
                "--destination-simulator",
                ctx.destination,
                "--source-commit",
                "HEAD",
                "--source-base",
                ctx.base,
                "--test-scope",
                "all",
                "--no-cache",
                "--output",
                str(reports),
            ],
            reports,
        )
        return mutest_mutants(reports)
    if tool == "muter":
        write_muter_configuration(
            ctx, [*XCODEBUILD_TEST, "-destination", ctx.destination, "CODE_SIGNING_ALLOWED=NO", "test"]
        )
        report = ctx.out / "muter.json"
        ctx.run(
            "run",
            [
                ctx.binary,
                "run",
                "--skip-update-check",
                "--files-to-mutate",
                changed,
                "--format",
                "json",
                "--output",
                str(report),
            ],
            ctx.out,
        )
        ctx.notes.append("no diff mode: --files-to-mutate names the changed file")
        return muter_mutants(report)
    if tool == "xcmutate":
        report = ctx.out / "xcmutate.json"
        ctx.run(
            "run",
            [
                ctx.binary,
                "run",
                "--since",
                ctx.base,
                "--workspace",
                "Transit.xcworkspace",
                "--scheme",
                "Transit",
                "--destination",
                ctx.destination,
                "--json-output",
                str(report),
                # Its copy and build inside the cell's scratch, so the cell's disk use counts them.
                "--work-dir",
                str(ctx.work.parent / "xcmutate-work"),
            ],
            ctx.out,
        )
        return xcmutate_mutants(report)
    if tool == "dlitmus":
        report = ctx.out / "dlitmus.json"
        ctx.run(
            "run",
            [
                ctx.binary,
                "run",
                "--project",
                ".",
                "--since",
                ctx.base,
                "--scheme",
                "Transit",
                "--destination",
                ctx.destination,
                "--format",
                "json",
                "--output",
                str(report),
            ],
            ctx.out,
        )
        return dlitmus_mutants(report)
    return None


# Litmus features.


def litmus_reach_off(ctx: Context) -> list[Mutant] | None:
    return litmus_mutants(litmus_ios(ctx, ["--no-per-test-reach"]))


def litmus_shared_process(ctx: Context) -> list[Mutant] | None:
    isolated = litmus_package(ctx, "WalletKit", name="isolated")
    shared = litmus_package(ctx, "WalletKit", ["--shared-process", "on"], name="shared")
    a = {r["mutation"]["id"]: r["verdict"] for r in results_of(isolated)}
    b = {r["mutation"]["id"]: r["verdict"] for r in results_of(shared)}
    differing = sorted(k for k in a if a[k] != b.get(k))
    ctx.notes.append(
        f"shared vs isolated: {len(differing)} verdict(s) differ" + (f": {differing}" if differing else "")
    )
    return litmus_mutants(shared)


def litmus_test_changes(ctx: Context) -> list[Mutant] | None:
    nightly = litmus_package(ctx, "FareKit", name="nightly")
    weaken_test(ctx)
    return litmus_mutants(
        litmus_package(
            ctx,
            "FareKit",
            ["--diff-base", ctx.base, "--include-test-changes", "--reach-from", str(nightly.parent)],
            name="pull-request",
        )
    )


def litmus_all_targets(ctx: Context) -> list[Mutant] | None:
    add_failing_target_test(ctx)
    run_dir = ctx.out / "run"
    ctx.run(
        "run",
        [
            ctx.binary,
            "run",
            str(ctx.work),
            "--trust-project",
            "--project",
            "Transit.xcworkspace",
            "--all-test-targets",
            "--skip-failing-targets",
            "--destination",
            ctx.destination,
            "--output",
            str(run_dir),
            *LITMUS_TIER,
        ],
        run_dir,
    )
    if (run_dir / "run.json").exists():
        notes = json.loads((run_dir / "run.json").read_text())["notes"]
        ctx.notes += [n for n in notes if "excluded" in n or "synthesized" in n]
    return litmus_mutants(run_dir / "run.json")


def litmus_ui_tests(ctx: Context) -> list[Mutant] | None:
    run_dir = ctx.out / "run"
    ctx.run(
        "run",
        [
            ctx.binary,
            "run",
            str(ctx.work),
            "--trust-project",
            "--project",
            "Transit.xcworkspace",
            "--all-test-targets",
            "--include-ui-tests",
            "--operators",
            "remove-view-element",
            "--destination",
            ctx.destination,
            "--output",
            str(run_dir),
        ],
        run_dir,
    )
    return litmus_mutants(run_dir / "run.json")


def litmus_inner_loop(ctx: Context) -> list[Mutant] | None:
    """Accept the equivalent mutant, then re-verify one survivor alone, as a developer or an agent would."""
    full = litmus_package(ctx, "WalletKit", name="full")
    results = results_of(full)
    equivalent = next(
        (
            r
            for r in results
            if r["mutation"]["original"] == "bounded > 100"
            and r["mutation"]["replacement"] == "bounded >= 100"
            and r["verdict"] == "survived"
        ),
        None,
    )
    package = ctx.work / "Modules" / "WalletKit"
    if equivalent:
        ctx.run(
            "accept",
            [
                ctx.binary,
                "accept",
                equivalent["mutation"]["id"],
                "--from",
                str(full.parent),
                "--root",
                str(package),
                "--reason",
                "max(-1, min(value, 101)) is never 100 and above 100 at once",
            ],
            None,
        )
    else:
        ctx.notes.append("the equivalent mutant was not among the survivors")
    survivor = next((r for r in results if r["verdict"] == "survived" and r is not equivalent), None)
    if survivor:
        litmus_package(ctx, "WalletKit", ["--only-id", survivor["mutation"]["id"]], name="only-id")
    ctx.run("agent", [ctx.binary, "analyze", str(package), "--results", str(full), "--format", "agent"], None)
    after = litmus_package(ctx, "WalletKit", name="after-accept")
    if after.exists() and full.exists():
        ctx.notes.append(f"accepted mutants left out of the next run: {len(results) - len(results_of(after))}")
    litmus_package(ctx, "WalletKit", ["--verify-accepted"], name="verify-accepted")
    return litmus_mutants(after)


def litmus_reuse(ctx: Context) -> list[Mutant] | None:
    """The result store: a second run of the same tree reuses every verdict."""
    store = ctx.out / "store"
    litmus_package(ctx, "FareKit", ["--result-store", str(store)], name="cold")
    warm = litmus_package(ctx, "FareKit", ["--result-store", str(store)], name="warm")
    if warm.exists():
        reuse = json.loads(warm.read_text()).get("reuse", {})
        ctx.notes.append(f"warm run reused {reuse.get('fromStore', 0)} verdict(s) from the store")
    return litmus_mutants(warm)


def litmus_shards(ctx: Context) -> list[Mutant] | None:
    for shard in ("1/2", "2/2"):
        litmus_package(ctx, "TripKit", ["--shard", shard], name="shard-" + shard[0])
    merged = ctx.out / "merged"
    ctx.run(
        "merge",
        [ctx.binary, "merge", str(ctx.out / "shard-1"), str(ctx.out / "shard-2"), "--output", str(merged)],
        merged,
    )
    return litmus_mutants(merged / "run.json")


def litmus_budget(ctx: Context) -> list[Mutant] | None:
    return litmus_mutants(litmus_ios(ctx, ["--budget", "60"]))


@dataclass
class Scenario:
    id: str
    description: str
    run: Callable[[str, Context], list[Mutant] | None]
    tools: tuple[str, ...]
    simulator: bool
    whole: bool = False  # mutates the whole subject (or package): where a missing probe counts against completeness


def only_litmus(function: Callable[[Context], list[Mutant] | None]) -> Callable[[str, Context], list | None]:
    return lambda tool, ctx: function(ctx)


ALL = ("litmus", "smt", "mutest", "muter", "xcmutate", "dlitmus")
SCENARIOS = [
    Scenario("ios-app", "the whole app and its packages on the simulator", common_ios, ALL, True, whole=True),
    Scenario("package", "one SwiftPM package (WalletKit) on macOS", common_package, ALL, False, whole=True),
    Scenario("diff", "a pull request changing one production file", common_diff, ALL, True),
    Scenario(
        "reach-off", "ios-app without per-test reach", only_litmus(litmus_reach_off), ("litmus",), True, whole=True
    ),
    Scenario(
        "shared-process",
        "WalletKit isolated and in a shared process, verdicts compared",
        only_litmus(litmus_shared_process),
        ("litmus",),
        False,
        whole=True,
    ),
    Scenario(
        "test-changes",
        "a pull request that only weakens a test (--include-test-changes)",
        only_litmus(litmus_test_changes),
        ("litmus",),
        False,
    ),
    Scenario(
        "all-targets",
        "every unit-test target, one failing unmutated (--all-test-targets)",
        only_litmus(litmus_all_targets),
        ("litmus",),
        True,
        whole=True,
    ),
    Scenario(
        "ui-tests",
        "view mutants against the UI tests (--include-ui-tests)",
        only_litmus(litmus_ui_tests),
        ("litmus",),
        True,
    ),
    Scenario(
        "inner-loop",
        "accept, --only-id, --format agent, --verify-accepted",
        only_litmus(litmus_inner_loop),
        ("litmus",),
        False,
    ),
    Scenario("reuse", "a second run served from the result store", only_litmus(litmus_reuse), ("litmus",), False),
    Scenario("shards", "two shards merged", only_litmus(litmus_shards), ("litmus",), False),
    Scenario("budget", "ios-app under a 60 s budget", only_litmus(litmus_budget), ("litmus",), True),
]


# ---------------------------------------------------------------------------------------------------------------------
# Driver


def fresh_subject(parent: Path) -> tuple[Path, str]:
    work = parent / "Transit"
    shutil.copytree(SUBJECT, work, ignore=shutil.ignore_patterns(".build", ".swiftpm", "DerivedData", "xcuserdata"))
    git(work, "init", "-q", "-b", "main")
    git(work, "config", "user.email", "bench@litmus.invalid")
    git(work, "config", "user.name", "bench")
    git(work, "config", "commit.gpgsign", "false")
    git(work, "add", "-A")
    git(work, "commit", "-q", "-m", "subject")
    return work, git(work, "rev-parse", "HEAD")


def simulator(requested: str | None) -> str:
    if requested and requested.startswith(("id=", "platform=")):
        return requested
    listing = json.loads(
        subprocess.run(
            ["xcrun", "simctl", "list", "-j", "devices", "available"], capture_output=True, text=True, check=True
        ).stdout
    )
    devices = [
        (runtime, device)
        for runtime, group in listing["devices"].items()
        for device in group
        if "iOS" in runtime and device.get("isAvailable", True)
    ]
    if requested:
        devices = [d for d in devices if requested in (d[1]["name"], d[1]["udid"])]
    phones = [d for d in devices if d[1]["name"].startswith("iPhone")] or devices
    if not phones:
        raise SystemExit("no available iOS simulator; pass --simulator")
    booted = [d for d in phones if d[1].get("state") == "Booted"]
    _, device = (booted or sorted(phones, key=lambda d: d[0]))[-1]
    return "id=" + device["udid"]


def first_errors(steps: list[StepResult], limit: int = 2) -> list[str]:
    """The first error lines of the steps that did not end well: what a failed row is reported with."""
    found: list[str] = []
    for step in steps:
        if step.status == "ok":
            continue
        try:
            lines = Path(step.log).read_text(errors="replace").splitlines()
        except OSError:
            continue
        # A compiler's or tool's `error:` line first; any line naming an error after.
        tagged = [line.strip() for line in lines if "error:" in line.lower() and len(line) < 400]
        errors = tagged or [line.strip() for line in lines if "error" in line.lower() and len(line) < 400]
        found += [f"{step.name}: {line}" for line in (errors or lines[-1:])[:limit]]
    return found


def run_cell(
    tool: Tool, binary: str, scenario: Scenario, output: Path, destination: str, args: argparse.Namespace
) -> dict:
    """One tool on one scenario, in a fresh copy of the subject with its own TMPDIR (so what a tool keeps there, a
    sandbox or a build, counts as the cell's disk use and is removed with it)."""
    cell = output / tool.id / scenario.id
    cell.mkdir(parents=True, exist_ok=True)
    steps: list[StepResult] = []
    with tempfile.TemporaryDirectory(prefix=f"bench-{tool.id}-{scenario.id}-") as scratch:
        work, base = fresh_subject(Path(scratch))
        temporary = Path(scratch) / "tmp"
        temporary.mkdir()

        def run(name: str, command: list[str], watch: Path | None, cwd: Path | None = None) -> StepResult:
            result = run_step(
                name,
                command,
                cwd or work,
                cell / f"{len(steps) + 1:02d}-{name}.log",
                args.idle_timeout,
                args.hard_timeout,
                [p for p in (watch, cell, work, temporary) if p is not None],
                env={"TMPDIR": str(temporary) + "/"},
                measure=[Path(scratch), cell],
            )
            steps.append(result)
            print(f"[{tool.id}/{scenario.id}] {name}: {result.status} in {result.seconds:.0f} s", flush=True)
            return result

        ctx = Context(work, cell, destination, binary, base, run)
        started = time.monotonic()
        try:
            mutants = scenario.run(tool.id, ctx)
        except Exception as error:  # a scenario's own failure is a result, not the end of the matrix
            mutants = None
            ctx.notes.append(f"scenario error: {error}")
        total = round(time.monotonic() - started, 1)
    # A non-zero exit is often a finding (survivors, a gate), not a broken run: a row is ok when its report was read
    # and no step timed out or failed to start.
    statuses = {s.status for s in steps}
    status = next((s for s in ("hard-timeout", "idle-timeout", "error") if s in statuses), None)
    if status is None:
        status = "ok" if mutants is not None else ("failed" if "failed" in statuses else "no-report")
    if status != "ok":
        ctx.notes += first_errors(steps)
    counts = count(mutants)
    decided = sum(counts[v] for v in DETECTED | UNDETECTED) if counts else 0
    return {
        "tool": tool.id,
        "scenario": scenario.id,
        "description": scenario.description,
        "whole": scenario.whole,
        "status": status,
        "seconds": total,
        "secondsPerMutant": round(total / decided, 2) if decided else None,
        "cpuSeconds": round(sum(s.cpu_seconds for s in steps), 1),
        "peakMemoryMiB": max((s.peak_rss_mib for s in steps), default=0.0),
        "peakDiskMiB": max((s.disk_mib for s in steps), default=0.0),
        "mutants": len(mutants) if mutants is not None else None,
        "counts": counts,
        "score": score(counts),
        "probes": evaluate_probes(mutants) if mutants is not None else {},
        # Kept so a later --merge evaluates the probes of the probes.json it runs with.
        "mutantRecords": mutants,
        "steps": [s.__dict__ for s in steps],
        "notes": ctx.notes,
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--tools", default=",".join(t.id for t in TOOLS), help="comma-separated tool ids")
    parser.add_argument("--scenarios", default="all", help="comma-separated scenario ids, or all")
    parser.add_argument("--simulator", help="a simulator name, UDID, or an id=/platform= destination")
    parser.add_argument("--idle-timeout", type=float, default=600, help="end a step after this long without activity")
    parser.add_argument("--hard-timeout", type=float, default=5400, help="end a step after this long regardless")
    parser.add_argument(
        "--jobs",
        type=int,
        default=1,
        help="cells run at once; simulator cells still run one at a time (they share the simulator)",
    )
    parser.add_argument("--output", type=Path, help="results directory (default: bench/results/<UTC time>)")
    parser.add_argument("--list", action="store_true", help="list tools and scenarios, then exit")
    parser.add_argument(
        "--matrix", action="store_true", help="print the applicable cells as a GitHub Actions matrix (JSON), then exit"
    )
    parser.add_argument(
        "--merge",
        nargs="+",
        type=Path,
        metavar="RESULTS",
        help="merge the results.json of several runs (one per CI job) into --output, then exit",
    )
    args = parser.parse_args()
    for handled in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
        signal.signal(handled, end_active_groups)

    if args.merge:
        output = (args.output or HERE / "results" / "merged").resolve()
        output.mkdir(parents=True, exist_ok=True)
        merged: dict = {"rows": [], "versions": {}, "destinations": []}
        for path in args.merge:
            data = json.loads((path / "results.json" if path.is_dir() else path).read_text())
            for row in data["rows"]:
                if row.get("mutantRecords") is not None:
                    row["probes"] = evaluate_probes(row["mutantRecords"])
                merged["rows"].append(row)
            merged["versions"].update(data.get("versions", {}))
            if data.get("destination"):
                merged["destinations"].append(data["destination"])
        merged["destination"] = ", ".join(sorted(set(merged.pop("destinations"))))
        merged["generated"] = datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
        (output / "results.json").write_text(json.dumps(merged, indent=2))
        write_markdown(output, merged)
        print(output / "results.md")
        return 0

    tools = [t for t in TOOLS if t.id in args.tools.split(",")]
    scenarios = SCENARIOS if args.scenarios == "all" else [s for s in SCENARIOS if s.id in args.scenarios.split(",")]
    if args.list:
        for tool in TOOLS:
            print(f"tool {tool.id:8} {resolve(tool) or '(not found: set ' + tool.env + ')'}  {tool.name}")
        for scenario in SCENARIOS:
            print(f"scenario {scenario.id:15} [{','.join(scenario.tools)}] {scenario.description}")
        return 0
    if args.matrix:
        cells = [{"tool": t.id, "scenario": s.id} for t in tools for s in scenarios if t.id in s.tools]
        print(json.dumps({"include": cells}))
        return 0

    stamp = datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    output = (args.output or HERE / "results" / stamp).resolve()
    output.mkdir(parents=True, exist_ok=True)
    destination = simulator(args.simulator) if any(s.simulator for s in scenarios) else ""
    results: dict = {"generated": stamp, "destination": destination, "versions": {}, "rows": []}
    lock, simulator_lock = threading.Lock(), threading.Lock()

    def keep(row: dict) -> None:
        with lock:
            results["rows"].append(row)
            (output / "results.json").write_text(json.dumps(results, indent=2))

    work = []
    for tool in tools:
        binary = resolve(tool)
        if binary:
            results["versions"][tool.id] = tool_version(binary)
        for scenario in scenarios:
            row = {"tool": tool.id, "scenario": scenario.id, "description": scenario.description}
            if tool.id not in scenario.tools:
                keep({**row, "status": "not-applicable"})
            elif not binary:
                keep({**row, "status": "unavailable", "notes": [f"set {tool.env} or put it on PATH"]})
            elif tool.id in DELETES_SIMULATORS and scenario.simulator and not os.environ.get("CI"):
                keep({**row, "status": "skipped", "notes": [DELETES_SIMULATORS[tool.id]]})
            else:
                work.append((tool, binary, scenario))

    def execute(tool: Tool, binary: str, scenario: Scenario) -> None:
        if scenario.simulator:
            with simulator_lock:
                keep(run_cell(tool, binary, scenario, output, destination, args))
        else:
            keep(run_cell(tool, binary, scenario, output, destination, args))

    # Simulator cells first: they are serial, so the parallel macOS cells fill the time beside them.
    work.sort(key=lambda item: not item[2].simulator)
    with concurrent.futures.ThreadPoolExecutor(max_workers=max(1, args.jobs)) as pool:
        for future in [pool.submit(execute, *item) for item in work]:
            future.result()
    write_markdown(output, results)
    print(f"results: {output / 'results.md'}")
    # The run fails when the benchmark did not happen (a tool's binary is missing) or when Litmus's own cell did not
    # end well. Another tool failing, timing out or writing no report is a result: it is in the table, with its errors.
    broken = [
        f"{r['tool']}/{r['scenario']}: {r['status']}"
        for r in results["rows"]
        if r["status"] == "unavailable" or (r["tool"] == "litmus" and r["status"] not in ("ok", "not-applicable", "skipped"))
    ]
    for row in results["rows"]:
        if row["status"] not in ("ok", "not-applicable", "unavailable", "skipped") and row["tool"] != "litmus":
            print(f"note: {row['tool']}/{row['scenario']}: {row['status']} (reported, not a benchmark failure)")
    for line in broken:
        print(f"not ok: {line}", file=sys.stderr)
    return 1 if broken else 0


# ---------------------------------------------------------------------------------------------------------------------
# The report

SYMBOLS = {
    "correct": "✅",
    "false-kill": "❌ false kill",
    "false-survivor": "❌ false survivor",
    "undecided": "❔ undecided",
    "not-generated": "⚠️ not mutated",
    "out-of-scope": "–",
}


def table(header: list[str], rows: list[list[object]], align: str = "") -> list[str]:
    align = align or "l" * len(header)
    rule = ["---:" if a == "r" else "---" for a in align]
    lines = ["| " + " | ".join(header) + " |", "| " + " | ".join(rule) + " |"]
    # A pipe inside a cell, even in a code span, ends the cell in GitHub's tables: escape it.
    lines += ["| " + " | ".join("" if c is None else str(c).replace("|", "\\|") for c in row) + " |" for row in rows]
    return lines + [""]


def probe_summary(rows: list[dict]) -> dict[str, str]:
    """One tool's outcome per probe over all its rows: a wrong verdict anywhere wins, then a right one."""
    summary = {}
    for probe in PROBES:
        results = [r["probes"][probe["id"]]["result"] for r in rows if probe["id"] in r.get("probes", {})]
        wrong = [r for r in results if r.startswith("false")]
        results = [r for r in results if r != "out-of-scope"]
        if wrong:
            summary[probe["id"]] = wrong[0]
        elif "correct" in results:
            summary[probe["id"]] = "correct"
        elif "undecided" in results:
            summary[probe["id"]] = "undecided"
        else:
            summary[probe["id"]] = "not-generated" if results else "out-of-scope"
    return summary


def write_markdown(output: Path, results: dict) -> None:
    rows = [r for r in results["rows"] if r["status"] != "not-applicable"]
    tools = [t for t in TOOLS if any(r["tool"] == t.id for r in rows)]
    scenarios = [s for s in SCENARIOS if any(r["scenario"] == s.id for r in rows)]
    cell = {(r["tool"], r["scenario"]): r for r in rows}
    ran = {t.id: [r for r in rows if r["tool"] == t.id and r["status"] not in ("unavailable",)] for t in tools}
    lines = [
        f"# Mutation-testing benchmark ({results.get('generated', output.name)})",
        "",
        f"Subject: `bench/Transit`. Simulator: `{results.get('destination') or 'none'}`.",
        "",
    ]
    lines += table(
        ["Tool", "Version"], [[t.name, results.get("versions", {}).get(t.id, "not installed")] for t in tools]
    )

    # Score card.
    card = []
    for tool in tools:
        mine = ran[tool.id]
        probes = probe_summary(mine)
        evaluated = [v for v in probes.values() if v not in ("not-generated", "out-of-scope")]
        # Completeness: of the probes whose file a whole-subject run mutated, how many sites the tool mutated too.
        whole = [r for r in mine if r.get("whole") and r.get("probes")]
        reachable = {p for r in whole for p, o in r["probes"].items() if o["result"] != "out-of-scope"}
        mutated = {
            p for r in whole for p, o in r["probes"].items() if o["result"] not in ("out-of-scope", "not-generated")
        }
        card.append(
            [
                tool.name,
                f"{sum(r['status'] == 'ok' for r in mine)}/{len(mine)}",
                f"{sum(v == 'correct' for v in evaluated)}/{len(evaluated)}",
                sum(v == "false-kill" for v in evaluated),
                sum(v == "false-survivor" for v in evaluated),
                f"{len(mutated)}/{len(reachable)}",
                cell.get((tool.id, "package"), {}).get("seconds"),
                cell.get((tool.id, "ios-app"), {}).get("seconds"),
                max((r.get("peakMemoryMiB", 0) for r in mine), default=None),
                max((r.get("peakDiskMiB", 0) for r in mine), default=None),
            ]
        )
    lines += ["## Score card", ""]
    lines += table(
        [
            "Tool",
            "Scenarios ok",
            "Probes right",
            "False kills",
            "False survivors",
            "Probes mutated",
            "package (s)",
            "ios-app (s)",
            "Peak memory (MiB)",
            "Peak disk (MiB)",
        ],
        card,
        "llrrrrrrrr",
    )

    # Correctness.
    lines += [
        "## Correctness",
        "",
        "Probe mutants whose right verdict is known (`bench/probes.json`), over every scenario a tool ran. "
        "A wrong verdict in any scenario counts.",
        "",
    ]
    summaries = {t.id: probe_summary(ran[t.id]) for t in tools}
    lines += table(
        ["Probe", "Expected", "Why"] + [t.id for t in tools],
        [[p["id"], p["expect"], p["why"]] + [SYMBOLS[summaries[t.id][p["id"]]] for t in tools] for p in PROBES],
    )
    consistency = [f"- {r['tool']}/{r['scenario']}: {n}" for r in rows for n in r.get("notes", []) if "differ" in n]
    if consistency:
        lines += ["Consistency between execution modes:", ""] + consistency + [""]

    # Completeness.
    def completeness(row: dict | None) -> str:
        if row is None:
            return "n/a"
        if row["status"] != "ok":
            return f"**{row['status']}**"
        return f"ok · {row['mutants']} mutants · {row['score']}%"

    lines += [
        "## Completeness",
        "",
        "Status, mutants reported, and score: (killed + timeout + crashed) / (that + "
        "survived + no coverage), the same formula for every tool. Operator sets differ between tools.",
        "",
    ]
    lines += table(
        ["Scenario"] + [t.id for t in tools],
        [[s.id] + [completeness(cell.get((t.id, s.id))) for t in tools] for s in scenarios],
    )

    # Speed.
    def speed(row: dict | None) -> str:
        if row is None or row.get("seconds") is None:
            return "n/a"
        per = f" ({row['secondsPerMutant']} s/mutant)" if row.get("secondsPerMutant") else ""
        return f"{row['seconds']:.0f} s{per}"

    lines += ["## Speed", "", "Wall time of the whole cell, every step included.", ""]
    lines += table(
        ["Scenario"] + [t.id for t in tools],
        [[s.id] + [speed(cell.get((t.id, s.id))) for t in tools] for s in scenarios],
    )

    # Resources.
    def usage(row: dict | None) -> str:
        if row is None or row.get("seconds") is None:
            return "n/a"
        return f"{row['cpuSeconds']:.0f} s CPU · {row['peakMemoryMiB']:.0f} MiB · {row['peakDiskMiB']:.0f} MiB disk"

    lines += [
        "## Resources",
        "",
        "CPU time of every process the tool waited for; peak resident memory of its largest process; peak "
        "disk used by the subject copy, the cell's TMPDIR and its output. Xcode's default DerivedData "
        "(`~/Library/Developer/Xcode/DerivedData`), used by tools that do not choose their own, is not "
        "counted.",
        "",
    ]
    lines += table(
        ["Scenario"] + [t.id for t in tools],
        [[s.id] + [usage(cell.get((t.id, s.id))) for t in tools] for s in scenarios],
    )

    # Verdicts in detail.
    detail = []
    for scenario in scenarios:
        for tool in tools:
            row = cell.get((tool.id, scenario.id))
            if row is None or not row.get("counts"):
                continue
            c = row["counts"]
            detail.append(
                [scenario.id, tool.id]
                + [
                    c[v]
                    for v in ("killed", "survived", "noCoverage", "timeout", "crashed", "unviable", "ignored", "other")
                ]
            )
    if detail:
        lines += ["## Verdicts", ""]
        lines += table(
            [
                "Scenario",
                "Tool",
                "Killed",
                "Survived",
                "No coverage",
                "Timeout",
                "Crashed",
                "Unviable",
                "Ignored",
                "Other",
            ],
            detail,
            "llrrrrrrrr",
        )

    notes = [f"- {r['tool']}/{r['scenario']}: {n}" for r in results["rows"] for n in r.get("notes", [])]
    if notes:
        lines += ["## Notes", ""] + notes + [""]
    (output / "results.md").write_text("\n".join(lines).rstrip() + "\n")


if __name__ == "__main__":
    sys.exit(main())

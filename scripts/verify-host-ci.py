#!/usr/bin/env python3
"""Remote-only, bounded host development verification. No native runtime tests.

Each command starts in a fresh owned session. An inherited pipe holds its launcher
until PID/PGID identity has been written and synced. Cleanup observes/signals only
that exact group, reaps the direct child, and requires group absence plus pipe EOF.
Nothing in this file resolves any previously held local process or resource.
"""
from __future__ import annotations

import datetime
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import selectors
import signal
import stat
import subprocess
import sys
import time
import traceback

PUBLIC_URL = "https://github.com/snowdamiz/mixer.git"
PUBLIC_PIN = "56ff14c925168284761c5aca4f0bd4129cf3c995"
EXPECTED_TESTS = 38
TOTAL_SECONDS = 750
CLEANUP_SECONDS = 30
OUTPUT_LIMIT = 32 * 1024 * 1024
SELECTION = "public-pin-development-v1"


def utc():
    return datetime.datetime.now(datetime.timezone.utc).isoformat()


def digest(data):
    return hashlib.sha256(data).hexdigest()


def strict_json(data):
    def pairs(items):
        value = {}
        for key, item in items:
            if key in value:
                raise ValueError("Duplicate JSON key")
            value[key] = item
        return value
    return json.loads(data, object_pairs_hook=pairs)


def hex_value(value, count):
    return isinstance(value, str) and len(value) == count and all(c in "0123456789abcdef" for c in value)


class VerificationFailure(Exception):
    pass


def child_entry(arguments):
    """Exec only after the parent has sealed this fresh child's identity."""
    if os.environ.get("GITHUB_ACTIONS") != "true" or os.environ.get("FIELDLOG_HOST_CI_SELECTION") != SELECTION:
        return 125
    descriptor = int(arguments[0])
    try:
        admitted = os.read(descriptor, 1) == b"G"
    finally:
        os.close(descriptor)
    if not admitted or len(arguments) < 2:
        return 125
    os.execvpe(arguments[1], arguments[1:], os.environ.copy())
    return 125


class Runner:
    def __init__(self, root, temporary):
        self.root = root
        self.evidence = temporary / "fieldlog-host-ci-evidence"
        self.work = temporary / "fieldlog-host-ci-work"
        # Refuse previous state instead of taking custody of unknown resources.
        if self.evidence.exists() or self.work.exists():
            raise VerificationFailure("Fresh CI evidence/work paths are required; existing state is held untouched")
        self.evidence.mkdir()
        self.work.mkdir()
        self.started = time.monotonic()
        self.deadline = self.started + TOTAL_SECONDS
        self.output_bytes = 0
        self.cancel_signal = None
        self.receipt = {
            "schema": 1, "selection": SELECTION, "status": "running", "startedAt": utc(),
            "scope": "Separate FieldLog development host tests using an exact public source-commit CI mirror",
            "bounds": {"totalSeconds": TOTAL_SECONDS, "cleanupReserveSeconds": CLEANUP_SECONDS,
                       "capturedOutputBytes": OUTPUT_LIMIT, "testJobs": 2},
            "python": sys.version, "host": platform.platform(),
            "runnerPID": os.getpid(), "runURL": "https://github.com/" + os.environ["GITHUB_REPOSITORY"]
                + "/actions/runs/" + os.environ["GITHUB_RUN_ID"],
            "commands": [], "errors": [], "nativeRuntimeOrDevices": False,
            "publishedReleasePackageQualification": False, "D0D8OrGAAcceptance": False,
            "priorLocalResources": "held; not inspected or acted upon by this remote runner",
        }
        self.journal = (self.evidence / "command-journal.jsonl").open("a", encoding="utf-8")
        self.save()

    def save(self):
        data = json.dumps(self.receipt, indent=2) + "\n"
        temporary = self.evidence / "receipt.json.saving"
        temporary.write_text(data)
        temporary.replace(self.evidence / "receipt.json")

    def record(self, event):
        self.journal.write(json.dumps({"at": utc(), **event}) + "\n")
        self.journal.flush()
        os.fsync(self.journal.fileno())

    def signal_requested(self, number, _frame):
        # Do not interrupt finally cleanup with an exception from a signal handler.
        self.cancel_signal = number

    @staticmethod
    def group_state(group):
        try:
            os.killpg(group, 0)
            return "present"
        except ProcessLookupError:
            return "absent"
        except PermissionError:
            return "ambiguous-permission"
        except OSError as error:
            return "ambiguous-errno-" + str(error.errno)

    def run(self, name, command, seconds, cwd=None):
        if self.cancel_signal or self.deadline - time.monotonic() <= CLEANUP_SECONDS:
            raise VerificationFailure("Cancelled or no execution budget remains before cleanup reserve")
        result = {"name": name, "command": command, "cwd": str(cwd or self.root),
                  "startedAt": utc(), "executionSecondsBound": seconds,
                  "spawnAttempted": False,
                  "childReaped": False, "ownedGroupAbsent": False, "pipeEOF": False,
                  "identityVerified": False, "signals": [], "errors": []}
        self.receipt["commands"].append(result)
        log = self.evidence / (name + ".log")
        process = None
        selector = selectors.DefaultSelector()
        output = None
        gate_read = gate_write = None
        group = None
        started = time.monotonic()
        stop = None
        capture_failed = False
        reaping_failed = False

        def record_cleanup(event):
            try:
                self.record(event)
            except BaseException:
                # Evidence-write failures must never skip owned-child cleanup.
                result["errors"].append("Cleanup journal: " + traceback.format_exc(limit=10))

        def reap():
            nonlocal reaping_failed
            if process is None or reaping_failed:
                return
            try:
                if process.poll() is not None:
                    result["childReaped"] = True
                    result["exitCode"] = process.returncode
            except BaseException:
                reaping_failed = True
                result["errors"].append("Direct-child reap: " + traceback.format_exc(limit=10))

        def observe_group():
            if result["ownedGroupAbsent"]:
                return "absent"
            state = self.group_state(group)
            if state != result.get("lastGroupState"):
                record_cleanup({"command": name, "ownedPGID": group, "groupState": state})
                result["lastGroupState"] = state
            if state == "absent":
                result["ownedGroupAbsent"] = True
            return state

        def drain(wait, cleanup=False):
            nonlocal capture_failed
            if capture_failed:
                if not cleanup:
                    raise VerificationFailure("Output collector failed")
                time.sleep(min(wait, 0.05))
                return
            if result["pipeEOF"]:
                time.sleep(min(wait, 0.05))
                return
            try:
                for key, _ in selector.select(timeout=max(0, wait)):
                    block = os.read(key.fileobj.fileno(), 65_536)
                    if not block:
                        selector.unregister(key.fileobj)
                        result["pipeEOF"] = True
                        return
                    remaining = OUTPUT_LIMIT - self.output_bytes
                    retained = block[:remaining]
                    output.write(retained)
                    output.flush()
                    self.output_bytes += len(retained)
                    if len(retained) != len(block):
                        result["outputTruncated"] = True
            except BaseException:
                capture_failed = True
                if not cleanup:
                    raise
                result["errors"].append("Cleanup collector: " + traceback.format_exc(limit=10))

        def send_owned(sig):
            state = observe_group()
            if state == "absent":
                return
            if state != "present":
                raise VerificationFailure("Owned group identity/permission is ambiguous; no signal sent")
            try:
                os.killpg(group, sig)
                result["signals"].append({"signal": sig, "at": utc()})
                record_cleanup({"command": name, "ownedPGID": group, "signal": sig})
            except ProcessLookupError:
                # Observe absence explicitly. Never signal again after absence.
                observe_group()

        try:
            output = log.open("wb")
            gate_read, gate_write = os.pipe()
            result["spawnAttempted"] = True
            process = subprocess.Popen(
                [sys.executable, "-B", str(Path(__file__).resolve()), "--owned-child", str(gate_read), *command],
                cwd=cwd or self.root, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT, start_new_session=True, pass_fds=(gate_read,),
            )
            os.close(gate_read)
            gate_read = None
            group = process.pid
            result["pid"] = process.pid
            result["ownedPGID"] = group
            result["observedPGID"] = os.getpgid(process.pid)
            result["identityVerified"] = result["observedPGID"] == group
            # This fsynced record precedes releasing the command or any wait/read.
            self.record({"command": name, "event": "created-before-execution",
                         "pid": process.pid, "ownedPGID": group,
                         "observedPGID": result["observedPGID"],
                         "identityVerified": result["identityVerified"]})
            self.save()
            if not result["identityVerified"]:
                raise VerificationFailure("Fresh child has unexpected PGID; command remains unadmitted")
            selector.register(process.stdout, selectors.EVENT_READ)
            os.write(gate_write, b"G")
            os.close(gate_write)
            gate_write = None
            execution_deadline = min(time.monotonic() + seconds, self.deadline - CLEANUP_SECONDS)
            while time.monotonic() < execution_deadline:
                if self.cancel_signal:
                    stop = "cancel-signal-" + str(self.cancel_signal)
                    break
                drain(0.05)
                reap()
                if result.get("outputTruncated"):
                    stop = "aggregate-output-limit"
                    break
                if result["childReaped"] and result["pipeEOF"]:
                    break
            else:
                stop = "execution-timeout"
        except BaseException:
            stop = stop or "command-or-collector-error"
            result["errors"].append(traceback.format_exc(limit=20))
        finally:
            for descriptor in (gate_read, gate_write):
                if descriptor is not None:
                    try:
                        os.close(descriptor)
                    except OSError as error:
                        result["errors"].append("Gate close: " + repr(error))
            cleanup_deadline = min(time.monotonic() + CLEANUP_SECONDS, self.deadline)
            try:
                reap()
                if process is not None and result["identityVerified"]:
                    state = observe_group()
                    if state == "present":
                        send_owned(signal.SIGTERM)
                        term_deadline = min(time.monotonic() + 25, cleanup_deadline - 5)
                        while time.monotonic() < term_deadline:
                            drain(0.05, cleanup=True)
                            reap()
                            if observe_group() != "present":
                                break
                        if observe_group() == "present" and time.monotonic() < cleanup_deadline:
                            send_owned(signal.SIGKILL)
                    while time.monotonic() < cleanup_deadline:
                        drain(0.05, cleanup=True)
                        reap()
                        state = observe_group()
                        if state.startswith("ambiguous"):
                            break
                        if result["childReaped"] and result["ownedGroupAbsent"] and result["pipeEOF"]:
                            break
                elif process is not None:
                    # Only the direct child may be reaped; identity ambiguity
                    # forbids group observation/signalling and any subsequent run.
                    while time.monotonic() < cleanup_deadline and not result["childReaped"]:
                        reap()
                        time.sleep(0.05)
            except BaseException:
                result["errors"].append("Cleanup: " + traceback.format_exc(limit=20))
            finally:
                reap()
                closers = [("selector", selector.close)]
                if process is not None and process.stdout is not None:
                    closers.append(("child stdout", process.stdout.close))
                if output is not None:
                    closers.append(("output log", output.close))
                for label, close in closers:
                    try:
                        close()
                    except BaseException:
                        result["errors"].append(label + " close: " + traceback.format_exc(limit=10))
                result["stopReason"] = stop
                result["endedAt"] = utc()
                result["wallSeconds"] = round(time.monotonic() - started, 3)
                result["cleanupNotRequired"] = not result["spawnAttempted"]
                result["cleanupVerified"] = result["cleanupNotRequired"] or all(result[key] for key in
                    ("identityVerified", "childReaped", "ownedGroupAbsent", "pipeEOF"))
                if log.exists():
                    result["outputBytes"] = log.stat().st_size
                    result["outputSHA256"] = digest(log.read_bytes())
                record_cleanup({"command": name, "event": "terminal", **result})
                try:
                    self.save()
                except BaseException:
                    result["errors"].append("Receipt write: " + traceback.format_exc(limit=10))
        if stop or result["errors"] or result.get("exitCode") != 0 or not result["cleanupVerified"]:
            raise VerificationFailure("Command failed or cleanup is held: " + name)
        return log.read_bytes()

    def source_entries(self, phase):
        names = self.run(phase + "-tracked-paths", ["git", "ls-files", "-z"], 15).decode("utf-8").split("\0")
        paths = [name for name in names if name]
        if not 1 <= len(paths) <= 1024:
            raise VerificationFailure("Source file-count bound")
        entries = []
        total = 0
        for name in paths:
            relative = Path(name)
            if relative.is_absolute() or ".." in relative.parts:
                raise VerificationFailure("Nonlocal tracked source path")
            path = self.root / relative
            info = path.lstat()
            if not stat.S_ISREG(info.st_mode) or not path.resolve().is_relative_to(self.root):
                raise VerificationFailure("Tracked source must be a regular app-local file")
            total += info.st_size
            if info.st_size > OUTPUT_LIMIT or total > 128 * 1024 * 1024:
                raise VerificationFailure("Source byte bound")
            data = path.read_bytes()
            entries.append({"path": name, "bytes": len(data), "sha256": digest(data)})
        encoded = json.dumps(entries, sort_keys=True, separators=(",", ":")).encode()
        self.receipt[phase + "Sources"] = {"entries": entries, "digest": digest(encoded)}
        self.save()
        return entries

    @staticmethod
    def require_pin(data):
        value = strict_json(data)
        expected = [{"identity": "mixer", "kind": "remoteSourceControl", "location": PUBLIC_URL,
                     "state": {"revision": PUBLIC_PIN}}]
        if set(value) != {"originHash", "pins", "version"} or type(value["version"]) is not int or value["version"] != 3 or value["pins"] != expected:
            raise VerificationFailure("Committed dependency identity/location/revision changed")
        if not hex_value(value["originHash"], 64):
            raise VerificationFailure("Invalid Package.resolved originHash")
        return value

    def verify(self):
        expected_sha = os.environ["GITHUB_SHA"]
        if not hex_value(expected_sha, 40):
            raise VerificationFailure("Exact app commit is required")
        head = self.run("app-head-before", ["git", "rev-parse", "HEAD"], 15).decode().strip()
        if head != expected_sha:
            raise VerificationFailure("App HEAD differs from dispatched commit")
        origin = self.run("app-origin", ["git", "remote", "get-url", "origin"], 15).decode().strip()
        repository = os.environ["GITHUB_REPOSITORY"]
        if origin not in ["https://github.com/" + repository, "https://github.com/" + repository + ".git"]:
            raise VerificationFailure("App origin differs from the selected separate repository")
        if self.run("app-status-before", ["git", "status", "--porcelain", "--untracked-files=normal"], 15).strip():
            raise VerificationFailure("CI app checkout is not clean")
        self.receipt["app"] = {"revision": head, "origin": origin}
        before_sources = self.source_entries("before")
        before_bytes = (self.root / "Package.resolved").read_bytes()
        before_lock = self.require_pin(before_bytes)
        (self.evidence / "Package.resolved.before.json").write_bytes(before_bytes)
        self.run("swift-version", ["swift", "--version"], 20)
        self.run("xcode-version", ["xcodebuild", "-version"], 20)
        self.run("git-version", ["git", "--version"], 15)
        self.run("mirror-help", ["swift", "package", "config", "set-mirror", "--help"], 20)
        mirror = self.work / "mixer.git"
        self.run("mirror-init", ["git", "init", "--bare", str(mirror)], 15)
        self.run("public-pin-fetch", ["git", "-C", str(mirror), "-c", "protocol.version=2", "fetch",
            "--no-tags", "--depth=1", PUBLIC_URL, PUBLIC_PIN + ":refs/heads/public-sdk-pin"], 180)
        self.run("mirror-head", ["git", "-C", str(mirror), "symbolic-ref", "HEAD", "refs/heads/public-sdk-pin"], 15)
        actual_pin = self.run("mirror-pin", ["git", "-C", str(mirror), "rev-parse", "HEAD"], 15).decode().strip()
        tree = self.run("mirror-tree", ["git", "-C", str(mirror), "rev-parse", "HEAD^{tree}"], 15).decode().strip()
        if actual_pin != PUBLIC_PIN or not hex_value(tree, 40):
            raise VerificationFailure("Fetched public SDK differs from immutable pin")
        self.receipt["sdk"] = {"publicURL": PUBLIC_URL, "revision": actual_pin, "tree": tree,
            "mirror": mirror.as_uri(), "fetchDepth": 1, "qualification": "development CI mirror only"}
        self.run("mirror-configure", ["swift", "package", "config", "set-mirror", "--original", PUBLIC_URL,
            "--mirror", mirror.as_uri()], 20)
        configured = self.run("mirror-readback", ["swift", "package", "config", "get-mirror", "--original", PUBLIC_URL], 20).decode().strip()
        if configured != mirror.as_uri():
            raise VerificationFailure("Transient package mirror readback differs")
        scratch = self.work / "host-build"
        tests = self.run("host-tests", ["swift", "test", "--scratch-path", str(scratch), "--jobs", "2"], 480)
        counts = re.findall(rb"Test run with ([0-9]{1,6}) tests(?: in [0-9]{1,6} suites)? passed after", tests)
        if counts != [str(EXPECTED_TESTS).encode()]:
            raise VerificationFailure("Expected exactly 38 executed Swift Testing functions")
        checkout = scratch / "checkouts" / "mixer"
        if not checkout.resolve().is_relative_to(scratch.resolve()):
            raise VerificationFailure("Dependency checkout escapes owned CI work")
        consumed = self.run("consumed-sdk-pin", ["git", "-C", str(checkout), "rev-parse", "HEAD"], 15).decode().strip()
        consumed_tree = self.run("consumed-sdk-tree", ["git", "-C", str(checkout), "rev-parse", "HEAD^{tree}"], 15).decode().strip()
        if consumed != PUBLIC_PIN or consumed_tree != tree:
            raise VerificationFailure("Actually consumed SDK commit/tree differs")
        if self.run("consumed-sdk-status", ["git", "-C", str(checkout), "status", "--porcelain", "--untracked-files=no"], 15).strip():
            raise VerificationFailure("Consumed public SDK source changed")
        after_bytes = (self.root / "Package.resolved").read_bytes()
        after_lock = self.require_pin(after_bytes)
        (self.evidence / "Package.resolved.after.json").write_bytes(after_bytes)
        before_without_hash = {k: v for k, v in before_lock.items() if k != "originHash"}
        after_without_hash = {k: v for k, v in after_lock.items() if k != "originHash"}
        if before_without_hash != after_without_hash:
            raise VerificationFailure("Package.resolved changed beyond originHash")
        lock_changed = before_bytes != after_bytes
        origin_hash_changed = before_lock["originHash"] != after_lock["originHash"]
        if lock_changed and not origin_hash_changed:
            raise VerificationFailure("Unexplained lock-byte change without originHash refresh")
        after_sources = self.source_entries("after")
        protected_before = [v for v in before_sources if v["path"] != "Package.resolved"]
        protected_after = [v for v in after_sources if v["path"] != "Package.resolved"]
        if protected_before != protected_after:
            raise VerificationFailure("App source changed during verification")
        final_status = self.run("app-status-after", ["git", "status", "--porcelain", "--untracked-files=normal"], 15).decode()
        expected_status = " M Package.resolved\n" if lock_changed else ""
        if final_status != expected_status:
            raise VerificationFailure("Unexpected tracked or untracked application changes")
        final_head = self.run("app-head-after", ["git", "rev-parse", "HEAD"], 15).decode().strip()
        if final_head != expected_sha:
            raise VerificationFailure("App HEAD changed during verification")
        self.receipt["lock"] = {"beforeSHA256": digest(before_bytes), "afterSHA256": digest(after_bytes),
            "pinsUnchanged": True, "originHashOnlyRefresh": origin_hash_changed,
            "originHashBefore": before_lock["originHash"], "originHashAfter": after_lock["originHash"],
            "canonicalLockResetOrCommitted": False}
        self.receipt["tests"] = {"expected": EXPECTED_TESTS, "observed": EXPECTED_TESTS, "failures": 0}
        self.receipt["status"] = "passed-development-host-only"

    def finish(self):
        self.receipt["endedAt"] = utc()
        self.receipt["wallSeconds"] = round(time.monotonic() - self.started, 3)
        self.receipt["capturedOutputBytes"] = self.output_bytes
        self.receipt["cancelSignal"] = self.cancel_signal
        self.receipt["cleanupVerified"] = all(
            value.get("cleanupVerified") for value in self.receipt["commands"])
        host_log = self.evidence / "host-tests.log"
        if host_log.exists():
            summaries = re.findall(rb"Test run with ([0-9]{1,6}) tests(?: in [0-9]{1,6} suites)? (passed|failed) after",
                host_log.read_bytes())
            command = next(value for value in self.receipt["commands"] if value["name"] == "host-tests")
            self.receipt["testObservation"] = {
                "expected": EXPECTED_TESTS,
                "completedSummaries": [{"count": int(count), "outcome": outcome.decode()} for count, outcome in summaries],
                "commandExitCode": command.get("exitCode"),
                "failures": 0 if summaries == [(str(EXPECTED_TESTS).encode(), b"passed")]
                    and command.get("exitCode") == 0 else None,
                "incompleteOrFailedDetails": "Retained in host-tests.log; absent counts/failures are not zero",
            }
        if not self.receipt["cleanupVerified"]:
            self.receipt["status"] = "held-cleanup-or-identity-unverified"
        elif self.cancel_signal:
            self.receipt["status"] = "cancelled-development-host-only"
        try:
            self.save()
        except BaseException:
            self.receipt["status"] = "failed-evidence-write"
            print("Final receipt write failed:\n" + traceback.format_exc(limit=20), file=sys.stderr, flush=True)
        try:
            self.journal.close()
        except BaseException:
            self.receipt["status"] = "failed-evidence-close"
            print("Final journal close failed:\n" + traceback.format_exc(limit=20), file=sys.stderr, flush=True)
        print(json.dumps({"status": self.receipt["status"], "receipt": str(self.evidence / "receipt.json"),
                          "cleanupVerified": self.receipt["cleanupVerified"]}), flush=True)


def main():
    if os.environ.get("GITHUB_ACTIONS") != "true" or os.environ.get("FIELDLOG_HOST_CI_SELECTION") != SELECTION:
        print("Refused: this unexecuted preparation is restricted to the selected remote CI workflow", file=sys.stderr)
        return 125
    root = Path(__file__).resolve().parents[1]
    temporary = Path(os.environ["RUNNER_TEMP"]).resolve()
    if Path(os.environ["GITHUB_WORKSPACE"]).resolve() != root or not temporary.is_dir():
        print("Refused: unexpected separate-app workspace or runner temporary directory", file=sys.stderr)
        return 125
    runner = None
    try:
        runner = Runner(root, temporary)
        signal.signal(signal.SIGTERM, runner.signal_requested)
        signal.signal(signal.SIGINT, runner.signal_requested)
        runner.verify()
    except BaseException:
        error = traceback.format_exc(limit=30)
        if runner is not None:
            runner.receipt["status"] = "failed-development-host-only"
            runner.receipt["errors"].append(error)
        else:
            print(error, file=sys.stderr)
    finally:
        if runner is not None:
            runner.finish()
    return 0 if runner is not None and runner.receipt["status"] == "passed-development-host-only" else 1


if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1] == "--owned-child":
        raise SystemExit(child_entry(sys.argv[2:]))
    raise SystemExit(main())

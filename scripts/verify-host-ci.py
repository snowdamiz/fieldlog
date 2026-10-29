#!/usr/bin/env python3
"""Remote-only, bounded host development verification. No native runtime tests.

Each command starts in a fresh owned session. An inherited pipe holds its launcher
until PID/PGID identity has been written and synced. Cleanup observes/signals only
that exact group and explicitly admitted adapter groups, reaps the direct child,
and requires all recorded group absences plus pipe EOF. This does not inventory
or prove custody of other SwiftPM/compiler descendants.
Nothing in this file resolves any previously held local process or resource.
"""
from __future__ import annotations

import datetime
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import platform
import re
import resource
import selectors
import signal
import shutil
import stat
import subprocess
import sys
import time
import traceback

PUBLIC_URL = "https://github.com/snowdamiz/mixer.git"
PUBLIC_PIN = "56ff14c925168284761c5aca4f0bd4129cf3c995"
EXPECTED_TESTS = 38
EXPECTED_SDK_TREE = "75989099938ed5256c4144cbc9e62979ee323183"
HOST_PHASE_SECONDS = 480
OUTPUT_TIMELINE_LIMIT = 512
TOTAL_SECONDS = 750
CLEANUP_SECONDS = 30
PASSIVE_CLEANUP_SECONDS = 1
OUTPUT_LIMIT = 16 * 1024 * 1024
SELECTION = "filtered-public-pin-host-v1"
TRANSPORT_SPEC = importlib.util.spec_from_file_location("fieldlog_filtered_transport", Path(__file__).with_name("filtered-sdk-git.py"))
TRANSPORT = importlib.util.module_from_spec(TRANSPORT_SPEC)
TRANSPORT_SPEC.loader.exec_module(TRANSPORT)


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


def observe_output(result, elapsed, offset, length):
    """Bounded arrival metadata; offsets refer to unchanged captured log bytes."""
    timeline = result.setdefault("outputTimeline", [])
    if len(timeline) < OUTPUT_TIMELINE_LIMIT:
        timeline.append({"elapsedSeconds": round(elapsed, 6), "offset": offset, "bytes": length})
    else:
        result["outputTimelineTruncated"] = True


def resource_snapshot(path):
    """Remote runner child accounting and filesystem capacity, never a process scan.

    Child usage is cumulative accounting for reaped children and descendants
    they reaped, not an inventory or proof of usage by every group member.
    maxRSS is the platform's cumulative child high-water field, not a delta.
    """
    usage = resource.getrusage(resource.RUSAGE_CHILDREN)
    disk = os.statvfs(path)
    return {"at": utc(), "childrenUserSeconds": usage.ru_utime,
            "childrenSystemSeconds": usage.ru_stime,
            "childrenMaxRSSPlatformUnits": usage.ru_maxrss,
            "childrenMajorFaults": usage.ru_majflt,
            "childrenBlockInputs": usage.ru_inblock,
            "childrenBlockOutputs": usage.ru_oublock,
            "filesystemAvailableBytes": disk.f_bavail * disk.f_frsize,
            "filesystemFreeInodes": disk.f_favail}


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
    environment = os.environ.copy()
    environment["FIELDLOG_TRANSPORT_PGID"] = str(os.getpgrp())
    environment["FIELDLOG_TRANSPORT_SID"] = str(os.getsid(0))
    os.execvpe(arguments[1], arguments[1:], environment)
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
                       "capturedOutputBytes": OUTPUT_LIMIT, "testJobs": 2,
                       "sharedResolveBuildTestSeconds": HOST_PHASE_SECONDS,
                       "outputArrivalRecordsPerCommand": OUTPUT_TIMELINE_LIMIT},
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

    def run(self, name, command, seconds, cwd=None, absolute_deadline=None, environment=None):
        if self.cancel_signal or self.deadline - time.monotonic() <= CLEANUP_SECONDS:
            raise VerificationFailure("Cancelled or no execution budget remains before cleanup reserve")
        result = {"name": name, "command": command, "cwd": str(cwd or self.root),
                  "startedAt": utc(), "executionSecondsBound": seconds,
                  "spawnAttempted": False,
                  "childReaped": False, "ownedGroupAbsent": False, "pipeEOF": False,
                  "identityVerified": False, "signals": [], "errors": [],
                  "outputTimeline": [], "resourceObservations": [],
                  "outputReadBytes": 0, "outputRetainedBytesConfirmed": 0,
                  "outputDiscardedBytes": 0, "outputSinkUnconfirmedBytes": 0,
                  "sinkFailureBlockBytes": 0, "sinkDiscardBytes": 0,
                  "sinkDiscardIterations": 0,
                  "sinkDiscardBounds": {"seconds": PASSIVE_CLEANUP_SECONDS,
                      "bytes": 1024 * 1024, "iterations": 128,
                      "initialFailureBlockBytes": 65_536}}
        self.receipt["commands"].append(result)
        log = self.evidence / (name + ".log")
        process = None
        selector = selectors.DefaultSelector()
        output = None
        gate_read = gate_write = None
        group = None
        custody = None
        custody_drained = False
        started = time.monotonic()
        stop = None
        pipe_failed = False
        pipe_registered = False
        sink_failed = False
        sink_deadline = None
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
            if result.get("heldGroupState"):
                return result["heldGroupState"]
            state = self.group_state(group)
            if state.startswith("ambiguous"):
                result["heldGroupState"] = state
            if state != result.get("lastGroupState"):
                record_cleanup({"command": name, "ownedPGID": group, "groupState": state})
                result["lastGroupState"] = state
            if state == "absent":
                result["ownedGroupAbsent"] = True
            return state

        def drain(wait, cleanup=False):
            nonlocal pipe_failed, sink_failed, sink_deadline, pipe_registered, stop
            if pipe_failed or not pipe_registered or result["pipeEOF"]:
                time.sleep(min(wait, 0.05))
                return
            if sink_failed:
                if cleanup:
                    sink_deadline = min(sink_deadline, cleanup_deadline)
                # The first failed block is accounted separately below. These
                # bounds cover subsequent passive discard, never another write.
                if not result.get("sinkDiscardBoundReached"):
                    if time.monotonic() >= sink_deadline:
                        result["sinkDiscardBoundReached"] = "seconds"
                    elif result["sinkDiscardIterations"] >= 128:
                        result["sinkDiscardBoundReached"] = "iterations"
                    elif result["sinkDiscardBytes"] >= 1024 * 1024:
                        result["sinkDiscardBoundReached"] = "bytes"
                if result.get("sinkDiscardBoundReached"):
                    time.sleep(min(wait, 0.05))
                    return
                result["sinkDiscardIterations"] += 1
                wait = min(wait, max(0, sink_deadline - time.monotonic()))
            sink_exception = False
            try:
                ready = selector.select(timeout=max(0, wait))
                for key, _ in ready:
                    if not pipe_registered or key.fileobj is not process.stdout:
                        raise VerificationFailure("Output selector returned an unregistered owned pipe")
                    read_limit = 65_536
                    if sink_failed:
                        if time.monotonic() >= sink_deadline:
                            result["sinkDiscardBoundReached"] = "seconds"
                            return
                        read_limit = min(read_limit, 1024 * 1024 - result["sinkDiscardBytes"])
                        if read_limit <= 0:
                            result["sinkDiscardBoundReached"] = "bytes"
                            return
                    block = os.read(key.fileobj.fileno(), read_limit)
                    if not block:
                        # Only an actual empty read of the registered pipe is
                        # EOF. Child/group state and collector failures are not.
                        result["pipeEOF"] = True
                        pipe_registered = False
                        selector.unregister(key.fileobj)
                        return
                    result["outputReadBytes"] += len(block)
                    if sink_failed:
                        result["sinkDiscardBytes"] += len(block)
                        result["outputDiscardedBytes"] += len(block)
                        continue
                    remaining = max(0, OUTPUT_LIMIT - self.output_bytes)
                    retained = block[:remaining]
                    stage = "tell"
                    try:
                        offset = output.tell()
                        stage = "write"
                        written = output.write(retained)
                        if written != len(retained):
                            raise OSError("Short output log write")
                        stage = "flush"
                        output.flush()
                    except BaseException:
                        sink_failed = True
                        sink_deadline = min(self.deadline, time.monotonic() + PASSIVE_CLEANUP_SECONDS)
                        stop = stop or "output-sink-error"
                        result["outputSinkFailure"] = stage
                        result["sinkFailureBlockBytes"] = len(block)
                        # A failed write/flush may have persisted an unknown
                        # prefix. It is neither confirmed retention nor discard.
                        uncertain = 0 if stage == "tell" else len(retained)
                        result["outputSinkUnconfirmedBytes"] += uncertain
                        result["outputDiscardedBytes"] += len(block) - uncertain
                        if not cleanup:
                            sink_exception = True
                            raise
                        result["errors"].append("Cleanup output sink: " + traceback.format_exc(limit=10))
                        return
                    self.output_bytes += len(retained)
                    result["outputRetainedBytesConfirmed"] += len(retained)
                    result["outputDiscardedBytes"] += len(block) - len(retained)
                    observe_output(result, time.monotonic() - started, offset, len(retained))
                    if len(retained) != len(block):
                        result["outputTruncated"] = True
            except BaseException:
                # A rethrown sink failure is not a failure of the pipe. Keep
                # reads enabled for the bounded passive-discard path above.
                if not sink_exception:
                    pipe_failed = True
                    result["outputPipeFailed"] = True
                if not cleanup:
                    raise
                result["errors"].append("Cleanup pipe collector: " + traceback.format_exc(limit=10))

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
            result["resourceObservations"].append(resource_snapshot(self.work))
            # Unbuffered output prevents close() retrying buffered writes after
            # a failed sink; short writes are treated as evidence failures.
            output = log.open("wb", buffering=0)
            gate_read, gate_write = os.pipe()
            if environment and environment.get("FIELDLOG_TRANSPORT_CONFIG"):
                environment = environment.copy()
                custody_path = self.work / ("custody-" + str(len(self.receipt["commands"])) + ".json")
                binding = digest(TRANSPORT.regular(environment["FIELDLOG_TRANSPORT_CONFIG"], 65536))
                custody = TRANSPORT.CustodyOwner(custody_path, binding, self.deadline,
                    lambda event: self.record({"command": name, **event}))
                environment["FIELDLOG_TRANSPORT_CUSTODY"] = str(custody_path)
            result["spawnAttempted"] = True
            process = subprocess.Popen(
                [sys.executable, "-B", str(Path(__file__).resolve()), "--owned-child", str(gate_read), *command],
                cwd=cwd or self.root, env=environment, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT, start_new_session=True, pass_fds=(gate_read,),
            )
            os.close(gate_read)
            gate_read = None
            group = process.pid
            result["pid"] = process.pid
            result["ownedPGID"] = group
            result["observedPGID"] = os.getpgid(process.pid)
            result["observedSID"] = os.getsid(process.pid)
            result["identityVerified"] = result["observedPGID"] == group and result["observedSID"] == group
            # This fsynced record precedes releasing the command or any wait/read.
            self.record({"command": name, "event": "created-before-execution",
                         "pid": process.pid, "ownedPGID": group,
                         "observedPGID": result["observedPGID"], "observedSID": result["observedSID"],
                         "identityVerified": result["identityVerified"]})
            self.save()
            if not result["identityVerified"]:
                raise VerificationFailure("Fresh child has unexpected PGID; command remains unadmitted")
            if custody is not None:
                custody.start(group)
            selector.register(process.stdout, selectors.EVENT_READ)
            pipe_registered = True
            if absolute_deadline is not None and time.monotonic() >= absolute_deadline:
                raise VerificationFailure("Shared phase deadline exhausted before command admission")
            os.write(gate_write, b"G")
            os.close(gate_write)
            gate_write = None
            execution_deadline = min(time.monotonic() + seconds, self.deadline - CLEANUP_SECONDS,
                absolute_deadline if absolute_deadline is not None else self.deadline)
            while time.monotonic() < execution_deadline:
                if self.cancel_signal:
                    stop = "cancel-signal-" + str(self.cancel_signal)
                    break
                if custody is not None:
                    try:
                        custody.poll()
                    except BlockingIOError:
                        pass  # The bounded loop retries; no child is admitted by this branch.
                state_path = self.work / "transport-state.json"
                if state_path.exists() and strict_json(TRANSPORT.regular(state_path, 1024 * 1024)).get("failed"):
                    stop = "filtered-transport-failed-no-retry"
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
            if custody is not None and custody.owner is not None:
                try:
                    close_deadline = min(cleanup_deadline, time.monotonic() + 1)
                    while time.monotonic() < close_deadline:
                        try:
                            custody.close()
                            custody.poll()  # Validate pending nominations for cleanup, without admission.
                            custody_drained = True
                            break
                        except BlockingIOError:
                            time.sleep(0.01)
                    if not custody.closed or not custody_drained:
                        raise VerificationFailure("Nested admission closure and final nomination scan unverified")
                except BaseException:
                    result["errors"].append("Nested custody close: " + traceback.format_exc(limit=10))
            try:
                reap()
                if process is not None and result["identityVerified"]:
                    state = observe_group()
                    if custody is not None and custody.closed:
                        custody.signal(signal.SIGTERM)
                    if state == "present" or (custody is not None and not custody.absent()):
                        send_owned(signal.SIGTERM)
                        term_deadline = min(time.monotonic() + 25, cleanup_deadline - 5)
                        while time.monotonic() < term_deadline:
                            drain(0.05, cleanup=True)
                            reap()
                            if observe_group() != "present" and (custody is None or custody.absent()):
                                break
                        if time.monotonic() < cleanup_deadline:
                            if custody is not None and custody.closed:
                                custody.signal(signal.SIGKILL)
                            if observe_group() == "present":
                                send_owned(signal.SIGKILL)
                    while time.monotonic() < cleanup_deadline:
                        drain(0.05, cleanup=True)
                        reap()
                        state = observe_group()
                        if state.startswith("ambiguous"):
                            break
                        if (result["childReaped"] and result["ownedGroupAbsent"] and result["pipeEOF"]
                                and (custody is None or custody.absent())):
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
                # Group ambiguity or an evidence failure cannot authorize a
                # signal, but also must not bypass the existing direct-child
                # reap and owned-pipe accounting. No group probes occur here.
                passive_deadline = min(cleanup_deadline, time.monotonic() + PASSIVE_CLEANUP_SECONDS)
                try:
                    while process is not None and time.monotonic() < passive_deadline and not (result["childReaped"] and result["pipeEOF"]):
                        drain(min(0.05, max(0, passive_deadline - time.monotonic())), cleanup=True)
                        reap()
                except BaseException:
                    result["errors"].append("Passive cleanup: " + traceback.format_exc(limit=10))
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
                try:
                    result["resourceObservations"].append(resource_snapshot(self.work))
                except BaseException:
                    result["errors"].append("Resource observation: " + traceback.format_exc(limit=10))
                result["stopReason"] = stop
                result["endedAt"] = utc()
                result["wallSeconds"] = round(time.monotonic() - started, 3)
                result["cleanupNotRequired"] = not result["spawnAttempted"]
                result["nestedAdmissionClosedAndDrained"] = custody is None or (custody.closed and custody_drained)
                result["registeredGroupsAbsent"] = custody is None or custody.absent()
                result["registeredGroups"] = [] if custody is None else list(custody.groups.values())
                if custody is not None:
                    result["errors"].extend(custody.errors)
                result["cleanupScope"] = "recorded outer and registered adapter groups; no complete descendant inventory"
                result["cleanupVerified"] = result["cleanupNotRequired"] or all(result[key] for key in
                    ("identityVerified", "childReaped", "ownedGroupAbsent", "pipeEOF", "registeredGroupsAbsent",
                     "nestedAdmissionClosedAndDrained"))
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

    def source_entries(self, phase, run=None):
        run = run or self.run
        names = run(phase + "-tracked-paths", [str(getattr(self, "real_git", "git")), "ls-files", "-z"], 15).decode("utf-8").split("\0")
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
            data = TRANSPORT.regular(path, OUTPUT_LIMIT)
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

    def verify_consumed_sdk(self, scratch, tree, phase, run):
        checkout = scratch / "checkouts" / "mixer"
        if not checkout.resolve().is_relative_to(scratch.resolve()):
            raise VerificationFailure("Dependency checkout escapes owned CI work")
        consumed = run(phase + "-consumed-sdk-pin",
            [str(self.real_git), "-C", str(checkout), "rev-parse", "HEAD"], 15).decode().strip()
        consumed_tree = run(phase + "-consumed-sdk-tree",
            [str(self.real_git), "-C", str(checkout), "rev-parse", "HEAD^{tree}"], 15).decode().strip()
        if consumed != PUBLIC_PIN or consumed_tree != tree:
            raise VerificationFailure("Actually consumed SDK commit/tree differs before " + phase)
        if run(phase + "-consumed-sdk-status",
            [str(self.real_git), "-C", str(checkout), "status", "--porcelain", "--untracked-files=no"], 15).strip():
            raise VerificationFailure("Consumed public SDK source changed before " + phase)
        self.receipt.setdefault("consumptionCheckpoints", []).append({"phase": phase,
            "revision": consumed, "tree": consumed_tree, "trackedWorkingTreeClean": True})
        self.save()

    def prepare_transport(self):
        """Capture trusted tools before the scoped PATH adapter is introduced."""
        found = shutil.which("git")
        if found is None:
            raise VerificationFailure("Trusted real Git missing")
        self.real_git = Path(found).resolve(strict=True)
        trusted_git = TRANSPORT.signature(self.real_git)
        script = TRANSPORT.nofollow(self.root / "scripts/filtered-sdk-git.py")
        closure = TRANSPORT.nofollow(self.root / "scripts/filtered-sdk-closure.json")
        TRANSPORT.closure(TRANSPORT.regular(closure, 1024 * 1024))
        if any(c.isspace() for c in sys.executable):
            raise VerificationFailure("Trusted Python shebang path cannot contain whitespace")
        self.transport_script = script
        bindir = self.work / "bin"
        bindir.mkdir(mode=0o700)
        transport_evidence = self.evidence / "transport"
        transport_evidence.mkdir(mode=0o700)
        self.work.chmod(0o700)
        self.evidence.chmod(0o700)
        for directory in (self.root, self.work, self.evidence, transport_evidence):
            TRANSPORT.nofollow(directory)
        adapter = bindir / "git"
        raw_script = TRANSPORT.regular(script, 1024 * 1024)
        adapter.write_bytes(("#!" + sys.executable + "\n").encode() + raw_script.split(b"\n", 1)[1])
        adapter.chmod(0o700)
        (self.work / "transport.lock").write_bytes(b"")
        (self.work / "transport-state.json").write_text(json.dumps(TRANSPORT.new_state()))
        self.transport_config = {"schema": 1, "selection": SELECTION, "work": str(self.work),
            "evidence": str(transport_evidence), "app": str(self.root), "git": trusted_git,
            "closure": str(closure), "originalPATH": os.environ["PATH"], "deadline": self.deadline - CLEANUP_SECONDS,
            "appRevision": os.environ["GITHUB_SHA"], "sdkRevision": PUBLIC_PIN, "sdkTree": EXPECTED_SDK_TREE}
        config_path = self.work / "transport-config.json"
        self.transport_environment = {key: value for key, value in os.environ.items() if not key.startswith("GIT_")}
        self.transport_environment.update({"PATH": str(bindir) + os.pathsep + os.environ["PATH"],
            "GIT_NO_LAZY_FETCH": "1", "GIT_TERMINAL_PROMPT": "0", "GIT_CONFIG_NOSYSTEM": "1",
            "GIT_CONFIG_GLOBAL": "/dev/null", "FIELDLOG_TRANSPORT_CONFIG": str(config_path)})
        self.set_transport_deadline(self.deadline - CLEANUP_SECONDS)
        self.receipt["transport"] = {"experiment": SELECTION, "realGit": trusted_git,
            "adapterSourceSHA256": digest(raw_script), "closureSHA256": TRANSPORT.CLOSURE_SHA,
            "sourceRoot": str(self.root), "originalPublicURL": PUBLIC_URL,
            "sdkRevision": PUBLIC_PIN, "sdkTree": EXPECTED_SDK_TREE,
            "bounds": {"publicAcquisitionSeconds": 180, "ownedGitLogicalBytesSampled": TRANSPORT.STORAGE_LIMIT,
                "sampleIntervalSeconds": TRANSPORT.SAMPLE_SECONDS, "sampledThresholdMayOvershoot": True,
                "packageLogicalBytes": 1048576, "innerAggregateCapturedOutputBytes": TRANSPORT.INNER_AGGREGATE_OUTPUT_LIMIT,
                "innerPerCommandCapturedOutputBytes": TRANSPORT.OUTPUT_LIMIT,
                "outerAggregateCapturedOutputBytes": OUTPUT_LIMIT, "events": 8192,
                "repositoryClones": 1, "checkoutClones": 3},
            "processCustody": "Git children inherit an outer or explicitly registered SwiftPM adapter group; adapter never changes group/session; outer Runner owns final cleanup",
            "custodyScope": "recorded groups only; other SwiftPM/compiler descendants are not inventoried",
            "noLazyFetch": True, "workspaceStateFabricated": False, "alternatesFabricated": False,
            "packByteScope": "stored pack bytes; network wire bytes not measured",
            "capabilityOrDirectOIDWantFailure": "one experiment failure; no automatic fallback or retry"}
        self.save()

    def set_transport_deadline(self, deadline):
        self.transport_config["deadline"] = deadline
        path = self.work / "transport-config.json"
        path.write_text(json.dumps(self.transport_config, sort_keys=True))

    def control(self, *arguments):
        return [sys.executable, "-B", str(self.transport_script), "--control", *arguments]

    def capture_transport(self):
        path = self.work / "transport-state.json"
        if path.exists():
            self.receipt.setdefault("transport", {})["finalState"] = strict_json(TRANSPORT.regular(path, 1024 * 1024))

    def verify_checkpoint(self, scratch, tree, name, phase, before_sources):
        # All of these operations consume the original shared 480-second clock.
        self.verify_consumed_sdk(scratch, tree, name, phase)
        phase(name + "-filtered-closure", self.control("checkpoint", name))
        checkpoint_lock = self.require_pin(TRANSPORT.regular(self.root / "Package.resolved", 1024 * 1024))
        current_sources = self.source_entries(name, phase)
        if [v for v in current_sources if v["path"] != "Package.resolved"] != [v for v in before_sources if v["path"] != "Package.resolved"]:
            raise VerificationFailure("App source changed before " + name)
        checkout = scratch / "checkouts/mixer"
        declaration = phase(name + "-public-declaration", ["swift", "package", "--package-path", str(checkout),
            "--scratch-path", str(self.work / "sdk-manifest"), "--disable-dependency-cache", "dump-package"])
        value = strict_json(declaration)
        targets = value.get("targets")
        if value.get("name") != "Mixer" or value.get("dependencies") != [] or not isinstance(targets, list) or len(targets) != 9:
            raise VerificationFailure("Real SwiftPM SDK declaration differs")
        if {target.get("name"): target.get("path") for target in targets} != TRANSPORT.SDK_TARGETS:
            raise VerificationFailure("Real SwiftPM SDK target paths differ")
        if any(target.get("type") not in {"regular", "test"} or target.get("pluginUsages") for target in targets):
            raise VerificationFailure("Real SwiftPM SDK plugin/target declaration differs")
        app_declaration = phase(name + "-app-declaration", ["swift", "package", "--scratch-path", str(scratch),
            "--disable-dependency-cache", "dump-package"])
        app = strict_json(app_declaration)
        expected_dependency = [{"identity": "mixer", "location": {"remote": [{"urlString": PUBLIC_URL}]},
            "productFilter": None, "requirement": {"revision": [PUBLIC_PIN]}}]
        deps = app.get("dependencies")
        if not isinstance(deps, list) or len(deps) != 1 or deps[0].get("sourceControl") != expected_dependency:
            raise VerificationFailure("Real SwiftPM app public dependency declaration differs")
        if app.get("name") != "FieldLog" or sorted(t.get("name", "") for t in app.get("targets", [])) != ["FieldLogFeatures", "FieldLogModels", "FieldLogStorage", "FieldLogTests"]:
            raise VerificationFailure("Real SwiftPM app target declaration differs")
        self.receipt.setdefault("declarationCheckpoints", []).append({"phase": name,
            "sdkDumpSHA256": digest(declaration), "appDumpSHA256": digest(app_declaration),
            "sdkTargets": 9, "sdkExternalDependencies": 0, "sdkPlugins": 0,
            "lockOriginHash": checkpoint_lock["originHash"], "appSourcesUnchanged": True})
        self.save()

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
        self.prepare_transport()
        self.run("git-version", [str(self.real_git), "--version"], 15)
        self.run("mirror-help", ["swift", "package", "config", "set-mirror", "--help"], 20)
        mirror = self.work / "mixer.git"
        # Acquisition is a single shared 180-second stage, including capability,
        # CLI checks, metadata fetch, explicit 73-OID hydration and provenance.
        acquisition_deadline = min(time.monotonic() + 180, self.deadline - CLEANUP_SECONDS)
        self.set_transport_deadline(acquisition_deadline)
        self.run("public-filtered-acquisition", self.control("acquire"), 180,
            absolute_deadline=acquisition_deadline, environment=self.transport_environment)
        tree = EXPECTED_SDK_TREE
        self.receipt["sdk"] = {"publicURL": PUBLIC_URL, "revision": PUBLIC_PIN, "tree": tree,
            "mirror": mirror.as_uri(), "fetchDepth": 1, "qualification": "development CI mirror only",
            "closureBlobs": 73, "closureLogicalBytes": 709204, "lazyFetchAllowed": False}
        self.run("mirror-configure", ["swift", "package", "config", "set-mirror", "--original", PUBLIC_URL,
            "--mirror", mirror.as_uri()], 20)
        configured = self.run("mirror-readback", ["swift", "package", "config", "get-mirror", "--original", PUBLIC_URL], 20).decode().strip()
        if configured != mirror.as_uri():
            raise VerificationFailure("Transient package mirror readback differs")
        scratch = self.work / "host-build"
        # The same 480 s budget now spans separately observable resolve/build/test
        # phases and their intervening provenance checks. No timeout is increased.
        phase_deadline = min(time.monotonic() + HOST_PHASE_SECONDS, self.deadline - CLEANUP_SECONDS)
        self.set_transport_deadline(phase_deadline)
        self.receipt["hostPhases"] = {"sharedSecondsBound": HOST_PHASE_SECONDS,
            "resourceAccountingScope": "cumulative reaped-child usage; incomplete for un-reaped descendants",
            "outputTimestampScope": "parent capture arrival time, not child emission time"}
        self.save()

        def phase(name, command, seconds=HOST_PHASE_SECONDS):
            remaining = min(seconds, phase_deadline - time.monotonic())
            if remaining <= 0:
                raise VerificationFailure("Shared resolution/build/test time bound exhausted before " + name)
            return self.run(name, command, remaining, absolute_deadline=phase_deadline,
                environment=self.transport_environment)

        phase("host-resolve", ["swift", "package", "--scratch-path", str(scratch), "--disable-dependency-cache", "--vv", "resolve", "--skip-update"])
        self.verify_checkpoint(scratch, tree, "prebuild", phase, before_sources)
        phase("host-build-tests", ["swift", "build", "--scratch-path", str(scratch), "--jobs", "2",
            "--build-tests", "--disable-automatic-resolution", "--disable-dependency-cache", "--vv"])
        self.verify_checkpoint(scratch, tree, "pretest", phase, before_sources)
        phase_tests = ["swift", "test", "--scratch-path", str(scratch), "--jobs", "2",
            "--skip-build", "--disable-automatic-resolution", "--disable-dependency-cache"]
        tests = phase("host-tests", phase_tests)
        counts = re.findall(rb"Test run with ([0-9]{1,6}) tests(?: in [0-9]{1,6} suites)? passed after", tests)
        if counts != [str(EXPECTED_TESTS).encode()]:
            raise VerificationFailure("Expected exactly 38 executed Swift Testing functions")
        self.verify_checkpoint(scratch, tree, "posttest", phase, before_sources)
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
        after_sources = self.source_entries("after", phase)
        protected_before = [v for v in before_sources if v["path"] != "Package.resolved"]
        protected_after = [v for v in after_sources if v["path"] != "Package.resolved"]
        if protected_before != protected_after:
            raise VerificationFailure("App source changed during verification")
        final_status = phase("app-status-after", [str(self.real_git), "status", "--porcelain", "--untracked-files=normal"], 15).decode()
        expected_status = " M Package.resolved\n" if lock_changed else ""
        if final_status != expected_status:
            raise VerificationFailure("Unexpected tracked or untracked application changes")
        final_head = phase("app-head-after", [str(self.real_git), "rev-parse", "HEAD"], 15).decode().strip()
        if final_head != expected_sha:
            raise VerificationFailure("App HEAD changed during verification")
        self.receipt["lock"] = {"beforeSHA256": digest(before_bytes), "afterSHA256": digest(after_bytes),
            "pinsUnchanged": True, "originHashOnlyRefresh": origin_hash_changed,
            "originHashBefore": before_lock["originHash"], "originHashAfter": after_lock["originHash"],
            "canonicalLockResetOrCommitted": False}
        self.receipt["tests"] = {"expected": EXPECTED_TESTS, "observed": EXPECTED_TESTS, "failures": 0}
        self.capture_transport()
        if time.monotonic() >= phase_deadline:
            raise VerificationFailure("Shared phase deadline expired during final provenance")
        self.receipt["status"] = "passed-development-host-only"

    def finish(self):
        try:
            self.capture_transport()
        except BaseException:
            self.receipt["errors"].append("Transport receipt: " + traceback.format_exc(limit=10))
            self.receipt["status"] = "failed-development-host-only"
        self.receipt["endedAt"] = utc()
        self.receipt["wallSeconds"] = round(time.monotonic() - self.started, 3)
        self.receipt["capturedOutputBytes"] = self.output_bytes
        self.receipt["cancelSignal"] = self.cancel_signal
        self.receipt["cleanupVerified"] = all(
            value.get("cleanupVerified") for value in self.receipt["commands"])
        host_log = self.evidence / "host-tests.log"
        if not host_log.exists():
            self.receipt["testObservation"] = {"expected": EXPECTED_TESTS,
                "completedSummaries": [], "commandExitCode": None, "failures": None,
                "incompleteOrFailedDetails": "Test phase not reached; inspect host-resolve/host-build-tests logs"}
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

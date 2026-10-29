#!/usr/bin/env python3
"""Selected remote CI experiment. No commands execute on import.

SwiftPM owns its repositories and checkout. This adapter replaces only its two
known clone forms, explicitly primes the fixed public package, and rejects every
other Git write/network invocation. Before Git starts, the outer Runner admits
only inherited groups or explicitly registered, verified SwiftPM adapter groups.
SwiftPM cancellation keeps its original group; outer Runner owns final cleanup.
Inner timeouts fail the whole phase. No adapter changes process group/session.
"""
from __future__ import annotations
import fcntl
import hashlib
import json
import math
import os
from pathlib import Path
import re
import resource
import selectors
import stat
import subprocess
import sys
import time

SELECTION = "filtered-public-pin-host-v1"
PIN = "56ff14c925168284761c5aca4f0bd4129cf3c995"
TREE = "75989099938ed5256c4144cbc9e62979ee323183"
URL = "https://github.com/snowdamiz/mixer.git"
CLOSURE_SHA = "7a7f5e8bcee31a8ac1adae89bb3ca94b750e1d0f6c5b4809a6328de2fe7c071d"
MANIFEST_SHA = "dbb1065830923ee249e991ff393808133f97261fcaf838969c18d15a08c7811b"
CLONE_PREFIX = ["clone", "-c", "core.symlinks=true", "-c", "core.fsmonitor=false", "-c", "core.longpaths=true"]
SPARSE = b"/Package.swift\n/sdk/\n"
STORAGE_LIMIT = 512 * 1024 * 1024
OUTPUT_LIMIT = 16 * 1024 * 1024
SAMPLE_SECONDS = 0.1
OID = re.compile(r"[0-9a-f]{40}\Z")
REPO_NAME = re.compile(r"mixer-[0-9a-f]{8}\Z")
SDK_TARGETS = {"MixerCore": "sdk/Sources/MixerCore", "MixerCapabilityIO": "sdk/Sources/MixerCapabilities/NativeIO",
    "MixerCapabilities": "sdk/Sources/MixerCapabilities", "MixerUI": "sdk/Sources/MixerUI",
    "MixerApple": "sdk/Sources/MixerApple", "MixerGuest": "sdk/Sources/MixerGuest",
    "MixerCoreTests": "sdk/Tests/MixerCoreTests", "MixerUITests": "sdk/Tests/MixerUITests",
    "MixerAppleTests": "sdk/Tests/MixerAppleTests"}

class Reject(ValueError):
    pass

def sha(data):
    return hashlib.sha256(data).hexdigest()

def help_options(*streams):
    """Read exact long-option tokens from Git's indented option declarations."""
    result = set()
    for stream in streams:
        for line in stream.splitlines():
            match = re.match(rb"[ \t]+(?:-[^ \t,-], )?(--(?:\[no-\])?[a-z0-9]+(?:-[a-z0-9]+)*)(?=[ \t]|$)", line)
            if match:
                result.add(match[1].replace(b"--[no-]", b"--", 1))
    return result

def child_usage():
    usage = resource.getrusage(resource.RUSAGE_CHILDREN)
    return {"userSeconds": usage.ru_utime, "systemSeconds": usage.ru_stime,
        "maxRSSPlatformUnits": usage.ru_maxrss,
        "scope": "cumulative reaped-child accounting; not a complete descendant inventory"}

def json_value(data):
    def unique(items):
        result = {}
        for key, value in items:
            if key in result:
                raise Reject("duplicate JSON key")
            result[key] = value
        return result
    return json.loads(data, object_pairs_hook=unique)

def canonical(value):
    if not isinstance(value, (str, Path)):
        raise Reject("path type")
    value = str(value)
    if not value.startswith("/") or any(c in value for c in ("\x00", "\\", "\n", "\r", "'", '"')):
        raise Reject("noncanonical absolute path")
    if any(part in ("", ".", "..") for part in value.split("/")[1:]):
        raise Reject("noncanonical path component")
    return Path(value)

def nofollow(value, missing=False):
    """Check every component; final reads also use O_NOFOLLOW, not Path.resolve."""
    path = canonical(value)
    cursor = Path("/")
    for number, part in enumerate(path.parts[1:]):
        cursor = cursor / part
        try:
            info = cursor.lstat()
        except FileNotFoundError:
            if missing:
                return path
            raise Reject("missing path: " + str(cursor))
        if stat.S_ISLNK(info.st_mode):
            raise Reject("symlink path component: " + str(cursor))
        if number < len(path.parts) - 2 and not stat.S_ISDIR(info.st_mode):
            raise Reject("nondirectory path component")
    return path

def regular(path, limit):
    path = nofollow(path)
    descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    try:
        info = os.fstat(descriptor)
        if not stat.S_ISREG(info.st_mode) or info.st_size > limit:
            raise Reject("regular file or byte bound: " + str(path))
        chunks = []
        total = 0
        while True:
            chunk = os.read(descriptor, min(65536, limit + 1 - total))
            if not chunk:
                break
            chunks.append(chunk)
            total += len(chunk)
            if total > limit:
                raise Reject("read byte bound")
        return b"".join(chunks)
    finally:
        os.close(descriptor)

def signature(path):
    path = nofollow(path)
    info = path.lstat()
    if not stat.S_ISREG(info.st_mode) or not info.st_mode & 0o111:
        raise Reject("trusted Git must be a regular executable")
    return {"path": str(path), "device": info.st_dev, "inode": info.st_ino,
            "bytes": info.st_size, "sha256": sha(regular(path, 128 * 1024 * 1024))}

def closure(data):
    if sha(data) != CLOSURE_SHA:
        raise Reject("reviewed closure hash differs")
    value = json_value(data)
    if value["revision"] != PIN or value["tree"] != TREE:
        raise Reject("closure immutable provenance")
    entries = value["entries"]
    if len(entries) != 73 or sum(e["bytes"] for e in entries) != 709204:
        raise Reject("fixed closure size")
    names, objects = set(), {}
    for e in entries:
        name = e["path"]
        if name in names or (name != "Package.swift" and not name.startswith("sdk/")):
            raise Reject("duplicate or unselected path")
        if any(x in ("", ".", "..") for x in name.split("/")) or "\\" in name or "\x00" in name:
            raise Reject("unsafe closure path")
        if e["mode"] != "100644" or e["type"] != "blob" or not OID.fullmatch(e["oid"]):
            raise Reject("closure type/mode/OID")
        if type(e["bytes"]) is not int or not 0 <= e["bytes"] <= 1048576:
            raise Reject("closure blob limit")
        names.add(name)
        objects[e["oid"]] = e["bytes"]
    if len(objects) != 73 or "Package.swift" not in names:
        raise Reject("fixed unique blob count")
    return entries, objects

def parse_inventory(data):
    inventory = {}
    for line in data.splitlines():
        fields = line.decode("ascii").split(" ")
        if len(fields) != 3 or not OID.fullmatch(fields[0]) or fields[0] in inventory:
            raise Reject("malformed or duplicate resident object")
        oid, kind, size = fields
        if kind not in {"blob", "tree", "commit"} or not size.isdecimal() or len(size) > 12:
            raise Reject("unexpected resident object type/size")
        inventory[oid] = (kind, int(size))
    return inventory

def verify_inventory(inventory, reachable, objects, hydrated):
    metadata = {oid for oid, (kind, _) in inventory.items() if kind != "blob"}
    if metadata != set(reachable) or inventory.get(PIN, (None,))[0] != "commit" or inventory.get(TREE, (None,))[0] != "tree":
        raise Reject("missing or unexpected resident commit/tree")
    if any(kind == "commit" and oid != PIN for oid, (kind, _) in inventory.items()):
        raise Reject("unexpected commit beyond fixed shallow pin")
    blobs = {oid: size for oid, (kind, size) in inventory.items() if kind == "blob"}
    if blobs != (objects if hydrated else {}):
        raise Reject("missing, extra, wrong-sized or early blob")

def verify_tree(data, entries):
    observed = []
    if not data.endswith(b"\0"):
        raise Reject("tree lacks NUL terminator")
    for record in data.split(b"\0")[:-1]:
        header, name = record.split(b"\t", 1)
        mode, kind, oid = header.decode("ascii").split(" ")
        observed.append((name.decode("utf-8"), mode, kind, oid))
    expected = [(e["path"], e["mode"], e["type"], e["oid"]) for e in entries]
    if sorted(observed) != sorted(expected):
        raise Reject("selected Git tree differs from frozen closure")

def verify_batch(data, objects):
    offset = 0
    bodies = {}
    for oid in sorted(objects):
        newline = data.find(b"\n", offset)
        header = data[offset:newline].decode("ascii")
        if newline < offset or header != oid + " blob " + str(objects[oid]):
            raise Reject("blob batch header/order")
        offset = newline + 1
        body = data[offset:offset + objects[oid]]
        if hashlib.sha1(b"blob " + str(len(body)).encode() + b"\0" + body).hexdigest() != oid:
            raise Reject("blob bytes/hash differ")
        offset += len(body)
        if data[offset:offset + 1] != b"\n":
            raise Reject("blob batch terminator")
        offset += 1
        bodies[oid] = body
    if offset != len(data):
        raise Reject("unexpected blob batch trailer")
    return bodies

def capability(data):
    return any(b"< fetch=" in line and b"filter" in line.split(b"< fetch=", 1)[1].split() for line in data.splitlines())

def filtered(stderr):
    low = stderr.lower()
    if b"filtering not recognized" in low or b"filter is ignored" in low or b"does not support filter" in low:
        raise Reject("server ignored requested blob filter")

def new_state():
    return {"schema": 1, "metadataFetches": 0, "publicHydrations": 0, "repositoryClones": 0,
        "checkoutClones": 0, "repository": None, "ready": {}, "events": 0, "outputBytes": 0,
        "eventBytes": 0, "maxOwnedLogicalBytes": 0, "failed": False}

def clone_shape(args, work, repository):
    # SwiftPM callGit appends --progress after destination when using its handler.
    progress = args[-1:] == ["--progress"]
    raw = args[:-1] if progress else args
    if raw[:len(CLONE_PREFIX)] != CLONE_PREFIX:
        raise Reject("unknown SwiftPM clone prefix")
    tail = raw[len(CLONE_PREFIX):]
    repos = work / "host-build/repositories"
    checkout = work / "host-build/checkouts/mixer"
    mirror = work / "mixer.git"
    if len(tail) == 3 and tail[0] == "--mirror":
        _, source, destination = tail
        dest = canonical(destination)
        if source != mirror.as_uri() or dest.parent != repos or not REPO_NAME.fullmatch(dest.name):
            raise Reject("SwiftPM cache source/destination")
        kind, origin = "repository", mirror
        options = ["--mirror", "--no-local", "--filter=blob:none"]
    elif len(tail) == 4 and tail[:2] == ["--shared", "--no-checkout"]:
        _, _, source, destination = tail
        dest, origin = canonical(destination), canonical(source)
        if repository is None or origin != Path(repository) or dest != checkout:
            raise Reject("SwiftPM checkout source/destination")
        kind = "checkout"
        options = ["--no-checkout", "--no-local", "--filter=blob:none"]
    else:
        raise Reject("unsupported/editable/expanded SwiftPM clone")
    command = CLONE_PREFIX + options + [source, str(dest)] + (["--progress"] if progress else [])
    return kind, origin, dest, command

def absent_repository_destination(repo, work):
    # The one pre-clone destination observed in the selected SwiftPM host run.
    # Do not generalize absence into authority for other paths or Git commands.
    repo = canonical(repo)
    if repo != canonical(work) / "host-build/repositories/mixer-27f26b57":
        return False
    nofollow(repo.parent)  # Only the final repository component may be absent.
    nofollow(repo, missing=True)
    try:
        repo.lstat()
    except FileNotFoundError:
        return True
    return False

def read_command(args, role, inventory):
    """Exact read-only classes; no option, config injection or arbitrary revision."""
    fixed = [["remote"], ["config", "--get", "remote.origin.url"], ["tag", "-l"], ["branch", "-l"],
        ["rev-parse", "--git-dir"], ["rev-parse", "--is-bare-repository"],
        ["rev-parse", "--verify", "HEAD"], ["rev-parse", "HEAD"], ["rev-parse", "HEAD^{tree}"],
        ["rev-parse", "--abbrev-ref", "HEAD"], ["status", "-s"],
        ["status", "--porcelain", "--untracked-files=no"], ["describe", "--exact-match", "--tags"],
        ["log", "--branches", "--not", "--remotes"]]
    if role == "app":
        return args in [["rev-parse", "--show-toplevel"], ["rev-parse", "--is-inside-work-tree"],
            ["rev-parse", "--git-dir"], ["rev-parse", "HEAD"], ["rev-parse", "--verify", "HEAD"],
            ["status", "--porcelain", "--untracked-files=no"],
            ["describe", "--exact-match", "--tags"], ["status", "-s"]]
    if args in fixed:
        return True
    if len(args) == 3 and args[:2] == ["rev-parse", "--verify"]:
        return args[2] in {PIN + "^{commit}", PIN + "^{tree}", PIN, "HEAD^{commit}", "HEAD^{tree}"}
    if len(args) == 2 and args[0] == "ls-tree":
        return args[1] in inventory and inventory[args[1]][0] == "tree"
    if len(args) == 3 and args[:2] == ["cat-file", "-p"]:
        return args[2] in inventory  # All and only reviewed blobs + reachable metadata.
    return False

class Store:
    def __init__(self, config):
        self.config = config
        self.work = nofollow(config["work"])
        self.evidence = nofollow(config["evidence"])
        self.state_path = self.work / "transport-state.json"
        self.lock_path = self.work / "transport.lock"
        self.lock = None

    def __enter__(self):
        self.lock = os.open(self.lock_path, os.O_RDWR | os.O_NOFOLLOW)
        try:
            fcntl.flock(self.lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            self.state = json_value(regular(self.state_path, 1024 * 1024))
            if self.state["failed"]:
                raise Reject("transport already failed; no retry or fallback")
        except BaseException:
            os.close(self.lock)
            self.lock = None
            raise
        return self

    def __exit__(self, kind, value, tb):
        try:
            if kind is not None:
                self.state["failed"] = True
                self.state["failure"] = str(value)[:2048]
            self.save()
        finally:
            if self.lock is not None:
                os.close(self.lock)

    def save(self):
        temporary = self.work / "transport-state.saving"
        descriptor = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_TRUNC | os.O_NOFOLLOW, 0o600)
        with os.fdopen(descriptor, "w") as output:
            json.dump(self.state, output, sort_keys=True)
            output.flush()
            os.fsync(output.fileno())
        os.replace(temporary, self.state_path)

    def event(self, value):
        self.state["events"] += 1
        if self.state["events"] > 8192:
            raise Reject("transport event count bound")
        raw = (json.dumps({"monotonic": time.monotonic(), **value}, sort_keys=True) + "\n").encode()
        self.state["eventBytes"] += len(raw)
        if self.state["eventBytes"] > OUTPUT_LIMIT:
            raise Reject("transport event byte bound")
        descriptor = os.open(self.evidence / "events.jsonl", os.O_WRONLY | os.O_APPEND | os.O_CREAT | os.O_NOFOLLOW, 0o600)
        with os.fdopen(descriptor, "ab") as output:
            output.write(raw)
            output.flush()
            os.fsync(output.fileno())

    def storage(self):
        stats = {"logicalBytes": 0, "packBytes": 0, "indexBytes": 0, "looseObjectBytes": 0, "files": 0}
        for root in [self.work / "mixer.git", self.work / "host-build/repositories", self.work / "host-build/checkouts"]:
            nofollow(root, missing=True)
            if not root.exists():
                continue
            for parent, directories, files in os.walk(root, followlinks=False):
                for name in directories + files:
                    path = Path(parent) / name
                    info = path.lstat()
                    if stat.S_ISLNK(info.st_mode) or not (stat.S_ISDIR(info.st_mode) or stat.S_ISREG(info.st_mode)):
                        raise Reject("nonregular owned Git storage")
                    if not stat.S_ISREG(info.st_mode):
                        continue
                    stats["files"] += 1
                    stats["logicalBytes"] += info.st_size
                    if stats["files"] > 200000 or stats["logicalBytes"] > STORAGE_LIMIT:
                        raise Reject("sampled owned Git storage threshold exceeded")
                    if "/objects/pack/" in str(path):
                        if path.suffix == ".pack": stats["packBytes"] += info.st_size
                        elif path.suffix == ".idx": stats["indexBytes"] += info.st_size
                    elif "/objects/" in str(path) and re.fullmatch(r"[0-9a-f]{38}", name):
                        stats["looseObjectBytes"] += info.st_size
        self.state["maxOwnedLogicalBytes"] = max(stats["logicalBytes"], self.state["maxOwnedLogicalBytes"])
        return stats

class CustodyFile:
    """A bounded nomination inbox, never a process-discovery mechanism."""
    def __init__(self, path, deadline):
        self.path, self.deadline = nofollow(path), deadline
        self.lock_path = nofollow(str(path) + ".lock")

    def update(self, edit):
        descriptor = os.open(self.lock_path, os.O_RDWR | os.O_NOFOLLOW)
        try:
            # A crashed writer releases flock; a busy writer never blocks a deadline.
            fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
            state = json_value(regular(self.path, 1024 * 1024))
            result = edit(state)
            raw = json.dumps(state, sort_keys=True).encode()
            if len(raw) > 1024 * 1024:
                raise Reject("custody metadata byte bound")
            temporary = str(self.path) + ".saving"
            target = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_TRUNC | os.O_NOFOLLOW, 0o600)
            with os.fdopen(target, "wb") as output:
                output.write(raw)
                output.flush()
                os.fsync(output.fileno())
            os.replace(temporary, self.path)
            return result
        finally:
            os.close(descriptor)


def custody_identity():
    """Only this adapter, its direct parent, and the declared owner are observed."""
    pid, parent = os.getpid(), os.getppid()
    result = {"pid": pid, "ppid": parent}
    for key, operation in [("pgid", os.getpgrp), ("sid", lambda: os.getsid(0)),
            ("parentPGID", lambda: os.getpgid(parent)), ("parentSID", lambda: os.getsid(parent))]:
        try:
            result[key] = operation()
        except OSError as error:
            result[key] = None
            result.setdefault("observationErrors", []).append(key + ": " + str(error)[:200])
    return result


def valid_custody_identity(identity, owner, inherited=False):
    keys = {"pid", "pgid", "sid", "ppid", "parentPGID", "parentSID"}
    if set(identity) != keys or any(type(identity[k]) is not int or
            identity[k] < (1 if k == "parentSID" else 2) for k in keys):
        raise Reject("invalid self custody identity")
    if identity["sid"] != owner or owner <= 1:
        raise Reject("adapter outside declared owned session")
    if inherited and identity["pgid"] == owner:
        # The already-owned outer session may have a parent in system session 1.
        return
    if identity["parentSID"] <= 1:
        raise Reject("invalid self custody identity")
    if identity["pid"] == owner or identity["pgid"] != identity["pid"]:
        raise Reject("adapter is not a fresh nested group leader")
    if identity["parentPGID"] != owner or identity["parentSID"] != owner:
        raise Reject("adapter direct parent outside declared outer group/session")


class CustodyOwner:
    """Outer-runner custody of explicitly nominated SwiftPM adapter groups.

    The runner alone admits groups and performs final cleanup. SwiftPM retains
    its existing cancellation target because neither adapters nor Git children
    change their group or session.
    """
    def __init__(self, path, binding, deadline, record):
        self.path, self.binding, self.deadline, self.record = path, binding, deadline, record
        self.owner = None
        self.groups = {}
        self.closed = False
        self.ambiguous = False
        self.errors = []
        for name, raw in [(str(path) + ".lock", b""), (str(path), json.dumps({
                "schema": 1, "binding": binding, "owner": None, "open": False, "requests": {}}).encode())]:
            descriptor = os.open(name, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
            with os.fdopen(descriptor, "wb") as output:
                output.write(raw)
                output.flush()
                os.fsync(output.fileno())
        self.file = CustodyFile(path, deadline)

    def start(self, owner):
        if type(owner) is not int or owner <= 1 or self.owner is not None:
            raise Reject("invalid or repeated custody owner")
        self.owner = owner
        def begin(state):
            state.update(owner=owner, open=True)
        self.file.update(begin)

    def close(self):
        def close_admission(state):
            if state["owner"] != self.owner or state["binding"] != self.binding:
                raise Reject("custody registry binding differs at close")
            state["open"] = False
        self.file.update(close_admission)
        self.closed = True

    def poll(self):
        def inspect(state):
            if state["owner"] != self.owner or state["binding"] != self.binding or len(state["requests"]) > 512:
                raise Reject("custody registry binding/count differs")
            for key, request in state["requests"].items():
                if request["state"] != "pending":
                    continue
                identity = request["identity"]
                valid_custody_identity(identity, self.owner)
                pid = identity["pid"]
                nonce = request.get("nonce", "")
                if (not isinstance(nonce, str) or not re.fullmatch(r"[0-9a-f]{32}", nonce)
                        or key != str(pid) + "-" + nonce or pid in self.groups):
                    raise Reject("duplicate or malformed custody nomination")
                # Validate the exact nominated process and its declared parent.
                # No process enumeration, ancestry walk, or inferred adoption.
                try:
                    current = {"pgid": os.getpgid(pid), "sid": os.getsid(pid),
                        "parentPGID": os.getpgid(identity["ppid"]), "parentSID": os.getsid(identity["ppid"])}
                except ProcessLookupError:
                    request["state"] = "unadmitted-identity-gone"
                    continue
                if any(current[k] != identity[k] for k in current):
                    self.ambiguous = True
                    request["state"] = "held-identity-mismatch"
                    raise Reject("nominated nested group identity differs")
                self.groups[pid] = {"pid": pid, "pgid": pid, "sid": self.owner, "absent": False}
                self.record({"event": "nested-group-owned-before-admission", **identity,
                             "admitted": not self.closed, "binding": self.binding, "requestKey": key})
                request["state"] = "closed-owned" if self.closed else "admitted"
        self.file.update(inspect)

    def group_state(self, group):
        item = self.groups[group]
        if item["absent"]:
            return "absent"
        try:
            # The group leader may have exited with surviving children. On
            # macOS getsid(group) then cannot establish identity: hold, no signal.
            if os.getpgid(group) != group or os.getsid(group) != self.owner:
                self.ambiguous = True
                return "ambiguous-identity"
            os.killpg(group, 0)
            return "present"
        except ProcessLookupError:
            try:
                os.killpg(group, 0)
            except ProcessLookupError:
                item["absent"] = True
                self.cleanup_record({"event": "nested-group-absent", "pgid": group, "sid": self.owner})
                return "absent"
            except OSError:
                pass
            self.ambiguous = True
            return "ambiguous-leader-gone"
        except OSError:
            self.ambiguous = True
            return "ambiguous-permission"

    def signal(self, number):
        if not self.closed:
            raise Reject("custody admission must close before outer cleanup")
        for group in self.groups:
            if self.group_state(group) != "present":
                continue
            try:
                os.killpg(group, number)
                self.cleanup_record({"event": "nested-group-signal", "pgid": group, "sid": self.owner, "signal": number})
            except ProcessLookupError:
                self.group_state(group)
            except OSError as error:
                self.ambiguous = True
                self.errors.append("nested signal: " + repr(error))

    def cleanup_record(self, event):
        try:
            self.record(event)
        except BaseException as error:
            self.errors.append("nested cleanup journal: " + repr(error))

    def absent(self):
        states = [self.group_state(group) for group in self.groups]
        return self.closed and not self.ambiguous and all(state == "absent" for state in states)


def admit_adapter_group(config, store, nonce):
    identity = custody_identity()
    # Persist self facts even on rejection, before any child can be created.
    store.event({"event": "adapter-self-custody", **identity})
    store.save()
    owner = int(os.environ["FIELDLOG_TRANSPORT_PGID"])
    if int(os.environ["FIELDLOG_TRANSPORT_SID"]) != owner:
        raise Reject("declared owner group/session differ")
    path = nofollow(os.environ["FIELDLOG_TRANSPORT_CUSTODY"])
    if path.parent != canonical(config["work"]) or not re.fullmatch(r"custody-[0-9]+\.json", path.name):
        raise Reject("unexpected custody path")
    if path.lstat().st_uid != os.getuid():
        raise Reject("custody owner UID differs")
    binding = sha(regular(os.environ["FIELDLOG_TRANSPORT_CONFIG"], 65536))
    registry = CustodyFile(path, config["deadline"])
    valid_custody_identity(identity, owner, inherited=True)
    inherited = identity["pgid"] == owner
    if not isinstance(nonce, str) or not re.fullmatch(r"[0-9a-f]{32}", nonce):
        raise Reject("invalid adapter lifetime nonce")
    key = str(identity["pid"]) + "-" + nonce
    wait_deadline = min(config["deadline"], time.monotonic() + 2)
    while time.monotonic() < wait_deadline:
        def request(state):
            if state["schema"] != 1 or state["owner"] != owner or state["binding"] != binding:
                raise Reject("custody owner/config binding differs")
            if not state["open"]:
                raise Reject("outer custody admission closed")
            if inherited:
                return True
            old = state["requests"].get(key)
            if old is None:
                if len(state["requests"]) >= 512:
                    raise Reject("custody group count bound")
                state["requests"][key] = {"identity": identity, "nonce": nonce, "state": "pending"}
                return False
            if old["identity"] != identity or old["state"] not in {"pending", "admitted"}:
                raise Reject("nested custody request rejected or changed")
            return old["state"] == "admitted"
        try:
            admitted = registry.update(request)
        except BlockingIOError:
            admitted = False
        if admitted:
            current = custody_identity()
            if current != identity or time.monotonic() >= config["deadline"]:
                raise Reject("adapter identity/deadline changed after admission")
            store.event({"event": "adapter-group-admitted", **identity, "owner": owner,
                         "kind": "inherited" if inherited else "registered-nested"})
            store.save()
            return identity["pgid"]
        time.sleep(min(0.01, max(0, wait_deadline - time.monotonic())))
    raise Reject("bounded nested custody admission timed out")


class Executor:
    def __init__(self, config, store):
        self.config, self.store = config, store
        self.custody_nonce = os.urandom(16).hex()

    def __call__(self, args, input_data=None, accepted=(0,), packet=False):
        # No shell, no detached inner session, no retry and no unbounded wait.
        if input_data is not None and len(input_data) > 4096:
            raise Reject("bounded inner input protocol")
        if time.monotonic() >= self.config["deadline"]:
            raise Reject("shared transport/host deadline expired")
        expected_group = admit_adapter_group(self.config, self.store, self.custody_nonce)
        if signature(self.config["git"]["path"]) != self.config["git"]:
            raise Reject("trusted Git identity changed")
        env = {key: value for key, value in os.environ.items() if not key.startswith("GIT_")}
        env.update({"PATH": self.config["originalPATH"], "GIT_NO_LAZY_FETCH": "1", "GIT_TERMINAL_PROMPT": "0",
            "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_OPTIONAL_LOCKS": "0"})
        if packet: env["GIT_TRACE_PACKET"] = "1"
        env["FIELDLOG_TRANSPORT_INNER"] = "1"
        env["FIELDLOG_TRANSPORT_EXEC_PGID"] = str(expected_group)
        gate_read = gate_write = None
        process = None
        collector = None
        stdout, stderr = bytearray(), bytearray()
        started = time.monotonic()
        ended = False
        identity = False
        logs_written = False
        log_number = self.store.state["events"] + 1
        usage_before = child_usage()
        try:
            collector = selectors.DefaultSelector()
            gate_read, gate_write = os.pipe()
            process = subprocess.Popen([sys.executable, "-B", str(Path(__file__).absolute()), "--inner-child", str(gate_read), *args],
                cwd=self.config["app"], env=env, stdin=subprocess.PIPE if input_data is not None else subprocess.DEVNULL,
                stdout=subprocess.PIPE, stderr=subprocess.PIPE, pass_fds=(gate_read,), start_new_session=False)
            os.close(gate_read)
            gate_read = None
            identity = os.getpgid(process.pid) == expected_group and os.getsid(process.pid) == int(os.environ["FIELDLOG_TRANSPORT_SID"])
            # fsync before releasing the inner child. It cannot exec Git earlier.
            self.store.event({"event": "inner-created-before-execution", "pid": process.pid,
                "inheritedPGID": expected_group, "identityVerified": identity, "argv": args})
            self.store.save()
            if not identity or time.monotonic() >= self.config["deadline"]:
                raise Reject("inner identity/deadline; command unadmitted")
            collector.register(process.stdout, selectors.EVENT_READ, stdout)
            collector.register(process.stderr, selectors.EVENT_READ, stderr)
            os.write(gate_write, b"G")
            os.close(gate_write)
            gate_write = None
            if input_data is not None:
                process.stdin.write(input_data)
                process.stdin.close()
            next_sample = 0
            samples, maximum_gap, last_sample = 0, 0.0, None
            while time.monotonic() < self.config["deadline"]:
                now = time.monotonic()
                if now >= next_sample:
                    sample_started = time.monotonic()
                    self.store.storage()
                    if last_sample is not None: maximum_gap = max(maximum_gap, now - last_sample)
                    last_sample = now
                    next_sample = sample_started + SAMPLE_SECONDS
                    samples += 1
                for key, _ in collector.select(timeout=min(0.05, max(0, self.config["deadline"] - time.monotonic()))):
                    block = os.read(key.fd, 65536)
                    if not block:
                        collector.unregister(key.fileobj)
                    else:
                        self.store.state["outputBytes"] += len(block)
                        if self.store.state["outputBytes"] > OUTPUT_LIMIT:
                            raise Reject("aggregate inner command output bound")
                        key.data.extend(block)
                code = process.poll()
                if code is not None and not collector.get_map():
                    ended = True
                    break
            if not ended:
                raise Reject("inner deadline; outer Runner must clean inherited group")
            filtered(stderr)
            for suffix, data in [("stdout", stdout), ("stderr", stderr)]:
                path = self.store.evidence / (str(log_number) + "." + suffix + ".log")
                descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
                with os.fdopen(descriptor, "wb") as output: output.write(data)
            logs_written = True
            self.store.event({"event": "inner-terminal", "pid": process.pid, "exitCode": code,
                "wallSeconds": time.monotonic() - started, "stdoutBytes": len(stdout), "stderrBytes": len(stderr),
                "storage": self.store.storage(), "storageSamples": samples, "sampleIntervalSeconds": SAMPLE_SECONDS,
                "maximumObservedSampleGapSeconds": maximum_gap, "logNumber": log_number,
                "childUsageBefore": usage_before, "childUsageAfter": child_usage(),
                "wireBytesMeasured": False, "directChildReaped": True, "inheritedGroupCleanup": "outer Runner"})
            if code not in accepted:
                raise Reject("Git command failed (no retry): " + str(code) + " " + repr(args))
            return bytes(stdout), bytes(stderr), code
        finally:
            for descriptor in (gate_read, gate_write):
                if descriptor is not None: os.close(descriptor)
            if collector is not None: collector.close()
            if process is not None:
                for stream in (process.stdin, process.stdout, process.stderr):
                    if stream is not None and not stream.closed: stream.close()
                if not logs_written:
                    # Retain bounded partial diagnostics for timeout/storage/
                    # identity failures too. This never skips outer cleanup.
                    for suffix, data in [("stdout", stdout), ("stderr", stderr)]:
                        path = self.store.evidence / (str(log_number) + "." + suffix + ".partial.log")
                        descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
                        with os.fdopen(descriptor, "wb") as output: output.write(data)
                # Never signal the shared outer group or wait without a bound.
                # On error it may still exist; failing the phase invokes Runner cleanup.
                self.store.event({"event": "inner-protocol-exit", "pid": process.pid,
                    "identityVerified": identity, "directChildReaped": ended,
                    "groupDetached": False, "cleanupAuthority": "outer Runner",
                    "partialStdoutBytes": len(stdout), "partialStderrBytes": len(stderr)})

class Controller:
    def __init__(self, config, store, execute=None):
        self.config, self.store = config, store
        self.work = canonical(config["work"])
        self.entries, self.objects = closure(regular(config["closure"], 1024 * 1024))
        self.execute = execute or Executor(config, store)

    def git(self, args, **kwargs):
        return self.execute(args, **kwargs)[0]

    def local(self, repo, args, **kwargs):
        nofollow(repo)
        return self.git(["-C", str(repo), *args], **kwargs)

    def metadata(self, repo, hydrated):
        pin = self.local(repo, ["rev-parse", "HEAD"]).decode().strip()
        tree = self.local(repo, ["rev-parse", "HEAD^{tree}"]).decode().strip()
        if pin != PIN or tree != TREE:
            raise Reject("actually fetched/consumed immutable commit/tree mismatch")
        inventory = parse_inventory(self.local(repo, ["cat-file", "--batch-all-objects", "--batch-check=%(objectname) %(objecttype) %(objectsize)"]))
        reachable = self.local(repo, ["rev-list", "--objects", "--no-object-names", "--filter=blob:none", PIN]).decode().splitlines()
        if len(reachable) != len(set(reachable)) or any(not OID.fullmatch(x) for x in reachable):
            raise Reject("reachable metadata inventory malformed")
        verify_inventory(inventory, reachable, self.objects, hydrated)
        verify_tree(self.local(repo, ["ls-tree", "-r", "-z", PIN, "--", "Package.swift", "sdk"]), self.entries)
        gitdir = repo if repo.name != "mixer" else repo / ".git"
        if regular(gitdir / "shallow", 1024) != (PIN + "\n").encode():
            raise Reject("fixed shallow boundary differs")
        if (gitdir / "objects/info/alternates").exists() or (gitdir / "objects/info/http-alternates").exists():
            raise Reject("unapproved object alternate; never fabricate/repair")
        for key, value in [("remote.origin.promisor", "true"), ("remote.origin.partialclonefilter", "blob:none")]:
            if self.local(repo, ["config", "--get", key]).decode().strip() != value:
                raise Reject("partial clone configuration changed")
        if hydrated:
            bodies = verify_batch(self.local(repo, ["cat-file", "--batch"],
                input_data=("\n".join(sorted(self.objects)) + "\n").encode()), self.objects)
            manifest = next(e for e in self.entries if e["path"] == "Package.swift")
            if sha(bodies[manifest["oid"]]) != MANIFEST_SHA:
                raise Reject("original public manifest bytes differ")
            # A hash-bound snapshot authorizes subsequent read-only requests.
            # Re-reading every blob for every ls-tree would spend the finite
            # output budget on duplicate audit payloads. Full audits run again
            # at all three actual consumption checkpoints.
            cached = self.store.evidence / (sha(str(repo).encode()) + ".inventory.json")
            raw = json.dumps(inventory, sort_keys=True, separators=(",", ":")).encode()
            descriptor = os.open(cached, os.O_WRONLY | os.O_CREAT | os.O_TRUNC | os.O_NOFOLLOW, 0o600)
            with os.fdopen(descriptor, "wb") as output: output.write(raw)
            self.store.state.setdefault("inventories", {})[str(repo)] = {"path": str(cached), "sha256": sha(raw)}
        self.store.event({"event": "repository-audit", "repository": str(repo), "hydrated": hydrated,
            "revision": pin, "tree": tree, "objectCounts": {kind: sum(v[0] == kind for v in inventory.values())
                for kind in ("commit", "tree", "blob")}, "storage": self.store.storage()})
        return inventory

    def origin(self, repo, expected):
        if self.local(repo, ["config", "--get", "remote.origin.url"]).decode().strip() != expected:
            raise Reject("source transport origin changed")

    def worktree(self, checkout, permit_empty=False):
        checkout = nofollow(checkout)
        gitdir = nofollow(checkout / ".git")
        if not gitdir.is_dir() or regular(gitdir / "info/sparse-checkout", 1024) != SPARSE:
            raise Reject("exact non-cone sparse rules differ")
        for key, expected in [("core.sparseCheckout", "true"), ("core.sparseCheckoutCone", "false"), ("index.sparse", "false")]:
            if self.local(checkout, ["config", "--get", key]).decode().strip() != expected:
                raise Reject("sparse configuration differs")
        found = {}
        for parent, directories, files in os.walk(checkout, followlinks=False):
            if Path(parent) == checkout:
                directories.remove(".git")
            for name in directories + files:
                path = Path(parent) / name
                info = path.lstat()
                if stat.S_ISLNK(info.st_mode) or not (stat.S_ISDIR(info.st_mode) or stat.S_ISREG(info.st_mode)):
                    raise Reject("sparse worktree has symlink/gitlink/nonregular entry")
            for name in files:
                path = Path(parent) / name
                found[path.relative_to(checkout).as_posix()] = regular(path, 1048576)
        if not found and permit_empty:
            return {"materialized": False, "files": 0}
        if set(found) != {e["path"] for e in self.entries}:
            raise Reject("missing/extra selected working files")
        for e in self.entries:
            data = found[e["path"]]
            if len(data) != e["bytes"] or hashlib.sha1(b"blob " + str(len(data)).encode() + b"\0" + data).hexdigest() != e["oid"]:
                raise Reject("selected working bytes/hash differ")
        if sha(found["Package.swift"]) != MANIFEST_SHA:
            raise Reject("working original public manifest differs")
        if self.local(checkout, ["status", "--porcelain", "--untracked-files=no"]).strip():
            raise Reject("consumed checkout dirty")
        return {"materialized": True, "files": len(found), "logicalBytes": sum(map(len, found.values()))}

    def hydrate(self, repo, source):
        # Explicit missing-object fetches must not advertise the shallow pin as
        # complete. Keep promisor semantics while requesting only reviewed OIDs.
        requested = ("\n".join(sorted(self.objects)) + "\n").encode("ascii")
        self.local(repo, ["-c", "protocol.version=2", "-c", "fetch.negotiationAlgorithm=noop",
            "fetch", "--no-tags", "--no-write-fetch-head", "--recurse-submodules=no",
            "--filter=blob:none", "--stdin", "origin"], input_data=requested, packet=(source == "origin"))
        return self.metadata(repo, True)

    def acquire(self):
        s = self.store.state
        if s["metadataFetches"] or s["publicHydrations"]:
            raise Reject("one acquisition only")
        version = self.git(["--version"]).decode().strip()
        if not re.fullmatch(r"git version [0-9]+\.[0-9]+(?:\.[0-9]+)?(?: \(Apple Git-[0-9.]+\))?", version):
            raise Reject("unrecognized real Git version")
        for args, tokens in [(["clone", "-h"], [b"--filter", b"--local"]),
                (["fetch", "-h"], [b"--filter", b"--depth", b"--write-fetch-head", b"--tags", b"--stdin"])]:
            out, err, _ = self.execute(args, accepted=(0, 129))
            if not set(tokens) <= help_options(out, err): raise Reject("real Git CLI lacks reviewed flags")
        _, advertised, _ = self.execute(["-c", "protocol.version=2", "ls-remote", URL, PIN], packet=True)
        if not capability(advertised): raise Reject("public protocol-v2 filter capability absent")
        mirror = self.work / "mixer.git"
        nofollow(mirror, missing=True)
        if mirror.exists(): raise Reject("fresh nonexistent public mirror required")
        self.git(["init", "--bare", str(mirror)])
        for key, value in [("remote.origin.url", URL), ("remote.origin.promisor", "true"),
                ("remote.origin.partialclonefilter", "blob:none"), ("uploadpack.allowFilter", "true"),
                ("uploadpack.allowAnySHA1InWant", "true")]:
            self.local(mirror, ["config", "--local", key, value])
        s["metadataFetches"] += 1
        self.store.save()
        self.local(mirror, ["-c", "protocol.version=2", "fetch", "--no-tags", "--depth=1", "--filter=blob:none",
            "origin", PIN + ":refs/heads/public-sdk-pin"])
        self.local(mirror, ["symbolic-ref", "HEAD", "refs/heads/public-sdk-pin"])
        self.origin(mirror, URL)
        self.metadata(mirror, False)
        s["publicHydrations"] += 1
        self.store.save()
        self.hydrate(mirror, "origin")
        s["ready"][str(mirror)] = True
        self.store.event({"event": "acquisition-complete", "gitVersion": version,
            "publicMetadataFetches": 1, "publicHydrationBatches": 1, "requestedBlobOIDs": 73})

    def clone(self, args):
        s = self.store.state
        kind, source, destination, command = clone_shape(args, self.work, s["repository"])
        nofollow(source)
        nofollow(destination, missing=True)
        if destination.exists() or not s["ready"].get(str(source)):
            raise Reject("nonexistent clone destination and audited owned source required")
        key, maximum = ("repositoryClones", 1) if kind == "repository" else ("checkoutClones", 3)
        if s[key] >= maximum: raise Reject("bounded SwiftPM clone count exceeded")
        self.metadata(source, True)
        s[key] += 1
        s["ready"].pop(str(destination), None)
        self.store.save()
        self.git(command)
        self.origin(destination, source.as_uri() if kind == "repository" else str(source))
        self.metadata(destination, False)
        self.hydrate(destination, source.as_uri() if kind == "repository" else str(source))
        if kind == "repository":
            for key in ["uploadpack.allowFilter", "uploadpack.allowAnySHA1InWant"]:
                self.local(destination, ["config", "--local", key, "true"])
            s["repository"] = str(destination)
        else:
            out, err, _ = self.execute(["-C", str(destination), "sparse-checkout", "set", "-h"], accepted=(0, 129))
            if not {b"--cone", b"--sparse-index"} <= help_options(out, err):
                raise Reject("real Git sparse CLI lacks reviewed flags")
            self.local(destination, ["sparse-checkout", "set", "--no-cone", "--no-sparse-index", "/Package.swift", "/sdk/"])
            self.worktree(destination, permit_empty=True)
        s["ready"][str(destination)] = True
        self.store.event({"event": "swiftpm-clone-complete", "kind": kind, "source": str(source),
            "destination": str(destination), "count": s["repositoryClones"] if kind == "repository" else s["checkoutClones"],
            "alternateFabricated": False, "workspaceStateWritten": False})
        return b"", b"", 0

    def checkpoint(self, phase):
        s = self.store.state
        if s["repository"] is None or s["repositoryClones"] != 1 or not 1 <= s["checkoutClones"] <= 3:
            raise Reject("missing real SwiftPM clone provenance")
        mirror, repository, checkout = self.work / "mixer.git", Path(s["repository"]), self.work / "host-build/checkouts/mixer"
        self.origin(mirror, URL)
        self.origin(repository, mirror.as_uri())
        self.origin(checkout, str(repository))
        self.metadata(checkout, True)
        selected = self.worktree(checkout)
        workspace = json_value(regular(self.work / "host-build/workspace-state.json", 1024 * 1024))
        dependencies = workspace.get("object", {}).get("dependencies")
        if not isinstance(dependencies, list) or len(dependencies) != 1:
            raise Reject("SwiftPM generated dependency record differs")
        dep = dependencies[0]
        ref = dep.get("packageRef", {})
        source = ref.get("location")
        if source not in {URL, mirror.as_uri()} or ref.get("identity") != "mixer" or ref.get("kind") != "remoteSourceControl":
            raise Reject("SwiftPM generated source identity/location differs")
        if dep.get("subpath") != "mixer" or dep.get("state") != {"checkoutState": {"revision": PIN}, "name": "sourceControlCheckout"}:
            raise Reject("SwiftPM generated immutable checkout record differs")
        self.store.event({"event": "consumption-checkpoint", "phase": phase, "selected": selected,
            "workspaceStateSHA256": sha(regular(self.work / "host-build/workspace-state.json", 1024 * 1024)),
            "workspaceStateReadOnly": True})
        return selected

    def dispatch(self, args, cwd):
        if sum(len(x) for x in args) > 32768 or len(args) > 256 or any("\x00" in x or "\n" in x for x in args):
            raise Reject("argv bounds")
        self.store.event({"event": "swiftpm-git-request", "argv": args, "cwd": str(cwd)})
        if args[:1] == ["clone"]: return self.clone(args)
        if args == ["--version"] or args == ["check-ref-format", "--allow-onelevel", PIN]:
            return self.execute(args)
        repo, tail = (canonical(args[1]), args[2:]) if len(args) >= 3 and args[0] == "-C" else (canonical(cwd), args)
        if (args == ["-C", str(repo), "rev-parse", "--git-dir"]
                and absent_repository_destination(repo, self.work)):
            s = self.store.state
            if (s["repository"] is not None or s["repositoryClones"] != 0
                    or s["metadataFetches"] != 1 or s["publicHydrations"] != 1
                    or s["ready"].get(str(repo)) or not s["ready"].get(str(self.work / "mixer.git"))):
                raise Reject("absent repository probe requires audited pre-clone state")
            # Executor starts in the existing app directory. Let real Git handle
            # the explicit -C failure under the unchanged ownership/child gate.
            result = self.execute(args, accepted=(128,))
            expected = ("fatal: cannot change to '" + str(repo) + "': No such file or directory\n").encode()
            if result != (b"", expected, 128) or not absent_repository_destination(repo, self.work):
                raise Reject("unexpected absent repository probe result or path change")
            self.store.event({"event": "absent-repository-probe", "repository": str(repo),
                "exitCode": 128, "repositoryCreated": False, "result": "expected-git-enoent"})
            return result
        nofollow(repo)
        if repo == canonical(self.config["app"]):
            if not read_command(tail, "app", {}): raise Reject("unknown app Git request")
            return self.execute(["-C", str(repo), *tail], accepted=tuple(range(256)))
        if not self.store.state["ready"].get(str(repo)):
            raise Reject("unowned or unaudited Git repository")
        cached = self.store.state.get("inventories", {}).get(str(repo))
        if cached is None or canonical(cached["path"]).parent != self.store.evidence:
            raise Reject("audited object inventory absent")
        raw = regular(cached["path"], OUTPUT_LIMIT)
        if sha(raw) != cached["sha256"]: raise Reject("audited object inventory changed")
        inventory = json_value(raw)
        checkout = self.work / "host-build/checkouts/mixer"
        if tail == ["checkout", "-f", PIN] and repo == checkout:
            self.worktree(repo, permit_empty=True)
            result = self.execute(["-C", str(repo), *tail])
            self.worktree(repo)
            return result
        if not read_command(tail, "owned", inventory): raise Reject("unknown Git network/write/read invocation")
        return self.execute(["-C", str(repo), *tail], accepted=tuple(range(256)))

def load_config():
    if os.environ.get("GITHUB_ACTIONS") != "true" or os.environ.get("FIELDLOG_HOST_CI_SELECTION") != SELECTION:
        raise Reject("remote selected experiment only")
    temporary = nofollow(os.environ["RUNNER_TEMP"])
    config_path = nofollow(os.environ["FIELDLOG_TRANSPORT_CONFIG"])
    if config_path != temporary / "fieldlog-host-ci-work/transport-config.json":
        raise Reject("unexpected transport configuration path")
    config = json_value(regular(config_path, 65536))
    if config.get("schema") != 1 or config.get("selection") != SELECTION or config.get("work") != str(temporary / "fieldlog-host-ci-work"):
        raise Reject("configuration selection/fresh scratch role")
    if config.get("app") != str(nofollow(os.environ["GITHUB_WORKSPACE"])):
        raise Reject("configuration app sourceRoot differs")
    if config.get("appRevision") != os.environ.get("GITHUB_SHA") or not OID.fullmatch(config.get("appRevision", "")) or config.get("sdkRevision") != PIN or config.get("sdkTree") != TREE:
        raise Reject("configuration exact app/public SDK pins differ")
    for key in ["work", "evidence", "app", "closure"]: nofollow(config[key])
    if canonical(config["evidence"]) != temporary / "fieldlog-host-ci-evidence/transport":
        raise Reject("unexpected evidence path")
    if type(config.get("deadline")) not in {int, float} or not math.isfinite(config["deadline"]) or config["deadline"] <= time.monotonic():
        raise Reject("shared deadline expired")
    for name in ["work", "evidence"]:
        if Path(config[name]).lstat().st_uid != os.getuid(): raise Reject("owned scratch UID differs")
    if signature(config["git"]["path"]) != config["git"]: raise Reject("real Git identity differs")
    return config

def inner_entry(arguments):
    config = load_config()
    if os.environ.get("FIELDLOG_TRANSPORT_INNER") != "1" or len(arguments) < 2:
        return 125
    descriptor = int(arguments[0])
    try: admitted = os.read(descriptor, 1) == b"G"
    finally: os.close(descriptor)
    group = int(os.environ["FIELDLOG_TRANSPORT_EXEC_PGID"])
    owner = int(os.environ["FIELDLOG_TRANSPORT_PGID"])
    if (not admitted or os.getpgrp() != group or group <= 1 or owner <= 1
            or int(os.environ["FIELDLOG_TRANSPORT_SID"]) != owner or os.getsid(0) != owner
            or time.monotonic() >= config["deadline"]):
        return 125
    os.execve(config["git"]["path"], [config["git"]["path"], *arguments[1:]], os.environ.copy())
    return 125

def main(arguments):
    config = load_config()
    with Store(config) as store:
        controller = Controller(config, store)
        try:
            if arguments == ["--control", "acquire"]:
                controller.acquire()
                return 0
            if len(arguments) == 3 and arguments[:2] == ["--control", "checkpoint"] and arguments[2] in {"prebuild", "pretest", "posttest"}:
                controller.checkpoint(arguments[2])
                return 0
            if arguments[:1] == ["--control"]: raise Reject("unknown control command")
            out, err, code = controller.dispatch(arguments, os.getcwd())
            sys.stdout.buffer.write(out)
            sys.stderr.buffer.write(err)
            return code
        except BaseException as error:
            store.event({"event": "transport-failure", "message": str(error)[:4096], "noRetry": True})
            raise

if __name__ == "__main__":
    try:
        code = inner_entry(sys.argv[2:]) if sys.argv[1:2] == ["--inner-child"] else main(sys.argv[1:])
    except BaseException as error:
        print("FILTERED-TRANSPORT REFUSED: " + str(error), file=sys.stderr)
        code = 125
    raise SystemExit(code)

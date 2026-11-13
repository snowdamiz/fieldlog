#!/usr/bin/env python3
"""Materialize and build FieldLog's public-host Android app in a fresh directory."""
import argparse
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import tempfile
import time

PIN = "8efc1a9e5b1602117f8211c95bfd4203cc91f689"
APP = Path(__file__).resolve().parents[1]


def app_inputs():
    # Validate the complete app-owned unit before creating any build output.
    platform = APP / "Platforms/Android"
    files = [(platform / "ApplicationPackage.swift", Path("Package.swift")),
             (platform / "Package.swift", Path("Platforms/Android/Package.swift")),
             (platform / "AndroidManifest.xml", Path("Platforms/Android/AndroidManifest.xml")),
             (platform / "Bridge/PublicBridge.c", Path("Platforms/Android/Bridge/PublicBridge.c"))]
    java = Path("Java/dev/fieldlog/generatedr90/androidhost")
    files += [(platform / java / name, Path("Platforms/Android") / java / name)
              for name in ("PublicBridge.java", "PublicActivity.java")]
    files += [(APP / "Sources/FieldLogAndroid" / name,
               Path("Platforms/Android/Sources/AppAndroid") / name)
              for name in ("NativeEntry.swift", "PublicFactory.swift")]
    for source, _ in files:
        if not source.is_file():
            raise ValueError("missing app-owned Android input: " + str(source))
    modules = ("FieldLogModels", "FieldLogStorage", "FieldLogFeatures")
    for source in [*(APP / "Sources" / module for module in modules),
                   APP / "Tests/FieldLogAndroidTests"]:
        if not source.is_dir():
            raise ValueError("missing app input: " + str(source))

    return files, modules


def install_app_inputs(output, files, modules):
    """Install app sources after public mixer create; preserve Generated/MixerSDK."""
    # Replace the starter bridge and Swift entry together, before mixer build.
    entry = output / "Platforms/Android/Sources/AppAndroid"
    tests = output / "Platforms/Android/Tests/AppAndroidTests"
    for directory in (entry, tests):
        for starter in directory.glob("*.swift"):
            starter.unlink()
    for source, relative in files:
        target = output / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(source, target)
    for module in modules:
        shutil.copytree(APP / "Sources" / module, output / "Sources" / module)
    for source in (APP / "Tests/FieldLogAndroidTests").glob("*.swift"):
        shutil.copyfile(source, tests / source.name)
    (output / "Resources").mkdir(exist_ok=True)



def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--mixer", required=True, type=Path)
    parser.add_argument("--sdk-checkout", required=True, type=Path)
    parser.add_argument("--android-adapter-path", required=True, type=Path,
                        help="Separate Android adapter directory admitted by the selected public CLI")
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--prepare-only", action="store_true", help="Run public mixer create and install app inputs without a native build")
    args = parser.parse_args()
    if args.output.is_symlink() or args.output.exists():
        parser.error("output must be absent; nothing was changed")
    output = args.output.resolve()
    sdk = args.sdk_checkout.resolve(strict=True)
    mixer = args.mixer.resolve(strict=True)
    adapter = args.android_adapter_path.resolve(strict=True)
    for source in (APP, sdk, mixer, adapter):
        if output == source or output in source.parents or source in output.parents:
            parser.error("output must be separate from the app, SDK, Android adapter, and Mixer executable")
    if not mixer.is_file() or not os.access(mixer, os.X_OK):
        parser.error("--mixer must name an executable Mixer CLI")
    if not (sdk / "sdk/Package.swift").is_file():
        parser.error("--sdk-checkout must be a revision-pinned checkout with required Swift SDK inputs")
    if not adapter.is_dir():
        parser.error("--android-adapter-path must name an Android adapter directory")
    for command, expected in ((["rev-parse", "HEAD"], PIN),
                              (["rev-parse", "--show-toplevel"], str(sdk)),
                              (["status", "--porcelain"], "")):
        observed = subprocess.check_output(
            ["git", "--no-optional-locks", "-C", str(sdk), *command],
            text=True, timeout=15).strip()
        if observed != expected:
            parser.error("SDK must be a clean revision-pinned checkout with required Swift SDK inputs at " + PIN)

    files, modules = app_inputs()

    output.parent.mkdir(parents=True, exist_ok=True)
    logs = Path(tempfile.mkdtemp(prefix=output.name + "-logs-", dir=output.parent))
    env = os.environ.copy()
    deadline = time.monotonic() + 600
    records = []

    def run(label, argv):
        record = {"label": label, "argv": [str(a) for a in argv], "cwd": str(output.parent)}
        records.append(record)
        with (logs / (label + ".log")).open("wb") as raw:
            process = subprocess.Popen(record["argv"], cwd=output.parent, env=env,
                                       stdout=raw, stderr=subprocess.STDOUT, start_new_session=True)
            record.update(pid=process.pid, pgid=process.pid)
            (logs / "commands.json").write_text(json.dumps(records, indent=2) + "\n")
            try:
                record["exitCode"] = process.wait(timeout=max(1, deadline - time.monotonic()))
            except subprocess.TimeoutExpired:
                # Only this newly owned command group is eligible for cleanup.
                os.killpg(process.pid, signal.SIGTERM)
                try:
                    process.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    os.killpg(process.pid, signal.SIGKILL)
                    process.wait(timeout=10)
                record["timedOut"] = True
                record["exitCode"] = process.returncode
            try:
                os.killpg(process.pid, 0)
                record["ownedGroupAbsent"] = False
            except ProcessLookupError:
                record["ownedGroupAbsent"] = True
            except PermissionError:
                record["ownedGroupAbsent"] = False
            (logs / "commands.json").write_text(json.dumps(records, indent=2) + "\n")
        print(label + ": exit " + str(record["exitCode"]) + "; raw output " + str(logs / (label + ".log")), flush=True)
        if record["exitCode"] or record.get("timedOut") or not record["ownedGroupAbsent"]:
            raise RuntimeError(label + " failed or has unresolved command custody; retain " + str(logs))

    run("create", [mixer, "create", "FieldLogGenerated", "--platform", "android",
                   "--android-host", "public-v4", "--directory", output,
                   "--application", "dev.fieldlog.generatedr90", "--sdk-path", sdk / "sdk",
                   "--android-adapter-path", adapter])
    install_app_inputs(output, files, modules)
    if args.prepare_only:
        logs.rename(output / ".fieldlog-build")
        print("Prepared app-owned sources: " + str(output))
        return
    run("build", [mixer, "build", "--platform", "android", "--directory", output])
    apk = output / ".mixer/android-build/FieldLogGenerated-unsigned.apk"
    if not apk.is_file():
        raise RuntimeError("Mixer returned without the expected unsigned APK; retain " + str(logs))
    retained = output / ".fieldlog-build"
    logs.rename(retained)
    print("Unsigned APK: " + str(apk))
    print("Raw command output: " + str(retained))


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, RuntimeError, subprocess.SubprocessError) as error:
        sys.exit(str(error))

#!/usr/bin/env python3
"""Exercise the actual app installer without invoking a native build."""
import argparse
import hashlib
import importlib.util
import json
from pathlib import Path
APP = Path(__file__).resolve().parents[1]
p = argparse.ArgumentParser(description=__doc__)
p.add_argument("--output", required=True, type=Path)
p.add_argument("--sdk", required=True, type=Path)
a = p.parse_args()
if a.output.exists(): p.error("output must be absent")
spec=importlib.util.spec_from_file_location("fieldlog_builder",APP/"scripts/build-android.py")
builder=importlib.util.module_from_spec(spec);spec.loader.exec_module(builder)
files,modules=builder.app_inputs()
for name in ("Platforms/Android/Sources/AppAndroid", "Platforms/Android/Tests/AppAndroidTests", "Generated"):
    (a.output/name).mkdir(parents=True, exist_ok=True)
sdk=a.sdk.resolve(strict=True)
(a.output/"Generated/MixerSDK").symlink_to(sdk,target_is_directory=True)
def digest():
    return {str(x.relative_to(sdk)):hashlib.sha256(x.read_bytes()).hexdigest() for x in sdk.rglob("*") if x.is_file()}
before=digest()
builder.install_app_inputs(a.output,files,modules)
for source,relative in files:
    assert (a.output/relative).read_bytes()==source.read_bytes(), relative
for module in modules:
    for source in (APP/"Sources"/module).rglob("*"):
        if source.is_file(): assert (a.output/"Sources"/module/source.relative_to(APP/"Sources"/module)).read_bytes()==source.read_bytes()
for source in (APP/"Tests/FieldLogAndroidTests").glob("*.swift"):
    assert (a.output/"Platforms/Android/Tests/AppAndroidTests"/source.name).read_bytes()==source.read_bytes()
assert before==digest(), "public SDK changed"
assert not list((a.output/"Platforms/Android/Java").rglob("NativeRendererSDK.java")), "Mixer renderer copied into app"
print(json.dumps({"app_inputs":len(files),"modules":list(modules),"android_test_files":len(list((APP/"Tests/FieldLogAndroidTests").glob("*.swift"))),"sdk_blobs_unchanged":len(before),"scope":"actual installer; public CLI create and native build not invoked"}))

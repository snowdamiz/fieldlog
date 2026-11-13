#!/usr/bin/env python3
"""Extract the unchanged app-owned report helpers for ordinary JVM checks."""
import argparse
import hashlib
import json
from pathlib import Path
APP = Path(__file__).resolve().parents[1]
p = argparse.ArgumentParser(description=__doc__)
p.add_argument("--output", required=True, type=Path)
a = p.parse_args()
if a.output.exists():
    p.error("output must be absent")
bridge = APP / "Platforms/Android/Java/dev/fieldlog/generatedr90/androidhost/PublicBridge.java"
text = bridge.read_text()
start = text.index("static final class ReportFiles {")
end = text.index("static final class ReportIntent {", start)
body = text[start:end].rstrip()
root_start = text.index("/** Canonicalize the trusted Context root before crossing the Swift boundary. */")
root_end = text.rindex("\n}")
root_body = text[root_start:root_end].rstrip()
if "static final class ReportRoot {" not in root_body:
    raise ValueError("ReportRoot must be a static nested production helper")
# ReportFiles has only java.io/java.nio/java.util dependencies. No Android or SDK replacement.
source = "package dev.fieldlog.generatedr90.androidhost;\nimport java.io.*;\nimport java.nio.file.*;\nimport java.nio.file.attribute.BasicFileAttributes;\nimport java.util.UUID;\nfinal class PublicBridge {\n" + body + "\n\n" + root_body + "\n}\n"
a.output.mkdir(parents=True)
(a.output / "PublicBridge.java").write_text(source)
(a.output / "extraction.json").write_text(json.dumps({"source": str(bridge), "source_sha256": hashlib.sha256(bridge.read_bytes()).hexdigest(), "report_files_sha256": hashlib.sha256(body.encode()).hexdigest(), "report_root_sha256": hashlib.sha256(root_body.encode()).hexdigest(), "scope": "exact nested ReportFiles and nested ReportRoot bodies; standard JDK imports only"}, indent=2))
print(a.output)

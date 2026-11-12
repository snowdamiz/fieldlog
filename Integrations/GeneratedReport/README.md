# Generated FieldLog report integration

This additive development package preserves the ordinary FieldLog app and its original package, lock files, iOS sources, tests, workflow, and behavior. The baseline repository has no Android host or shared EntryEditor and lacks the attachPhoto storage method required by the tested generated app. This package keeps that app as a separate integration rather than replacing those original targets.

Sources and host tests come from the accepted R992 source ZIP (SHA-256 b9b725460ccb69e78cc4962217b089ebc323ce2fc3244f48a451a38fcdeb472b). PublicActivity and PublicBridge incorporate the independently reviewed R1702 report fix. ReportRoot exposes the same trusted-root canonicalization for ordinary JVM testing. ReportFiles, ReportIntent, the source descriptor checks, strict child no-follow checks, and fixed-stage diagnostics remain unchanged. NativeRendererSDK is supplied by Mixer and is never copied into this app.

The public Mixer development pin is 8efc1a9e5b1602117f8211c95bfd4203cc91f689. Supply its SDK directory explicitly for local development; no engine internals or substitute APIs are used:

```sh
export FIELDLOG_MIXER_SDK=/absolute/pinned-mixer/sdk
export FIELDLOG_WORKSPACE=/absolute/owned-scratch/workspaces
mkdir -p "$FIELDLOG_WORKSPACE"
swift test --package-path . --scratch-path /absolute/owned-scratch/swift-build \
  --cache-path /absolute/owned-scratch/swift-cache --jobs 4
```

For JVM checks, use a fresh output and workspace. The preparation script copies the exact nested ReportFiles body from the real bridge into a Java-only compilation unit. It supplies standard JDK imports, with no Android mocks or handmade API stubs:

```sh
python3 scripts/prepare-report-files-tests.py --output /absolute/owned-scratch/java-source
javac -encoding UTF-8 -d /absolute/owned-scratch/classes \
  /absolute/owned-scratch/java-source/PublicBridge.java \
  Platforms/Android/Java/dev/fieldlog/generatedr90/androidhost/ReportRoot.java \
  Tests/ReportFilesJava/ReportFilesChecks.java
java -cp /absolute/owned-scratch/classes \
  dev.fieldlog.generatedr90.androidhost.ReportFilesChecks /absolute/owned-scratch/report-workspace
```

To create the native development tree, use a public Mixer CLI and a clean checkout at the Swift SDK pin above, including sdk/. Supply the Android adapter separately with `--android-adapter-path`; the old Swift SDK pin does not supply the current Pair21 adapter. The selected public CLI authoritatively admits its exact 27 adapter inputs; unrelated worktree changes outside those inputs do not require a clean adapter repository. The Swift SDK checkout must still be clean and pinned. The output path must be absent, including when an existing directory is empty; existing paths are rejected before source or tool work. The recipe invokes public `mixer create` with public-v4 and installs the app-owned Swift, C, Java, manifest, and test sources. It preserves the CLI-created SDK snapshot and lock. The library product remains AppAndroid; its Swift module is FieldLogAndroid, matching the actual tests. The application package depends only on the three real FieldLog modules, without starter AppModels/AppFeatures targets.

```sh
python3 scripts/build-android.py --mixer /absolute/public/mixer \
  --sdk-checkout /absolute/pinned-mixer \
  --android-adapter-path /absolute/pair21-mixer/native/android \
  --output /absolute/fresh/FieldLogGenerated \
  --prepare-only
```

Omit `--prepare-only` to request the existing unsigned Android build. That build requires the platform toolchain and is outside this host-only verification. Preparation, APK/native compilation, installation, device behavior, signing, immutable published-package consumption, and final D0-D8/GA qualification each require their own evidence. A source checkout or host pass does not qualify those gates.

Run the recipe boundary controls without native tools:

```sh
python3 -m unittest discover -s Tests/Recipe -p 'test_*.py'
```

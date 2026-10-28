# FieldLog

An original native Swift iOS app for keeping project checklists, field notes and
photos together. This repository began with an ordinary SwiftUI baseline. Its
task-editor source consumes public MixerCore, MixerUI and MixerApple packages at an immutable Git
revision, with no dependency on a local Mixer checkout. The prepared fields-only public
renderer adoption is uncompiled and unrun; it does not establish native parity.

The app opens an empty **offline workspace** without an account. Create a
project, add and reorder tasks, write a dated/categorized entry, keep an automatic
draft, select up to eight photos, and share a text project report through the
system share sheet. Project search, checklist progress, saved drafts and the
last open project/editor restore from private local storage. There are no seeded
users, projects, activity totals or simulated network successes.

`FieldLogModels` uses Foundation and Codable only. `FieldLogStorage` serializes
mutations in an actor, uses a private process lock, writes and fsyncs a temporary
snapshot, atomically renames it and fsyncs its directory. State and pending local
change records commit together. Interrupted/invalid writes do not reset saved
data. A failed uncertain commit requires reopening; corrupt or unsupported
workspaces remain untouched. Typed notes preserve Unicode, spacing and newlines.
The editor distinguishes saving from confirmed durable draft storage.

Selected photos are imported through the native system picker as bounded files,
resized to at most 1600 pixels and re-encoded as JPEG without original metadata.
They are stored before the referencing snapshot commits. Photos are local;
camera capture and upload/resumption are not implemented. Text reports disclose
that photos are not embedded. The On device screen shows retained local changes
as **not sent**. No backend transport, fake retry, account session, invite,
notification or purchase result is produced.

```sh
swift test
xcodebuild -project ios/FieldLog.xcodeproj -scheme FieldLog \
  -configuration Debug -sdk iphonesimulator \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath build CODE_SIGNING_ALLOWED=NO build
```

Open `ios/FieldLog.xcodeproj` for native development. The development bundle ID
is `dev.mixer.fieldlog`, version `0.1.0`, build `1`, iOS 26.0+. Production identity,
provisioning, store approval and public licensing are separate decisions. No
credentials or signing keys are committed. A physically signed build is produced
only with an explicitly selected local identity/profile outside the source.

`FieldLogUITests` exercises the visible empty → project → checklist → saved
draft → relaunch → entry → native report/share → pending-local-changes workflow.
It supplies a random UUID with `--fieldlog-ui-workspace`, requires a visible
isolated-workspace badge before making changes, and never sends a report or
signs in. The argument selects a separate app-private folder only in Debug;
Release refuses it before opening any workspace. Screenshot attachments remain
in the xcresult. The app's ordinary workspace is never the intended test dataset.

```sh
xcodebuild -project ios/FieldLog.xcodeproj -scheme FieldLog \
  -configuration Debug -destination 'platform=iOS Simulator,id=SIMULATOR_UUID' \
  -derivedDataPath /tmp/fieldlog-ui-build \
  -resultBundlePath /tmp/fieldlog-ui.xcresult \
  -disableAutomaticPackageResolution CODE_SIGNING_ALLOWED=NO test
```

Keep build/results/log outputs outside the package directory for this UI-test
command. Editing package sources or generating artifacts under its root during
an Xcode test session can trigger repeated package graph resolution. Physical
test execution uses the same target and a locally selected development team;
it still does not establish real-user, authentication or store qualification.

This is D0 groundwork, **not a passed D0 milestone**. Login/auth, a production
backend, team synchronization/conflicts, camera capture, maps, push, purchases,
real users/records, physical-device recordings/timings and store distributions
remain required. The proposed public SDK source pin is
`56ff14c925168284761c5aca4f0bd4129cf3c995`. It changes the prior public package's
iOS 17 minimum to the product plan's already fixed iOS 26.0 baseline. The app
manifest and Xcode deployment defaults align to 26.0, with no upper major cutoff
or private 26.5 appearance allowlist. A source edit does not establish an iOS build.

`TaskEditorPresentation` remains the durable shared form and navigation owner.
Its title field now authors an explicit vertical axis; the responsible-person
field keeps the unchanged horizontal default. Unsupported native consumers must
reject the vertical document. An Apple adapter projects only the exact shared
fields Section through public `MixerUIHost` and `MixerNativeView`. Each installed
projection is paired with its immutable shared source render and owner identity.
Callbacks preserve the original revision and exact prospective value, validate
both bindings and identities, and synchronously re-enter the shared owner with
the original-revision envelope. Toolbar callbacks retain their displayed shared
snapshot envelope too. Failed host updates disable the retained fields and stop
admission; closing revokes the owner before removing observation and closing the
shared feature. Persistence still uses the serialized fsynced repository.
Navigation ends after confirmed durable save or unsaved cancel. Cancellation
does not undo a save already committed to disk.

This is **partial public fields rendering**, not full native-host/shared-theme
adoption. The app keeps the native inline navigation title, cancellation and
confirmation toolbar placement, red error label with glyph, secondary footnote
disclosure, native Form, and its existing dynamic light/dark tint. The public
renderer is nested inside that Form as a Section. The SDK has no shared text
error/secondary roles or navigation-action placement contract here; full V2
appearance, focus/IME, accessibility and visual parity remain unqualified.
No local SDK path, internal module or competitor code is imported.

This slice adds 12 Apple bridge/projection/lifecycle test functions to the
26 existing tests: **38 are expected on the macOS host runner; this integrated
slice remains uncompiled and unrun pending its exact-commit host CI**. The
public baseline [run 40762789024](https://github.com/snowdamiz/fieldlog/actions/runs/40762789024)
at `4062256839c192645a9ba271d4244f482f9aa811` compiled and executed 26 tests:
25 passed and one failed because its expected responsible-person value omitted
preserved surrounding spaces. This slice corrects that test expectation to the
verbatim saved value; production storage continues preserving the input.
The baseline's consumed-SDK and post-test lock/source checks were not reached.

All nine public multiline/UI host tests passed at the selected public pin in
job `123044761924` of run `40753111254`. The job later failed an unrelated CLI
Android compatibility size map, so this is a scoped prerequisite pass, not a
whole-engine CI pass. Independent and controlling source review accepted this
fields-only slice with explicit unrun gates. The late-save-after-close test uses
`Task.yield()` without a deterministic save-completion witness, and projector
preparation failure has no separate owner-level test; these remain coverage
limits. No native build, runtime, UI automation, capture, physical-device test,
published immutable release package qualification, D0-D8 or GA acceptance is
claimed. The prior local compiler/fetch cleanup hold remains unresolved and was
not inspected or reused. The lock revisions were updated as text; their baseline
`originHash` values must be observed/refreshed by the allowed resolver, with both
bytes retained. Android's synchronous value-only reducer still cannot host this
asynchronous fsynced save flow. Native runtime checks remain paused and phones
disconnected.

See `verification/native-baseline-2026-10-22.json` for exact observed evidence and
`scripts/verify.sh` for the separate repository's local CI entrypoint. No customer
activity is claimed.

The public repository [snowdamiz/fieldlog](https://github.com/snowdamiz/fieldlog)
is configured as `origin`; its visibility was changed under the user's explicit
instruction before the public baseline run. The shared task-editor and manual host-CI code was
delivered in commit `70f3aa1d28f29e7c327a17fd46199480d41ca749`.
The historical private [host workflow run 40744921829](https://github.com/snowdamiz/fieldlog/actions/runs/40744921829)
targeted that exact commit and failed before runner assignment because GitHub
reported failed account payments or a spending limit requiring an increase.
**0 of 26 expected host test functions executed; no artifacts were produced.**
No compiler, public SDK fetch, lock refresh or runner cleanup executed in that
attempt. The earlier local Swift dependency-fetch attempt still has unverified
cleanup; its held resources have not been inspected or reused.

`.github/workflows/host.yml` is a manual host-only development workflow. When a
runner is admitted, it invokes `scripts/verify-host-ci.py` on one disposable macOS
runner. The remote-only script records each fresh child PID/PGID before admitting
its command, reserves cleanup time, and requires direct-child reaping, exact
owned-group absence and output EOF. It stops on ambiguous identity/cleanup and
does not inspect previously held local resources. The total runner budget is
750 seconds, captured output is capped at 32 MiB, and host tests use two compiler
jobs. It does not invoke native builds or runtimes. The public baseline exercised these command cleanup safeguards with all 16
new command groups closed and no signals, while its single test failure left
post-test verification unreached. The integrated 38-test slice remains pending.

The workflow is designed to fetch only the existing public Mixer commit into a
transient CI mirror while keeping the declared remote URL and immutable pin. It
binds the actual consumed SDK commit/tree, all tracked app source and test
results. A lock refresh may change only `originHash`, which is reported with
before/after bytes; changed dependency identity/location/revision fails. This
development verification through a disposable CI mirror of the public SDK
remains pending for the integrated slice and does not establish new
published-release-package qualification.

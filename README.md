# FieldLog

An original native Swift iOS app for keeping project checklists, field notes and
photos together. This repository began with an ordinary SwiftUI baseline. Its
native task editor now consumes the public MixerCore package at an immutable Git
revision, with no dependency on a local Mixer checkout.

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
is `dev.mixer.fieldlog`, version `0.1.0`, build `1`, iOS 17+. Production identity,
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
remain required. The native task editor now consumes `MixerCore` from the public
Git repository at revision `d8c6965a277ca21e685f3ef9e0f68a7d59b46156`, through
the separate `FieldLogFeatures` module. The public state/effect owner validates
input, admits one save, preserves text after failure and rejects completions after
the editor closes. Existing native controls and the serialized workspace repository
remain in use. Cancellation does not undo a save already committed to disk.

Both SwiftPM and Xcode lock that remote revision; no Mixer checkout path or internal
module is imported. Seventeen host tests and the original simulator workflow pass.
This is initial external package consumption, not full MixerUI migration or D1
acceptance. Android, interpreted/OTA modes, physical regression and the remaining
dogfood requirements stay open. No stable Mixer API or release tag is implied.

See `verification/native-baseline-2026-10-22.json` for exact observed evidence and
`scripts/verify.sh` for the separate repository's local CI entrypoint. No hosted
CI execution or customer activity is claimed.

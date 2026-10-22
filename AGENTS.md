# FieldLog implementation rules

FieldLog is the separate consumer app described by the Mixer product plan,
sections 21, 22 and 28. Preserve useful app behavior and meaningful saved data.
Start with native SwiftUI; adopt only public immutable published Mixer packages
when qualification permits. No imports of engine internals or unpublished Mixer
checkout paths may close a dogfood gate.

No Patch/Skip source, generated output, fixtures or dependencies. Shared models
remain Foundation/Codable values so platform adaptation does not require a data
rewrite. No seeded customer activity or simulated account/backend success. Keep
offline mode explicit and preserve drafts on validation/storage failure.

Record exact tools, commands, source revision, datasets and evidence scope.
Simulator and Mac unit checks are not physical-device receipts. D0 remains
blocked until its login, physical recording, baseline timing, meaningful saved
records and signed-build evidence exists. No production publication, credential
change or customer communication is implied by implementation work.

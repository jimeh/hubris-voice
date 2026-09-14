# Vendored source workflow

Hubris Voice builds FluidAudio directly from the selected upstream files in
`Vendor/FluidAudio`. The recipe in `sources.json` pins FluidAudio 0.15.7 at
revision `41540ea237350afe5117a082b5c28eda642d0612`, the GitHub source archive
checksum, the archive root, the complete selected path set, and the ordered
local patch stack. The selected paths include both upstream license inventories.

`mise run vendor:check` downloads the pinned archive once into the ignored
`.native/vendor/archives` cache, verifies its SHA-256 before extraction, copies
only the declared paths, applies every patch in order, and compares the complete
result with the build tree. A corrupt cached archive is rejected and is never
silently replaced. Verification never repairs source drift.

SwiftPM creates the ignored `Vendor/FluidAudio/.build` directory because
FluidAudio is a local package dependency. Verification and edit snapshots skip
that one generated directory before traversal. Every other non-empty file in
the vendored directory remains part of the exact comparison, including hidden
files, executable bits, symlink targets, and upstream license inventories.

The pre-commit hook first runs `vendor:index-check`. It fails when any
vendor-related input differs between the Git index and working tree, including
untracked recipe files, so the subsequent working-tree verification represents
the bytes being committed. Ordinary `vendor:check` remains working-tree based
so partially staged development does not change the edit workflow.

## Edit an existing patch

Check for an interrupted session before editing:

```sh
mise run vendor:status
mise run vendor:start -- fluidaudio compiler-fixes
```

Edit and test `Vendor/FluidAudio` as the normal build input. Then fold the
tested tree into the selected patch and replay all later patches:

```sh
mise run vendor:finish -- fluidaudio
mise run vendor:check
```

If replay conflicts, the command prints the private workspace and the exact
`git add` command. Resolve the files there, preserve the intended final source
in `Vendor/FluidAudio`, and run:

```sh
mise run vendor:continue -- fluidaudio
```

Use `vendor:reopen` to return a session to editing after finish has started.
Use `vendor:cancel` to end a session while preserving source edits and a
recoverable session backup. Neither command rewrites the vendored source.

`vendor:start` rejects unexplained source drift. After reviewing deliberate
pre-existing edits, assign them explicitly with:

```sh
mise run vendor:start -- fluidaudio compiler-fixes --adopt-edits
```

Do not edit `sources.json` or patch files during an active session.

## Add a patch

Add a named entry at the correct ownership point in `sources.json`, create its
empty patch file, and start a session targeting that name. The finish workflow
keeps earlier patches byte-identical and replays later patches over the new
change.

## Upgrade FluidAudio

Treat an upstream upgrade as a reviewed recipe change:

1. Choose the exact upstream tag and resolve it to a 40-character commit.
2. Download only that commit's GitHub `.tar.gz` archive. Record the archive
   SHA-256 and exact single top-level directory in `sources.json`.
3. Review the archive inventory and confirm every selected path still exists.
   Keep `Package.swift`, `Package@swift-6.2.swift`, `LICENSE`,
   `Sources/FastClusterWrapper`, `Sources/FluidAudio`,
   `Sources/MachTaskSelfWrapper`, and `ThirdPartyLicenses` unless a deliberate,
   documented packaging change requires a different complete set. The
   FluidAudio CLI and tests are outside the vendored build inventory.
4. Preserve the old recipe outside the build tree, replace
   `Vendor/FluidAudio` with the new selected archive paths, and temporarily
   set the new manifest entry's patch list to empty. Run `vendor:check` to
   verify the new unmodified baseline.
5. For each old patch still needed, add its named manifest entry with an empty
   patch file. Start a session targeting that patch, apply the old change to
   the vendored tree, resolve conflicts there, and finish the session to record
   the port against the verified new baseline. Keep the old dependency order
   and omit fixes supplied upstream. A clean textual application does not prove
   behavioral compatibility.
6. Confirm that upstream removals and additions are intentional, including all
   license files. Run `mise run vendor:check`, the focused FluidAudio tests, and
   `mise run check`. Review the final source and patch diffs together.

The workflow does not download models, SDKs, or other FluidAudio assets.

## Tooling provenance

The vendor session and verification machinery was adapted from Huterm revision
`e604d0dcb47734a5ee0a02f9f06ee6e961291747`. Its narrow license notice is in
`Scripts/vendor-LICENSE`.

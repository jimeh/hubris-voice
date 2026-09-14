# FluidAudio vendor provenance

This directory contains the FluidAudio 0.15.7 library source from:

- Repository: https://github.com/FluidInference/FluidAudio.git
- Tag: `v0.15.7`
- Revision: `41540ea237350afe5117a082b5c28eda642d0612`

Hubris Voice removes the CLI and test targets from the vendored manifests,
disables FluidAudio's logger, and carries narrow compiler-compatibility fixes.
FluidAudio logs can contain transcript text and user vocabulary terms, so
sending them to stderr or Unified Logging would break Hubris Voice's diagnostics
privacy boundary. The logging change keeps the public facade intact while
making every sink a no-op.

The compatibility changes fix a temporary pointer lifetime, preserve weak
termination capture semantics, handle Core ML's `int8` array type when building
with a Swift 6.2 or newer SDK, remove dead or redundant expressions, and opt in
to Accelerate's current LP64 CBLAS headers. They do not change the model paths,
model selection, or logging policy.

`UPSTREAM.sha256` records the selected files before local changes.
`Patches/hubris.patch` records all local changes. Run
`Scripts/verify-vendored-fluidaudio.sh` from the repository root to reconstruct
and verify the exact upstream snapshot and patched tree.

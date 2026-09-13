# FluidAudio vendor provenance

This directory contains the FluidAudio 0.15.7 library source from:

- Repository: https://github.com/FluidInference/FluidAudio.git
- Tag: `v0.15.7`
- Revision: `41540ea237350afe5117a082b5c28eda642d0612`

Hubris Voice removes the CLI and test targets from the vendored manifests and
disables FluidAudio's logger. FluidAudio logs can contain transcript text and
user vocabulary terms, so sending them to stderr or Unified Logging would break
Hubris Voice's diagnostics privacy boundary. The source change keeps the public
logging facade intact while making every sink a no-op.

`UPSTREAM.sha256` records the selected files before local changes.
`Patches/hubris.patch` records all local changes. Run
`Scripts/verify-vendored-fluidaudio.sh` from the repository root to reconstruct
and verify the exact upstream snapshot and patched tree.

# Sparkle provenance

Hubris Voice packages Sparkle 2.9.6 from the official binary release. The
archive URL, release date, SHA-256 digest, framework identity, minimum macOS
version, and upstream license digest are pinned in
`Scripts/sparkle-source.json`.

`mise run sparkle:prepare` verifies those values before a release build uses
the framework. Release packages copy the complete upstream license into the
application bundle. Ordinary development bundles do not download, link, or
package Sparkle.

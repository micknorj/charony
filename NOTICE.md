# Notices and attribution

## WQ Files

Charony is a modified version of [WQ Files (Worse Query Files)](https://github.com/kolbicz/WQFiles) by kolbicz and contributors, based on stable v0.9.18 at `e44cd0ef226305bc265c8d7a15607ec49ceb4368`.

Modifications began on November 19, 2026. Charony reduces the product to application data and cache management, removes application logging and networking, changes scan persistence, and adds Charony branding and validation infrastructure.

The single-word application-identifier correction and Apple-only fallback-icon keyword matching were adapted from WQ Files v0.9.19 during the November 20, 2026 review. Its App Store networking and other out-of-scope features were not imported.

WQ Files and Charony are licensed under GPL-3.0-or-later. The complete license text is in [LICENSE](LICENSE). Preserve this notice and original source notices, and distribute corresponding source for the exact binary, including modifications and build scripts.

## Access techniques

- [worse_query](https://github.com/forcequitOS/worse_query) by Taj C (forcequit): sandbox access technique
- [KAMUI](https://github.com/murk-sus/kamui-escape) by murk-sus: container enumeration using `fsgetpath`
- terminal_worse: retained container-manager enumeration notes

These acknowledgments describe implementation provenance. Independent Git history does not change the original authorship or licensing obligations.

## Test materials

The test-only upstream safety fixture preserves nine unmodified functions from WQ Files stable v0.9.18 under GPL-3.0-or-later. The pinned baseline manifest records source provenance and checksums for independent testing. These materials and the downloaded baseline are excluded from the application bundle.

## Artwork

The original layered moon artwork and editable SVG/Icon Composer project were created for Charony. Apple's tools provide the native Liquid Glass materials and compiled appearance variants. The superseded flat development artwork is no longer included.

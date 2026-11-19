charony is a modified version of WQ Files (Worse Query Files) by kolbicz and contributors, based on stable v0.9.18 at e44cd0ef226305bc265c8d7a15607ec49ceb4368. Modifications prepared on November 19, 2026 reduce the product to application data and cache management, remove application logging and networking, change scan persistence, and introduce Charony branding and validation infrastructure.

WQ Files and this derivative are licensed under GPL-3.0-or-later. The complete GPL text is in LICENSE. Distribute corresponding source for the exact binary, including these modifications and build scripts, and preserve this notice and original source notices.

The sandbox technique derives from worse_query by Taj C (forcequit). Container enumeration using fsgetpath derives from KAMUI by murk-sus. The retained container-manager enumeration notes acknowledge terminal_worse. These acknowledgments describe implementation provenance.

Upstream and technique sources are available below.

- https://github.com/kolbicz/WQFiles
- https://github.com/forcequitOS/worse_query
- https://github.com/murk-sus/kamui-escape

The development moon artwork was generated for charony. Layered Icon Composer artwork remains incomplete.

The test-only upstream safety fixture preserves nine unmodified functions from WQ Files stable v0.9.18 under the same GPL-3.0-or-later terms. The pinned baseline manifest records source provenance and checksums for independent testing. These materials are excluded from the application bundle. Charony's independent Git history does not change the original authorship or this attribution.

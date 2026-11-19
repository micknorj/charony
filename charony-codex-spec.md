# charony — Codex implementation specification

**Status:** Requirements approved through List 10. Initial implementation and focused safety review are complete locally and accepted for initial CI validation. Native CI and physical-device checks remain unverified. This specification defines requirements and does not establish successful testing.

**Verified fork (2026-11-19):** https://github.com/micknorj/charony, default branch `main`, at `985cf765cdf3bd4cb88da15de3f7d928664efae6` when checked (upstream debug commit). Stable `v0.9.18` baseline: `e44cd0ef226305bc265c8d7a15607ec49ceb4368`, `CFBundleVersion=106` (fork debug main has build 110). Re-check the fork SHA at task start; it may change.

## Source and distribution

- Upstream: https://github.com/kolbicz/WQFiles (Worse Query Files). **Implementation baseline: stable tag `v0.9.18`, commit `e44cd0ef226305bc265c8d7a15607ec49ceb4368`.** Do not use the fork's current debug `main` as the code baseline.
- Target repository: https://github.com/micknorj/charony (public, detached from the upstream fork network). App display name: `charony`.
- Licensing: preserve GPL-3.0-or-later, all required copyright/source notices and upstream acknowledgments. Remove WQ Files *product branding* from the UI; do not remove legal attribution.
- Updates: independent fork; upstream security/compatibility fixes reviewed and incorporated **manually**. No in-app updater, release polling, analytics, telemetry, or network activity initiated by the app.
- Releases: public source plus IPA release assets; describe the required re-signing/App Group entitlement and supported versions. Do not embed credentials in CI or IPA artifacts.

## Repository-specific GitHub authorization

On November 19, 2026, the maintainer authorized Codex to manage **https://github.com/micknorj/charony only**, superseding this project's earlier prohibition on remote Git operations. Shared engineering principles for other repositories and projects remain unchanged.

- Codex may create development branches, commit and push to those branches, create and update pull requests, trigger and monitor GitHub Actions, read CI logs, download diagnostic artifacts, fix failures, push corrections and update project documentation. Read-only remote inspection and fetching this repository are permitted when needed to preserve current remote work.
- Normal submissions use development branches and pull requests targeting `main`. The current independent-history migration follows its one-time exception below. Repeat required validation until it passes or a genuine blocker is identified.
- Check the repository identity and current GitHub write permissions before pushing. Prefer the connected GitHub integration where supported. Reuse existing platform authentication and restricted networking. Do not request personal access tokens or enable unrestricted Internet unnecessarily.
- **Outside the one-time history exception below, never push directly to `main`, force-push or rewrite published history. Never merge pull requests or publish releases without explicit approval. Remote deletion requires approval outside the reviewed one-time cleanup. Do not enable automatic merging, releasing or deployment.**
- Never disable safety tests or bypass failing CI. Never introduce credentials or secrets into source control. Preserve existing implementation, safety-review changes and remote development work.
- This authorization covers development tooling. Charony's application-controlled networking, logging and privacy restrictions remain unchanged.

### One-time independent-history exception

The maintainer subsequently authorized a one-time history replacement for `micknorj/charony`, superseding the no-history-rewrite/direct-main restrictions only for this migration. Preserve implementation commit `994f97085bb309ababae876637e2ae02043cd16f` in a verified recoverable Git bundle. Confirm the live repository identity, owner permissions and detachment from the WQ Files fork network before destructive operations. Create a new parentless root containing the complete Charony implementation, with no inherited WQ Files commits or merges. Replace default `main` only through an explicit force-with-lease against its freshly verified old SHA. Inventory and back up obsolete remote refs/releases before deleting them. Do not delete/recreate the repository or publish a release.

Use repository-local identity `micknorj <329715135+micknorj@users.noreply.github.com>` for the new root and subsequent Charony commits. Do not change global Git configuration or falsify authorship. Verify the root's stored author and committer metadata before pushing. Preserve GPL-3.0-or-later, copyright notices and upstream acknowledgments. Verify remaining refs, fork status, GitHub history, Contributors and Actions after migration. Report retained server-side metadata and unverified checks. Shared engineering principles for other projects remain unchanged. The exception does not authorize further history rewrites after migration.

Preserve baseline safety coverage independently of Charony ancestry. The stable source archive and every extracted file are pinned in `tests/upstream-baseline.json`, checked against the trusted stable Git tree before migration. Nine unchanged upstream safety helpers are retained as test-only provenance fixtures. CI runs the unchanged stable runner from verified source without importing upstream commits into Charony history.


## Fork bootstrap: current `main` is not the approved baseline

- The fork was created from upstream `main`, **8 commits ahead of** stable `v0.9.18` when checked. The difference touches `Info.plist`, `build.sh`, and `main.m` (including debug-related changes). Compare these changes before implementation; record the exact fork SHA at task start because the branch may move. Do not silently carry over any debug instrumentation or build number.
- Verify locally that stable commit `e44cd0ef226305bc265c8d7a15607ec49ceb4368` is available (`git cat-file -e e44cd0ef226305bc265c8d7a15607ec49ceb4368^{commit}`). Inspect `git diff`/`git show` and run baseline tests before code reduction where executable. Fetching this repository is permitted under the repository-specific authorization. If the stable object cannot be obtained, report the blocker rather than implementing from debug source. The baseline has already been restored for the current implementation; preserve the existing changes.
- The original bootstrap restored stable file contents without rewriting published history before implementing Charony. That work is complete. Preserve the current implementation rather than restoring stable files over it. Subsequent history replacement is governed solely by the one-time exception above.
- Create an auditable baseline-to-Charony diff, recording the upstream baseline SHA and intentionally deleted paths. Avoid merging upstream debug-only commits back in.
- Codex Cloud's GitHub connection may be used to push development branches, create/update pull requests and run validation for this repository under the authorization above. Verify permissions first. Merging, releasing and remote branch deletion remain approval-controlled. Do not deploy or rewrite published history.

## Remove unused files, not just UI entries

Treat cleanup as a required engineering deliverable, not an optional size optimization. Before deletion, map compile-time and runtime dependencies (including safety checks and relevant tests). Then delete unreferenced implementations, assets, docs, and build links; **never remove a security primitive just because its caller is being refactored**.

**Expected deletion candidates (subject to dependency analysis):**
- **Removed feature modules:** `WQWebServer.*`, `WQSharing.*`, `WQTheme.*`, `WQInspector.*`, `WQPlistEditor.*`, `WQHexViewer.*`, `WQSQLiteViewer.*`, `WQSQLiteSave.*`, `WQSyntax.*`, `WQMediaStream.*`, `WQArchive.*`, `WQTrash.*`, and their feature-exclusive support headers. Only retain a shared helper if an approved Apps/Caches path genuinely needs it; document the exception.
- **Old UI and product surfaces:** Delete feature-exclusive views/routes from `main.m`, `WQUI.*`, `WQApps.m` and `WQCache.m`. Do not delete entire shared files without checking dependencies. Remove file browsing, Go to Path, backup/restore, editors, share sheets, custom targets, Wi-Fi server, Recent/Favorites, theme controls, settings, update checker, log UI and touch diagnostics.
- **Obsolete content:** `RELEASE_NOTES_*.md`, `source.json`, `scripts/update_source.py`, `examples/inspectors/`, `themes/`, `screenshots/` (if obsolete), upstream branding-only art, old icon generation resources replaced by the Charony icon, and non-English `*.lproj` folders. Retain or rewrite `en.lproj` only if needed by the remaining localization approach.
- **Metadata/build:** Remove old document-type registrations for themes/inspectors, local-network permission text, unused file-sharing declarations, irrelevant frameworks/link flags, compiled sources, resources and references from `build.sh`, `Info.plist` and CI. **Preserve and correctly validate the App Group entitlement**, deployment target, system-required metadata, and legitimate licensing notices.
- **Tests:** Remove obsolete feature-only tests, runner entries, fixtures, and scripts *once their replacement/remaining coverage is understood*. Preserve or expand tests for `WQAccess` safety, `WQCacheSafety`, scanning, identity checks, LaunchServices and crash-log boundaries. Keep `tests/run_all_tests.sh` and other test commands accurate for the reduced tree. Do not remove a failing test simply to make CI green.

**Explicitly protect:** `LICENSE`, upstream copyright/attribution, modified-source license obligations; app-container identity/permission checks, access-cache recovery, scan checkpoints, fail-closed deletion, and relevant tests. `WQAccess*`, `WQCacheSafety.h`, `WQScan*`, `WQHealth*`, and `WQLaunchServices*` are important review targets, **not blanket deletion candidates**.

**Cleanup acceptance:** Produce a before/after inventory, list deleted paths and retained exceptions, verify no dead imports/references, compile only required modules, and prove no hidden UI action exposes removed operations. The build and IPA must not include dead feature code/resources. Reduced size is desirable but correctness and security take precedence.

## Devices and build

- Primary validation device: iPhone 11 Pro on iOS 27.2.1.
- Retain WQ Files' supported operating-system range: iOS 26.0–26.7.2 and iOS 27.0–27.3 beta 1, subject to upstream capability checks. **Do not claim support on iOS 27.3 beta 2 or later**, where worse_query was patched.
- User has Windows and a free Apple account, **not** a Mac/Xcode installation. Provide GitHub Actions macOS/Xcode workflow to build/test/package IPA, with pinned compatible tooling and validation of entitlements. IPA is ad-hoc signed by the upstream script and needs compatible re-signing for sideload installation.
- App Group entitlement is essential. Sideload setup target: AltStore Classic on Windows; verify entitlement survives signing and confirm on the actual iPhone. Don't assume CI success proves on-device sandbox access.
- Coding agent follows repository/local principles and the scoped GitHub authorization above. Development-branch pushes, pull requests and Actions validation are permitted for `micknorj/charony`. Other remote infrastructure/account changes and deployment remain outside scope. Merges, releases and remote branch deletion require explicit maintainer approval.

## Product surface (only two functions)

### Apps tab
- Show accessible, detected apps, including third-party and Apple apps such as Safari or Messages when accessible. **Hide inaccessible apps**, including Apple apps.
- Show **app icon, name, bundle ID, and total data size** in minimal compact native rows. Preserve upstream symbol fallback for icons unavailable on some iOS builds.
- Retain search and relevant filters (Apple vs. others, installed vs. offloaded where identity is reliable). Remove backup-based filters, backup/restore/import/export features, open-folder and copy-identifier actions.
- Per-app **Clear Data** empties the app's `Documents`, `Library`, and `tmp` using upstream target validation and deletion safety. Stable WQ Files has an explicit **Clear Without Backup** path; review and reuse its validated purge logic instead of designing a new deletion engine. Remove the optional backup flow and any implicit backup writes for this operation. Preserve root containers and verify postconditions; failures must not be hidden. Require a standard destructive confirmation that specifies app and irreversibility. For Safari and Messages, **best effort using existing supported access**, not claims of complete cleanup or new access bypasses.

### Caches tab
- Scan and delete standard app `Library/Caches`, app `tmp`, and accessible iOS crash/diagnostic reports using existing WQ Files logic.
- Allow manual multi-app selection by tapping rows; one confirmation dialog summarizes batch deletion. Preserve search.
- Remove custom cleaning targets, arbitrary folder selection/navigation, and bulk **selection shortcuts** (Select All, Invert, None, Large Caches), while retaining manual selection.
- Preserve revalidation and fail-closed handling for inaccessible/changed targets. Never broaden deletion to arbitrary system paths.

## Scanning and storage

- Retain progress indication, user-initiated refresh, pause/resume, foreground/background handling, and **local checkpoints** needed to resume interrupted scans. Deleting app/cache data remains an explicit user action.
- **Remove durable cached completed results** (including historical app sizes and completed cache scans). On reopening/relaunch, don't present stale completed results as current. Keep in-memory results during the current session, and only persist the minimal checkpoint state necessary for an unfinished scan. Remove checkpoints after successful completion where safe.
- No automatic timed rescans (the current Apps controller has a 10-minute rescan path); initial scanning on first opening a tab is permitted. Manual refresh starts a new scan. Restore incomplete scan work without treating it as a completed result.
- Scan checkpoint storage is local operational state, **not activity logging**; do not retain path/activity history beyond necessary recovery state.

## Privacy (non-negotiable)

- No app-owned analytics, telemetry, tracking, crash-report upload, periodic update checks, or background network requests.
- **No application-generated logging**, including `NSLog`, `os_log`, `wq_log` output, activity logs, touch traces, on-device log viewer, or diagnostics exported from the app. Explicit errors and progress may be displayed ephemerally to the user without log storage. Remove call sites or refactor logging appropriately; simply hiding the Log UI is insufficient.
- Remove Wi-Fi Sharing and web server/local network service, Recent and Favorites, stored history, custom JS inspectors, editor tools and unrelated viewers if no longer referenced, themes, localization files except English, update checking and its GitHub `source.json` request.
- Keep only operational data strictly needed for active scans, user selections during the session, and safe access cache recovery. Avoid third-party runtime services.
- Privacy claim scope: charony itself; iOS/system diagnostics and Apple/sideloading infrastructure cannot be guaranteed to produce zero records.

## UI and identity

- Native UIKit, minimal styling, compact accessible list rows, follows device Light/Dark. Two bottom tabs labeled **Apps** and **Caches**. Search is a native **bottom-right** search affordance and searches the **currently selected tab only**, restoring that context when dismissed. Verify `UISearchTab`/platform behavior across supported iOS versions; don't replace with an unverified mockup.
- **No Settings page or gear icon**. Reset Access Cache is available only on a detected recoverable access failure. Keep required license/copyright attribution in the repository and distributed source.
- App icon: a circular Charon-inspired moon silhouette with **very subtle** crater/surface markings, no lettering. Target Apple's layered Icon Composer Liquid Glass appearances (light, dark, clear light/dark, tinted). Verify actual `.icon`/asset compilation in macOS CI and on device; don't claim Icon Composer coverage without verification. If blocked, mark icon work incomplete and document the blocker rather than representing flat PNGs as layered Liquid Glass.
- Rename bundle metadata/build product/resources appropriate for `charony`; avoid accidentally depending on upstream group identifiers and keep signing entitlement validation intact.

## Hard boundaries and safety

- Remove file manager, Go to Path, file browsing, text/plist/SQLite/hex editors, ZIP tooling, file/folder mutation actions, backup and restore screens, Wi-Fi sharing and arbitrary system-container navigation. Inspect the final UI and APIs for hidden routes to those actions.
- Preserve existing App Group access checks, container identity checks, race/symlink protections, cancellation behavior, and deletion target revalidation. No operation should bypass the selection + confirmation flow, even after stripping backups.
- Cache cleaning remains scoped to eligible cache/tmp/crash-report paths; full app clearing remains scoped to **one explicitly selected app container**. Do not add general system data deletion.
- Keep troubleshooting UI capable of showing *current* failure reasons and an access-cache repair action without storing logs.

## Suggested implementation sequence

1. **Fork and baseline:** verify `micknorj/charony` checkout and debug main SHA, inspect/restore stable `v0.9.18` tree without rewriting remote history, map dependencies, run applicable baseline tests and record gaps.
2. **Privacy:** remove all app-owned logging and network paths; add static source checks for forbidden logging/network symbols in production code.
3. **Core reduction and physical cleanup:** isolate Apps and Caches; remove obsolete implementations, assets, localization, release notes, tests and build references, not only UI; preserve security-sensitive primitives and document any retained shared dependencies.
4. **Scan behavior:** eliminate completed-result persistence and timed rescan, keep interruption checkpoints and manual pause/resume.
5. **Native UI:** Apps / Caches / contextual bottom Search, no settings, compact lists, confirmed destructive actions.
6. **Brand/CI:** rename app, build layered icon, configure macOS Actions and packaging checks, update README and license notices.
7. **Validation:** build/test, inspect network and logging references, verify IPA metadata and App Group entitlement, exercise app listing + iOS permissions and crash/report cleanup on a **real supported device** (maintainer-controlled).

## Acceptance tests / exit criteria

- No app-generated log messages or log export UI, no update-check requests or listeners, and no runtime telemetry SDK/dependency. Document any unavoidable Apple or signer network behavior separately.
- Only Apps and Caches user-facing surfaces, plus contextual search and conditional access-recovery dialog; no file manager paths or backup/restore actions.
- App data clearing and cache deletion show explicit confirmation, prevent mutation of changed/inaccessible targets, and never cross the chosen scope. Confirm **no backup artifacts are produced** by these operations, as requested; data recovery is not implied.
- No completed scan results survive app restart; incomplete scans resume from a checkpoint; no timer-driven rescanning; manual refresh and pause/resume work.
- iOS 26/27 compatibility is **tested where available**, not assumed; acknowledge patched later versions. Preserve App Group during signing.
- Public repository contains source, GPL notices, attribution, build/test documentation, privacy disclosure, supported-version matrix, and **manually published** IPA release instructions/assets. The finished source tree contains no obsolete feature-only modules/assets/build entries unless their necessity is justified.
- Final Codex handoff reports changed files, actual tests executed, checks not executed, and risks; it must not claim device testing without device evidence.

## Selected Codex skills (optional, targeted use)

Only load a skill when its workflow directly applies. Project requirements and coding-agent restrictions override any skill instructions. A generic workflow does not expand the repository-specific GitHub authorization, authorize merging/releases/deployment or permit adding telemetry/logging. Review skill contents before installation.

- **pstack `/architect`** — inspect WQ Files' existing module/call graph before removing file browser, backup, logging, or cache management code; preserve needed access, validation, and scan recovery primitives. Source: https://github.com/backnotprop/pstack
- **Addy Osmani `test-driven-development`** — create regression tests first for deletion boundaries, changed targets, cancellation, and checkpoints. Source: https://github.com/addyosmani/agent-skills
- **Addy Osmani `doubt-driven-development`** — challenge claims that deletion is safe, network-free, or compatible; stop on unresolved evidence and test failures. Same source.
- **Addy Osmani `source-driven-development`** — verify use of UIKit `UISearchTab`, supported iOS APIs, icon compilation, entitlements, and runner/Xcode availability against authoritative Apple documentation. Same source.
- **Matt Pocock `diagnosing-bugs`** — reproduce and reduce a failing build, scanner regression, or test before implementing a fix. Source: https://github.com/mattpocock/skills

Avoid entire packs and unrelated React/TypeScript/browser/observability workflows. A skill is a procedure, not proof that its checks ran.

## Pre-device validation gates (mandatory before installing on the main iPhone)

1. **Baseline first:** Pin the approved upstream source commit. Run upstream host tests unchanged on macOS CI; record any baseline failures and the distinction between host fixture tests and real-device behavior.
2. **Test after each reduction:** Keep focused positive and negative tests for data clearing and cache cleaning: allow only selected app `Documents`/`Library`/`tmp` and narrowly scoped cache/tmp/crash-report paths; deny path traversal, symlink redirection, stale inode/identity, moved containers, inaccessible apps, overlapping requests, interrupted scans, and double deletion. Verify no App Backups/Backups artifacts are created after clear or clean. Use disposable fixture directories only.
3. **Privacy gate:** Static-source and built-binary reviews for `wq_log`, `NSLog`, `os_log`, touch tracing, trackers, update polling, network listeners, and accidental outbound connections. A test may output CI diagnostics; production Charony must not generate its own activity logs. Inspect released entitlements and declared permissions separately from source.
4. **Build gate:** macOS CI must run relevant host tests, compile/link the iOS target, build an IPA, verify package contents, expected bundle ID, deployment target, App Group entitlement, and code signing/asset compilation. Treat any skipped check as unverified. Do not claim the final sideloaded signature is valid until checked after re-signing.
5. **UI gate:** Use fixture-driven iOS Simulator UI tests where available for Apps/Caches navigation, contextual search, appearance, filtering, confirmation/cancel behavior, inaccessible-app hiding, scan pause/resume, and conditional access-cache reset. Simulator tests do **not** validate worse_query sandbox access or real protected-app deletion.
6. **Quality gate:** Keep one concise `TESTING.md` matrix: check, command/workflow, pass/fail/untested, platform, and evidence. Block an IPA release when critical deletion-scope, privacy, scan-recovery, or packaging gates fail. Require independent review of destructive paths before main-phone use.
7. **Device-only gate:** Even comprehensive CI cannot prove the sandbox technique works on a real iPhone, or that clearing Safari/Messages is safe. Start with **read-only** launch, App Group/access, listing, and scanning checks on the user's iPhone. For destructive verification, first test against an expendable app with disposable data (preferably on a spare device). Do not test by deleting the user's live Safari/Messages data. If safe disposable-device testing is unavailable, mark real-device destructive behavior **unverified**; never imply the app is fully validated.

**Risk decision:** "Tested before my main phone" can mean build, host logic, and simulator UI testing, but cannot guarantee actual iOS container access or destructive safety without a physical supported iPhone. This is a verification limit, not a request to weaken safeguards.

## Codex Cloud handoff and control

- Codex should first confirm which repository and commit are checked out, and whether all approved source materials are available. The maintainer may place this specification at the repository root; treat it as the project-specific requirements alongside any `AGENTS.md` and personal project principles.
- Preserve the current implementation and safety-review changes. Complete the authorized independent-history migration under its safeguards above. Normal subsequent work uses development branches and pull requests targeting `main`, with macOS Actions and correction commits until required checks pass or a genuine blocker is identified. Never merge or publish without approval.
- Report on completion **in the Codex conversation** for copying back into the separate ChatGPT planning chat. There is no automatic cross-conversation handoff. Report stable baseline, changed/deleted files and retained safety code, branch and PR URL, commit SHA, actual CI/test results, fixes, privacy findings, remaining failures/unverified checks and any actions requiring maintainer approval.
- If a gating contradiction appears, stop at the conflicting requirement and present the smallest concrete question; otherwise complete as much safe local work as the environment permits and explicitly identify any unverified checks.

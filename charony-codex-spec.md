# Charony implementation specification

This specification defines the approved product requirements. [TESTING.md](TESTING.md) records actual verification. Merged-main native CI passed. The editable layered icon is verified with Apple tools; physical-device behavior and final signing remain unverified.

## Source and licensing

- Repository: [micknorj/charony](https://github.com/micknorj/charony), detached from the WQ Files fork network
- App display name: `charony`
- Implementation baseline: [WQ Files](https://github.com/kolbicz/WQFiles) stable v0.9.18, commit `e44cd0ef226305bc265c8d7a15607ec49ceb4368`, build 106
- Stable restoration and initial implementation are complete; preserve Charony and exclude later upstream debug changes
- Independent Git history is established; do not rewrite it again or merge inherited history into it
- Preserve GPL-3.0-or-later, copyright/source notices, modified-source obligations and upstream acknowledgments; remove upstream product branding from the interface without removing legal attribution
- Review upstream security/compatibility fixes manually; no app-controlled updater or release polling
- Distribute corresponding source and build scripts for the exact binary alongside any manually approved IPA release

## Compatibility and installation

The upstream access range is iOS 26.0–26.7.2 and iOS 27.0–27.3 beta 1, subject to access capabilities. iOS 27.3 beta 2 and later patched worse_query and are unsupported. Keep the retained patched-build check. Do not describe an upstream range as verified Charony device compatibility.

The intended physical validation target is an iPhone 11 Pro on iOS 27.2.1. The maintainer uses Windows and a free Apple account, with no local Mac/Xcode installation. The intended signing route is AltStore Classic. Verify the final re-signed App Group entitlement and actual access on the device; CI or an ad-hoc signature does not prove this works.

## Apps

- Show accessible detected third-party and Apple apps; hide inaccessible apps
- Present icon, name, bundle ID and total data size in comfortable, readable native rows; keep the upstream symbol fallback when an icon is unavailable
- Keep search by name/bundle ID and relevant Apple/other and installed/offloaded filters where identity is reliable
- Clear only one explicitly selected app container's `Documents`, `Library` and `tmp` contents, using retained validated purge logic
- Retain container/part roots and metadata, revalidate targets and check postconditions; report failures
- Require a destructive confirmation identifying the app and permanent scope; create no backup
- Safari and Messages are best effort through existing supported access; no claim of complete cleanup and no new access bypass
- Exclude backup filters, restore/import/export, open-folder and copy-identifier actions

## Caches

- Detect standard application/extension `Library/Caches` and `tmp`, plus accessible crash/diagnostic reports through the existing fixed upstream allowlist
- Permit manual multi-app selection by tapping individual rows; keep search
- Present one confirmation describing the captured batch scope
- Revalidate the entire batch and each target; refuse changed/inaccessible targets and never broaden to arbitrary system paths
- Keep cooperative cancellation and explicit partial-failure reporting
- Exclude bulk selection shortcuts, custom targets and arbitrary folder navigation

## Scanning and local state

- Keep manual refresh, progress, pause/resume, foreground/background handling and interruption recovery
- Opening a tab does not start a scan; show "Refresh to update" until the user refreshes
- Refresh starts a fresh scan; Resume retains interrupted-task identity and checkpoints; no timed rescans
- Keep in-memory results during the process, with only minimal local task/measurement/inode checkpoints for unfinished work
- Do not persist completed scan results, historical sizes, completed cache rows or discovery/activity history
- Remove completed recovery state when safe, sanitize legacy state before workers begin and surface cleanup failure without recording logs
- Preserve access-cache recovery separately from app-data backups

## Privacy

- Zero app-controlled telemetry, analytics, tracking or unnecessary networking
- No network clients, background requests, listeners, web server or update checking
- No application-generated logs, diagnostic collection/export, touch traces, log viewer or persistent activity history
- Errors/progress may be displayed directly in memory without recording them
- Store only operational state required for unfinished scans and safe access recovery; selections and discovery hints remain process-local
- Keep third-party runtime services out of the application
- Audit source and the actual compiled application for logging, telemetry and network behavior
- Scope privacy claims to Charony; iOS/system diagnostics and Apple or third-party signing services remain outside its control

## Interface and branding

- Minimal native UIKit interface following system Light/Dark appearance
- Bottom tabs: **Apps** and **Caches**, with native bottom-right contextual **Search**
- Search the selected tab only; preserve its controller, query/selection context and scan state when entering/leaving Search
- Verify `UISearchTab` behavior across supported versions; do not substitute an unverified mockup
- Small top-left Apps/Caches title, native Back on any secondary screen, top-right Refresh icon and separate ellipsis filter menu
- Comfortable native rows containing icon, name, bundle ID and storage size; keep selection state accessible to VoiceOver
- Center "Refresh to update" before loading; distinguish loading, genuine empty results, no search matches, unavailable access and errors
- Remove large counts/storage summaries, last-scanned banners, repeated refresh instructions and descriptive list footers
- Cap application-controlled typography at normal iOS system size (Large), allowing smaller system sizes; keep VoiceOver and accessibility labels/traits
- Native confirmations with short permanent-deletion, exact scope, no-backup and relevant content-loss warnings; necessary progress/cancellation/errors remain
- Dismiss active Search and restore the original controller before presenting a confirmation, preserving query, selection and captured targets
- Native bottom tabs/Search on both supported device families; use UIKit layout traits rather than drawing custom bars/materials
- No Settings page or gear icon
- Show Reset Access Cache only for a detected recoverable access failure
- Circular Charon-inspired moon icon with subtle surface detail and no lettering
- Use the editable layered Icon Composer Liquid Glass project for Default/Light, Dark, Clear and Tinted appearances; require native compilation/renders and record device appearance separately
- Do not substitute flattened sources for native layers; generated compatibility PNGs do not replace the layered catalog
- Use Charony bundle/product metadata and validate a usable final App Group instead of depending on upstream signing identifiers

## Feature removal

Physically remove unused implementations, resources, dependencies, build references and exclusive tests after mapping shared dependencies. Hiding a route is insufficient.

Excluded capabilities include general file management and arbitrary paths, backup/restore/import/export, file editors/viewers, ZIP utilities, Wi-Fi Sharing/web server, custom inspectors/cache targets, Recent/Favorites/activity history, themes/imports, non-English localizations, Settings/logging interfaces, diagnostics collection and update checking.

Audit feature-exclusive archive, sharing, theme, inspector, editor and media modules; remove obsolete examples, release notes, scripts, assets and dependencies. Keep `build.sh`, `Info.plist`, compile inventories, runners and packaged resources consistent. Do not indiscriminately delete shared code or a security primitive during refactoring. [ARCHITECTURE.md](ARCHITECTURE.md) documents retained exceptions and removed groups.

## Safety requirements

Preserve App Group access/recovery, container identity and permission validation, deletion boundaries, no-follow traversal, symlink/race checks, cancellation, scan checkpoints and meaningful safety tests.

App clearing is confined to the selected application container. Cache cleaning is confined to eligible fixed cache/tmp/report paths. Selection and confirmation remain mandatory after backup removal. Validate identity and scope before mutation and during destructive walks, serialize overlapping operations, preserve required roots and report partial outcomes. Never imply cancellation can restore deleted data or that removed backups provide rollback.

Use disposable fixtures for destructive tests. No destructive testing against real user data or live Safari/Messages data is permitted. Stop for contradictions or unresolved safety-critical uncertainty rather than guessing. [docs/SAFETY.md](docs/SAFETY.md) records implementation boundaries and residual races.

## Validation requirements

Keep the pinned stable archive/file manifest and nine exact upstream safety-helper comparisons independent of Charony Git ancestry. Run the unchanged upstream baseline on a compatible macOS runner and distinguish environment limitations from defects. Never delete or disable a failing test to get a passing build.

Maintain focused positive and negative coverage for:

- Exact deletion scope and preservation of unrelated data
- Traversal, symlink redirection, stale inode/bundle identity, moved containers and inaccessible apps
- Interrupted/repeated/overlapping operations, cancellation and failure reporting
- Cache/crash boundaries, manual batch selection and confirmation/cancel flows
- Scan checkpoint persistence, recovery and removal of completed results
- Absence of app/file backup artifacts after clearing or cleaning
- Logging/network removal, contextual search and navigation

GitHub Actions must run relevant native macOS tests, strict Objective-C iOS compilation/linking, disposable Simulator fixtures, source/binary privacy audits, IPA/package/bundle metadata validation, App Group/signature validation and asset/icon compilation. Check actual pinned Xcode/SDK/runtime availability and fail on missing tooling. Do not embed signing credentials in source or artifacts. An unrun/skipped check remains unverified.

Screenshot galleries, exhaustive capture hosts and screenshot-only CI jobs are outside scope. Preserve their useful functional and safety assertions in required native tests; do not retain generated screenshots or ZIPs in source control. Native icon compilation and focused appearance renders belong in the required validation job; they are not a UI screenshot gallery.

Keep [TESTING.md](TESTING.md) accurate with commands, platform, outcomes, evidence and unresolved requirements. Simulator fixtures cannot validate real sandbox tokens, supported protected-app access or final sideloaded signing. Begin physical checks read-only; destructive validation must use an expendable app with disposable data, preferably on a spare supported device. If that is unavailable, keep destructive-device behavior unverified. Require independent destructive-code review before primary-phone use.

Critical deletion, privacy, recovery or packaging failures block an IPA release. Complete actual icon appearance and device/signing gates before claiming release readiness. CI success alone does not establish destructive safety on a primary iPhone.

## Repository workflow

[AGENTS.md](AGENTS.md) defines repository-specific GitHub permissions, mandatory local identity and development procedures. Normal work uses development branches and pull requests targeting `main`. Never modify `main` directly, force-push, rewrite history, delete/recreate the repository, bypass checks or commit secrets. The one-time history exception is complete and expired. Merges, remote branch deletion and release publication require explicit maintainer approval; do not enable automatic merging, releasing or deployment. Authorization does not extend to other projects or external accounts/infrastructure.

Keep the README concise and place technical detail in architecture, safety and testing documents. Preserve notices and accurate build/install, privacy, compatibility and release limitations. Report actual results, branch/PR/commit, remaining risks and approval requirements in the conversation for the maintainer's separate planning review. Do not add temporary handoff diaries to the repository or assume automatic communication between conversations.


## First installation

Prepare a downloadable CI development IPA with source revision/tree and actual package checksum, architecture, deployment target and embedded App Group evidence. Keep signing credentials out of Git/CI. Research the Windows signer's real Apple provisioning flow; do not equate entitlement strings with authorization. Before first launch, verify an Apple-issued profile and matching signed/installed App Group. A refusal or unavailable verification is a blocker; do not remove the entitlement or bypass Apple signing. [Windows preparation](docs/INSTALL_WINDOWS.md) defines the credential-private procedure and strictly read-only first session.

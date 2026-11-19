charony is a minimal, English-only native UIKit derivative of WQ Files for managing accessible application data and caches. This initial implementation is prepared for code review. Native build and simulator checks passed in GitHub Actions. Physical-device verification and layered icon work remain outstanding. See TESTING.md before building or installing.

Apps lists accessible third-party and Apple application data containers with name, icon, bundle identifier and measured storage. Search matches name and bundle ID. Session filters cover Apple/other apps and installed/offloaded state when the upstream checks provide sufficient identity information. Selecting an app opens one destructive confirmation. Clear Data permanently empties that selected container's Documents, Library and tmp while retaining the container, part directories and metadata. Close the target app first. No backup is created.

Caches scans application and extension Library/Caches and tmp folders and the upstream allowlisted crash-report directories when accessible. Tap individual rows to select or deselect them. One Clean confirmation describes the batch scope. Offline downloads stored in caches may be removed. Stop requests cancellation between filesystem items. Targets that have changed identity or have incomplete access require a fresh scan.

The trailing native Search tab applies to the currently selected Apps or Caches controller. The same controller is moved into the search navigation stack to retain current selections and scanning state. Dismissing search returns to that tab. Contextual search and controller restoration passed the programmatic iOS 26.2 simulator fixtures. Touch delivery, keyboard interaction, accessibility and iOS 27 behavior require further verification. Both lists follow system Light/Dark appearance. Access Cache recovery is offered only after a detected recovery failure.

Initial tab opening may start a scan. Pull to refresh explicitly starts fresh work. Pause and Resume preserve unfinished work. Scans suspend on background entry and continue when foregrounded. In-memory results serve the current process. Completed task rows, timestamps and container discovery results are excluded from durable storage. Unfinished measurement and inode checkpoints allow interrupted work to resume. Legacy completed state is removed at startup before workers begin. Checkpoint I/O uses no-follow, descriptor-relative operations. Checkpoint removal failures produce an ephemeral storage warning. Old orphaned checkpoints are pruned after seven days.

Application source removes logging, analytics, telemetry, diagnostics collection/export, update checks, network clients and listeners. Discovery hints and filter choices are process-local. Persisted operational state is confined to unfinished scan recovery and the access-cache recovery protocol. Errors and progress are presented in memory. iOS system diagnostics and Apple or third-party signing services operate independently. Source and built-binary auditing passed in GitHub Actions. This does not establish control over system diagnostics or signing services.

The intended upstream operating-system range is iOS 26.0–26.7.2 and iOS 27.0–27.3 beta 1, subject to access capabilities. iOS 27.3 beta 2 and later patched worse_query and are unsupported. The retained build check disables access on known patched builds. The maintainer's iPhone 11 Pro on iOS 27.2.1 has not been tested with this implementation. Safari and Messages cleanup is best effort through existing access methods. Data in other containers, App Groups, keychain or system services may remain.

Linux/macOS host checks require Python 3, Git, Bash, zip and unzip. Python code uses the standard library. Build-pipeline tests use command doubles for Apple tools. Windows can run the source/package suite with `python3 -m unittest discover -s tests -p test_charony.py`; the POSIX pipeline fixtures run in Codex Cloud and macOS CI.

```bash
cd /workspace/charony
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s tests -p 'test_*.py' -v
python3 scripts/privacy_audit.py
bash -n build.sh scripts/sources.sh tests/run_all_tests.sh tests/run_scan_ui_tests.sh
```

Building requires macOS, Python 3 and Xcode with an iOS SDK supporting deployment target 26.0. No CocoaPods, Swift packages or third-party runtime dependencies are used. Build and test from the repository root.

```bash
bash tests/run_all_tests.sh
bash build.sh
```

The build produces charony.ipa after host fixtures, strict Objective-C compilation/linking, source and binary audits, asset compilation, metadata checks, ad-hoc signing and package validation. Set CHARONY_FINAL_IPA to an output path whose parent already exists. Failed checks preserve an existing final IPA. The current icon is a flat development moon asset resized by sips and compiled by actool. Layered Icon Composer Light, Dark, Clear and Tinted appearances are incomplete and require Mac authoring, compilation and on-device checks.

.github/workflows/validate.yml prepares macOS validation using a four-CPU macos-26-intel baseline runner and a native Arm64 macos-26 Charony/simulator runner, both with pinned Xcode 26.2, with pinned checkout/upload actions and read-only permissions. Early preflight checks verify active CPUs, installed Xcode, SDK directories/versions and the available simulator runtime. It runs the unchanged stable baseline before the Charony job. The Charony job builds a development IPA, runs a fixture-driven UIKit harness on a disposable iOS 26 simulator and uploads the artifact after those checks pass. Diagnostics are retained on failures. The current published runner inventory lists Xcode 26.2 and an iOS 26.2 runtime. CI checks the actual installation and fails if pinned tooling is absent. [CI_VALIDATION.md](CI_VALIDATION.md) records the authorized development-branch/PR/Actions process, independent-history baseline verification and evidence to return for review. The maintainer authorized Codex-managed development and one verified independent-history migration for this repository only. Normal work uses development branches and PRs. Merges and releases require explicit approval. Actual Actions outcomes are recorded in TESTING.md and the task report.

For Windows installation, the intended signing route is AltStore Classic with a free Apple account. A working App Group entitlement must survive re-signing. The development bundle ID is io.github.micknorj.charony, and its ad-hoc entitlement requests group.io.github.micknorj.charony. The signer may assign a different group. Runtime access selects the signer's actual usable group. Confirm the final signed entitlement and group access on the iPhone. Free-account provisioning, refresh and service limits are controlled by Apple and the signing tool. Successful compilation or ad-hoc packaging does not verify the re-signed app.

Keep release preparation maintainer-controlled.

1. Review the baseline-to-Charony changes and destructive paths independently. ARCHITECTURE.md records retained safety code and all removed paths.
2. Run both CI jobs and inspect actual test, compiler, simulator, entitlement, privacy and packaging outcomes. Fix every critical failure and complete the layered icon work.
3. Validate read-only launch, the actual App Group, app listing, permission failures, contextual search, manual scanning, pause/resume and restart recovery on a supported iPhone.
4. Exercise destructive behavior only on an expendable app containing disposable data, preferably on a spare supported device. Leave real Safari/Messages data out of destructive tests. If this verification is unavailable, keep device destruction marked unverified.
5. Update TESTING.md with actual evidence and supported builds. Select a release version/build, build from that source revision, review the final re-signed metadata and entitlement, and manually publish the corresponding source and IPA with GPL notices and limitations.

LICENSE and NOTICE.md preserve GPL-3.0-or-later and upstream attribution. The authoritative implementation requirements are retained in charony-codex-spec.md. Charony has an independent Git history. Upstream source provenance remains documented and fixes require explicit review before integration. Baseline tests use a checksum-verified stable source snapshot without importing upstream ancestry.

IMPLEMENTATION_REVIEW.md records the focused safety review, baseline failure diagnosis, test-coverage mapping and fixes.

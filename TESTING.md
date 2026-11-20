# Testing and verification

## Verified baseline

The reviewed main revision `286782c0e35747f3676de1af23e4b1addabd7944` passed [GitHub Actions run 44606787990](https://github.com/micknorj/charony/actions/runs/44606787990). Both `upstream-baseline` and `charony` succeeded. This is build, fixture and simulator evidence; physical-device behavior remains unverified.

| Check | Result | Platform / evidence |
| --- | --- | --- |
| Unchanged WQ Files v0.9.18 runner | Passed, including 32 Python tests and native suites | Four-CPU Intel macOS, Xcode 26.2; `upstream-baseline` job |
| Optional upstream ffmpeg-video subcase | Skipped: ffmpeg unavailable | Removed Charony functionality; not device evidence |
| Reviewed main portable suite | 42 tests passed | macOS; `tests/test_*.py` |
| Current native safety fixtures | All 10 executables passed | Arm64 macOS; `tests/run_all_tests.sh` |
| Strict iOS syntax, compilation and linking | Passed with `-Wall -Wextra -Werror` | Arm64, Xcode / iOS SDK 26.2, deployment target 26.0 |
| Source and compiled-binary privacy audits | Passed | Real built executable; `scripts/privacy_audit.py` |
| Flat development icon / asset compilation | Passed | `actool`, compiled `Assets.car` |
| Development IPA, metadata, exact App Group entitlement and ad-hoc signature | Passed | Real IPA; build verification and extracted signature check |
| UIKit, lifecycle and cold-relaunch fixtures | Passed | Disposable iPhone 17 / iOS 26.2 simulator |
| Downloaded final IPA structural/metadata recheck | Passed | Linux; `scripts/verify_ipa.py` |
| Layered Icon Composer appearances | Incomplete | Flat icon only |
| Final sideloaded signature, physical App Group/access and actual deletion | Unverified | No physical device tested |

No required check failed in that run. Historical Linux baseline failures were missing-tool limitations, not established application defects. Native CI subsequently passed the unchanged baseline. See [safety coverage](docs/SAFETY.md#baseline-failures) for the classification.

## Local checks

Run from the repository root. Python uses only the standard library.

On Linux or macOS, with Python 3, Git, Bash, zip and unzip:

```sh
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s tests -p 'test_*.py' -v
python3 scripts/privacy_audit.py
bash -n build.sh scripts/sources.sh tests/run_all_tests.sh tests/run_scan_ui_tests.sh
```

The current 46-test suite includes 19 source/package checks, seven POSIX build-pipeline methods, seven verified-baseline extraction methods and 13 toolchain-preflight methods. The reviewed main run above predates the four inventory-timeout regressions and executed 42 tests. Pipeline tests use command doubles for Apple tools; they do not replace native validation. Windows can run the source/package subset with `python -m unittest discover -s tests -p test_charony.py`; run POSIX fixtures in Cloud or macOS.

On macOS with Xcode 26.2 selected:

```sh
export DEVELOPER_DIR=/Applications/Xcode_26.2.app/Contents/Developer
python3 scripts/ci_preflight.py --simulator
bash build.sh
```

`build.sh` runs the native and portable suites, strict iOS checks, source/binary audits, asset compilation, ad-hoc signing and package verification. It writes `charony.ipa` only after the build gates pass. `CHARONY_FINAL_IPA` may select an output path whose parent already exists. Failure preserves an existing final artifact.

To run host/syntax checks separately, use `bash tests/run_all_tests.sh`. To recheck an IPA's structure and metadata, use `python3 scripts/verify_ipa.py path/to/charony.ipa`. This Python check alone does not verify an Apple signature.

## GitHub Actions

[`.github/workflows/validate.yml`](.github/workflows/validate.yml) runs on branch pushes, pull requests and manual dispatch. It does not merge, release or deploy.

| Job | Environment | Required work |
| --- | --- | --- |
| `upstream-baseline` | `macos-26-intel`, at least four active CPUs | Verify Xcode/SDKs, verify pinned stable source, run unchanged upstream tests |
| `charony` | Arm64 `macos-26`, at least two active CPUs | Native/portable tests, strict iOS build, privacy, assets, signature/entitlements, IPA, disposable simulator |

Both jobs require `/Applications/Xcode_26.2.app/Contents/Developer` and iOS 26.2 SDKs. Simulator preflight requires an available iPhone 17 / iOS 26.2 runtime. It records `toolchain.json` and fails on missing or mismatched tooling. A timed-out read-only CoreSimulator inventory query is retried once with the same 60-second bound. A second timeout, nonzero command result or invalid inventory still fails; tests and mutation commands are not retried by this setup helper. The unchanged upstream interruption fixture needs two workers from half the active CPUs; Charony's corresponding fixture selects existing parallel mode without changing its recovery assertions.

The stable archive and all files are verified against the pinned manifest before extraction. Safety-helper comparisons do not depend on inherited Git objects. See [source provenance](ARCHITECTURE.md#source-provenance).

The Charony job requires baseline success. There are no allowed-failure steps. Checkout/upload actions are pinned, permissions are `contents: read`, and checkout credentials are not persisted. No Apple credentials, provisioning profiles or signing secrets are required.

### Submitting changes

1. Check repository identity, write permissions, local commit identity and existing remote work as required by [AGENTS.md](AGENTS.md).
2. Push a development branch and open a pull request targeting `main`.
3. Find the submitted commit's runs and inspect both job conclusions:

   ```sh
   gh run list --repo micknorj/charony
   gh run view RUN_ID --repo micknorj/charony
   gh run watch RUN_ID --repo micknorj/charony --exit-status
   ```

4. Fix failures without disabling checks. A skipped dependent job is unverified. Keep the first failing stage and its full log.

### Artifacts

- `upstream-baseline-diagnostics`: selected baseline/preflight logs
- `charony-validation-diagnostics`: build, native, Python and simulator evidence
- `charony-development-unverified-on-device`: development IPA, uploaded only after validation succeeds

Artifacts are retained for 14 days. Selected diagnostics are uploaded even on failure; hidden result/log paths are included. Download needed evidence before expiry. Preserve the run URL, tested SHA, toolchain record, conclusions and remaining gaps when reporting results.

## UI screenshots

Manual dispatch also runs the `gallery` job after normal validation succeeds. It builds a separate simulator fixture host from the production controllers, tab shell, alerts and mutation engines, then captures real PNGs with `simctl`. The host supplies disposable app discovery and fixture identities; it does not demonstrate protected sandbox access or final device signing.

The gallery covers Apps/Caches lists, contextual search, confirmations, real disposable-file mutation outcomes, access errors, scan controls and cold-relaunch recovery. It requests Light/Dark appearance on an available iPhone 11 Pro (iPhone 17 fallback) and iPad, and the largest accessibility text size on iPhone. Keyboard visibility and actual trait values are recorded. Unsupported or unavailable states are listed explicitly. Capture failures fail the job; they are not replaced with mockups. The fixture driver waits for native alert-dismissal completion before advancing or releasing a held mutation, and asserts that the mutation remains busy until the conflict alert is gone. This prevents an outcome from being deferred behind a dismissing test alert. Overflowing native alert text is scrolled in overlapping pages and captured before the alert is dismissed; these extra frames retain the underlying fixture-step identity. Enlarged cache rows and an overflowing Apps safety footer receive additional actual scrolled-table captures, without replacing their initial viewport frames. Failed runs retain their actual partial PNGs, captured lifecycle stdout and native layout/navigation diagnostics. Cache-footer checks bring an off-screen footer into the actual viewport at accessibility sizes before asserting its rendered scope text; visible footers are checked without recreating them. Per-commit validation is recorded in [readiness PR #2](https://github.com/micknorj/charony/pull/2); an application-job pass alone does not establish gallery completion.

```sh
gh workflow run validate.yml --repo micknorj/charony --ref YOUR_DEVELOPMENT_BRANCH
```

Download `charony-fixture-ui-gallery` for individually named PNGs, `INDEX.md`, an offline HTML gallery, provenance manifest and ZIP. Generated images stay in ignored `.work` output and are not committed. The regular lifecycle harness remains a required check on every push and pull request; the longer gallery runs only on manual dispatch.

The completed fixture gallery at commit `66b7238` exposed a floating Apps footer, unreadable horizontal cache labels at the largest accessibility size and stale selection guidance. Follow-up fixes and regressions remain subject to their own commit's validation. On iPad, native UIKit places tabs and Search at the top; this differs from the specification's literal bottom placement and remains an interface review item. The first phone Search capture can include an OS keyboard introduction despite simulator preferences; later captures show the keyboard. No overlay is removed from the PNGs.

## Safety coverage

Native fixtures cover access-cache recovery, no-follow path checks, purge boundaries, selected-app scope, identity changes, symlinks, traversal, unrelated-file preservation, cancellation, repeated operations, missing access, scan interruption and checkpoint recovery. Clearing and cleaning must create no backup artifacts.

The simulator uses production controllers with disposable fixture roots. Loading/empty Apps tests drive real task notifications before any completed rows exist and check that every advertised row has a model; refresh must keep existing rows. Normal empty-note snapshots must show Apps totals, cache selection and cleaning results; partial storage must be labelled incomplete. Header/footer fixtures require complete wrapping error/safety text and singular app counts. Apps guidance must follow the last row without floating over the list. Cache fixtures check the rendered selection-dependent footer, remove Stop when cleaning finishes even if a rescan is deferred, and verify non-overlapping wrapping labels at accessibility sizes while retaining compact normal-size rows. Deferred-clear fixtures retain an outcome behind an actual modal, dismiss it, and require delivery without navigation or a foreground event; the gallery repeats this with a real disposable-file purge. Search tests wait for actual UIKit presentation and completed context restoration within a bounded deadline, then check that the real controller remains attached to the visible window. Failure records include the selected/pending tab and presentation state. Cache-row checks cover grouped accessibility content, selected/unselected/limited state and Dynamic Type participation. LaunchServices malformed-input tests cover paths at each short prefix before a possible embedded-plist header, while preserving valid later mappings. It covers fixed crash/cache boundaries, changed-target batch refusal, manual selection, one confirmation, cancellation, unselected sentinels, contextual search/controller restoration, background/foreground handling and cold relaunch. Test-only root overrides are excluded from the production build. These fixtures do not issue real sandbox tokens.

[docs/SAFETY.md](docs/SAFETY.md) records the destructive-operation model, review fixes and all 21 original portable-test dispositions. Counts alone do not establish equivalent coverage.

## Device verification

Physical verification is maintainer-controlled. The intended target is an iPhone 11 Pro on iOS 27.2.1, build `24B156`; it has not been tested with Charony. That exact build passes the retained patched-build predicate in a regression fixture. This checks the guard decision, not hardware access or signing.

1. Review the final re-signed bundle ID, App Group entitlement and signature. The development values are `io.github.micknorj.charony` and `group.io.github.micknorj.charony`; the signer may assign a different group. Runtime must select the signer's actual usable group.
2. Begin read-only: launch, verify group/access setup, accessible-app listing, inaccessible-app hiding, icons and size measurement. Check current permission failures and conditional Reset Access Cache.
3. Verify refresh, pause/resume, background/foreground, interrupted scans, restart recovery and absence of completed-result caching.
4. Check tab/search placement, keyboard/touch interaction, Light/Dark appearance, filters, confirmation/cancel, VoiceOver, Dynamic Type and supported iOS/iPad layouts. Programmatic simulator success is not complete interaction coverage.
5. Test deletion only on an expendable app with disposable data, preferably on a spare supported device. Check exact scope, preserved roots/unrelated files, no backups, cancellation where supported, changed identity, failure reporting and repeat behavior. Never test by deleting live Safari or Messages data.
6. Verify real asset appearances after layered Icon Composer work is complete. Do not infer Light/Dark/Clear/Tinted icon support from flat PNG compilation.

The intended Windows signing route is [AltStore Classic with AltServer](https://faq.altstore.io/altstore-classic/how-to-install-altstore-windows). Follow its current Windows/iTunes/iCloud, device-trust, Wi-Fi sync and Developer Mode instructions. With a free Apple account, provisioning expires after seven days; refresh before expiry with AltServer available. Apple documents up to three installed apps per device and ten App IDs for Personal Teams; AltStore itself occupies an app slot. See [Apple membership limits](https://developer.apple.com/support/compare-memberships/).

The upstream stable README says AltStore/SideStore can create the required group with free accounts. This is a documented route, not a verified Charony installation. Inspect the final executable entitlements and embedded provisioning profile for an authorized, usable group after re-signing. A copied entitlement string or the CI ad-hoc signature alone is insufficient. Installation and App Group preservation remain unverified. If disposable-device testing is unavailable, keep destructive-device behavior marked unverified.

## Release checklist

Releases require explicit maintainer approval and manual publication.

- Obtain independent destructive-code review and pass all current baseline, safety, privacy, scan, UI and packaging gates
- Complete layered icon work and record actual device/signing evidence and supported builds
- Keep unsupported patched iOS versions and partial-deletion limits visible
- Select and verify the version/build metadata; build from the reviewed source revision
- Review the final re-signed signature, App Group entitlement, metadata and package contents
- Include GPL licensing, notices, corresponding source and build scripts for the exact binary
- Record the tested commit, run URL, device/build, results and any unresolved checks before approving publication

Critical deletion, privacy, recovery or packaging failures block an IPA release. A CI pass alone does not establish safety for destructive use on a primary iPhone.

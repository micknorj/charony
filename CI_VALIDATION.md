The workflow validates the Charony development implementation. It does not merge, publish a release or deploy. No Apple account, signing certificate, provisioning profile or repository secret is required. The IPA is ad-hoc signed for packaging checks and requires maintainer-controlled re-signing before device installation.

The GitHub repository is micknorj/charony, ID 1463379238. On November 19, 2026 the authenticated owner API reported fork=false, no parent/source, main as the default branch and push/admin permissions. The initial remote inventory contained only main at 985cf765cdf3bd4cb88da15de3f7d928664efae6, with no tags, releases or pull requests. The maintainer authorized a one-time parentless-history replacement with an explicit force-with-lease. AGENTS.md and charony-codex-spec.md preserve the exact scope and the normal restrictions after migration.

The original Charony implementation commit 994f97085bb309ababae876637e2ae02043cd16f is retained in an independently restored and verified external Git bundle. The new root and subsequent Charony commits use repository-local identity micknorj <329715135+micknorj@users.noreply.github.com>. Global Git configuration is unchanged. Licensing and upstream provenance remain in the source and NOTICE.md.

| Item | Required value | Evidence |
| --- | --- | --- |
| Baseline runner | macos-26-intel, four active CPUs | Unchanged upstream utility-mode interruption fixture requires two workers |
| Charony build/simulator runner | macos-26, Arm64, three active CPUs | Native simulator execution; Charony fixture explicitly requests two-worker parallel mode |
| Xcode | /Applications/Xcode_26.2.app/Contents/Developer, version 26.2 | Published inventory lists Xcode 26.2 build 17C52 |
| Device/simulator SDK | iOS 26.2 | Published inventory and mandatory runtime preflight |
| Deployment target | iOS 26.0 | Reviewed Info.plist and compilation arguments |
| Simulator | Available iOS 26.2, iPhone 17 | Published inventory and mandatory simctl JSON preflight |

The inventory source is https://github.com/actions/runner-images/blob/main/images/macos/macos-26-Readme.md. CI records the actual Xcode/SDK/runtime versions and runner image in toolchain.json. It refuses missing or mismatched tooling without substitution or skipped checks. The earlier Xcode 26.0/iOS 26.0 runtime assumptions were corrected against the now-accessible inventory. Deployment compatibility stays at 26.0.

The native interruption fixture requires two scanner workers. The scanner's utility mode uses half the active CPU count, rounded down. The unchanged upstream fixture runs on four-CPU Intel so utility mode supplies two workers. Charony's corresponding fixture explicitly selects the existing full parallel mode, which supplies at least two workers on Arm64. Its checkpoint/frontier algorithm and crash/recovery assertions are unchanged. Preflight verifies the corresponding four-CPU/two-CPU minimum. No test or assertion is disabled. Charony's simulator step runs natively on Arm64 after an Intel simulator boot stalled, while every native suite and real IPA check remains mandatory.

The upstream-baseline job downloads the exact stable source archive pinned in tests/upstream-baseline.json. Before migration, every archive file and executable bit was compared to trusted stable Git commit e44cd0ef226305bc265c8d7a15607ec49ceb4368. Archive SHA-256, all 147 file hashes/sizes/modes and the original Git tree are recorded. scripts/baseline_source.py verifies those values and rejects unexpected, duplicate, missing, changed, linked or traversing entries before extraction. CI then runs the complete unchanged stable regression runner. No inherited Git commit is required in Charony's new history.

Charony's safety-helper test still compares the same nine functions byte for byte with upstream. Its test-only fixture has a pinned checksum and stable-source provenance. The diagnostic baseline build probe uses the same verified source extractor. No baseline test was removed or skipped during the history transition.

The Charony job depends on baseline success. bash build.sh unconditionally runs ten native macOS safety fixture executables, the Python suite, source auditing, strict arm64 iOS syntax/link checks and plist validation. It then compiles the application and development icon, audits the Mach-O, ad-hoc signs, verifies the exact App Group entitlement, validates the IPA archive/metadata and verifies the extracted signature. A fresh disposable simulator exercises UIKit, cache/crash boundaries, confirmation, search and interruption/recovery. The development IPA is uploaded only after all gates succeed.

Both jobs retain selected diagnostics for 14 days even on failure, including hidden .ci-results and .work log paths. There are no allowed-failure steps or CI skip inputs. Checkout credentials are not persisted, actions are pinned by commit and workflow permissions remain contents read. No keychain import, signing secret, environment dump or user-data collection is configured.

Normal work after migration uses development branches and pull requests targeting main. Do not perform further direct main or force pushes under the expired one-time exception. Check the owner/repository and current push permissions, preserve existing remote work and verify commit author/committer metadata before pushing. Use connected tools where supported or existing GitHub CLI/platform authentication. Never request a personal access token as a shortcut.

A branch push or pull request triggers Charony validation. Use gh run list --repo micknorj/charony to locate the submitted SHA, then inspect/watch both upstream-baseline and charony. A skipped Charony job after baseline failure is unverified. Fix causes without disabling checks and retain the first failing stage and full log.

Download upstream-baseline-diagnostics and charony-validation-diagnostics from the run page, along with charony-development-unverified-on-device when produced. Preserve the run URL, submitted SHA, job conclusions, toolchain.json and logs for the separate planning conversation. There is no automatic cross-conversation handoff.

The initial history replacement and remote cleanup are verified through live API/ref checks and recorded in the task completion report. GitHub may retain creation metadata, cached contributor information, Actions records and unreachable or pull-request objects under its retention rules. Do not claim these were erased through a branch update.

Layered Icon Composer artwork, final sideloaded App Group signing, physical sandbox access and destructive-device safety remain separate open gates. A green CI run alone does not establish safety for destructive use on a primary iPhone. Merges and releases require explicit maintainer approval. Do not publish a release for this migration.

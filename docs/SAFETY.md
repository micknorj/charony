# Safety model and test coverage

Charony uses upstream deletion and access primitives with a reduced Apps/Caches interface. The focused review and native CI corrections below are implemented. Current execution evidence and open device gates are in [TESTING.md](../TESTING.md).

## Destructive operations

### App data

[`CHAppData`](../CHAppData.m) accepts one explicitly selected application UUID under the exact application-data parent. It captures device/inode and bundle identity, validates `Documents`, `Library` and `tmp` before mutation, and rechecks the selected target during purge.

Traversal, symlink redirection, changed identity, inaccessible targets and Charony's own container are refused. Container/part roots and metadata are retained, emptiness is checked, and partial failures are reported. App Groups, keychain and unrelated containers are outside the operation.

Canceling the confirmation starts no worker. Confirmed full app clearing uses the upstream permanent-clear behavior and has no Stop button. No app-data backup or rollback is created.

### Caches and crash reports

[`WQCache`](../WQCache.m) accepts exact application/extension parents with fixed `Library/Caches` and `tmp` paths. Crash cleaning is limited to the two upstream report directories and requires canonical, no-link ancestry and the scanned directory identity. Fixture-only crash roots are available only in test compilation.

The confirmation captures the exact item array and scan generation. The complete batch is validated before mutation, each target is checked again before use, and changed generations/identities are refused. Malformed records and existing cache targets of the wrong type are rejected before access. Unselected targets must remain unchanged.

Cancellation is cooperative between filesystem items. Leaving the cache view cancels active cleaning. Cancellation or the first failure stops remaining work and reports the outcome; completed deletions remain permanent.

### Shared purge

[`WQAccess`](../WQAccess.m) uses descriptor-relative traversal. Immediately before every unlink attempt, including permission/lock-flag retries, it rechecks cancellation, selected scope, parent ancestry and leaf identity. The walk stops on the first removal failure. A main-thread reservation and serial I/O queue prevent overlapping app/cache mutations.

The operating system does not provide an atomic compare-inode-and-unlink transaction against an uncooperative writer. Revalidation reduces observable race windows but cannot prove all external races impossible. Interruption or a later failure can leave a partially cleared target.

## Recovery without backups

The removed backup/restore flow was not a rollback transaction required by upstream's Clear Without Backup path. Selection, identity/path checks, descriptor traversal, root preservation, cancellation where supported and partial-failure reporting remain.

The App Group cache-swap marker, preserved directory and interrupted-swap recovery protocol remain because they protect access setup. Checkpoint writes/reads/publication/removal use no-follow descriptors and retain unexpected directories. These are operational recovery mechanisms, not copies of app data.

Nine exact upstream safety helpers, including the directory-creation pair needed for checkpoints, remain compared through the pinned provenance fixture. See [retained shared code](../ARCHITECTURE.md#retained-shared-code).

## Review corrections

| Finding | Retained fix and regression coverage |
| --- | --- |
| Cache selection could change after confirmation was displayed | Capture items/generation; UIKit fixtures preserve an unselected third app and refuse stale confirmation |
| Purge could use stale leaf identity or omit checks on retries | Immediate scope/ancestry/identity/cancellation revalidation; late replacement, traversal, cancellation and repeat fixtures |
| Crash/cache records could be malformed or have a wrong target type | Validate shape before access, exact report-root agreement and directory identity/type; allowlist and refusal fixtures |
| Completed results or legacy discovery data could survive startup | Prepare both tasks before workers, remove completed/legacy state, retain unfinished identity and remove staging orphans; process-recovery fixtures |
| Checkpoint operations could follow redirected ancestry | No-follow directory creation, pinned descriptors, regular-file reads and descriptor-relative publication/cleanup; symlink and unexpected-directory fixtures |
| Python optimization could remove the entitlement gate | Unconditional comparison; optimized missing/lookalike-group cases must fail without replacing the final artifact |
| Final IPA output could be interpreted as a directory | Exact atomic replacement; directory/sentinel refusal and staging-cleanup fixtures |
| IPA validation accepted unsafe entries or incomplete metadata | Reject links, special files, traversal/aliases, duplicates, obsolete resources and missing execute permission; compare source metadata |
| Runtime failure delivery and tests lacked positive preconditions | Foreground error delivery, work after dialog dismissal and conditional recovery; canonical fixture roots with valid path/identity assertions |
| Real macOS found stale diagnostic/type references and Bash 3.2 guard failures | Compile fixes and explicit deployment/architecture/output/asset refusal; all native fixtures and pipeline fault tests pass |
| Independent history removed inherited Git objects | Verified stable archive plus pinned helper fixture; unchanged upstream runner and extraction refusal tests remain active |

See [`tests/WQPurgeTests.m`](../tests/WQPurgeTests.m), [`tests/CHAppDataTests.m`](../tests/CHAppDataTests.m), [`tests/WQScanRecoveryTests.m`](../tests/WQScanRecoveryTests.m), [`tests/CHUITests.m`](../tests/CHUITests.m), [`tests/test_build_pipeline.py`](../tests/test_build_pipeline.py) and [`tests/test_charony.py`](../tests/test_charony.py).

## Baseline failures

The original full Python discovery contained 32 tests. Its Linux execution reported seven assertion failures and one error. These were reproduced against unchanged stable source.

| Original failing case | Missing prerequisite | Classification |
| --- | --- | --- |
| `test_compiles_for_the_info_plist_minimum_os` | `plutil` | Linux tool limitation |
| `test_default_output_stays_in_project` | `plutil` | Linux tool limitation |
| `test_executable_preflight_runner_runs` | `plutil` | Linux tool limitation |
| `test_explicit_skip_bypasses_preflight_with_warning`, runner absent | `plutil` | Linux tool limitation |
| `test_explicit_skip_bypasses_preflight_with_warning`, runner present | `plutil` | Linux tool limitation |
| `test_non_executable_preflight_runner_still_runs` | `plutil` | Linux tool limitation |
| `test_success_publishes_only_a_validated_zip` | `plutil` | Linux tool limitation |
| `test_navigation_does_not_cancel_scans` | `xcrun` / macOS Foundation | Native test requires macOS |

A negative test can appear to pass because a missing tool stops it before the intended stage. [`tests/baseline_build_probe.py`](../tests/baseline_build_probe.py) therefore extracts the verified stable archive to disposable storage, adapts two absolute plist-tool paths there, and supplies explicit plist responses. All ten original build-fixture methods reach their intended stages and pass with upstream compiler/asset/signing doubles. This is orchestration evidence, not native execution.

The unchanged full baseline runner subsequently passed real macOS CI. Its first three-CPU attempt timed out in the two-worker interruption fixture; the four-CPU Intel runner satisfies the unchanged worker requirement. No application defect was established by the original eight Linux observations. No assertion was removed to obtain the native pass.

## Original portable coverage

The original 21 portable checks and the initial 16 Charony checks covered different features. The current suite combines source/package/pipeline tests with native and simulator fixtures. Retained requirements have replacement coverage; removed-feature checks were retired with their implementations.

| Original check | Current disposition or coverage |
| --- | --- |
| `test_every_language_matches_english` | Non-English translations removed; English metadata/resource absence checked |
| `test_language_tables_have_identical_keys` | Translation tables removed; obsolete resources excluded from source/package inventory |
| `test_placeholders_are_preserved` | Native English-format fixture and strict Objective-C format checking |
| `test_critical_ui_terms_are_translated` | Translation requirement retired; destructive confirmation/cancel source and UIKit fixtures retained |
| `test_unused_restore_keys_are_removed` | Restore interface, helpers and resources physically removed and audited |
| `test_plural_suffixes_are_not_localized_as_placeholders` | Translation lookup removed; English-format and batch-confirmation fixtures cover retained behavior |
| `test_plist_date_and_data_actions_stay_distinct` | Plist editor removed |
| `test_localized_lookup_honors_verbatim` | `WQEnglishPresentationTests` checks English/raw-string identity and optional strings |
| `test_bundle_and_build_declare_localizations` | English-only metadata, resource absence, compile inventory and package checks |
| `test_info_plist_declares_documented_ios_26_minimum` | Source/package metadata and recorded compiler-argument checks |
| `test_ipad_declares_all_orientations` | Device-family and orientation metadata checks; no claim of device layout validation |
| `test_signing_requests_app_group_but_not_signer_owned_identifier` | Source and real ad-hoc entitlement gates; missing/lookalike/optimized refusal tests; final sideload signature unverified |
| `test_catalog_policy_is_explicitly_26_0` | Catalog removed; build and compiled-argument fixtures enforce target 26.0 |
| `test_matching_ipa_succeeds_and_uses_embedded_minimum_os` | Positive IPA verifier, pipeline tests and real development IPA |
| `test_rejects_identity_version_build_and_policy_mismatches_without_mutation` | Metadata refusals and package-stage failures preserve previous artifact |
| `test_rejects_missing_and_malformed_ipas_without_mutation` | Missing, malformed and empty archives rejected; build failures preserve previous artifact |
| `test_existing_description_is_preserved_when_notes_are_omitted` | Mutable release catalog removed |
| `test_malformed_xml_info_plist_is_a_clean_value_error` | Malformed metadata/package faults reject before replacement; developer CLI may emit a traceback |
| `test_missing_ipa_is_rejected_before_catalog_write` | Catalog removed; missing archive refused and CI requires the upload artifact |
| `test_replace_failure_preserves_catalog_and_cleans_temporary_sibling` | Catalog removed; exact IPA replacement failure preserves directory/sentinel or prior file and cleans staging |
| `test_invalid_zip_member_is_rejected` | Traversal, dot/empty components, backslashes, duplicates, links, special files, obsolete resources and missing execute permission rejected |

The ten original build-fixture tests were additional to the 21 portable checks. Their staging/failure behavior is retained in seven pipeline test methods with multiple injected subcases. The original scan-lifecycle Python wrapper required native Foundation; the remaining native lifecycle/recovery and simulator process fixtures cover Charony's approved behavior.

## Verification limits

A source audit alone cannot establish compiled behavior. The passing workflow audits the real executable and package as well as source. Native fixtures and programmatic UIKit checks still do not validate worse_query access on a physical iPhone, final re-signing, complete app-data removal or destructive primary-device safety.

Keep physical access/signing, disposable-data deletion, broader interaction/accessibility and layered icon work open until evidence is recorded. Real Safari and Messages data were not used for destructive testing.

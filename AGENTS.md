# Charony project instructions

These instructions apply to `micknorj/charony` and this repository's files. Read `charony-codex-spec.md` completely before changing implementation. Preserve applicable shared engineering principles. The GitHub authorization below is a project-specific exception and does not grant permissions for other repositories or projects.

## GitHub management authorization

The maintainer authorized Codex on November 19, 2026 to manage https://github.com/micknorj/charony. This supersedes this project's earlier prohibition on remote Git operations.

Codex may create development branches, commit and push to those branches, create and update pull requests targeting `main`, trigger and monitor GitHub Actions, read CI logs, download diagnostic artifacts, fix failures, push corrections and update project documentation. Read-only remote inspection and fetching this repository are permitted when needed to preserve current remote work. The original `charony/initial-ci` commit is retained for recovery. Validate the independent history on a parentless preparation branch before replacing main.

The maintainer subsequently authorized one history replacement for this repository. After verifying a recoverable backup, live repository identity, owner permissions and fork-network detachment, Codex may create a parentless Charony history and replace `main` once using an explicit `--force-with-lease=refs/heads/main:<verified-old-sha>`. Obsolete remote branches/tags/releases may be removed after inventory, recovery backup and dependency review. Do not delete/recreate the GitHub repository, merge inherited history into the new root or publish a release. This exception ends when the one-time replacement and reviewed cleanup are complete. Other projects remain outside scope.

The reviewed pre-migration main tip is `985cf765cdf3bd4cb88da15de3f7d928664efae6`. Recheck it immediately before the one-time update. If it changes, preserve and review the new remote work before proceeding. Once default main contains the independent Charony history, this exception cannot authorize another force update. A later chat or environment restoration does not renew it.

Charony's repository-local Git identity must be `micknorj <329715135+micknorj@users.noreply.github.com>`. Do not change global Git configuration. Verify the effective author and committer before committing and inspect the new root's stored metadata before pushing. Preserve GPL, copyright notices and upstream acknowledgments regardless of the Git commit graph.

Before pushing, verify the remote identity and current GitHub write permissions for this repository. Prefer connected GitHub integration tools where supported. Otherwise use the existing HTTPS Git proxy and GitHub CLI authentication. Never print or extract credentials, request a personal access token, or enable unrestricted Internet merely to work around a scoped access failure. Report a concrete permission or network blocker after finishing independent local work.

The following restrictions remain mandatory.

- Outside the authorized one-time history replacement, never push directly to `main`, force-push or rewrite published history.
- Never merge a pull request or publish a release without explicit maintainer approval. Remote branch deletion requires approval outside the reviewed one-time cleanup.
- Do not enable automatic merge, release or deployment.
- Never disable safety tests or bypass failing CI. Diagnose failures and fix their causes. Treat skipped checks as unverified.
- Never introduce credentials, signing material or secrets into source control or diagnostic artifacts.
- Preserve all existing implementation and safety-review changes. If a remote development branch already exists, inspect it and preserve its work before updating it.

## Implementation and validation

The implementation baseline is WQ Files stable v0.9.18 at `e44cd0ef226305bc265c8d7a15607ec49ceb4368`. Exclude the later debug source changes. The baseline was already restored before implementation. Do not restore it again over the existing Charony work. New Charony history excludes inherited commits. `tests/upstream-baseline.json` pins the independently downloaded source archive, every source file and executable mode. The unchanged baseline runner and nine safety-helper comparisons must remain active without depending on inherited Charony Git objects.

Retain the approved Apps/Caches scope, privacy requirements, App Group recovery, container identity and path validation, no-follow deletion safeguards, scan checkpoints and meaningful safety tests. Use disposable fixtures for destructive tests. Never test deletion on real user data.

Run the portable suite with `PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s tests -p 'test_*.py' -v` and source auditing with `python3 scripts/privacy_audit.py`. The macOS workflow must run the unchanged stable baseline, native fixtures, strict iOS compile/link checks, simulator checks, source/binary privacy auditing, asset compilation and IPA/metadata/signature/entitlement validation. Keep workflow permissions read-only and application signing ad-hoc. Do not add Apple credentials or signing secrets.

Record actual results and unresolved gates in `TESTING.md`. A CI pass does not validate physical-device access, final sideloaded signing or destructive safety on a primary iPhone. Layered icon work and device verification remain separate gates. Provide a final report with branch, PR URL, commit SHA, CI results, fixes, remaining risks and actions requiring approval. Never claim automatic communication with the separate planning conversation.

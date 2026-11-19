# Charony project instructions

These instructions apply only to `micknorj/charony`. Preserve shared engineering principles for other projects. Read [charony-codex-spec.md](charony-codex-spec.md) completely before changing implementation.

## GitHub permissions

The maintainer authorizes development branches, commits and pushes to those branches, pull requests targeting `main`, GitHub Actions execution and monitoring, CI logs/artifact downloads, fixes and documentation updates for this repository. Read-only remote inspection and fetching are permitted when needed to preserve remote work. The repository description and topics may be updated through the authenticated API.

- Verify repository identity and current write permissions before pushing
- Use development branches and pull requests; never modify `main` directly
- Never force-push or rewrite published history
- Never merge pull requests, publish releases or delete remote branches without explicit maintainer approval
- Do not enable automatic merging, releasing or deployment
- Preserve existing implementation, safety-review changes and remote development work
- Never disable safety tests or bypass failing CI; investigate the cause and treat skipped checks as unverified
- Never commit credentials, signing material or secrets, or include them in diagnostic artifacts
- Other account, infrastructure and deployment changes remain outside scope

The authorized independent-history reset and reviewed cleanup are complete. That one-time exception is expired and cannot be reused, including after a new chat or environment restoration. Do not delete or recreate the repository.

Prefer connected GitHub tools where supported. Otherwise use existing GitHub CLI/platform authentication. Never print or extract credentials, request a personal access token, or enable unrestricted networking to work around a scoped access failure. Report the concrete blocker and continue independent work.

## Git identity

Use repository-local identity `micknorj <329715135+micknorj@users.noreply.github.com>` for Charony commits. Do not change global Git configuration or falsify authorship. Check effective identity before committing and stored author/committer metadata before pushing. Preserve GPL licensing, copyright notices and upstream attribution.

## Implementation

The stable WQ Files baseline is `e44cd0ef226305bc265c8d7a15607ec49ceb4368` (v0.9.18). Restoration and implementation are complete; do not restore upstream files over Charony or reintroduce later debug changes.

Baseline verification must remain independent of inherited Git objects. Preserve the pinned source manifest, unchanged upstream runner and nine exact safety-helper comparisons. Do not alter manifests, fixtures or checksums for documentation style.

Retain the approved Apps/Caches scope, privacy requirements, App Group recovery, container identity and path validation, no-follow deletion, cancellation, scan checkpoints and meaningful safety tests. Stop on contradictory requirements or unresolved safety-critical uncertainty. Destructive tests must use disposable fixtures, never real user data.

## Validation

Run relevant checks and resolve failures without bypasses. Portable checks from the repository root:

```sh
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s tests -p 'test_*.py' -v
python3 scripts/privacy_audit.py
```

The macOS workflow must retain unchanged upstream tests, native safety fixtures, strict iOS compilation/linking, simulator checks, source/binary privacy audits, asset compilation and IPA/metadata/signature/App Group validation. Keep workflow permissions read-only and development signing ad-hoc. Do not add Apple credentials or signing secrets.

Keep actual evidence and open gates in [TESTING.md](TESTING.md). A CI pass does not validate physical access, final sideloaded signing or destructive safety on a primary iPhone. Layered icon appearances remain a separate gate.

Report branch, PR URL, commit SHA, actual CI/test results, fixes, remaining risks and approval requirements in the conversation. Do not commit temporary handoff reports or claim automatic communication with a separate planning conversation.

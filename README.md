# Charony

Part of Mick's Tools.

A privacy-focused iOS utility for managing accessible application data and caches.

## Features

- Accessible third-party and Apple apps with name, icon, bundle ID and storage usage
- Per-app data clearing with destructive confirmation
- Manual selection of application caches, temporary files and accessible crash reports
- One confirmation for a cache-cleaning batch
- Search within the selected Apps or Caches tab
- Manual refresh, scan progress, pause, resume and interruption recovery
- Native UIKit interface with system Light and Dark appearance
- English only

## Compatibility

Charony uses the existing [worse_query](https://github.com/forcequitOS/worse_query) access method from WQ Files. Access depends on the iOS build and the final signed App Group entitlement.

| iOS version | Status |
| --- | --- |
| 26.0–26.7.2 | Upstream access range; Charony device behavior unverified |
| 27.0–27.3 beta 1 | Upstream access range; Charony device behavior unverified |
| 27.3 beta 2 and later | Unsupported; worse_query was patched |

Native builds and disposable iPhone 17 / iPad Pro simulator fixtures passed [GitHub Actions validation](https://github.com/micknorj/charony/actions/runs/44763475557) on iOS 26.2 in Light and Dark. No physical iPhone has been tested with this implementation. See [testing and verification](TESTING.md).

## Installation

There is no published release IPA. Passing validation runs provide a `charony-development-unverified-on-device` artifact on the [Actions page](https://github.com/micknorj/charony/actions).

The development IPA is ad-hoc signed and requires re-signing before installation. The intended Windows route is AltStore Classic with a free Apple account. The final signer must preserve a usable App Group entitlement; this route and physical sandbox access remain unverified. See the [device checklist](TESTING.md#device-verification) before installing on a primary iPhone.

## Usage

1. Open **Apps** and tap **Refresh** to scan accessible applications. Close the target app before selecting it and confirming **Clear Data**. This permanently empties its `Documents`, `Library` and `tmp` contents. No backup is created.
2. Open **Caches**, tap **Refresh**, then tap individual rows to select targets, then review and confirm **Clean**. Cached offline downloads may be removed.
3. Use the bottom-right **Search** to search the selected tab. The top-right **…** menu holds filters and **Pause Scan** / **Resume Scan**. Refresh starts a new scan; Resume continues unfinished work.

Rows show logical data-container bytes, excluding app binaries, App Groups and keychain. Fully measured app/extension caches smaller than 64 KB are omitted; accessible nonempty crash reports are listed separately. Application text is capped at the normal system size and allows smaller sizes; VoiceOver remains enabled.

Cache cleaning can be stopped between filesystem items. Cancellation or failure does not restore data already deleted. Reset Access Cache appears only after a recoverable access failure.

## Privacy

Charony has no application-controlled networking, analytics, telemetry, update checks, network listeners, application-generated logs or diagnostic export.

Results and selections remain in memory. Local storage is limited to unfinished scan checkpoints and access-cache recovery state. Completed scan results and activity history are not retained.

iOS system diagnostics and Apple or third-party signing services operate independently of Charony.

## Limitations

- Inaccessible apps are hidden
- Safari and Messages cleanup is best effort; data in other containers, App Groups, keychain or system services may remain
- Deletion is permanent and may finish partially after interruption or failure
- Physical access, final sideloaded signing and destructive behavior remain unverified
- iOS 27 interface behavior, touch interaction and accessibility need further verification
- The flat development moon icon compiles; layered Light, Dark, Clear and Tinted appearances remain incomplete

## Development

Requires macOS, Python 3, Bash and Xcode. CI uses Xcode 26.2 with iOS 26.2 SDKs and deployment target 26.0. There are no CocoaPods, Swift packages or third-party runtime SDKs.

From the repository root:

```sh
bash build.sh
```

The build runs native and portable tests, strict iOS compilation, privacy audits, asset compilation, ad-hoc signing and IPA validation before producing `charony.ipa`. No Apple credentials are required.

- [Testing, build commands and release checklist](TESTING.md)
- [Architecture and retained shared code](ARCHITECTURE.md)
- [Safety model and test coverage](docs/SAFETY.md)
- [Implementation specification](charony-codex-spec.md)
- [Agent instructions](AGENTS.md)

## Credits

Based on [WQ Files](https://github.com/kolbicz/WQFiles) by kolbicz and contributors, using stable v0.9.18 as the implementation baseline. The sandbox technique comes from [worse_query](https://github.com/forcequitOS/worse_query) by Taj C (forcequit).

See [NOTICE.md](NOTICE.md) for source provenance and additional acknowledgments.

## License

Licensed under [GPL-3.0-or-later](LICENSE).

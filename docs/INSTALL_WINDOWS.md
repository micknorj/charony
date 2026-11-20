# Windows installation and first device test

Use a passing development artifact from the reviewed commit. It is ad-hoc signed and cannot be installed directly on a stock iPhone. Re-sign privately on Windows with an Apple-issued device profile. No Apple credentials belong in PowerShell commands, Git, Actions, reports or this chat.

The target is an iPhone 11 Pro on iOS 27.2.1, build `24B156`. Device access, installation and renewal have not been verified. Passing CI is not installation approval or evidence of protected-app access.

## Signing verdict

AltServer's published Windows implementation selects a free team, enables the requested App Group feature, registers/associates the group with Apple, downloads a provisioning profile, embeds it and signs using that profile's entitlements. It appends the team identifier to the original app and group identifiers. This is a genuine provisioning flow, rather than copying arbitrary entitlement strings.

That source establishes implementation support, not current Apple-server approval for your account or proof about every distributed AltServer version. Apple's developer-account documentation does not guarantee Personal Team eligibility for this capability. **Your free-account App Group authorization remains unverified until Apple issues an appropriate profile and the normal iOS installer accepts the signed app.**

If Apple refuses the group, the signed app lacks it, or its authorization cannot be verified, stop before launching Charony. Do not remove the entitlement, inject an unauthorized group, disable signing verification or use a signing bypass. Record the precise error; it is an installation blocker, not an application defect to work around.

## Download and verify

Install GitHub CLI if needed, or download the artifact through the run's Actions page. GitHub login is separate from Apple signing; use the CLI's browser login, never put tokens in commands.

Run in PowerShell, substituting the run and source commit from the completion report:

```powershell
$ErrorActionPreference = 'Stop'
$RunId = 'REPLACE_WITH_VALIDATED_RUN_ID'
$ExpectedSource = 'REPLACE_WITH_ARTIFACT_SOURCE_COMMIT'
$Work = Join-Path $env:USERPROFILE 'Downloads\Charony-ReadOnly'
New-Item -ItemType Directory -Force $Work | Out-Null
gh run download $RunId --repo micknorj/charony `
  --name charony-development-unverified-on-device --dir $Work
if ($LASTEXITCODE -ne 0) { throw 'Artifact download failed' }
$Build = Get-Content (Join-Path $Work 'charony-build.json') -Raw | ConvertFrom-Json
$Ipa = Join-Path $Work 'charony.ipa'
$Actual = (Get-FileHash $Ipa -Algorithm SHA256).Hash.ToLowerInvariant()
if ($Actual -ne $Build.ipa_sha256 -or $Build.source_commit -ne $ExpectedSource) {
  throw 'Build source or IPA checksum does not match the reviewed artifact'
}
$Build | Select-Object source_commit, bundle_id, architecture, minimum_os, sdk, signing, ipa_sha256
```

Also compare the checksum with the completion report. Expect `io.github.micknorj.charony`, arm64, minimum iOS 26.0 and ad-hoc signing. The CI group is `group.io.github.micknorj.charony`. These are pre-sign values; AltServer may legitimately rewrite app/group identifiers after registering them with Apple. The manifest records CI build context and actual artifact hashes, not an Apple provisioning grant.

Keep the original IPA and manifest. Re-signing changes the package and its checksum; the CI checksum does not authenticate an independently re-signed file.

## Sign and install privately

1. Follow the current [AltStore Classic Windows guide](https://faq.altstore.io/altstore-classic/how-to-install-altstore-windows) for AltServer, compatible Apple device/iTunes/iCloud components, USB trust and Wi-Fi sync. Download only from the official guide. The guide's website rejected requests from this cloud environment; current installer/version behavior needs checking on your laptop.
2. Check the downloaded Windows installer's signature with `Get-AuthenticodeSignature`. Require a valid signature and the publisher identified by the official download. This does not verify the iOS signature or App Group.
3. Install/start AltServer, connect the unlocked iPhone by USB and trust the computer. Enable Apple's Developer Mode and developer trust when normally required by iOS. Do not launch Charony yet.
4. The published Windows tray implementation exposes **Sideload .ipa** when Shift is held while opening its tray menu. Select the connected device and the verified local `charony.ipa`. Enter your Apple credentials/2FA only in AltServer's own local interface. This is a GUI signing/install step; no verified headless PowerShell signing command is provided.
5. If the distributed version lacks that menu, use its documented AltStore Classic import flow. Do not substitute an unknown command-line switch or an online signing service.
6. Record AltServer's exact version, normal iOS installation success and any group/provisioning error. Successful installation is necessary, but still does not prove Charony's access mechanism works.

AltServer and Apple's components may cache authentication/signing material locally. That behavior is outside Charony and Codex; do not export it into CI or send credentials/private keys for review.

## Verify before first launch

Use a legitimate export of the final signed IPA/profile if your signing tool provides one. AltServer's published tray flow does not establish a user-facing signed-IPA export, so do not assume such a button exists.

Alternatively, paired-device inspection tools can retrieve installed metadata and profiles without launching Charony. Official MSYS2 packages provide Windows builds of libimobiledevice tools; installation/query behavior on iOS 27.2.1 remains unverified. Check each tool's `--help` before use. The currently inspected MSYS2 `ideviceinstaller` package is 1.1.1 and uses the older list syntax:

```powershell
# Install MSYS2 from https://www.msys2.org/ and update it as documented there.
# In its UCRT64 shell, install these official packages:
# pacman -S --needed mingw-w64-ucrt-x86_64-ideviceinstaller mingw-w64-ucrt-x86_64-libimobiledevice
$Tools = 'C:\msys64\ucrt64\bin'
& "$Tools\ideviceinstaller.exe" --help
& "$Tools\ideviceprovision.exe" --help
$Metadata = & "$Tools\ideviceinstaller.exe" -l -o xml
if ($LASTEXITCODE -ne 0) { throw 'Installed-app query failed' }
[IO.File]::WriteAllText((Join-Path $Work 'installed-apps.plist'), ($Metadata -join "`n"), [Text.UTF8Encoding]::new($false))
& "$Tools\ideviceprovision.exe" list
if ($LASTEXITCODE -ne 0) { throw 'Profile query failed' }
# Identify Charony's profile locally; copy ONLY that UUID into the existing folder.
$ProfileUuid = 'REPLACE_WITH_CHARONY_PROFILE_UUID'
& "$Tools\ideviceprovision.exe" copy $ProfileUuid $Work
if ($LASTEXITCODE -ne 0) { throw 'Profile retrieval failed' }
```

Newer upstream `ideviceinstaller` uses `list --xml` and supports `--attribute` / `--bundle-identifier`; do not pass those newer options to 1.1.1. A missing entitlement field is **unverified**, not an empty/authorized entitlement. Tool compatibility or unavailable metadata can itself block this inspection route.

Verify the copied profile's CMS signature and Windows trust chain before reading its claims. With PowerShell 7:

```powershell
Add-Type -AssemblyName System.Security.Cryptography.Pkcs
$Profile = Join-Path $Work "$ProfileUuid.mobileprovision"
$Cms = [System.Security.Cryptography.Pkcs.SignedCms]::new()
$Cms.Decode([IO.File]::ReadAllBytes($Profile))
$Cms.CheckSignature($false) # Validate signature AND certificate trust; do not change to $true.
$Cms.SignerInfos | ForEach-Object { $_.Certificate | Select-Object Subject, Issuer }
[IO.File]::WriteAllBytes((Join-Path $Work 'profile.plist'), $Cms.ContentInfo.Content)
```

Require an Apple provisioning-profile signer/chain, not merely any parsed XML or any trusted non-Apple signer. Stop on trust/verification errors; do not import unknown roots or disable validation. These commands inspect a profile, not the installed executable's code signature.

Before first launch, verify all of the following locally:

- The normal stock-iOS installer accepted the app without a signing bypass
- Profile application identifier/team match Charony's actual installed bundle ID; the profile covers this device and has not expired
- The Apple-verified profile authorizes a concrete App Group, and the final signed/installed entitlement contains that same authorized group; all claimed groups are covered
- The group corresponds to Charony's original group, with the signer's legitimate team suffix if rewritten; it was not removed or replaced with an unrelated group
- Installed version/build match the selected artifact; retain the original checksum and signing-tool version

Read the installed app's `Entitlements` dictionary if iOS exposes it. `GroupContainers` is useful corroboration, not a substitute for inspecting signed entitlements. A group string in the original IPA, `ALTAppGroups` in Info.plist, a profile by itself, or installation success by itself does not satisfy this gate. If metadata omits entitlements, obtain a legitimate signed-artifact export for inspection. If neither route is available, keep the gate blocked and report that limitation before launching. No complete signing/device verification was performed in the cloud.

Keep profiles and installed metadata private; they contain device/account identifiers. Share only sanitized results/errors for review, never credentials, private keys or the full profile.

## First read-only session

Proceed only after the signing/group gate above has been reviewed.

1. Record device model, iOS version/build, source/checksum, installed version, signer/tool version and verified group outcome.
2. Launch Charony. Record any unsupported-build, missing-group or access error. Do not dismiss an unexplained failure and assume access works. Initial access setup can write its own operational App Group cache/recovery state; “read-only” here means no cleanup of application data or reports.
3. Open Apps and Caches. Verify initial **Refresh to update**, bottom tabs/Search, leading titles and separate Refresh/ellipsis controls.
4. Refresh Apps. Check accessible entries, icons, names, bundle IDs and plausible storage values. Inaccessible apps should be hidden; incomplete measurements must remain labelled. Do not tap app rows: they open deletion confirmations, not details.
5. Refresh Caches. Observe ordinary caches and any accessible report entry. Do not select/clean targets or invoke report removal.
6. Test Search, no-match queries and filters in each tab. Verify contextual query/navigation restoration, keyboard dismissal and no oversized/clipped text.
7. Pause/resume a read-only scan, then background/foreground the app. If practical, interrupt an unfinished scan and relaunch to verify Resume/checkpoint recovery. Completed results should not survive a cold relaunch.
8. Check system Light/Dark and Home Screen Default/Dark/Clear/Tinted icon choices. Record the actual iOS 27 appearance; native previews and iOS 26.2 simulator results are not this evidence.
9. Observe conditional access recovery if a recoverable failure occurs. Record the error and whether Reset Access Cache appears. Do not execute Reset Access Cache in this first session; it changes operational state and needs a separate reviewed recovery test.
10. Record errors, partial discovery, Apple-app limitations and unexpected navigation. Stop on unexplained behavior. No Clear Data, Clean, crash removal or destructive confirmation is permitted during this session.

## Renewal

Free-account development provisioning normally expires after seven days. Refresh before expiry using the same trusted signing tool/account. AltStore Classic can renew managed apps with AltServer available; direct AltServer sideloading requires repeating its signing/install flow. Verify the actual version's renewal behavior, group and bundle identity; never use uninstall/reinstall as a troubleshooting shortcut for identity failures.

Apple's Personal Team limits include three installed apps and ten registered App IDs in seven days; AltStore itself uses a slot if installed. Record actual profile expiry rather than assuming renewal succeeded. Windows installation, group preservation and renewal remain device-dependent gates.

## Sources

- [Apple: register an App Group](https://developer.apple.com/help/account/identifiers/register-an-app-group/)
- [Apple: developer account and Personal Team limits](https://developer.apple.com/help/account/basics/about-your-developer-account)
- [Apple: Developer Mode](https://developer.apple.com/documentation/xcode/enabling-developer-mode-on-a-device)
- [AltServer Windows free-team/provisioning flow](https://github.com/rileytestut/AltServer-Windows/blob/41fb42bc78056f59e64566f7561ba405ef59b5d9/AltServer/AltServerApp.cpp#L736)
- [AltServer Windows group registration/association](https://github.com/rileytestut/AltServer-Windows/blob/41fb42bc78056f59e64566f7561ba405ef59b5d9/AltServer/AltServerApp.cpp#L1066)
- [Signer embeds the profile and signs with its entitlements](https://github.com/rileytestut/AltServer-Windows/blob/41fb42bc78056f59e64566f7561ba405ef59b5d9/AltSign/Signer.cpp#L245)
- [Windows Shift/tray sideload implementation](https://github.com/rileytestut/AltServer-Windows/blob/41fb42bc78056f59e64566f7561ba405ef59b5d9/AltServer/AltServer.cpp#L312)
- [libimobiledevice tools](https://github.com/libimobiledevice/libimobiledevice/tree/master/tools), [ideviceinstaller](https://github.com/libimobiledevice/ideviceinstaller), [MSYS2 package](https://github.com/msys2/MINGW-packages/blob/master/mingw-w64-ideviceinstaller/PKGBUILD)

These sources were inspected; no Apple login, profile issuance or physical installation was performed.

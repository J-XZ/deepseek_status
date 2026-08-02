# DeepSeekBalance

[中文](README.md) | [English]

A pure-Swift native macOS menu bar app that shows your DeepSeek API balance in real time, records a 3-day balance trend, and displays DeepSeek's official service status. It lives in the system menu bar with no Dock icon. The only third-party dependency is Google LevelDB (a Git submodule, see below).

## Screenshots

The popover shows your balance, official service status, and 3-day trend:

<p align="center">
  <img src="docs/screenshots/deepseek-balance-popover.png" alt="DeepSeekBalance popover" width="500">
</p>

The menu bar shows the monochrome icon and current balance:

<p align="center">
  <img src="docs/screenshots/deepseek-menu-bar.png" alt="DeepSeekBalance menu bar balance" width="240">
</p>

## Features

- Menu bar shows a monochrome DeepSeek icon plus balance text (e.g. `¥110.00`, or `¥110.00 · $2.50` for multiple currencies)
- Left-clicking the menu bar icon opens the popover; right-clicking shows a menu with a Quit item
- Clicking the menu bar item opens a popover with total balance, topped-up balance, granted balance, and last update time
- Status badges: Available / Insufficient balance / Not configured / Request failed / Keychain error
- Save your API key to the macOS Keychain from the UI, or clear it and fall back to the environment variable
- Refresh on launch, every 5 minutes, and when the popover opens after more than 60 seconds
- Keeps the last successful balance after request failures; authentication failure or an unreadable Keychain clears stale account data instead of showing it
- 3-day balance trend chart (Apple Swift Charts, 10-minute time buckets, local LevelDB storage)
- Trend chart supports click/drag selection with local time, each balance figure, and the delta from the previous sample
- DeepSeek official service status card: overall status, API Service, Web Chat Service, incidents, and scheduled maintenance
- Launch at Login using Apple's native `SMAppService.mainApp`
- One-click Simplified Chinese / English switching, applied instantly without restart
- Built with Swift Concurrency (`async/await` + `URLSession`), AppKit `NSStatusItem` + SwiftUI `NSPopover`, Security.framework, CryptoKit, Charts, and ServiceManagement

## Basic Usage

1. Open [Releases](https://github.com/J-XZ/deepseek_status/releases) and download the latest version. The `.dmg` is recommended: open it and drag `DeepSeekBalance.app` into `Applications`. You can also use the `.pkg` installer or unzip the `.zip` and move the app to `Applications`.
2. Launch the app from `Applications`. It has no Dock window; look for the DeepSeek icon in the menu bar at the top-right of the screen.
3. Click the menu bar icon, enter your DeepSeek API key in the API Key section under Settings, and save it. Saving it to the macOS Keychain is recommended because it also works when the app is launched from Finder.
4. After the key is saved, the app fetches your balance and the official service status. Click the menu bar item to see total, topped-up, and granted balances, the last update time, and the 3-day trend. Use the bottom Refresh button for an immediate update.
5. Settings lets you switch between Chinese and English, enable Launch at Login, and clear local history.

If you downloaded an unsigned release, macOS may say that it cannot verify the developer on first launch. In Finder, Control-click the app, choose Open, and confirm once. Do not disable Gatekeeper globally just to run this app.

## Menu Bar Balance

- Without an API key the menu bar shows "Not configured"; errors show "Error"; loading shows "…"
- Currency symbols follow the API response: CNY → `¥`, USD → `$`, unknown currencies → `EUR 10.00` style
- Number grouping, dates, times, and percentages use the locale of the currently selected UI language and update instantly when the language changes

## 3-Day Balance Trend

- DeepSeek has no public balance-history API, so the app records each successful balance fetch locally.
- History is stored in **10-minute UTC buckets**: one record per currency per bucket, with newer refreshes overwriting older ones; negative Unix timestamps use strict floor.
- The balance query cadence is unchanged (immediate refresh on launch + every 5 minutes); multiple successes within 5 minutes share one 10-minute bucket.
- History starts from the first successful sample; no data is produced while the app is not running; sleep gaps appear as broken lines (gaps over 20 minutes are not interpolated).
- The trend chart uses `LineMark` only for continuous data and does not draw small point markers that add visual noise. Gaps over 20 minutes break the line, and the full 72-hour window (up to ~432 ten-minute buckets) stays smooth.
- The X axis domain is explicitly `now - 72 hours ... now`, with an injectable time source.
- History is stored locally only and kept for up to 72 hours; a startup prune runs on launch (using the injected clock), followed by throttled pruning (the throttle time is recorded only after a successful prune, so a failure can be retried).
- Database location: `<Application Support>/com.jxz.deepseekbalance/BalanceHistory.leveldb`; upgrades also read the legacy `com.example.DeepSeekBalance` directory.
- The popover offers a "Clear Local History" button (with confirmation) that removes only the current account's history; it does not affect the API key or current balance. Currencies that really exist in the current balance remain in the picker after clearing.
- The currency picker only shows currencies that truly exist in the current balance response or in the current account's history (CNY and USD are prioritized only when they actually exist); no fake options are shown.
- The chart shows total, topped-up, and granted balance per currency and supports light/dark mode.

## DeepSeek Official Service Status

- Data source: DeepSeek's official status page public JSON only: `https://status.deepseek.com/api/status-page/6410630422455/summary/active` (the official status page is hosted by Flashcat; its public `page_id` from the page HTML is `6410630422455`; the standard Statuspage path `/api/v2/summary.json` returns 404 on this domain and is not used)
- Official status page: `https://status.deepseek.com/`
- Status requests need no API key and send no `Authorization` header; the status networking layer is fully independent from the balance layer, so one failing does not affect the other.
- Status is fetched immediately on launch, refreshed every 5 minutes, refreshed when the popover opens after a cache age over 60 seconds, refreshed after wake/didBecomeActive by cache age, refreshable via a dedicated "Refresh Service Status" button, and the bottom "Refresh" button refreshes balance and status concurrently without overwriting each other's errors.
- Overall indicator supports `none / minor / major / critical / maintenance / unknown`; component status, incident phase, and impact support all common Statuspage values, with unknown values falling back to `unknown` instead of failing decoding.
- Components are recognized by normalized name and prioritized as API Service and Web Chat Service (no dependency on fixed component IDs); other official components appear under "Other components"; component groups are not duplicated.
- The semantics strictly distinguish "DeepSeek service disruption" from "official status unavailable": only official `major_outage` / `critical` counts as a severe disruption; status timeouts or network failures only mean the official status is temporarily unavailable.
- When a previous success exists, the old data is kept and marked "Possibly stale" with the last successful update time; on first failure the UI shows Unknown/Unavailable and never fakes an operational status.
- Open incidents show title, current phase, impact, last update time, and a short plain-text excerpt of the latest update; scheduled maintenance is listed separately. Remote bodies are rendered as plain text only (truncated to a reasonable length); no HTML parsing or Markdown execution.
- An "Open Official Status Page" button uses `NSWorkspace.shared.open`.

## Launch at Login

- Uses Apple's native `ServiceManagement` `SMAppService.mainApp`; no helper app is created.
- The Settings section has a "Launch at Login" toggle plus the real system status: Enabled / Not registered / Requires approval / Not found / Error.
- Enabling calls `register()`; disabling calls `unregister()`; already-registered and already-unregistered states are treated as idempotent success; the real `SMAppService.mainApp.status` is re-read after every operation instead of trusting a local Bool.
- User rejection or system approval requirements map to `requiresApproval`, with an "Open Login Items Settings" button.
- The status is re-read when the app becomes active, because the user may change it in System Settings.
- After a failed toggle, the UI rolls back to the real system status and shows a non-sensitive error.

System approval note: auto-signed Debug builds run from Xcode may not register a login item. Real registration requires a properly signed app running from a suitable location. If System Settings asks for approval (General → Login Items), use "Open Login Items Settings" and approve manually. Unit tests use a Fake LoginItemManager and never modify real login items.

## One-Click Language Switching

- Supported languages: Simplified Chinese (`zh-Hans`) and English (`en`).
- First launch picks the system preferred language when it is Chinese or English; any other system language defaults to English. The user's choice is persisted in `UserDefaults` (language only — API keys stay in the Keychain).
- Both the header and the Settings section have a one-click button: the Chinese UI shows `English`; the English UI shows `中文`. One click switches instantly, no restart required.
- All text (menu bar, status badges, errors, trends, service status, login item status, date/number formats) is rendered on demand from semantic data via L10n in the current language; the state layer never stores translated strings.
- Already-visible errors re-render in the new language immediately without re-requesting.
- Localization uses an Xcode String Catalog (`DeepSeekBalance/Resources/Localizable.xcstrings`) with complete `en` and `zh-Hans` coverage, verified by a test.

## Settings Section

The popover's Settings section contains:

1. Language: one-click switch button
2. Launch at Login: toggle + status text + "Open Login Items Settings" when approval is required
3. API Key: the existing Keychain configuration
4. Local History: the existing "Clear Local History" button

The window uses a ScrollView at about 500 points wide and fits common MacBook screens.

## LevelDB Integration (Git Submodule)

LevelDB is the only C/C++ third-party runtime dependency, pinned as a Git submodule:

- Submodule path: `Vendor/LevelDB`
- Repository: https://github.com/google/leveldb
- Commit: `99b3c03b3284f5886f9ef9a4ef703d57373e61be`
- Tag: `1.23`

To clone with submodules:

```bash
git clone --recurse-submodules https://github.com/J-XZ/deepseek_status.git
```

To initialize submodules in an existing clone:

```bash
git submodule update --init --recursive
```

`build.sh` checks the submodule state: uninitialized (`-`), checkout mismatch (`+`), and conflict (`U`) all produce a clear message (`请运行：git submodule update --init --recursive`) and exit non-zero. It never downloads submodules implicitly during a normal build and never changes the system Xcode selection.

The LevelDB license is documented in `THIRD_PARTY_NOTICES.md`.

## API Key and Keychain

### Two Ways to Configure the API Key

1. **In-app (recommended)**: click the menu bar icon, enter the key in the API Key section, and click Save. The key is written to the macOS Keychain; the input field never echoes the saved key.
2. **Environment variable**: set it in the terminal before launching the app:

```bash
export DEEPSEEK_API_KEY="sk-xxxxxxxx"
open /path/to/DeepSeekBalance.app
```

### Environment Variable Name

- `DEEPSEEK_API_KEY`

### Priority

1. API key saved in the Keychain (highest)
2. Environment variable `DEEPSEEK_API_KEY`
3. Not configured

"Clear Saved Key" only deletes the Keychain value; if the environment variable exists, the app falls back to it and refreshes automatically.

When the Keychain cannot be read, the app cancels in-flight requests, clears the current balance, last update time, credentialID, history samples, and currency selection, and shows a Keychain error — it never keeps showing an old account's trend.

### Finder Launch and Shell Environment

GUI apps launched from Finder usually do not inherit environment variables set in a terminal shell. If you launch by double-clicking, the environment variable may be unavailable. Saving the key to the Keychain from the UI is recommended because it works regardless of how the app is launched.

## Local Build and Test

Debug build:

```bash
./build.sh
```

Release build:

```bash
./build.sh --release
```

Build all distributable installers in one command (ZIP, double-click PKG, drag-to-install DMG, and SHA256SUMS):

```bash
./build.sh --package
```

Artifacts are written to `build/artifacts/`. Because the default release build is unsigned, macOS may require approval in System Settings → Privacy & Security on first launch.

Local unit tests:

```bash
./build.sh --test
```

Clean and build Debug:

```bash
./build.sh --clean
```

Full pipeline (clean + Debug + Release + tests + analyze):

```bash
./build.sh --all
```

`--help` returns 0; invalid arguments return non-zero; `--all` really runs clean, Debug build, Release build, all unit tests, and static analysis in order.

## GitHub Releases

Push a version tag to publish automatically:

```bash
git tag v2.0.1
git push origin v2.0.1
```

`.github/workflows/release.yml` initializes the LevelDB submodule on a macOS runner, runs the unit tests, and publishes every artifact to the matching GitHub Release. Signing is optional:

- If none of the Apple signing secrets are configured, the workflow publishes unsigned ZIP, PKG, and DMG artifacts; users must approve the first launch as described in Basic Usage.
- If all of the following secrets are configured, the workflow signs with Developer ID and notarizes the distribution, so users can normally open the app directly.
- If only some secrets are configured, the workflow fails with a clear message instead of publishing a partially configured release.

To enable signing, configure these repository Actions secrets before pushing a release tag:

- `APPLE_CERTIFICATE_P12_BASE64`: Base64-encoded `.p12` containing both the Developer ID Application and Developer ID Installer certificates.
- `APPLE_CERTIFICATE_PASSWORD`: Password used when exporting the `.p12`.
- `APPLE_KEYCHAIN_PASSWORD`: Password for the temporary CI keychain.
- `APPLE_DEVELOPER_ID_APPLICATION`: Full certificate name, such as `Developer ID Application: Your Name (TEAMID)`.
- `APPLE_DEVELOPER_ID_INSTALLER`: Full certificate name, such as `Developer ID Installer: Your Name (TEAMID)`.
- `APPLE_TEAM_ID`: Apple Developer Team ID.
- `APPLE_ID`: Apple account email used for notarization.
- `APPLE_APP_SPECIFIC_PASSWORD`: App-specific password for that Apple account.

The `.p12` can be exported from Keychain Access after selecting both Developer ID certificates. `APPLE_APP_SPECIFIC_PASSWORD` is not the Apple account password. Existing unsigned releases cannot be repaired in place; build and publish a new tag after configuring the secrets.

Local unsigned packaging remains available. For a signed local package, set `CODE_SIGNING_ALLOWED=YES`, `CODE_SIGN_IDENTITY`, and `DEVELOPMENT_TEAM` before running the packaging script. The workflow uses Xcode's `notarytool` and staples the ticket to the app, PKG, and DMG.

You can also build and test directly with xcodebuild:

```bash
xcodebuild \
  -project DeepSeekBalance.xcodeproj \
  -scheme DeepSeekBalance \
  -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO \
  test
```

Static analysis:

```bash
xcodebuild \
  -project DeepSeekBalance.xcodeproj \
  -scheme DeepSeekBalance \
  -configuration Debug \
  -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO \
  analyze
```

The tests never hit the real DeepSeek balance API or the real status page, never write to the real Keychain, never modify real login items, and never write to the production Application Support database: network calls use a custom `URLProtocol`, the Keychain uses in-memory fakes, LevelDB tests use temporary directories, and login items use a Fake LoginItemManager. Coverage includes balance parsing, authorization headers, status codes, timeouts, formatting, key priority, credential isolation, time buckets, LevelDB failure paths and iterator errors, prune throttling, trend models, lifecycle observer cleanup, the official status client/store, the login item state machine, and localization completeness.

## System Requirements

- macOS 13 or later
- Xcode 15 or later (this project is verified building and testing under Xcode 26.6)

## How to Run

1. Open the project: `open DeepSeekBalance.xcodeproj`
2. Select the shared `DeepSeekBalance` scheme
3. Choose Your Mac as the destination and hit Run, or press Cmd+B to build

The app shows no Dock icon; it lives in the menu bar with its icon and balance text. You can also double-click `DeepSeekBalance.app` from Finder.

## Replacing the DeepSeek Icon

The menu bar icon is a local vector asset:

```text
DeepSeekBalance/Assets.xcassets/DeepSeekIcon.imageset/deepseek_icon.pdf
```

The current icon is the official whale artwork from the SVG embedded in DeepSeek's website nav bar (`https://www.deepseek.com`), converted to a vector PDF and rendered as a template image. The vector source lives at `scripts/deepseek_icon_source.svg` (with provenance and regeneration notes). To replace it:

1. Replace the PDF above with an official icon (monochrome outline, transparent background, PDF or SVG-converted PDF)
2. Keep the asset name `DeepSeekIcon`
3. Keep the template rendering intent so light/dark menu bars adapt
4. Rebuild

Do not use colorful large images as the menu bar icon.

## Privacy and Security

- API keys are stored only in the macOS Keychain, never in `UserDefaults` or source code
- API keys are never written to LevelDB, logs, or error messages; history stores only the irreversible SHA-256 `credentialID`
- Official status requests carry no API key and no `Authorization` header
- Never commit API keys or the local LevelDB data directory (`BalanceHistory.leveldb`)
- This project **does not use GitHub Actions**; all validation is done locally
- Never print, display, or log a full API key in logs, errors, or the UI
- Do not commit, screenshot, or forward UI or logs that contain API keys
- Environment variables and Keychain contents are secrets; keep them safe

## Known Limitations

- Real Launch at Login registration can be affected by code signing, sandboxing, and user approval; when System Settings asks for approval, it must be granted manually in General → Login Items.
- Incident/maintenance titles and bodies from the official status page are shown as-is; the app does not machine-translate them, while surrounding labels and status words are localized.
- The trend only accumulates while the app is running; there is no data for periods when the app was not running.
- An unreachable status endpoint only means "official status unavailable"; it does not mean DeepSeek is down.

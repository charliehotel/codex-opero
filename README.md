[English](./README.md) | [한국어](./README.ko.md)

# codex-opero

`codex-opero` is a minimal macOS menu bar app that shows AI usage as a compact string like `57%/90%`.  
Instead of a full dashboard, it focuses on one thing: letting you check the numbers you need at a glance.

<table width="100%">
  <tr>
    <td width="50%" valign="top"><img src="./Screenshots/Screenshot_v0.1.6_main.gif" alt="codex-opero auto rotate" width="100%" /></td>
    <td width="50%" valign="top"><img src="./Screenshots/Screenshot_v0.1.6_main.png" alt="codex-opero menu" width="100%" /></td>
  </tr>
  <tr>
    <td width="50%" valign="top"><img src="./Screenshots/Screenshot_v0.1.4.png" alt="codex-opero first-run popup" width="100%" /></td>
    <td width="50%" valign="top"><img src="./Screenshots/Screenshot_v0.1.6_noti.png" alt="codex-opero reset notifications" width="100%" /></td>
  </tr>
</table>

## Highlights

- Shows the selected provider's remaining usage in a compact two-value format from the menu bar
- Lets you choose between `Codex`, `Claude`, and `Gemini/Antigravity`
- Remembers the last selected provider
- Supports `Auto Rotate` to cycle through available providers at a configurable interval
- Lets you choose the refresh interval from preset options in the menu
- Lets you choose the auto-rotate interval from preset options in the menu
- Refreshes automatically at the configured interval and also supports `Refresh Now`
- Sends reset notifications when important usage buckets return to 100%
- Checks for new GitHub releases about once a week
- Supports `Launch at Login` when running as a packaged `.app`
- Falls back to `--/--` when usage lookup fails

## Authentication

This app does not provide its own login UI or OAuth flow.  
Instead, it reuses existing local authentication state and only fetches usage.

- `Codex`: uses `~/.codex/auth.json`
- `Claude`: uses the macOS Keychain item `Claude Code-credentials` or `~/.claude/.credentials.json`
- `Gemini/Antigravity`: uses the macOS Keychain item `gemini-cli-oauth` or `~/.gemini/oauth_creds.json`
- `Antigravity` (agy): uses `~/.antigravity_cockpit/cache/quota_api_v1/authorized/` cache files (no Keychain prompt required)

That means Codex, Claude, or Gemini/Antigravity must already be logged in on the local machine.

For `Gemini/Antigravity`, the two menu bar values currently map to representative `Pro / Flash` quota buckets rather than the same `5-hour / weekly` windows used by Codex and Claude.  
When you open the menu, Gemini/Antigravity usage is shown in more detail by `Pro`, `Flash`, and `Flash Lite` model groups.

If you use `Claude` or `Gemini/Antigravity`, macOS may ask for your password when the app first tries to read the Keychain credentials.  
Note that this prompt **only appears if you actually use that AI tool and its keychain item exists**. If you do not use Claude or Gemini/Antigravity, no popups for those credentials will appear at all.

Because `codex-opero` refreshes on a recurring interval, choosing `Allow` can cause repeated prompts.  
To avoid that, choose **`Always Allow`** for `codex-opero` when macOS asks for access to the keychain credential.

## Notifications

`codex-opero` can send macOS notifications when usage becomes available again.

- `Codex` and `Claude`: notifies when the `5h` or `7d` remaining usage returns to `100%`
- `Gemini/Antigravity`: notifies when the representative `Pro` or `Flash` usage bucket returns to `100%`

Each bucket is notified only once while it stays at `100%`.  
It can notify again after usage drops below `100%` and later returns to `100%`.

The app also checks GitHub Releases about once a week.  
If a newer version is available, it asks whether you want to open the release page in your browser.

## Auto Rotate

`Auto Rotate` is off by default.  
When enabled, `codex-opero` rotates through available providers in this order:

- `Codex`
- `Claude`
- `Gemini/Antigravity`

You can choose the refresh interval from preset options such as `1 min`, `3 min`, `5 min`, and `15 min`.  
You can also choose the auto-rotate interval from preset options such as `10 sec`, `30 sec`, and `60 sec`.

Providers that are currently unavailable and showing `--/--` are skipped automatically.  
If the menu is open, rotation pauses until the menu closes.  
During refresh, the app keeps showing the last successful snapshot and only falls back to `--/--` if a provider refresh actually fails.

## Install from Release

The easiest way to use `codex-opero` is from the GitHub release.

1. Download the latest `.dmg` from [Releases](https://github.com/charliehotel/codex-opero/releases)
2. Open the `.dmg`
3. Drag `codex-opero.app` into the `Applications` folder
4. Launch `codex-opero.app` from `Applications`

## If macOS blocks the app

`codex-opero` is currently distributed as an unsigned app.  
If macOS blocks it, use one of the following methods.  
Only do this for builds you trust.

### Option 1. Open from Finder

1. Right-click `codex-opero.app`
2. Select `Open`
3. If macOS shows a warning, choose `Open` again

### Option 2. Remove quarantine

```bash
xattr -dr com.apple.quarantine /Applications/codex-opero.app
open /Applications/codex-opero.app
```

## Quick Start from Source

```bash
git clone https://github.com/charliehotel/codex-opero.git
cd codex-opero
swift run codex-opero
```

Requires macOS and an existing Codex, Claude, or Gemini/Antigravity login on the local machine.

## Release Notes

<details>
  <summary>v0.1.8</summary>
  <ul>
    <li>Add Antigravity (agy) CLI usage as an independent tab</li>
    <li>Read <code>~/.antigravity_cockpit/cache/quota_api_v1/authorized/</code> cache files directly — no Keychain prompt required</li>
    <li>Group models by provider (Google / Anthropic / OpenAI) in the detail menu</li>
    <li>Now supports 4 tabs: <code>Codex</code> / <code>Claude</code> / <code>Gemini</code> / <code>Antigravity</code></li>
  </ul>
</details>

<details>
  <summary>v0.1.7</summary>
  <ul>
    <li>Improved compatibility with Antigravity CLI and newer Gemini CLI versions</li>
    <li>Added automatic token retrieval from macOS Keychain (<code>gemini-cli-oauth</code>) when local credentials file (<code>oauth_creds.json</code>) is missing</li>
    <li>Added OAuth client config fallback for cases where Gemini CLI is uninstalled</li>
  </ul>
</details>

<details>
  <summary>v0.1.6</summary>
  <ul>
    <li>Add reset notifications for Codex and Claude <code>5h</code> and <code>7d</code> usage windows</li>
    <li>Add reset notifications for Gemini <code>Pro</code> and <code>Flash</code> quota buckets</li>
    <li>Show individual Gemini model usage in the menu, grouped by <code>Pro</code>, <code>Flash</code>, and <code>Flash Lite</code></li>
    <li>Add a weekly GitHub release update check with a browser-open prompt</li>
    <li>Start usage refresh at app launch so reset notifications can fire without opening the menu</li>
    <li>Remove the extra refresh-rate helper text from the menu</li>
  </ul>
</details>

<details>
  <summary>v0.1.5</summary>
  <ul>
    <li>Fix Gemini usage lookup after recent Gemini CLI updates</li>
    <li>Improve Gemini OAuth source discovery for newer Gemini CLI bundle layouts</li>
  </ul>
</details>

<details>
  <summary>v0.1.4</summary>
  <ul>
    <li>Add a first-run onboarding popup with a notch guidance image</li>
    <li>Add a <code>Don't show again</code> checkbox and compact <code>OK</code> button</li>
    <li>Bundle the popup guidance image inside the packaged app</li>
  </ul>
</details>

<details>
  <summary>v0.1.3</summary>
  <ul>
    <li>Add configurable refresh interval presets</li>
    <li>Add configurable auto-rotate interval presets</li>
    <li>Keep the last successful snapshot visible during refresh to reduce fallback flicker</li>
    <li>Use fixed English compact reset text such as <code>resets in 4h</code></li>
  </ul>
</details>

<details>
  <summary>v0.1.2</summary>
  <ul>
    <li>Add provider tray icons for Codex, Claude, and Gemini</li>
    <li>Add Auto Rotate in the menu with 30-second rotation across available providers</li>
    <li>Keep previous successful usage snapshots visible during refresh to reduce flicker</li>
  </ul>
</details>

<details>
  <summary>v0.1.1</summary>
  <ul>
    <li>Add Gemini provider support</li>
    <li>Include the app icon in the packaged <code>.app</code> and DMG release</li>
    <li>Keep Codex and Claude usage support</li>
  </ul>
</details>

<details>
  <summary>v0.1.0</summary>
  <ul>
    <li>Initial public release</li>
    <li>Minimal macOS menu bar app for Codex and Claude usage</li>
    <li>Basic DMG distribution and unsigned app installation guidance</li>
  </ul>
</details>

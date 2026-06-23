[English](./README.md) | [한국어](./README.ko.md)

# codex-opero

`codex-opero` is a minimal macOS menu bar app that shows AI usage as a compact string like `57%/90%`.  
Instead of a full dashboard, it focuses on one thing: letting you check the numbers you need at a glance.

<table width="100%">
  <tr>
    <td width="50%" valign="top"><img src="./Screenshots/Screenshot_v0.1.9_toggle.gif" alt="codex-opero collapsible provider sections" width="100%" /></td>
    <td width="50%" valign="top"><img src="./Screenshots/Screenshot_v0.1.9_main.png" alt="codex-opero menu" width="100%" /></td>
  </tr>
  <tr>
    <td width="50%" valign="top"><img src="./Screenshots/Screenshot_v0.1.4.png" alt="codex-opero first-run popup" width="100%" /></td>
    <td width="50%" valign="top"><img src="./Screenshots/Screenshot_v0.1.6_noti.png" alt="codex-opero reset notifications" width="100%" /></td>
  </tr>
</table>

## Highlights

- Shows the selected provider's remaining usage in a compact two-value format from the menu bar
- Lets you choose between `Codex`, `Claude`, and `Antigravity`
- Remembers the last selected provider
- Supports `Auto Rotate` to cycle through available providers at a configurable interval
- Lets you choose the refresh interval from preset options in the menu
- Lets you choose the auto-rotate interval from preset options in the menu
- Shows the installed app version at the bottom of the menu and links to a new GitHub Release when available
- Refreshes automatically at the configured interval and also supports `Refresh Now`
- Shows each provider as soon as its usage lookup finishes, without waiting for slower providers
- Sends reset notifications when important usage buckets return to 100%
- Checks for new GitHub releases every 24 hours after the last successful check
- Supports `Launch at Login` when running as a packaged `.app`
- Falls back to `--/--` when usage lookup fails

## Authentication

This app does not provide its own login UI or OAuth flow.  
Instead, it reuses existing local authentication state and only fetches usage.

- `Codex`: uses `~/.codex/auth.json`
- `Claude`: uses the macOS Keychain item `Claude Code-credentials` or `~/.claude/.credentials.json`
- `Antigravity` (agy): reads model quota only from a running Antigravity IDE local service; it requires an existing Antigravity login state

That means Codex, Claude, or Antigravity must already be logged in on the local machine.

Under [Google's official policy](https://docs.cloud.google.com/gemini/docs/codeassist/release-notes), Gemini CLI stopped serving requests for individual, Google AI Pro, and Google AI Ultra users on June 18, 2026, so the standalone Gemini provider has been removed. Individual users can view Gemini model quota through Antigravity.

For `Antigravity`, the two menu bar values normally show the remaining 5-hour quota for its two shared model groups. If a group's weekly quota is exhausted, that group displays `0%` even when 5-hour quota remains:

- `Gemini Models`: Gemini Flash and Gemini Pro variants
- `Claude and GPT models`: Claude Opus/Sonnet and GPT-OSS variants

Open the provider details to see compact `[5h]` and `[7d]` rows for each group, with the five-hour limit first. `codex-opero` reads Antigravity's local `RetrieveUserQuotaSummary` service, the same source used by the current Model Quota screen, and retains the older per-model endpoint as a compatibility fallback. For safety, it does not automatically launch `agy` in the background: repeated CLI launches can initiate authentication flows and create IDE workspace entries. Keep the Antigravity app running when reading its quota; if the local service is unavailable, the app displays an explicit availability message instead of launching `agy` or showing stale cache values.

The `[5h]` reset uses the macOS time format and shows the exact time to the minute, such as `resets at 2:18 PM`. Other windows, including `[7d]`, retain the compact relative-time format.

If you use `Claude`, macOS may ask for your password when the app first tries to read the Keychain credentials.
This prompt **only appears if you use Claude and its keychain item exists**. If you do not use Claude, no credential prompt appears.

Because `codex-opero` refreshes on a recurring interval, choosing `Allow` can cause repeated prompts.  
To avoid that, choose **`Always Allow`** for `codex-opero` when macOS asks for access to the keychain credential.

<p>
  <img src="./Screenshots/Screenshot_v0.1.9_keychain.png" alt="macOS Keychain prompt for codex-opero" width="520" />
</p>

When this dialog appears, select **`Always Allow`** so `codex-opero` can refresh usage in the background without asking for your password again.

## Notifications

`codex-opero` can send macOS notifications when usage becomes available again.

- `Codex` and `Claude`: notifies when the `5h` or `7d` remaining usage returns to `100%`
- `Antigravity`: notifies when the available usage for the `Gemini Models` or `Claude and GPT models` group returns to `100%`

Each bucket is notified only once while it stays at `100%`.  
It can notify again after usage drops below `100%` and later returns to `100%`.

The app checks GitHub Releases every 24 hours after the last successful check. If the Mac or app was off when the interval elapsed, it checks immediately on the next launch.
When a newer version is available, the footer changes to a softly pulsing link such as `v0.2.1 → v0.2.2`. Clicking it opens that GitHub Release page. With Reduce Motion enabled in macOS, the link remains static.

## Auto Rotate

`Auto Rotate` is off by default.  
When enabled, `codex-opero` rotates through available providers in this order:

- `Codex`
- `Claude`
- `Antigravity`

You can choose the refresh interval from preset options such as `1 min`, `3 min`, `5 min`, and `15 min`.  
You can also choose the auto-rotate interval from preset options such as `10 sec`, `30 sec`, and `60 sec`.

Providers that are currently unavailable and showing `--/--` are skipped automatically.  
If the menu is open, rotation pauses until the menu closes.  
During refresh, the app keeps showing the last successful snapshot and only falls back to `--/--` if a provider refresh actually fails.
At first launch, providers appear as soon as each lookup finishes, and the first successful provider is shown in the menu bar while slower providers continue loading.

## Install from Release

The easiest way to use `codex-opero` is from the GitHub release.

1. Download the latest `.dmg` from [Releases](https://github.com/charliehotel/codex-opero/releases)
2. Open the `.dmg`
3. Drag `codex-opero.app` into the `Applications` folder
4. Launch `codex-opero.app` from `Applications`

## If macOS blocks the app

`codex-opero` is ad-hoc signed for local use, but it is not signed with an Apple Developer ID or notarized.
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

Requires macOS and an existing Codex, Claude, or Antigravity login on the local machine.

## Release Notes

<details>
  <summary>v0.2.1</summary>
  <ul>
    <li>Normally show each Antigravity model group's 5-hour remaining quota, but display <code>0%</code> when that group's weekly quota is exhausted.</li>
    <li>Show each <code>[5h]</code> reset as an exact hour and minute using the macOS time format.</li>
    <li>Show the current app version at the bottom of the menu.</li>
    <li>Turn the footer version into a soft pulse link when a new version is available, opening the matching GitHub Release when clicked.</li>
    <li>Replace the weekly update prompt with a non-blocking check every 24 hours after the last successful check.</li>
    <li>Remove the standalone Gemini provider following the June 18, 2026 end of Gemini CLI service for individual users.</li>
    <li>Automatically migrate an existing Gemini selection to Antigravity.</li>
  </ul>
</details>

<details>
  <summary>v0.2.0</summary>
  <ul>
    <li>Support the quota service used by Antigravity 2.1.4 in the current agy 1.0.9 environment.</li>
    <li>Read the new <code>RetrieveUserQuotaSummary</code> response and show weekly and five-hour limits for both Gemini and Claude/GPT model groups.</li>
    <li>Display Antigravity detail rows as <code>[5h]</code> followed by <code>[7d]</code>, matching the compact Codex format.</li>
    <li>Adapt to the new local HTTP listener port while retaining the previous per-model endpoint as a compatibility fallback.</li>
    <li>Ad-hoc sign packaged app bundles after resources are copied, so local package verification succeeds.</li>
    <li>Verify immediate update checks after a missed interval, and harden GitHub requests with a timeout, explicit API version, and cancellation-safe scheduling.</li>
  </ul>
</details>

<details>
  <summary>v0.1.97</summary>
  <ul>
    <li>Stop launching <code>agy</code> automatically during background refreshes; Antigravity quota is now read only from an already running Antigravity app local service.</li>
    <li>Prevent repeated background CLI authentication attempts that could open Google login tabs and create duplicate Antigravity workspace entries while the Mac is offline or locked.</li>
    <li>Show a clear message to open the Antigravity app when its local quota service is unavailable, rather than falling back to unsafe CLI launches or stale disk cache.</li>
  </ul>
</details>

<details>
  <summary>v0.1.96</summary>
  <ul>
    <li>Parse Antigravity CLI 1.0.2 exhausted 3rd Party quota rows that report a standalone <code>0%</code> with a future refresh timer, so they correctly display as <code>100% used</code>.</li>
    <li>Publish each provider's quota as soon as its refresh completes instead of waiting for the slowest provider.</li>
    <li>On initial loading, show the first successfully loaded provider in the menu bar while slower lookups, including Antigravity, continue in the background.</li>
  </ul>
</details>

<details>
  <summary>v0.1.95</summary>
  <ul>
    <li>Fix Antigravity usage lookup by reading the same local Antigravity 2.0 language server model quota API used by the IDE, instead of depending on the interactive <code>agy /usage</code> terminal UI.</li>
    <li>Restore Antigravity Google bucket reset timers from the IDE quota payload.</li>
    <li>Treat Antigravity 3rd Party quota entries with a future reset time but no remaining fraction as exhausted, so they show <code>100% used</code> instead of <code>0% used</code> or a timeout.</li>
    <li>Keep the older live <code>agy /usage</code> and cache readers as fallback paths when the Antigravity IDE is not running.</li>
  </ul>
</details>

<details>
  <summary>v0.1.94</summary>
  <ul>
    <li>Fix Antigravity Google bucket reset parsing when terminal redraw output places the reset timer on the same row as the model name.</li>
  </ul>
</details>

<details>
  <summary>v0.1.93</summary>
  <ul>
    <li>Preserve Antigravity Google bucket reset timers when <code>agy</code> reports <code>Quota available</code> together with <code>Refreshes in ...</code>.</li>
  </ul>
</details>

<details>
  <summary>v0.1.92</summary>
  <ul>
    <li>Fix exhausted Antigravity 3rd Party quota parsing when <code>agy</code> shows only <code>Refreshes in ...</code> without an explicit remaining percentage.</li>
  </ul>
</details>

<details>
  <summary>v0.1.91</summary>
  <ul>
    <li>Fix Antigravity live usage parsing when <code>agy /usage</code> renders quota data through terminal redraw escape sequences.</li>
  </ul>
</details>

<details>
  <summary>v0.1.9</summary>
  <ul>
    <li>Rework Antigravity usage lookup to prefer live <code>agy /usage</code> output instead of stale quota cache files.</li>
    <li>Show Antigravity as two shared quota buckets: <code>Google</code> and <code>3rd Party</code>.</li>
    <li>List the selectable Antigravity models under each bucket, including Gemini 3.1 Pro, Gemini 3.5 Flash, Claude Opus/Sonnet 4.6, and GPT-OSS 120B.</li>
    <li>Make Antigravity lookup failures visible instead of silently falling back to old 100% cache values.</li>
    <li>Add collapsible provider sections and persist expanded/collapsed state across app restarts.</li>
    <li>Use consistent bucket detail formatting for Codex, Claude, Gemini, and Antigravity.</li>
    <li>Update Gemini detail groups to the current Pro, Flash, and Flash Lite model families.</li>
    <li>Improve tests for Antigravity live usage parsing, current-account cache selection, and persisted collapse state.</li>
  </ul>
</details>

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

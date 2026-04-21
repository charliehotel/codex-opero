[English](./README.md) | [한국어](./README.ko.md)

# codex-opero

`codex-opero` is a minimal macOS menu bar app that shows AI usage as a compact string like `57%/90%`.  
Instead of a full dashboard, it focuses on one thing: letting you check the numbers you need at a glance.

![codex-opero screenshot](./Screenshot.png)

## Highlights

- Shows the selected provider's remaining usage in a `5-hour/weekly` format from the menu bar
- Lets you choose between `Codex` and `Claude`
- Remembers the last selected provider
- Refreshes automatically every minute and also supports `Refresh Now`
- Supports `Launch at Login` when running as a packaged `.app`
- Falls back to `--/--` when usage lookup fails

## Authentication

This app does not provide its own login UI or OAuth flow.  
Instead, it reuses existing local authentication state and only fetches usage.

- `Codex`: uses `~/.codex/auth.json`
- `Claude`: uses the macOS Keychain item `Claude Code-credentials` or `~/.claude/.credentials.json`

That means Codex or Claude must already be logged in on the local machine.

## Run

### CLI check

```bash
cd /path/to/codex-opero
swift run codex-opero-cli
```

Example:

```text
Codex: 80%/94%
Claude: --/-- (credentials missing)
```

### Run the menu bar app

```bash
cd /path/to/codex-opero
swift run codex-opero
```

### Build the `.app`

```bash
cd /path/to/codex-opero
chmod +x Scripts/package_app.sh
./Scripts/package_app.sh
open /path/to/codex-opero/codex-opero.app
```

The script also creates `dist/codex-opero.dmg`.

## Testing the unsigned `.app`

The generated `.app` is currently an unsigned development build.  
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

# AI Usage Widget

A KDE Plasma 6 widget that displays your AI coding assistant usage statistics in the taskbar. Supports Claude, Antigravity, and Amp.

![Popup](screenshots/popup.png)

## Features

- **Multi-Provider Support**: Track usage across Claude, Antigravity, and Amp
- **Compact Panel Display**: Shows usage percentage right in your taskbar
  ![Panel](screenshots/panel.png)
- **Color-coded Indicators**: Green (<50%), Yellow (<80%), Red (>=80%)
- **Detailed Popup**: Click to see full statistics
  - Session and weekly usage with progress bars
  - Reset times for limits
  - Per-model breakdown (Claude: Sonnet/Opus)
  - Subscription plan badges
- **Auto-refresh**: Updates every minute automatically (configurable)
- **Error Handling**: Clear messages when not logged in or token expired
- **No Dependencies**: Pure QML, no Python or external tools required

## Requirements

- KDE Plasma 6.0 or later
- At least one of:
  - Claude Code CLI installed and logged in
  - Antigravity usage file configured
  - Amp usage file configured

## Installation

### From KDE Store

1. Right-click on your panel
2. Select "Add Widgets..."
3. Click "Get New Widgets..." > "Download New Plasma Widgets..."
4. Search for "AI Usage"
5. Click Install

### Manual Installation

```bash
kpackagetool6 -t Plasma/Applet -i ai-usage-widget.plasmoid
```

### From Source

```bash
git clone https://github.com/anthropics/plasma-ai-usage.git
cd plasma-ai-usage
kpackagetool6 -t Plasma/Applet -i .
```

## Configuration

### Claude

Claude works automatically if you're logged in via Claude Code CLI:

1. Run `claude` in your terminal and log in
2. The widget reads credentials from `~/.claude/.credentials.json`
3. Usage data is fetched live from the Anthropic API

### Antigravity

Antigravity support attempts to automatically detect the local language server process (Linux only) to fetch live usage data.

If automatic detection fails, it falls back to reading usage data from a local JSON file: `~/.antigravity/usage.json`

**Fallback JSON format:**

```json
{
  "bucket_small": {
    "name": "Small",
    "used": 45,
    "limit": 100
  },
  "bucket_medium": {
    "name": "Medium", 
    "used": 12,
    "limit": 50
  },
  "bucket_large": {
    "name": "Large",
    "used": 3,
    "limit": 10
  }
}
```

To set up manually for testing:

```bash
mkdir -p ~/.antigravity
cp examples/antigravity-usage.json ~/.antigravity/usage.json
```

### Amp

Amp reads usage data from a local JSON file. You need to create or have a tool that maintains this file.

**File location:** `~/.amp/usage.json`

**Expected format:**

```json
{
  "free_quota": {
    "used": 7,
    "limit": 10,
    "resets_at": "2025-01-25T00:00:00Z"
  },
  "credits": {
    "balance": 15.50,
    "currency": "USD"
  }
}
```

To set up manually for testing:

```bash
mkdir -p ~/.amp
cp examples/amp-usage.json ~/.amp/usage.json
```

## Usage

1. Configure at least one provider (see Configuration above)
2. Add the widget to your panel
3. Click the widget to see detailed usage statistics

## How It Works

The widget reads configuration files from your home directory:

| Provider    | File Path                        | Data Source     |
|-------------|----------------------------------|-----------------|
| Claude      | `~/.claude/.credentials.json`    | Live API fetch  |
| Antigravity | `~/.antigravity/usage.json`      | Local file      |
| Amp         | `~/.amp/usage.json`              | Local file      |

For Claude, the widget uses your OAuth token to call the Anthropic usage API directly. For Antigravity and Amp, you need to maintain the JSON files (either manually or via integration scripts).

### Claude API Endpoint

```
GET https://api.anthropic.com/api/oauth/usage
Headers:
  Authorization: Bearer <oauth-token>
  anthropic-beta: oauth-2025-04-20
```

## Troubleshooting

### "No accounts found" error

Make sure at least one of these files exists and is valid JSON:
- `~/.claude/.credentials.json` (for Claude)
- `~/.antigravity/usage.json` (for Antigravity)
- `~/.amp/usage.json` (for Amp)

### Claude "Token expired" error

Your OAuth token has expired. Run Claude Code again to refresh it:
```bash
claude
```

### Widget shows 0%

- Click the refresh button in the popup
- Check that your JSON files are valid: `cat ~/.antigravity/usage.json | jq .`
- Check logs: `journalctl --user -f | grep -i "AI Usage"`

### Provider not appearing

- Verify the JSON file exists at the correct path
- Ensure the JSON is valid (no syntax errors)
- Check that numeric values are actual numbers, not strings

## File Structure

```
plasma-ai-usage/
├── metadata.json              # Widget metadata
├── contents/
│   ├── config/
│   │   ├── config.qml         # Config panel definition
│   │   └── main.xml           # Config schema
│   ├── ui/
│   │   ├── main.qml           # Main widget
│   │   ├── Providers.js       # Provider parsers
│   │   ├── configGeneral.qml  # Settings UI
│   │   └── Translations.qml   # i18n support
│   └── icons/
│       └── claude.svg         # Provider icons
├── examples/
│   ├── antigravity-usage.json # Example Antigravity config
│   └── amp-usage.json         # Example Amp config
└── screenshots/               # Preview images
```

## License

GPL-3.0-or-later

## Author

deftdawg, izll

## Credits

- **Tract0r (<@cornfields>)**: Author of `@levitycheck.py`, which provided the logic for detecting and querying the Antigravity local language server.

## Version History

### 1.1.0 (2025)
- Added Antigravity provider support
- Added Amp provider support
- Multi-provider architecture
- Configurable refresh interval
- Multi-language support

### 1.0.0 (2025)
- Initial release
- Session and weekly usage display
- Per-model breakdown (Sonnet/Opus)
- Auto-refresh every minute
- Error handling for login issues

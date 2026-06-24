# codex-opero Design System

## 1. Atmosphere & Identity

codex-opero는 조용한 macOS 메뉴바 계기판이다. 사용자는 긴 설정 화면이 아니라 현재 남은 사용량과 몇 가지 즉시 제어만 확인한다. 시그니처는 "compact native control": 시스템 기본 컨트롤을 유지하되, 정보와 설정, 액션을 분명한 작은 그룹으로 나눈다.

## 2. Color

### Palette

| Role | Token | Light | Dark | Usage |
|------|-------|-------|------|-------|
| Surface/primary | system-window-background | system window background | system window background | Menu popover background |
| Surface/secondary | system-control-background | system control background | system control background | Native buttons and pickers |
| Text/primary | primary | system primary | system primary | Provider names, labels |
| Text/secondary | secondary | system secondary | system secondary | Detail rows, timestamps |
| Text/tertiary | tertiary | system tertiary | system tertiary | Version text |
| Border/default | divider | system separator | system separator | Group dividers |
| Accent/primary | accent | system accent | system accent | Selected provider, update link, focus |
| Status/success | system-green | system green | system green | Enabled status text |
| Status/error | system-red | system red | system red | Destructive or error states when needed |

### Rules

- Prefer SwiftUI semantic colors over raw colors.
- Accent is for selection, focus, and links only.
- Dividers separate major groups; avoid extra borders or shadows inside the menu.

## 3. Typography

### Scale

| Level | Size | Weight | Line Height | Tracking | Usage |
|-------|------|--------|-------------|----------|-------|
| Header | system headline | 600 | system | 0 | Selected provider name |
| Metric | 24px rounded | 600 | system | 0 | Menu bar quota string |
| Body | system body | 400 | system | 0 | Primary rows and controls |
| Body/sm | system subheadline | 500 | system | 0 | Settings row labels |
| Caption | system caption | 400-600 | system | 0 | Detail rows, timestamps, versions |

### Font Stack

- Primary: SwiftUI system font.
- Metric: SwiftUI rounded system font with monospaced digits.
- Mono: Use `monospacedDigit()` for quota strings, timestamps, and versions.

### Rules

- Preserve native macOS text rendering.
- Use weight, not size jumps, for small control hierarchy.
- Numbers that can change in place use tabular digits.

## 4. Spacing & Layout

### Base Unit

All spacing derives from a base of 4px.

| Token | Value | Usage |
|-------|-------|-------|
| space-1 | 4px | Detail row spacing |
| space-2 | 8px | Inline control gaps |
| space-3 | 12px | Compact group spacing |
| space-4 | 16px | Comfortable row grouping |
| space-6 | 24px | Major content separation |

### Grid

- Menu width: 320px unless content proves it needs more.
- Layout: one-column vertical stack with native rows.
- Breakpoints: not applicable; this is a fixed-width menu popover.

### Rules

- Keep settings in stable rows so controls do not jump when toggled.
- Use one divider between major groups only.
- Avoid nested cards and framed panels inside the menu.

## 5. Components

### Menu Settings Group

- Structure: compact action rows. Left side starts with a native SF Symbol button, then a primary label and status text. Right side owns the `Interval` label and picker.
- Variants: refresh action row, rotate action row, login toggle row.
- Spacing: `space-2` between controls and `space-3` between rows.
- States: default, disabled, loading where provided by native controls.
- Accessibility: visible labels remain attached to each control.
- Motion: native control motion only.
- Row grammar: action and current state belong together on the left; interval configuration belongs together on the right. Use SF Symbols, never emoji, for icon buttons.

### Menu Footer

- Structure: two compact action rows; refresh status first, quit/version second.
- Variants: version text, update link.
- Spacing: `space-2` inline gaps and `space-3` vertical row gap.
- States: update link may pulse unless Reduce Motion is enabled.
- Accessibility: update link exposes its release destination label.
- Motion: opacity-only pulse for update availability.

## 6. Motion & Interaction

### Timing

| Type | Duration | Easing | Usage |
|------|----------|--------|-------|
| Native | system | system | Buttons, toggles, pickers |
| Attention | 800ms | ease-in-out | Update availability pulse |

### Rules

- Prefer native SwiftUI control feedback.
- Respect Reduce Motion for any non-native animation.
- Do not animate layout in the menu.

## 7. Depth & Surface

### Strategy

borders-only

| Type | Value | Usage |
|------|-------|-------|
| Default | SwiftUI `Divider()` | Major group separation |

The menu uses system surfaces and dividers only. No custom shadows, nested cards, or decorative backgrounds.

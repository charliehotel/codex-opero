---
slug: v0-2-3-metric-display-toggle
status: awaiting-approval
intent: clear
pending-action: write .omo/plans/v0-2-3-metric-display-toggle.md
review_required: false
approach: Add a persisted metric display mode with remaining as the default and usage as an opt-in mode. Apply it only to compact bare-number surfaces: menu bar label, selected-provider metric, and provider rows. Keep expanded detail rows, quota parsing, reset notifications, and CLI behavior out of scope unless the user expands scope.
---

# Draft: v0-2-3-metric-display-toggle

## Components (topology ledger)
<!-- Lock the SHAPE before depth. One row per top-level component that can succeed or fail independently. -->
<!-- id | outcome (one line) | status: active|deferred | evidence path -->
| C1 | Core metric formatting can produce compact remaining and usage strings from the same `ProviderSnapshot` data without changing provider fetch/parsing. | active | `Sources/QuotaCore/Models.swift:22`, `Sources/QuotaCore/Models.swift:92` |
| C2 | `QuotaStore` persists the user's selected metric display mode in `UserDefaults`, defaulting to remaining. | active | `Sources/QuotaCore/QuotaStore.swift:12`, `Sources/QuotaCore/QuotaStore.swift:51` |
| C3 | Menu UI exposes a compact native switch/control in settings and passes the selected mode to menu bar/top/provider-row metric rendering. | active | `Sources/QuotaPeekMenu/QuotaPeekMenuApp.swift:31`, `Sources/QuotaPeekMenu/MenuSettingsView.swift:5`, `Sources/QuotaPeekMenu/ProviderTrayLabel.swift:75` |
| C4 | Tests, docs, and manual QA prove both modes and protect existing detail/notification semantics. | active | `Tests/QuotaCoreTests/QuotaCoreTests.swift:248`, `README.md:21`, `DESIGN.md:80` |

## Open assumptions (announced defaults)
<!-- Record any default you adopt instead of asking, so the user can veto it at the gate. -->
<!-- assumption | adopted default | rationale | reversible? -->
| Default mode | Remaining amount | Current README and app behavior describe the menu number as remaining usage/quota; preserving this avoids surprising existing users. | yes |
| Toggle scope | Compact bare-number surfaces only | The user named menu bar and provider-adjacent numbers; expanded detail rows already say `N% used` and are not ambiguous. | yes |
| Control placement | Add to existing lower settings area in `MenuSettingsView` | The design system favors compact native control rows and no new settings screen. | yes |
| CLI behavior | Leave `codex-opero-cli` showing remaining | User asked about menu bar/provider UI. Changing CLI would broaden public behavior and docs. | yes |
| Notification logic | Leave reset notifications based on remaining returning to 100% | This is not a display-only concern and uses `remainingPercent` as domain logic. | yes |

## Findings (cited - path:lines)
- Current compact menu strings are remaining-only: `ProviderSnapshot.menuTitle` returns `primary.remainingPercent/secondary.remainingPercent`, including the previous quota during loading (`Sources/QuotaCore/Models.swift:92`).
- `QuotaWindow` already stores `usedPercent` and computes `remainingPercent`, so no provider API or parsing changes are required for display-mode switching (`Sources/QuotaCore/Models.swift:22`).
- The menu bar label uses `store.selectedSnapshot.menuTitle` as the tray title (`Sources/QuotaPeekMenu/QuotaPeekMenuApp.swift:31`) and `ProviderTrayLabelRenderer.makeImage` renders that string into the menu bar image (`Sources/QuotaPeekMenu/ProviderTrayLabel.swift:75`).
- The popover's selected-provider metric and each provider row also use `menuTitle` (`Sources/QuotaPeekMenu/QuotaPeekMenuApp.swift:61`, `Sources/QuotaPeekMenu/QuotaPeekMenuApp.swift:86`).
- Expanded detail rows already display explicit usage copy such as `[5h]  25% used, ...` (`Sources/QuotaPeekMenu/QuotaPeekMenuApp.swift:99`, `Sources/QuotaPeekMenu/QuotaPeekMenuApp.swift:112`).
- `QuotaStore` already persists settings via `didSet` and static defaults keys (`Sources/QuotaCore/QuotaStore.swift:12`, `Sources/QuotaCore/QuotaStore.swift:51`), and tests cover persistence patterns (`Tests/QuotaCoreTests/QuotaCoreTests.swift:1410`).
- Existing test `loadedSnapshotUsesCompactMenuTitle` pins `usedPercent` values 16/6 to displayed remaining string `84%/94%` (`Tests/QuotaCoreTests/QuotaCoreTests.swift:248`).
- README currently presents the menu number as remaining usage/quota (`README.md:21`, `README.md:48`), and Korean README has matching wording (`README.ko.md:21`, `README.ko.md:153`).
- Design guidance says the app is a compact native menu bar dashboard and settings should remain compact native rows (`DESIGN.md:5`, `DESIGN.md:80`).
- Dirty worktree pre-existed this planning turn: `.gitignore` modified, multiple `docs/superpowers/...` files deleted, and `temp_app/` untracked. Executor must not modify or revert these unrelated paths.
- Prior memory for this repo says the ambiguity is user-facing bare-number semantics and the mitigation is explicit remaining-vs-usage labeling/toggle.
- User clarified with screenshot that expanded detail rows already say `N% used` and should not be changed; only the menu bar numbers and the right-side numbers beside `Codex`, `Claude`, and `Antigravity` should switch between remaining and usage.
- User clarified the intended arithmetic is intentionally simple: the toggle decides whether the compact UI shows `x` or `100 - x`. Current normalized model already has `usedPercent` and computed `remainingPercent`, so implementation must remain display-layer focused.

## Decisions (with rationale)
- Plan will introduce a `QuotaMetricDisplayMode`-style core enum with `.remaining` and `.usage`, because display mode is a domain setting used by both core formatting tests and menu UI.
- Plan will replace or overload bare `menuTitle` formatting with mode-aware formatting, rather than duplicating arithmetic in SwiftUI views, because menu bar, top metric, and provider rows must stay consistent.
- Plan will persist the setting in `QuotaStore` using the existing `UserDefaults` pattern and a new static defaults key.
- Plan will default to remaining mode for existing installs and first launch.
- Plan will require visible labeling in settings so the active mode is clear, while keeping the compact metric itself short enough for the menu bar.
- Plan will keep expanded detail rows' `used` copy unchanged to avoid contradicting already explicit detail text.
- Plan will treat this as a low-complexity display-mode change, not a quota-provider rewrite: the formatter should choose `window.usedPercent` for usage mode and `100 - window.usedPercent` via `window.remainingPercent` for remaining mode.

## Scope IN
- Core model/formatting support for compact remaining and usage display strings.
- `QuotaStore` persisted metric display mode with default remaining.
- `MenuSettingsView` control for switching display mode.
- `QuotaPeekMenuApp` wiring so menu bar, selected-provider metric, and provider rows all use the chosen mode.
- Unit tests for remaining default, usage mode formatting, loading previous quota behavior, and persisted display mode.
- README/README.ko/release-note or changelog wording for v0.2.3 explaining the toggle and default.
- Manual QA plan for running the menu app and confirming both modes visually, plus a bad-state scenario such as loading/no quota still showing `--/--`.
- Explicitly verify that the screenshot-like surfaces switch: menu bar string, selected-provider large string, and each provider row's right-side compact string.

## Scope OUT (Must NOT have)
- Do not change provider fetch/parsing logic for Codex, Claude, or Antigravity.
- Do not change reset notification logic or `QuotaResetDetector`.
- Do not auto-launch Antigravity/`agy` or weaken the current safe fallback behavior.
- Do not change expanded detail rows from their explicit `N% used` wording unless the user expands scope.
- Do not change `codex-opero-cli` output unless the user explicitly wants CLI parity.
- Do not touch unrelated dirty-worktree paths: `.gitignore`, deleted `docs/superpowers/...`, or `temp_app/`.
- Do not complicate this into provider-specific conversion logic; use the normalized `QuotaWindow.usedPercent` / `remainingPercent` values.

## Open questions
None blocking. If you want a different product default, veto one of these before approval:
- Default display mode: recommended `Remaining` (current behavior) instead of `Usage`.
- Scope: recommended compact menu/provider numbers only, not expanded detail rows or CLI.
- Control: recommended settings-row switch/segmented control in `MenuSettingsView`, not a separate settings window.

## Approval gate
status: awaiting-approval
pending action: write and fill `.omo/plans/v0-2-3-metric-display-toggle.md`
approval needed: reply with approval such as `진행`, `approve`, or corrected defaults. Approval authorizes only the final executable plan, not implementation.
<!-- When exploration is exhausted and unknowns are answered, set status: awaiting-approval. -->
<!-- That durable record is the loop guard: on a later turn read it and resume at the gate instead of re-running exploration. -->

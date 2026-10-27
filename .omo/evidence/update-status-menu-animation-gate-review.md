recommendation: REJECT

# Gate Review: Update Status Menu Animation

## originalIntent
Fix the severe macOS SwiftUI `MenuBarExtra` regression where an available-update indicator caused the menu panel to jump toward the upper-right every ~0.8 seconds. The intended behavior is that the menu panel remains stationary and clickable while only the blue footer update link pulses.

## desiredOutcome
- Remove the global `withAnimation(.repeatForever)` state mutation from `UpdateStatusView`.
- Preserve the blue pulsing update link when Reduce Motion is off.
- Honor Reduce Motion by disabling the pulse.
- Avoid animation of the `MenuBarExtra` panel frame or parent layout.
- Keep the change scoped, with no unrelated refactor.
- Support the result with build/test evidence and real manual QA or a clearly documented limitation.

## userOutcomeReview
Static source review supports the intended implementation direction:
- `Sources/QuotaPeekMenu/UpdateStatusView.swift:21-27` scopes `.animation(..., value: isDimmed)` to the `Text` label opacity.
- `Sources/QuotaPeekMenu/UpdateStatusView.swift:48-49` changes state by plain assignment and removes global `withAnimation`.
- `Sources/QuotaPeekMenu/UpdateStatusView.swift:23-25` uses `nil` animation when `accessibilityReduceMotion` is true.
- `Sources/QuotaPeekMenu/QuotaPeekMenuApp.swift:162-172` places `UpdateStatusView` only in the footer `HStack`, so the intended pulsing surface is the footer link.

However, the shipped evidence does not prove the user-visible outcome. The reproduced defect was a real macOS menu-panel displacement, and no manual QA artifact shows the app panel remaining stationary and clickable with an available update after this change. The executor limitation that the desktop status-item panel could not be programmatically reopened after an onboarding dialog directly affects this verdict because it leaves the original failure mode unobserved after the fix.

## blockers
1. Missing manual QA evidence for the actual `MenuBarExtra` surface. No artifact shows the panel opened with an available update, observed over multiple 0.8s pulse cycles, remaining stationary, and the link remaining clickable.
2. Missing manual QA matrix. No checked artifact records happy path, Reduce Motion, clickability, or regression observation for the panel frame.
3. Missing package artifact. The prompt claims `package_app.sh` passed, but no package log or package output artifact was found under `.omo/evidence` or by repository search.
4. Missing code review report. No artifact was found that explicitly performs the required `remove-ai-slops` / `programming` perspective check or overfit/slop coverage. This is a hard gate failure under the final-review instructions.
5. Missing notepad path/input. The review request said the input should include a notepad path, but none was provided and none relevant to this task was found.
6. Existing logs prove compile/tests only, not the original UI bug class. `swift test` and release build cannot verify macOS status-item panel geometry.

## removeAiSlopsAndProgrammingPass
Direct slop/overfit pass over the changed production file:
- No excessive or deletion-only tests were added.
- No tautological or implementation-mirroring tests were added.
- No new abstraction, helper extraction, parser, normalization, or broad refactor was introduced.
- The production diff is narrowly scoped to the requested animation behavior.
- The remaining gap is evidentiary, not code slop: the user-visible macOS panel behavior is not proven.

Report coverage check:
- FAIL. No separate code review report artifact was present, so the required skill-perspective and overfit/slop criterion coverage is absent.

## checkedArtifactPaths
- `Sources/QuotaPeekMenu/UpdateStatusView.swift`
- `Sources/QuotaPeekMenu/QuotaPeekMenuApp.swift`
- `.omo/evidence/update-status-menu-animation-review/update-status-view.diff`
- `.omo/evidence/update-status-menu-animation-review/update-status-view.nl.txt`
- `.omo/evidence/update-status-menu-animation-review/footer-placement.nl.txt`
- `.omo/evidence/update-status-menu-animation-review/static-animation-scan.log`
- `.omo/evidence/update-status-menu-animation-review/swift-test.log`
- `.omo/evidence/update-status-menu-animation-review/swift-build-release.log`
- Repository search for `manual`, `qa`, `review`, `package`, `notepad`, `gate`, and update-status evidence artifacts.

## exactEvidenceGaps
- No artifact for `package_app.sh` execution.
- No artifact for visual/manual QA of the opened menu panel.
- No artifact for Reduce Motion manual verification.
- No artifact for update-link clickability after several pulse cycles.
- No artifact for the code review report required by the gate.
- No task-specific notepad path.

## observedEvidence
- `git diff -- Sources/QuotaPeekMenu/UpdateStatusView.swift` matches the supplied diff.
- `rg` found no `withAnimation` in `Sources/QuotaPeekMenu`; the only `repeatForever` is the new `Text` opacity animation in `UpdateStatusView`.
- `git diff --check` returned no whitespace errors.
- `.omo/evidence/update-status-menu-animation-review/swift-test.log` ends with `Test run with 48 tests in 0 suites passed`.
- `.omo/evidence/update-status-menu-animation-review/swift-build-release.log` ends with `Build of product 'codex-opero' complete!`.
- Current worktree also contains unrelated changes (`.gitignore`, deleted `docs/superpowers/...`, untracked `.omo/`, `temp_app/`), which were not modified by this review.

## recommendation
REJECT

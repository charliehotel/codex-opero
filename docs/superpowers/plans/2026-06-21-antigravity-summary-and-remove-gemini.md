# Antigravity 요약 수정 및 Gemini provider 제거 구현 계획

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Antigravity 상단 요약에서 주간 쿼터 소진을 우선 반영하고, 종료된 개인용 Gemini CLI provider를 제거한 0.2.1 앱을 만든다.

**Architecture:** `AntigravityProvider`가 그룹별 5시간 구간을 기본 요약으로 사용하되 주간 잔여량이 0%이면 요약만 0%로 재정의한다. 독립 Gemini provider는 모델, 기본 provider 목록, CLI, UI 아이콘과 리소스에서 제거하고, 저장된 `gemini` 선택 문자열은 `Antigravity`로 마이그레이션한다.

**Tech Stack:** Swift 6, SwiftUI, Observation, Swift Testing, SwiftPM, macOS app bundle

---

### Task 1: Antigravity 주간 소진을 상단 요약에 반영

**Files:**
- Modify: `Tests/QuotaCoreTests/QuotaCoreTests.swift:287-398`
- Modify: `Sources/QuotaCore/AntigravityProvider.swift:508-543`

- [ ] **Step 1: 실패하는 summary 회귀 테스트 작성**

`antigravityProviderUsesAntigravityIDELocalQuotaSummary` fixture에서 Gemini는 `[5h] 100%`, `[7d] 97%`, Claude/GPT는 `[5h] 69%`, `[7d] 0%`로 설정하고 다음 기대값을 사용한다.

```swift
#expect(quota.primary.remainingPercent == 100)
#expect(quota.secondary.remainingPercent == 0)
#expect(quota.detailGroups[0].windows.map(\.remainingPercent) == [100, 97])
#expect(quota.detailGroups[1].windows.map(\.remainingPercent) == [69, 0])
```

- [ ] **Step 2: 테스트가 현재 69% 요약 때문에 실패하는지 확인**

Run:

```bash
swift test --filter antigravityProviderUsesAntigravityIDELocalQuotaSummary
```

Expected: `quota.secondary.remainingPercent`가 `69`여서 실패한다.

- [ ] **Step 3: 주간 소진 시에만 요약을 0%로 만드는 최소 구현**

`quota(from:)`에서 상세 그룹은 그대로 만들고, 다음 helper로 각 그룹의 상단 요약을 만든다.

```swift
private func summaryWindow(from group: QuotaDetailGroup) -> QuotaWindow? {
    guard let fiveHour = group.windows.first(where: { $0.name == "5h" }) else {
        return nil
    }
    guard let weekly = group.windows.first(where: { $0.name == "7d" }),
          weekly.remainingPercent == 0 else {
        return fiveHour
    }
    return QuotaWindow(
        id: fiveHour.id,
        name: fiveHour.name,
        usedPercent: 100,
        resetAt: weekly.resetAt
    )
}
```

기존 bucket ID 탐색 대신 아래처럼 두 그룹의 helper 결과를 사용한다.

```swift
guard let primary = summaryWindow(from: groups[0]),
      let secondary = summaryWindow(from: groups[1]) else {
    return nil
}
```

- [ ] **Step 4: 대상 테스트 통과 확인**

Run:

```bash
swift test --filter antigravityProviderUsesAntigravityIDELocalQuotaSummary
```

Expected: PASS. Gemini 요약은 100%, Claude/GPT 요약은 0%이며 상세 값은 원본을 유지한다.

### Task 2: 기본 Gemini 노출 제거와 기존 선택값 마이그레이션

**Files:**
- Modify: `Tests/QuotaCoreTests/QuotaCoreTests.swift`
- Modify: `Sources/QuotaCore/QuotaStore.swift:57-97`
- Modify: `Sources/QuotaPeekCLI/main.swift:7`

- [ ] **Step 1: 기본 provider와 마이그레이션 실패 테스트 추가**

```swift
@MainActor
@Test
func defaultProvidersExcludeRetiredGemini() {
    let defaults = UserDefaults(suiteName: "QuotaCoreTests.defaultProviders")!
    defaults.removePersistentDomain(forName: "QuotaCoreTests.defaultProviders")
    let store = QuotaStore(defaults: defaults)
    #expect(store.snapshots.map(\.providerID) == [.codex, .claude, .antigravity])
}

@MainActor
@Test
func persistedGeminiSelectionMigratesToAntigravity() {
    let defaults = UserDefaults(suiteName: "QuotaCoreTests.geminiMigration")!
    defaults.removePersistentDomain(forName: "QuotaCoreTests.geminiMigration")
    defaults.set("gemini", forKey: QuotaStore.selectedProviderDefaultsKey)
    let store = QuotaStore(defaults: defaults)
    #expect(store.selectedProviderID == .antigravity)
}
```

- [ ] **Step 2: 두 테스트의 RED 확인**

Run:

```bash
swift test --filter 'defaultProvidersExcludeRetiredGemini|persistedGeminiSelectionMigratesToAntigravity'
```

Expected: 기본 snapshots에 Gemini가 포함되고 기존 선택값이 Gemini로 유지되어 실패한다.

- [ ] **Step 3: 기본 목록과 마이그레이션 구현**

`QuotaStore` 기본값과 선택 복원을 다음 계약으로 변경한다.

```swift
providers: [any UsageProvider] = [CodexProvider(), ClaudeProvider(), AntigravityProvider()]
```

```swift
let persisted = defaults.string(forKey: Self.selectedProviderDefaultsKey)
if persisted == "gemini", providers.contains(where: { $0.providerID == .antigravity }) {
    self.selectedProviderID = .antigravity
} else if let persisted,
          let providerID = ProviderID(rawValue: persisted),
          providers.contains(where: { $0.providerID == providerID }) {
    self.selectedProviderID = providerID
} else {
    self.selectedProviderID = selectedProviderID
}
```

CLI 기본 목록도 다음과 같이 변경한다.

```swift
let providers: [any UsageProvider] = [CodexProvider(), ClaudeProvider(), AntigravityProvider()]
```

- [ ] **Step 4: 두 테스트의 GREEN 확인**

Run:

```bash
swift test --filter 'defaultProvidersExcludeRetiredGemini|persistedGeminiSelectionMigratesToAntigravity'
```

Expected: PASS.

### Task 3: Gemini 타입·UI·리소스 제거와 테스트 보존

**Files:**
- Delete: `Sources/QuotaCore/GeminiProvider.swift`
- Delete: `Resources/TrayIcon-Gemini.png`
- Delete: `Resources/TrayIcon-Gemini@2x.png`
- Modify: `Sources/QuotaCore/Models.swift:3-20`
- Modify: `Sources/QuotaCore/QuotaResetDetector.swift:112-125`
- Modify: `Sources/QuotaPeekMenu/QuotaPeekMenuApp.swift:208-221`
- Modify: `Tests/QuotaCoreTests/QuotaCoreTests.swift`

- [ ] **Step 1: Gemini enum과 전용 구현 제거**

`ProviderID`는 다음 세 case만 유지한다.

```swift
public enum ProviderID: String, Codable, CaseIterable, Identifiable, Sendable {
    case codex
    case claude
    case antigravity
}
```

`GeminiProvider.swift` 전체와 Gemini 아이콘 두 파일을 삭제한다. `ProviderTrayIcon`의 `.gemini` 분기도 삭제한다.

- [ ] **Step 2: reset 알림 switch와 테스트 fixture 정리**

`QuotaResetDetector`의 모델 그룹 분기를 다음과 같이 변경한다.

```swift
case .antigravity:
    return [
        NotifiableResetWindow(window: primary, kind: .modelBucket),
        NotifiableResetWindow(window: secondary, kind: .modelBucket),
    ]
```

`geminiProviderIDHasDisplayName` 테스트는 제거한다. Auto Rotate와 incremental refresh 테스트의 `.gemini` fixture는 `.antigravity`로 바꾸고 테스트 이름과 지역 변수도 Antigravity로 변경한다. Gemini reset 테스트 네 개는 `.antigravity`를 사용하도록 바꾸되 event 개수, marker 중복 방지, 사용 후 재충전 검증은 유지한다.

- [ ] **Step 3: 컴파일과 관련 회귀 테스트 확인**

Run:

```bash
swift test --filter 'selectedProviderSkipsUnavailableProvidersWhenRotating|refreshPublishesSnapshotsAsProvidersFinishAndSelectsFirstLoadedProvider|quotaResetEvent'
```

Expected: PASS, `ProviderID.gemini` 컴파일 참조 0건.

- [ ] **Step 4: 남은 독립 Gemini 참조 확인**

Run:

```bash
rg -n 'GeminiProvider|ProviderID\.gemini|case \.gemini|TrayIcon-Gemini' Sources Resources Tests
```

Expected: 검색 결과 없음. Antigravity 모델 이름에 포함된 `Gemini Models` 문자열은 유지한다.

### Task 4: README·릴리즈 노트·버전 0.2.1 정리

**Files:**
- Modify: `README.ko.md`
- Modify: `README.md`
- Modify: `Resources/Info.plist`
- Create: `ReleaseNotes/v0.2.1.md`

- [ ] **Step 1: 현재 기능 설명에서 독립 Gemini 제거**

한국어·영어 README의 provider 목록, 인증 방식, 알림, Auto Rotate, 요구사항은 `Codex`, `Claude`, `Antigravity`만 현재 지원 대상으로 설명한다. Antigravity의 `Gemini Models` 설명과 과거 릴리즈 기록은 유지한다. 현재 설명에 개인용 Gemini CLI가 2026년 6월 18일 종료되어 Antigravity로 통합됐다는 문장을 추가한다.

- [ ] **Step 2: 0.2.1 버전과 릴리즈 노트 작성**

`Resources/Info.plist`를 다음 값으로 변경한다.

```xml
<key>CFBundleShortVersionString</key>
<string>0.2.1</string>
<key>CFBundleVersion</key>
<string>19</string>
```

`ReleaseNotes/v0.2.1.md`에는 한국어를 먼저 두고 다음 내용을 기록한다.

```markdown
# codex-opero v0.2.1

## 한국어

- Antigravity 상단 요약은 평소 5시간 잔여량을 표시하고, 주간 쿼터 소진 시 0%를 표시합니다.
- 2026년 6월 18일 개인용 Gemini CLI 종료에 맞춰 독립 Gemini provider를 제거했습니다.
- 기존 Gemini 선택값은 Antigravity로 자동 이전됩니다.
```

README의 현재 릴리즈 노트 최상단에도 동일한 0.2.1 요약을 추가한다.

- [ ] **Step 3: 문서와 버전 일관성 확인**

Run:

```bash
rg -n '0\.2\.1|독립 Gemini|standalone Gemini' README.md README.ko.md ReleaseNotes/v0.2.1.md
plutil -p Resources/Info.plist | rg 'CFBundleShortVersionString|CFBundleVersion'
```

Expected: 현재 버전 `0.2.1`, build `19`; 과거 릴리즈 노트 외 현재 지원 목록에는 독립 Gemini가 없다.

### Task 5: 전체 검증과 0.2.1 패키징

**Files:**
- Verify: all modified Swift and documentation files
- Generate: `codex-opero.app`, `dist/codex-opero.app`, `dist/codex-opero.dmg`

- [ ] **Step 1: 전체 테스트 실행**

Run:

```bash
swift test
```

Expected: 모든 테스트 통과, 실패 0개.

- [ ] **Step 2: 0.2.1 앱 패키징**

Run:

```bash
./Scripts/package_app.sh
```

Expected: `codex-opero.app`과 `dist/codex-opero.dmg` 생성.

- [ ] **Step 3: 패키지 무결성 확인**

Run:

```bash
plutil -extract CFBundleShortVersionString raw codex-opero.app/Contents/Info.plist
codesign --verify --deep --strict --verbose=2 codex-opero.app
hdiutil verify dist/codex-opero.dmg
```

Expected: `0.2.1`, 유효한 ad-hoc 서명, 유효한 DMG checksum.

- [ ] **Step 4: 실제 메뉴 QA**

패키징된 앱을 실행하고 다음을 확인한다.

- provider 행은 `Codex`, `Claude`, `Antigravity` 세 개뿐이다.
- 기존 선택값이 `gemini`였던 환경에서 Antigravity가 선택된다.
- 주간 쿼터가 0%인 Claude/GPT 그룹의 상단 값은 0%다.
- 상세 `[5h]`, `[7d]` 값은 원본 그대로다.

- [ ] **Step 5: 커밋 전 상태 정리**

Run:

```bash
git diff --check
git status --short
git diff --stat
```

Expected: 실제 구현·테스트·문서 변경만 남고 `temp_app/`은 건드리지 않는다. 커밋과 푸시는 사용자 확인 후 진행한다.


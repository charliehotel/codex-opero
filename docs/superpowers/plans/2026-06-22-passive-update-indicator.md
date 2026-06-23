# 수동 방해 없는 업데이트 표시 구현 계획

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. 이 저장소에서는 사용자 테스트 전 커밋하지 않으며 `temp_app/`은 건드리거나 stage하지 않는다.

**Goal:** 새 GitHub 안정 릴리즈가 있으면 메뉴 하단의 버전 표시를 `v0.2.1 → v0.2.2` 펄스 링크로 바꾸고 기존 업데이트 팝업을 제거한다.

**Architecture:** 기존 `UpdateChecker`가 네트워크 조회와 스케줄링을 계속 담당하되 관찰 가능한 업데이트 상태를 SwiftUI에 제공한다. 버전 비교·표시 문자열·캐시 복원 판단은 `QuotaCore`의 순수 타입과 정책으로 분리해 테스트하고, 메뉴 하단 표현은 독립 SwiftUI 컴포넌트로 구현한다.

**Tech Stack:** Swift 6.1, SwiftUI, Observation, AppKit, Foundation, Swift Testing, GitHub Releases REST API

---

## 파일 구조

- 생성 `Sources/QuotaCore/AvailableUpdate.swift`: 현재/최신 버전과 Release URL을 나타내는 불변 값 타입
- 수정 `Sources/QuotaCore/UpdateCheckPolicy.swift`: 24시간 확인 주기, 릴리즈 URL 선택, 캐시 복원 정책
- 수정 `Sources/QuotaPeekMenu/UpdateChecker.swift`: 팝업 제거, 상태 관찰, 업데이트 정보 저장·복원
- 생성 `Sources/QuotaPeekMenu/UpdateStatusView.swift`: 현재 버전 또는 펄스 업데이트 버튼 렌더링
- 수정 `Sources/QuotaPeekMenu/QuotaPeekMenuApp.swift`: `UpdateChecker` 주입 및 하단 버전 표시 교체
- 수정 `Tests/QuotaCoreTests/QuotaCoreTests.swift`: 정책·표시 문자열·캐시 복원 회귀 테스트
- 수정 `README.ko.md`, `README.md`, `ReleaseNotes/v0.2.1.md`: 24시간 확인 및 지속형 업데이트 링크 설명

### Task 1: 업데이트 값 타입과 24시간 정책

**Files:**
- Create: `Sources/QuotaCore/AvailableUpdate.swift`
- Modify: `Sources/QuotaCore/UpdateCheckPolicy.swift`
- Test: `Tests/QuotaCoreTests/QuotaCoreTests.swift`

- [ ] **Step 1: 실패 테스트 작성**

다음 동작을 각각 독립 테스트로 추가한다.

```swift
@Test
func updateCheckPolicyUsesDailyCadence() {
    #expect(UpdateCheckPolicy.checkInterval == 24 * 60 * 60)
}

@Test
func availableUpdateUsesCurrentAndLatestDisplayString() throws {
    let current = try #require(AppVersion("0.2.1"))
    let latest = try #require(AppVersion("0.2.2"))
    let url = try #require(URL(string: "https://github.com/charliehotel/codex-opero/releases/tag/v0.2.2"))
    let update = AvailableUpdate(currentVersion: current, latestVersion: latest, releaseURL: url)

    #expect(update.displayString == "v0.2.1 → v0.2.2")
}

@Test
func updatePolicyRestoresOnlyNewerCachedVersion() throws {
    let current = try #require(AppVersion("0.2.1"))

    let restored = UpdateCheckPolicy.restoredUpdate(
        currentVersion: current,
        cachedVersion: "0.2.2",
        cachedReleaseURL: "https://github.com/charliehotel/codex-opero/releases/tag/v0.2.2"
    )
    let stale = UpdateCheckPolicy.restoredUpdate(
        currentVersion: current,
        cachedVersion: "0.2.1",
        cachedReleaseURL: "https://github.com/charliehotel/codex-opero/releases/tag/v0.2.1"
    )

    #expect(restored?.latestVersion == AppVersion("0.2.2"))
    #expect(stale == nil)
}
```

잘못된 버전 문자열, 잘못된 URL, HTTP(S)가 아닌 URL도 `nil`인지 별도 테스트한다.

- [ ] **Step 2: RED 확인**

Run:

```bash
CLANG_MODULE_CACHE_PATH=/tmp/codex-opero-clang-cache \
SWIFTPM_MODULECACHE_OVERRIDE=/tmp/codex-opero-swiftpm-cache \
swift test --disable-sandbox --scratch-path /tmp/codex-opero-swift-build \
  --filter 'updateCheckPolicyUsesDailyCadence|availableUpdateUsesCurrentAndLatestDisplayString|updatePolicyRestoresOnlyNewerCachedVersion'
```

Expected: `AvailableUpdate`와 `restoredUpdate`가 없어 컴파일 실패하거나 기존 7일 주기 때문에 테스트 실패.

- [ ] **Step 3: 최소 구현**

`AvailableUpdate`를 다음 계약으로 구현한다.

```swift
public struct AvailableUpdate: Equatable, Sendable {
    public let currentVersion: AppVersion
    public let latestVersion: AppVersion
    public let releaseURL: URL

    public var displayString: String {
        "\(currentVersion.displayString) → \(latestVersion.displayString)"
    }
}
```

`UpdateCheckPolicy.checkInterval`을 `24 * 60 * 60`으로 변경하고 다음 순수 함수를 추가한다.

```swift
public static func restoredUpdate(
    currentVersion: AppVersion,
    cachedVersion: String?,
    cachedReleaseURL: String?
) -> AvailableUpdate?
```

버전이 현재보다 높고 URL scheme이 `http` 또는 `https`일 때만 복원한다.

- [ ] **Step 4: GREEN 확인**

Step 2의 명령을 다시 실행한다. Expected: 선택 테스트 전부 PASS.

### Task 2: 릴리즈 응답을 지속형 상태로 변환

**Files:**
- Modify: `Sources/QuotaCore/UpdateCheckPolicy.swift`
- Modify: `Sources/QuotaPeekMenu/UpdateChecker.swift`
- Test: `Tests/QuotaCoreTests/QuotaCoreTests.swift`

- [ ] **Step 1: 릴리즈 URL 및 fallback 실패 테스트 작성**

`ReleaseVersionInfo`에 선택적 `releaseURL`을 추가한 뒤 다음을 테스트한다.

```swift
@Test
func updatePolicyBuildsAvailableUpdateWithReleaseURL() throws {
    let current = try #require(AppVersion("0.2.1"))
    let direct = try #require(URL(string: "https://github.com/charliehotel/codex-opero/releases/tag/v0.2.2"))
    let fallback = try #require(URL(string: "https://github.com/charliehotel/codex-opero/releases"))
    let release = ReleaseVersionInfo(
        tagName: "v0.2.2",
        prerelease: false,
        draft: false,
        releaseURL: direct
    )

    #expect(
        UpdateCheckPolicy.availableUpdate(
            latestRelease: release,
            currentVersion: current,
            fallbackURL: fallback
        )?.releaseURL == direct
    )
}
```

`releaseURL == nil`, 비 HTTP(S) URL이면 fallback을 쓰는 테스트와 draft/prerelease/동일 버전이면 `nil`인 테스트를 추가한다.

- [ ] **Step 2: RED 확인**

Task 1과 같은 Swift 테스트 명령에 새 테스트 이름을 filter로 지정한다. Expected: 새 initializer 인자와 `availableUpdate`가 없어 실패.

- [ ] **Step 3: 정책 구현**

`ReleaseVersionInfo.releaseURL: URL?`을 기본값 `nil`로 추가해 기존 호출자를 보존한다. `UpdateCheckPolicy.availableUpdate`는 기존 `newerVersion`을 재사용하고, 유효한 direct URL 또는 fallback URL을 선택해 `AvailableUpdate`를 반환한다.

- [ ] **Step 4: UpdateChecker 상태·저장 구현**

`UpdateChecker`에 Observation을 적용하고 다음 상태를 둔다.

```swift
@Observable
@MainActor
final class UpdateChecker {
    private(set) var availableUpdate: AvailableUpdate?
    let currentVersion: AppVersion?
}
```

UserDefaults 키는 `updateCheck.availableVersion`, `updateCheck.availableReleaseURL`을 사용한다. 초기화 때 `restoredUpdate`로 상태를 복원하고, 실패하면 두 캐시 키를 제거한다.

성공 응답 처리:

- 새 버전: `availableUpdate` 갱신 후 버전·URL 저장
- 최신 상태: `availableUpdate = nil` 후 캐시 삭제
- 두 경우 모두 `lastCheckedAt` 갱신

오류 처리:

- `lastCheckedAt`과 `availableUpdate`를 변경하지 않음
- `retryInterval`인 한 시간 뒤 재시도

`LatestRelease`는 `html_url`을 decode해 `ReleaseVersionInfo.releaseURL`로 전달한다.

- [ ] **Step 5: 기존 팝업 제거**

다음을 삭제한다.

- `lastPromptedVersionKey`, `lastPromptedAtKey`
- `shouldPrompt`
- `showUpdatePrompt`
- `NSAlert` 생성과 Yes/No 분기

`releasesURL`은 direct URL이 없을 때 fallback으로 유지한다.

- [ ] **Step 6: 전체 정책 테스트 실행**

Run: Task 1의 Swift 테스트 명령에서 filter를 제거한다. Expected: 전체 테스트 PASS.

### Task 3: 메뉴 하단 펄스 업데이트 링크

**Files:**
- Create: `Sources/QuotaPeekMenu/UpdateStatusView.swift`
- Modify: `Sources/QuotaPeekMenu/QuotaPeekMenuApp.swift`

- [ ] **Step 1: UpdateStatusView 구현**

컴포넌트는 `currentVersion`과 `availableUpdate`를 입력받는다.

```swift
struct UpdateStatusView: View {
    let currentVersion: AppVersion?
    let availableUpdate: AvailableUpdate?
}
```

- `availableUpdate == nil`: 현재 버전을 `.caption`, `.tertiary`로 표시하고 클릭 불가
- 업데이트 있음: borderless 버튼, accent color, `availableUpdate.displayString`
- 클릭: `NSWorkspace.shared.open(availableUpdate.releaseURL)`
- 접근성 레이블: `\(latestVersion.displayString) 업데이트 가능, GitHub Releases 열기`
- `accessibilityReduceMotion == false`: opacity `1.0 ↔ 0.45`, 0.8초 autoreverse 반복
- `accessibilityReduceMotion == true`: opacity `1.0`, 애니메이션 없음

- [ ] **Step 2: ContentView에 상태 주입**

`QuotaPeekMenuApp`에서 `UpdateChecker.shared`를 SwiftUI 상태로 보관하고 `ContentView`에 전달한다. 기존 하단 `Text(version.displayString)`을 `UpdateStatusView`로 교체한다. `AppDelegate`의 `start()`/`stop()` 수명주기는 유지한다.

- [ ] **Step 3: 컴파일 확인**

Run:

```bash
CLANG_MODULE_CACHE_PATH=/tmp/codex-opero-clang-cache \
SWIFTPM_MODULECACHE_OVERRIDE=/tmp/codex-opero-swiftpm-cache \
swift build --disable-sandbox --scratch-path /tmp/codex-opero-swift-build
```

Expected: exit 0, actor isolation과 Observation 오류 없음.

### Task 4: 문서와 회귀 테스트

**Files:**
- Modify: `README.ko.md`
- Modify: `README.md`
- Modify: `ReleaseNotes/v0.2.1.md`
- Modify: `Tests/QuotaCoreTests/QuotaCoreTests.swift`

- [ ] **Step 1: 기존 주기·팝업 테스트 정리**

기존 `shouldPrompt` 관련 테스트를 삭제하고 다음 계약 테스트로 교체한다.

- 24시간 직전에는 확인하지 않음
- 정확히 24시간이면 확인
- 놓친 확인은 다음 실행에서 즉시 수행
- 실패 재시도는 한 시간
- 캐시된 새 버전 복원
- 현재/낮은 버전 캐시 무시
- 오류 시 기존 업데이트 값 유지에 사용되는 순수 정책

- [ ] **Step 2: README와 릴리즈 노트 수정**

한국어 문서를 우선 작성한다.

- `약 일주일에 한 번`을 `마지막 성공 확인 후 24시간마다`로 변경
- 기존 브라우저 열기 팝업 설명을 하단 펄스 링크 설명으로 교체
- 클릭 시 해당 Release 페이지로 이동, 동작 줄이기 지원 명시
- 영문 README와 `ReleaseNotes/v0.2.1.md`도 동일 계약으로 갱신

- [ ] **Step 3: 전체 테스트와 diff 검사**

Run:

```bash
CLANG_MODULE_CACHE_PATH=/tmp/codex-opero-clang-cache \
SWIFTPM_MODULECACHE_OVERRIDE=/tmp/codex-opero-swiftpm-cache \
swift test --disable-sandbox --scratch-path /tmp/codex-opero-swift-build
git diff --check
```

Expected: 전체 테스트 PASS, `git diff --check` 출력 없음.

### Task 5: 패키징 및 실제 앱 검증

**Files:**
- Verify: `codex-opero.app`
- Verify: `dist/codex-opero.dmg`

- [ ] **Step 1: 앱·DMG 재패키징**

Run: `./Scripts/package_app.sh`

Expected: 앱과 DMG 생성, ad-hoc 서명 완료.

- [ ] **Step 2: 최신 상태 검증**

패키징 앱을 실행해 하단에 클릭 불가능한 `v0.2.1`이 표시되는지 확인한다.

- [ ] **Step 3: 캐시 기반 업데이트 상태 검증**

기존 UserDefaults 값을 먼저 보관한 뒤 테스트용 `availableVersion=0.2.2`, 유효한 Release URL을 설정하고 앱을 재실행한다. 다음을 확인한다.

- `v0.2.1 → v0.2.2` 표시
- accent color와 부드러운 opacity 펄스
- VoiceOver 접근성 레이블
- 클릭 시 해당 GitHub Release URL 이동
- 동작 줄이기 활성화 시 정적 표시

검증 후 테스트용 UserDefaults를 제거하고 원래 값을 복원한다.

- [ ] **Step 4: 산출물 검증**

Run:

```bash
codesign --verify --deep --strict codex-opero.app
hdiutil verify dist/codex-opero.dmg
shasum -a 256 dist/codex-opero.dmg
```

Expected: 서명과 DMG 검증 성공, SHA-256 출력.

- [ ] **Step 5: 사용자 테스트용 전달**

앱·DMG 경로, 테스트 수, 실제 UI 검증 결과를 전달한다. 커밋과 push는 사용자가 문제없다고 확인한 뒤 수행하며 `temp_app/`은 계속 제외한다.

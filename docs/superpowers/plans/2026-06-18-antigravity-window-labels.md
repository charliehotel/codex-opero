# Antigravity 쿼터 구간 표시 구현 계획

> **에이전트 작업 지침:** 이 계획은 `superpowers:executing-plans`를 사용해 순서대로 실행한다.

**목표:** Antigravity 상세 쿼터를 `[5h]`, `[7d]`로 축약하고 5시간 구간을 먼저 표시한다.

**구조:** `RetrieveUserQuotaSummary`의 bucket `window` 값을 `QuotaWindow`로 변환할 때 표시 이름과 순서를 정규화한다. SwiftUI는 정규화된 이름을 Codex와 같은 대괄호 행 형식으로 렌더링한다.

**기술 스택:** Swift 6, Swift Testing, SwiftUI, SwiftPM

---

### 작업 1: 회귀 테스트로 축약 이름과 순서 고정

**파일:**
- 수정: `Tests/QuotaCoreTests/QuotaCoreTests.swift:266`

- [x] **1단계: 실패 테스트 작성**

기존 `antigravityProviderUsesAntigravityIDELocalQuotaSummary`의 검증을 다음 기대값으로 변경한다.

```swift
#expect(quota.detailGroups[0].windows.map(\.id) == ["gemini-5h", "gemini-weekly"])
#expect(quota.detailGroups[0].windows.map(\.name) == ["5h", "7d"])
#expect(quota.detailGroups[0].windows.map(\.remainingPercent) == [100, 78])
#expect(quota.detailGroups[1].windows.map(\.id) == ["3p-5h", "3p-weekly"])
#expect(quota.detailGroups[1].windows.map(\.name) == ["5h", "7d"])
#expect(quota.detailGroups[1].windows.map(\.remainingPercent) == [4, 68])
```

- [x] **2단계: RED 확인**

실행:

```bash
swift test --filter antigravityProviderUsesAntigravityIDELocalQuotaSummary
```

기대 결과: 현재 순서 `weekly`, `5h` 및 긴 표시 이름 때문에 실패한다.

### 작업 2: summary bucket 정규화

**파일:**
- 수정: `Sources/QuotaCore/AntigravityProvider.swift:508`
- 테스트: `Tests/QuotaCoreTests/QuotaCoreTests.swift:266`

- [x] **1단계: 표시 이름과 정렬 우선순위 추가**

`AgyIDEQuotaSummaryBucket`에 `window` 기반 계산 속성을 추가한다.

```swift
var compactDisplayName: String {
    switch window {
    case "5h": "5h"
    case "weekly": "7d"
    default: displayName
    }
}

var sortOrder: Int {
    switch window {
    case "5h": 0
    case "weekly": 1
    default: 2
    }
}
```

- [x] **2단계: bucket 정렬 및 축약 이름 적용**

`quota(from:)`에서 각 그룹의 bucket을 `sortOrder`로 정렬하고 `QuotaWindow.name`에 `compactDisplayName`을 사용한다.

```swift
let buckets = group.buckets.sorted { $0.sortOrder < $1.sortOrder }
return QuotaDetailGroup(
    name: group.displayName,
    windows: buckets.map { bucket in
        QuotaWindow(
            id: bucket.bucketID,
            name: bucket.compactDisplayName,
            usedPercent: bucket.usedPercent,
            resetAt: bucket.resetDate
        )
    }
)
```

- [x] **3단계: GREEN 확인**

실행:

```bash
swift test --filter antigravityProviderUsesAntigravityIDELocalQuotaSummary
```

기대 결과: 단일 회귀 테스트 통과.

### 작업 3: SwiftUI 상세 행을 Codex 형식으로 통일

**파일:**
- 수정: `Sources/QuotaPeekMenu/QuotaPeekMenuApp.swift:99`

- [x] **1단계: 여러 window를 가진 그룹의 행 형식 변경**

`group.modelNames.isEmpty` 분기의 window 행을 다음과 같이 변경한다.

```swift
Text("[\(window.name)]  \(window.usedPercent)% used, \(QuotaFormatter.resetString(for: window))")
```

이 분기는 현재 새 Antigravity summary 그룹에 사용되며 Codex의 상세 행과 동일한 시각 문법을 만든다.

### 작업 4: 전체 검증 및 0.2.0 재패키징

**파일:**
- 검증: `Resources/Info.plist`
- 실행: `Scripts/package_app.sh`

- [x] **1단계: 전체 테스트 실행**

```bash
swift test
```

결과: 37개 테스트, 실패 0개.

- [x] **2단계: 0.2.0 앱 재패키징**

```bash
zsh Scripts/package_app.sh
```

- [x] **3단계: 패키지 검증**

```bash
plutil -lint codex-opero.app/Contents/Info.plist
codesign --verify --deep --strict --verbose=2 codex-opero.app
hdiutil verify dist/codex-opero.dmg
```

기대 결과: plist 버전 `0.2.0`, 코드 서명 유효, DMG 체크섬 유효.

사용자가 새 앱을 몇 시간 동안 확인한 뒤 커밋과 푸시를 승인했다.

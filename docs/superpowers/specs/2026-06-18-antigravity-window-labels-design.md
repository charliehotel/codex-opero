# Antigravity 쿼터 구간 표시

## 목표

Antigravity 쿼터 상세 표시를 Codex의 간결한 형식과 통일한다. 긴 `Five Hour Limit`, `Weekly Limit` 대신 `[5h]`, `[7d]`를 사용하고 `[5h]`를 먼저 표시한다.

## 변경 범위

- Antigravity 메뉴 막대의 요약 값은 변경하지 않는다.
- Antigravity summary API의 `window` 값을 다음과 같이 정규화한다.
  - `5h`는 `5h`로 표시한다.
  - `weekly`는 `7d`로 표시한다.
- API 응답 순서와 관계없이 `5h`, `7d` 순서로 정렬한다.
- Antigravity 상세 행은 Codex와 동일하게 `[5h]`, `[7d]` 형식으로 표시한다.

## 데이터 흐름

`RetrieveUserQuotaSummary`를 계속 원본 데이터로 사용한다. `QuotaDetailGroup`으로 변환할 때 각 bucket의 `window` 값을 기준으로 축약 표시 이름과 정렬 우선순위를 결정한다. SwiftUI 메뉴는 API의 긴 이름을 다시 해석하지 않고 정규화된 `QuotaWindow`를 그대로 표시한다.

## 호환성

기존 `GetAvailableModels` fallback은 변경하지 않는다. 여러 구간을 제공하는 새 그룹 단위 summary 경로에만 축약 라벨과 정렬 규칙을 적용한다.

## 검증

- Antigravity quota summary 회귀 테스트에서 window 순서가 `5h`, `7d`이고 표시 이름도 축약형인지 확인한다.
- 구현 전 테스트 실패와 구현 후 통과를 모두 확인한다.
- 전체 Swift 테스트를 실행하고 0.2.0 앱을 다시 패키징한다.
- 패키징된 앱의 서명, plist 버전, DMG 체크섬을 검증한다.

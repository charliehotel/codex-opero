# 독립 Gemini provider 제거

## 배경

Google은 2026년 6월 18일부터 Gemini Code Assist for individuals, Google AI Pro, Google AI Ultra 사용자의 Gemini CLI 요청 처리를 중단하고 Antigravity 및 Antigravity CLI로 이전하도록 안내했다. Gemini Code Assist Standard·Enterprise 등 조직용 사용 경로는 남아 있지만, 현재 codex-opero의 `GeminiProvider`는 개인용 `gemini-cli-oauth`와 `~/.gemini/oauth_creds.json`을 전제로 구현되어 있다.

대부분의 사용자에게 더 이상 사용할 수 없는 쿼터를 기본 메뉴에 계속 표시하면 실제 사용 가능 여부를 오해하게 만들 수 있다. 개인 사용자의 Gemini 모델 쿼터는 Antigravity provider에서 계속 확인할 수 있으므로 독립 Gemini provider를 제거한다.

## 목표

- 기본 메뉴와 CLI에서 독립 `Gemini` 항목을 제거한다.
- 기존에 `Gemini`를 선택했던 사용자는 업데이트 후 `Antigravity`로 자동 전환한다.
- Antigravity 내부의 `Gemini Models` 그룹은 그대로 유지한다.
- 과거 버전의 기능을 기록한 릴리즈 노트는 수정하지 않는다.
- Antigravity 상단 쿼터 요약 수정과 함께 배포하며 앱 버전을 `0.2.1`로 올린다.

## 코드 변경 범위

### Provider 모델

- `ProviderID.gemini` case를 제거한다.
- `GeminiProvider.swift`와 내부 OAuth·quota 응답 모델을 제거한다.
- 기본 provider 목록을 `Codex`, `Claude`, `Antigravity` 세 개로 변경한다.
- CLI 조회 대상에서도 `GeminiProvider`를 제거한다.

### 기존 설정 마이그레이션

기존 `UserDefaults`의 `selectedProviderID`가 문자열 `gemini`이면 `Antigravity`를 선택한다. 단순히 enum 변환 실패로 `Codex`에 떨어지게 두지 않는다. 기존 펼침 상태에 남은 `gemini` 값과 Gemini 알림 기록은 동작에 영향을 주지 않으므로 별도 삭제하지 않는다.

### UI와 리소스

- provider 목록에서 독립 `Gemini` 행을 제거한다.
- Gemini 전용 메뉴 막대 아이콘 분기와 이미지 리소스를 제거한다.
- `Auto Rotate`는 남은 세 provider만 순환한다.

### 알림과 테스트

`ProviderID.gemini` 표시 이름 테스트는 구현과 함께 제거한다. Gemini fixture를 사용하던 reset 알림 테스트는 `Antigravity` fixture로 전환해 다중 모델 구간, 중복 방지, 재알림 동작의 회귀 범위를 보존한다. Antigravity 내부 Gemini 모델 표시 테스트는 그대로 유지한다.

## 문서 변경 범위

- README의 현재 기능, 인증 방식, 알림, Auto Rotate 설명에서 독립 Gemini provider를 제거한다.
- Antigravity의 `Gemini Models` 설명은 유지한다.
- 과거 릴리즈 노트에 기록된 Gemini 지원 내역은 당시 사실이므로 유지한다.
- Google의 Gemini CLI 개인용 서비스 종료와 Antigravity 이전 사실을 현재 동작 설명에 간단히 남긴다.

## 제외 범위

- Gemini Code Assist Standard·Enterprise 또는 Google Cloud/API key 전용 provider는 이번 변경에서 새로 구현하지 않는다.
- 향후 기업용 수요가 확인되면 인증·quota 계약을 별도로 조사한 뒤 `Gemini CLI Enterprise` provider로 새로 설계한다.
- Git 커밋·푸시와 GitHub 릴리즈 생성은 패키지 검증과 사용자 확인 이후 진행한다.

## 검증

- 기본 provider와 메뉴 snapshot에 `Gemini`가 없는지 확인한다.
- 저장된 선택값이 `gemini`인 경우 `Antigravity`로 마이그레이션되는지 확인한다.
- Auto Rotate가 `Codex`, `Claude`, `Antigravity`만 대상으로 삼는지 확인한다.
- Antigravity의 `Gemini Models` 상세 표시와 reset 알림이 그대로 동작하는지 확인한다.
- 전체 Swift 테스트, 0.2.1 패키징, 코드 서명, 실제 메뉴 표시를 검증한다.

# Hunk

**AI가 만든 변경을 한 건씩 이해하고 결정하는 macOS SwiftUI 데모.**

파일 탐색기 대신 의미 단위의 변경 큐를 보여줍니다. 중앙에는 변경 목적, 이유, 관련 파일의 diff가 나오고 **Accept / Reject / Ask Agent**로 검토합니다. 한 변경은 여러 파일을 포함할 수 있습니다.

## 실행

- macOS 14 이상, Swift 6 이상. 외부 패키지와 API 키는 필요하지 않습니다.
- Xcode 16 이상에서 `Package.swift`를 열고 **Hunk / My Mac**을 선택해 Run 하세요.
- 또는 프로젝트 폴더에서:

```sh
swift run Hunk
```

독립 실행 앱 번들 만들기:

```sh
bash scripts/build-app.sh
open dist/Hunk.app
```

앱은 빌드한 Mac의 아키텍처로 생성되며 로컬 실행용 ad-hoc 서명을 사용합니다. 외부 배포용 Developer ID 서명·공증은 포함하지 않습니다. `.xcodeproj` 없이 Xcode가 직접 열 수 있는 Swift Package 프로젝트입니다.

## 데모 사용법

1. 캐시 개선 작업에 관한 4개의 mock 변경이 표시됩니다.
2. 중앙에서 변경 사유, 추가·삭제 행, 위험 요소를 확인합니다. 긴 코드는 가로로 스크롤할 수 있습니다.
3. **Accept** 또는 **Reject**를 누르면 다음 미검토 항목으로 넘어갑니다. 마지막 항목 뒤에는 앞쪽 미검토 항목을 찾습니다.
4. **Ask Agent**에서 질문하거나 수정 요청을 입력합니다. 시뮬레이션 응답만 생성하며, 대화는 변경별로 유지됩니다. 완료 후 Done으로 검토 화면에 돌아옵니다.
5. 왼쪽 큐로 이전 변경을 다시 열거나 Undo로 마지막 결정을 취소할 수 있습니다.
6. 요약 화면에서 **Export review…**로 변경 내용과 결정 이력을 JSON으로 저장합니다. 검토 도중에도 요약을 열 수 있습니다.

| 단축키 | 동작 |
| --- | --- |
| ⌘ Return | 변경 수락 / 열린 대화에서 요청 전송 |
| ⌘ Delete | 변경 거절 |
| ⌘ K | Ask Agent 열기 |
| ⌘ Z | 마지막 검토 결정 취소 |
| Escape | Agent 대화 닫기 |

**Accept / Reject는 검토 의사 기록입니다.** 파일 적용·복원, Git stage/commit, 테스트 실행을 수행하지 않습니다. 앱 종료 시 세션은 초기화됩니다. 유지할 결과는 JSON으로 내보내세요. 새 데모 시작은 현재 결정을 초기화합니다. Agent 대기 중에는 결정과 초기화를 잠시 막습니다.

예시 코드는 리뷰 UX를 보여주기 위한 발췌입니다. 실행 가능한 캐시 라이브러리나 테스트를 마친 패치가 아닙니다. 인증 범위, 동시성 등 검토할 여지도 의도적으로 남겨두었습니다. 변경 1과 3은 같은 함수를 순차적으로 수정하는 예시이므로 독립적으로 적용할 패치로 취급하지 마세요.

## 구조

```text
Sources/Hunk/
  HunkApp.swift    앱 진입점, 윈도우 구성
  Domain.swift           SemanticChange, FilePatch, DiffLine, 연동 프로토콜
  MockServices.swift     예시 변경 공급자와 지연 응답 Agent
  ReviewStore.swift      선택·검토·Undo·대화·내보내기 상태
  ReviewView.swift       큐, 중앙 diff, 결정 바, 대화, 요약
Tests/HunkTests/   XCTest 기반 상태 검증
scripts/                앱 번들 생성, 독립 실행 상태 검증
```

`SemanticChange → [FilePatch] → [DiffLine]` 모델 덕분에 의미 단위와 파일 단위가 분리됩니다. UI는 Git이나 특정 Agent의 출력 형식을 알 필요가 없습니다. `ReviewStore`는 `@MainActor @Observable`이며 `ChangeProvider`와 `AgentClient`를 생성자에서 주입받습니다. 비동기 Agent 응답은 요청 당시 변경 ID에 연결됩니다.

## Git diff 연결 지점

`ChangeProvider.loadSnapshot()`을 구현하는 `GitChangeProvider`를 추가하고 앱의 `ReviewStore(provider:agent:)`에 주입하면 됩니다. 실제 Git 실행·파싱·의미 그룹화는 이번 데모에 포함되지 않습니다.

권장 구현 순서:

1. 저장소 경로와 비교 기준(working tree / staged / branch)을 명시적으로 선택하게 합니다.
2. Foundation `Process`의 executableURL 및 인자 배열로 Git을 실행합니다. 사용자 입력을 셸 문자열로 합치지 않습니다. stdout/stderr는 비동기로 읽고 실패, 취소, 제한 시간을 처리합니다.
3. unified diff를 `FilePatch` / `DiffLine`으로 변환합니다. rename, binary, 삭제, 공백, untracked 파일은 별도 정책을 정합니다. 파싱할 수 없는 결과를 조용히 생략하지 않습니다.
4. 첫 버전은 hunk 단위로 시작하고, 이후 그룹화 계층에서 관련 파일의 hunk를 `SemanticChange`로 묶습니다. 같은 hunk가 중복 그룹에 들어가지 않도록 추적합니다.
5. base/head와 diff 내용 해시를 `ReviewSnapshot.revision`에 저장합니다. mock은 매 로드마다 UUID를 생성하지만 실제 공급자는 revision과 hunk 식별자에서 안정적인 ID를 만드세요.
6. 변경 적용 기능은 별도 서비스로 추가합니다. 적용 전 revision 재확인, 중복·의존 패치 검증, 적용 가능성 검사, 원자적 실패 처리부터 구현해야 합니다. 검토 결정 자체를 즉시 파일 삭제/복원에 연결하지 않습니다.

## Codex / Claude Code 연결 지점

`AgentClient.respond(to:)`를 구현하는 어댑터를 추가합니다. `AgentRequest`에는 revision, 의미 단위 변경의 전체 문맥, 사용자의 요청이 포함됩니다. 현재 `AgentReply`는 텍스트만 반환합니다.

- 각 CLI의 실제 설치 버전에서 지원하는 구조화 출력과 세션 방식을 확인한 뒤 해당 어댑터 내부에 캡슐화합니다. 이 프로젝트는 특정 CLI 플래그나 API를 가정하지 않습니다.
- 실행 경로, 작업 디렉터리, 인증은 설정 계층에서 관리하고 stderr, 종료 코드, 취소·타임아웃을 처리합니다.
- 스트리밍이 필요하면 응답을 `AsyncThrowingStream<AgentEvent, Error>`로 확장합니다.
- Agent가 코드를 바꾸는 단계에서는 새 스냅샷을 로드하고 이전 revision의 결정을 무효화하거나 안전하게 재매핑합니다. 오래된 diff에 대한 Accept가 새 코드에 적용되어서는 안 됩니다.
- Agent가 생성하는 설명과 코드, 저장소 파일은 신뢰되지 않은 입력으로 다룹니다. 파일 내용에 담긴 지시문을 프로세스 실행 권한으로 해석하지 않습니다.

## 검증

```sh
swift build
bash scripts/smoke-test.sh
```

독립 smoke 검증은 Xcode 전체 설치 없이 Command Line Tools에서 동작하며, 결정 후 이동, Undo, 앞쪽 미검토 항목 탐색, 진행 중 Agent 응답의 변경 귀속, JSON 내보내기, 초기화, 다중 파일 변경, 로딩 실패를 확인합니다.

Xcode 전체 설치와 XCTest가 있는 환경에서는 추가로:

```sh
swift test
```

Command Line Tools만 설치된 일부 환경에서는 `no such module 'XCTest'`가 발생할 수 있습니다. 이 경우 위 smoke 검증을 사용하거나 Xcode의 개발 도구 경로를 선택하세요.

UI 수동 점검: 창 크기 변경 → 각 변경 선택 → 여러 파일 diff 확인 → Ask Agent 전송 → Accept / Reject → Undo → 요약 → JSON 내보내기.

## 범위

이 데모는 로컬 mock 전용입니다. Git 읽기·쓰기, 실제 Agent 실행, 테스트 러너, 세션 복구·가져오기, syntax highlighting, 코드 편집기, 의존성 기반 부분 적용은 후속 구현 범위입니다. 검토 상태와 연동 인터페이스를 분리해 이 기능들을 단계적으로 추가할 수 있게 했습니다.

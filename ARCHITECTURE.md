# kbbs 구조

```
kbbs.swift                       루트 명령 · 부트 사다리 · 하위명령
   │
App/Loop.swift                   100ms poll(2) 루프. 모델과 렌더링만 소유한다.
   │                             AX 호출을 단 한 번도 하지 않는다 (make lint-print 가 강제)
   │  작업 ↓              ↑ 값 (메일박스, 세대 도장)
AX/Worker.swift                  직렬 큐 하나. 모든 AXUIElement 호출이 여기서 돈다
   │
KakaoTalk/                       kmsg 에서 가져온 스크레이퍼
   ChatListScanner               대화방 목록
   MessageContextResolver        입력창 · 전사 루트
   TranscriptReader              메시지 추출
   Sender / WindowCloser         전송 · 창 닫기
   │
Accessibility/UIElement          AXUIElement 감싸개 (예산 있는 탐색)
   │
macOS Accessibility API
```

## 화면

전부 순수 함수다. 모델을 넣으면 **정확히 24행 × 80칸**이 나온다. 터미널도 카카오톡도
필요 없어서 테스트가 전부 여기에 있다.

| | |
|---|---|
| `UI/ListScreen` | 대화방 목록, 동의 게이트 |
| `UI/RoomScreen` | 대화, 입력칸 |
| `UI/BlockedScreen` | 통신 두절 |
| `Term/Frame` | 24×80 불변조건. 행마다 폭을 맞추고 제어문자를 중화한다 |
| `Term/Width` | 한글·CJK·이모지 폭. 목록 한 칸이 틀리면 모든 행이 어긋난다 |

## 이 저장소의 규칙

전부 실측에서 나왔다. 자세한 내용과 숫자는
`docs/specs/2026-09-16-kbbs-hitel-tui-design.md` §13 에 있다.

- **예산 없는 AX 탐색 금지.** 무예산 `findFirst` 는 카카오톡 트리에서 7분이 지나도 끝나지
  않았다. 항상 `limit` 과 `maxNodes` 를 준다.
- **넓이우선 탐색보다 "있는 곳만 본다".** 카카오톡은 AX 질의 하나에 5~10ms 를 쓴다.
  600노드 탐색이 4~7초다. 입력창·전사 루트를 두 단계만 훑게 바꿔 방 열기가 7.2초 →
  0.58초가 됐다.
- **AX 액션은 광고와 다르다.** 「전송」 버튼의 `AXPress` 는 보내고도 실패를 반환하고,
  스크롤 액션과 `AXShowMenu` 는 아무 일도 하지 않는다. 반환값도 액션 목록도 증거가
  아니다 — 결과를 확인한다.
- **읽기는 포커스를 뺏지 않는다.** 카카오톡을 앞으로 가져오는 것은 사용자가 동의한 창
  열기뿐이다.
- **메인 스레드는 AX 를 호출하지 않는다.** 살아있는 `UIElement` 는 워커 밖으로 나가지
  않고, 메인은 정수 토큰만 본다.
- **취소는 없다. 포기만 있다.** AX 호출은 멈출 수 없으므로 결과에 세대 도장을 찍고,
  낡은 답은 도착하면 버린다.

## 진단

카카오톡이 바뀌어서 뭔가 깨졌을 때. 전부 본문을 찍지 않는다.

```bash
kbbs open "방" --dry-run     # 클릭 직전까지 좌표·프레임·화면
kbbs probe-send "방"         # 전송 경로. 넣었다 지우기만, 보내지 않음
kbbs probe-send "방" --minimized   # 숨긴 창이 살아있는지
kbbs keys                    # 터미널이 실제로 보내는 바이트
kbbs inspect --depth 5       # AX 트리
kbbs --room "방" --why       # 발신자를 어떻게 판정했는지
```

로그는 `~/.kbbs/kbbs.log`.

## 빌드

```bash
make build      # swift build
make test       # 330개. 카카오톡도 권한도 필요 없다
make install    # ~/bin/kbbs, 고정 애드혹 서명
make lint-print # 일부러 지운 위험 코드가 돌아오면 실패
make release    # VERSION 올리고 커밋·태그
```

`.build/debug/kbbs` 말고 `~/bin/kbbs` 로 개발한다. macOS 는 손쉬운 사용 권한을
**바이너리와 서명 조합**으로 기억하는데 `swift build` 는 매번 바이너리를 다시 쓴다.
고정 경로와 고정 서명이 권한을 살려 둔다.

## 상태

`~/.kbbs/` — `kbbs.log` 한 개뿐이다. 자격증명도, 캐시도, 대화 내용도 저장하지 않는다.

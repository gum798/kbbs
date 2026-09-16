# kbbs 설계 — 하이텔 방식 카카오톡 터미널 단말

- 작성일: 2026-09-16
- 상태: 승인 대기
- 저장소: `~/project/kbbs` (`~/project/kmsg` 복사본, 이후 독립)

## 1. 무엇을 만드는가

카카오톡을 1990년대 한국 PC통신 단말기처럼 쓰는 macOS 터미널 앱.
전체화면 80×24, 이중선 박스, 번호 매긴 대화방 목록, `선택>` 프롬프트.
화살표로 커서를 움직이거나 방 번호를 직접 쳐서 고르고, Enter 로 들어가면
그 방의 대화가 보이고 아래 입력줄에서 답장을 쓴다.

### 범위

**만든다**

- 대화방 목록 (이름 · 마지막 대화 · 시각 · 안읽음 수 · 창 열림 여부)
- 대화 읽기 + 3초 주기 실시간 수신
- 메시지 보내기

**안 만든다**

검색, 이미지 전송, 파일 전송, 설정 화면, 스크롤백, 알림, 여러 방 동시 감시,
그리고 이 저장소가 kmsg 에서 물려받은 배포 기능 일체 (Homebrew, 자동 업데이트,
MCP 서버, 문서 사이트).

### 이 프로젝트가 kmsg 와 맺는 관계

kmsg 를 **복사해서** 만들었고 kmsg 는 건드리지 않는다. 두 저장소는 여기서부터
갈라진다. 카카오톡이 UI 를 바꾸면 양쪽이 각자 썩는다. 그 대가로 kmsg 는 무손상.

상태 파일도 분리한다 (`~/.kbbs/`). 같이 쓰면 안 되는 이유는 `AXPathCache` 가
락 없이 파일 전체를 덮어쓰기 때문이고 (AXPathCache.swift:245-250), 오래 떠 있는
TUI 가 낡은 메모리 사본을 들고 있다가 그 사이 실행된 kmsg CLI 의 기록을 날린다.

## 2. 설계를 지배하는 제약

전부 kmsg 소스를 읽어서 확인한 사실이다. 추측이 아니다.

### 2.1 전송의 마지막 Enter 는 전역 키보드 이벤트다 — 이게 이 프로젝트의 중심 문제

메시지 제출은 `pressKey(code: 36)` 을 `.cghidEventTap` 에 post 하는 것이다
(AXActionRunner.swift:160, :261-271). 이 Enter 는 **그 순간 최전면 앱**에 간다.
유일한 방어는 `kakao.activate()` 뒤의 `Thread.sleep(0.1)` 한 줄
(SendCommand.swift:262-264) 인데, activate 는 비동기이고 post 는 동기다.
100ms 는 보장이 아니라 경합이다.

텍스트를 넣는 것 자체는 포커스가 필요 없다 — `setAttribute(kAXValueAttribute, ...)`
(AXActionRunner.swift:95). **오직 Enter 만** 카카오톡이 최전면이어야 한다.

전체화면 TUI 는 정의상 자기가 최전면이다. 경합에 지면 사용자의 사적인 메시지가
자기 터미널 입력창에 찍히고 Enter 까지 주입된다. 그리고 원본 코드에는 포커스를
되돌리는 곳이 없다 — 복원되는 건 마우스 커서뿐이다 (AXActionRunner.swift:307-314).

### 2.2 기존 폴백은 데이터 유출 버그다

`forceTypeIntoChatWindow` (SendCommand.swift:467-480) 는 무조건 `return true` 로
끝나고, `typeTextWithVerification` 은 검증 요소가 nil 이면 즉시 true 를 반환한다
(AXActionRunner.swift:129-132). 그래서 호출부가 "✓ Message sent" 를 찍는다.
쌍둥이인 `pressEnterWithVerification` 은 더 나쁘다 — 같은 `guard let element else
{ return true }` 가 `pressKey(code: 36)` **뒤에** 있어서 (:152-155), 전역 Enter 를
쏘고 나서 아무것도 검증하지 않은 채 성공을 보고한다.

→ **셋 다 트리에서 삭제한다.** 바이너리에 없으면 샐 수 없다.

### 2.3 "보냄" 은 전송 함수로는 알 수 없다

성공 판정이 입력창이 비워졌는지로 이뤄지는데 (didEnterEffect, :331-337), 죽은 AX
핸들은 stringValue 가 nil → "" 로 강등되어 성공으로 채점된다 (:168). 게다가 현재
조건은 `after != before` 라서 카카오톡 리렌더나 IME 부산물도 성공이 된다.

### 2.4 푸시가 없다 — 전부 폴링이다

`AXObserver` / `kAXValueChangedNotification` 이 소스 전체에 0건.
모든 갱신은 전체 재순회다 (WatchCommand.swift:152-182).

### 2.5 모든 AX 호출이 동기 · `Thread.sleep` 기반 · 취소 불가

async 없음, Task 없음, 취소 토큰 없음, `Thread.sleep` 19곳.
공유 싱글턴 둘은 `@unchecked Sendable` 인데 내부는 동기화 없는 가변 상태다
(AXPathCache.swift:47-56, ChatIdentityRegistry.swift:20).

### 2.6 stdout/stderr/stdin 을 코어가 빼앗는다

`KakaoTalkAuthenticator.swift:136/:209/:636` 의 맨 `print()`,
`AccessibilityPermission.swift:56-69`, stderr 로 하드와이어된 트레이스 라이터
(AXActionRunner.swift:12-16), `PasswordPrompt` 의 `readLine()` +
`tcsetattr(STDIN_FILENO)` (:52, :74-91). `PasswordPrompt.canPrompt` 는 isatty 만
확인하는데 TUI 는 isatty 가 참이라 저 가드가 보호해 주지 않는다.

### 2.7 스크롤백이 없다

`AXScrollToVisible`, 스크롤바, 휠 이벤트 — 소스 전체에 0건.
카카오톡이 이미 그려놓은 것만 읽힌다.

### 2.8 메시지에 안정된 식별자가 없고, 중복 제거가 진짜 메시지를 지운다

지문 = 작성자 + 분 단위 시각 + 본문 (TranscriptReader.swift:1191).
같은 사람이 같은 분에 "ㅋㅋ" 를 두 번 보내면 하나가 사라진다.
호출 지점이 **두 곳**이다 — :379 (무조건 실행) 과 :607
(`extractFallbackMessages` 끝). 행 파서가 적게 뽑으면 (:373 조건) 폴백이 주
공급원이 되므로, :379 만 고치면 정작 문제되는 경로에서는 여전히 먹힌다.

### 2.9 발신자 판정은 기하학 추측이고 실패하면 "나" 가 된다

본문 프레임 가로비율 ≤0.56 왼쪽, ≥0.62 오른쪽, 사이는 `.unknown`
(TranscriptReader.swift:811-841). `.right` 와 `.unknown` 둘 다
`author == nil`, `source == "default-me"` 로 간다 (:852-854).

### 2.10 창 없는 방을 여는 건 불가피하게 시끄럽다

`openChatListRow` (ChatWindowResolver.swift:332-383) 는 activate + raise +
AXPress/select/Enter 를 하고, 행을 다시 찾으려고 200행 목록 스캔을 새로 돌리며
(:332-352), 폴백 하나는 화면 좌표에 **하드웨어 더블클릭**을 한다
(AXActionRunner.swift:277-315). 주석 (:273-276) 에 카카오톡 행이 AXPress 와 Enter
를 모두 무시하고 AXShowDefaultUI/AXShowAlternateUI 만 노출한다고 적혀 있다.

반대로 **창이 이미 있으면 전부 싸다** — `resolveExistingWindowOnly`
(:189-207) 는 AX 읽기 한 번 + 창당 제목 한 번, 수십 ms.

### 2.11 ⌘W 창닫기 폴백도 같은 전역 HID 패턴이다

ChatWindowResolver.swift:184-186. 경합에 지면 사용자 터미널 탭이 닫힌다.
→ **아예 연결하지 않는다.**

### 2.12 TCC 접근성 신뢰는 바이너리 단위다

kbbs 는 kmsg 와 별개로 권한을 받아야 한다. 그리고 `swift build` 는 매번 바이너리를
새로 쓴다. 고정 경로 + 고정 ad-hoc 서명 없이는 개발 루프가
편집 → 빌드 → 시스템 설정 → 재승인 → 재실행이 된다.

### 2.13 인증은 선택이고, TUI 안에서는 위험하다

`ReadCommand.swift:95-97` 이 `--background-safe` 에서 AuthBootstrap 을 통째로
건너뛰고도 전 경로가 동작함을 증명한다. 반면 `isAuthenticated()` 는 잠금 화면을
정상 창으로 받아들이고 (주석 :625-628), 암호를 여러 번 틀리면 카카오톡이 계정을
로그아웃시킨다 (:672-673).

→ **`Auth/` 를 통째로 삭제한다.** 위험을 관리하는 대신 제거한다.
   카카오톡에 로그인돼 있어야 kbbs 가 동작한다 — 그건 사용자가 한다.

## 3. 검증하지 않은 가정

사용자가 스파이크를 생략하고 최악을 전제하기로 결정했다. 나중에 뒤집히면
해당 부분만 재설계한다.

| # | 가정 | 뒤집히면 |
|---|------|---------|
| A1 | 입력창에 `AXConfirm` 이 없다 → 전송마다 카카오톡이 앞으로 나온다 | 포커스 게이트 · 자판 잠금 · 전송 밴드 · 실패 분류 절반, 약 200줄이 불필요해진다 |
| A2 | 가려지거나 최소화된 창은 AX 서브트리를 안 준다 | `*`/`-` 구분이 느슨해지고 `open_confirm` 게이트가 드물어진다 |
| A3 | 열린 방 3초, 목록 12초 폴링 | 따뜻한 읽기가 2초면 3초 주기는 5초로 올려야 한다 |
| A4 | 기록은 "카카오톡이 지금 그려둔 것" 까지 | — |

A1 은 아무도 시험한 적이 없다. `supportsAction` 이 SendCommand.swift:160 에
정의돼 있지만 kAXRaiseAction 에만 쓰인다 (:483). 입력창에는 한 번도 물어본 적 없다.

## 4. 화면

### 접속 사다리 (`boot`)

The dial ritual, printed in COOKED mode before termios is touched and before the alternate screen exists. This is deliberately the only place in the program where a bare print() is legal, which is what makes constraint 6 structural rather than a discipline: AccessibilityPermission's instructions, a missing KakaoTalk, and a revoked TCC grant all report here, on a normal terminal, and exit(1) without ever entering raw mode. Each dot-leader line is a real check with its real elapsed cost, so the theatre is also the smoke test — in a repo with no Swift test suite this ladder is how you find out the AX stack still works. Lines 4 and 5 report the two untested assumptions (A1 AXConfirm, A2 window readability) that were probed at Milestone 0, and line 6 reports the DSR-CPR ambiguous-width measurement.

```
KBBS  카카오톡 통신 단말기  v0.1.0   (c) 1994  seojeonghwa                      
                                                                                
ATZ                                                                             
OK                                                                              
ATDT 01410                                                                      
CONNECT 9600/ARQ/V32BIS/LAPM/V42BIS                                             
                                                                                
  ╔══════════════════════ 접  속 ══════════════════════╗                        
  ║           K B B S  ·  카카오톡 통신 서비스         ║                        
  ║              하이텔 호환 모드   80 x 24            ║                        
  ╚════════════════════════════════════════════════════╝                        
                                                                                
 손쉬운 사용 권한 (kbbs 바이너리) .......................... 확인               
 카카오톡 실행 ................................... 확인  PID 1421               
 대화목록 창 ................................. 확인  「카카오톡」               
 입력창 AXConfirm 지원 조사 .................... 없음 → 전환 방식               
 문자폭 측정 (▶ ● ○ ─ 등) .............................. 좁게 1칸               
 대화방 목록 읽기 ................................... 27개  1.9초               
                                                                                
 ※ 잠금 화면은 건드리지 않습니다. 암호를 여러 번 틀리면 계정이 로그아웃됩니다.  
 ※ 전송할 때만 카카오톡이 잠깐 앞으로 나옵니다. 그동안 자판이 잠깁니다.         
                                                                                
 접속되었습니다.  아무 키나 누르십시오… _
```

**키:** Any key enters raw mode + the alternate screen and goes to `rooms`. Q or Ctrl-C exits with status 0 before termios is ever touched — there is nothing to restore. If any dot-leader reports 실패 the line renders in red, the trailing prompt becomes ' 계속할 수 없습니다. 아무 키나 누르면 종료합니다.', and any key exits 1. The Accessibility line is the hard gate: on denial it prints the rewritten instructions naming the kbbs binary's own absolute path (from CommandLine.arguments[0]) plus the reminder that the kmsg grant does not carry over, then exits. No other key is read; the terminal is still in cooked mode throughout.

### 대화방 목록 — 유일한 진입 화면 (`rooms`)

The board index — the only entry screen. 13 rooms per page, ▶ cursor, and a 선택> number buffer that the cursor mirrors so the screen always tells the truth about what Enter will do. Column 7 is the cost disclosure and the most important affordance in the product: `*` means KakaoTalk already has a window for this room, so entering is ~1 AX read plus one title read per window (tens of ms, silent); `-` means entering costs a disruptive foreground grab and will ask first. 시각 and 안읽 are read from nodes ChatListScanner already walks and currently discards. Row 4 shows the truncation case no designer drew — a long Korean group name clipped at 20 cells on a grapheme boundary, never mid-wide-cell.

```
╔══════════════════════════════════════════════════════════════════════════════╗
║  K B B S   카카오톡 통신                              1994-03-17 (목) 21:04  ║
╠══════════════════════════════════════════════════════════════════════════════╣
║ 번호   대화방               마지막 대화                            시각 안읽 ║
╠══════════════════════════════════════════════════════════════════════════════╣
║ ▶ 1. * 김민수               내일 몇 시에 봐요?                     21:03   2 ║
║   2. * 개발팀               빌드 깨졌어요 확인 부탁드립니다        20:58  14 ║
║   3. - 어머니               밥은 먹었니                            20:31     ║
║   4. - 고등학교 3학년 2반 … [사진]                                 20:12   3 ║
║   5. - 박지훈               ㅋㅋㅋㅋㅋ                             19:44     ║
║   6. - 회사 공지방          금요일 전사 워크샵 안내드립니다        18:02     ║
║   7. - Claude Code 스터디   다음 주 발표 자료 공유드려요           17:20   1 ║
║   8. - 이수진               네 알겠습니다                           어제     ║
║   9. - 가족방               이번 주말에 내려갈게요                  어제     ║
║  10. - 최영호               감사합니다!                             어제     ║
║  11. - 점심 메뉴 추천방     오늘은 국밥                              3일     ║
║  12. - 정은지               링크 보냈어요                            3일     ║
║  13. - 동아리 번개          다들 시간 되시나요                       4일     ║
╠══════════════════════════════════════════════════════════════════════════════╣
║  전체 27개 / 1-13 (1/3 쪽) / 갱신 21:04:02 / *=창열림 -=창없음     [접속중]  ║
╠══════════════════════════════════════════════════════════════════════════════╣
║  P:이전  N:다음  R:새로고침  Q:종료                                          ║
║                                                    선택> 2_                  ║
╚══════════════════════════════════════════════════════════════════════════════╝
```

**키:** ↑/k and ↓/j move ▶ one row and CLEAR the 선택> buffer; at a page edge they turn the page and land on the last/first row. 0-9 append to the buffer (max 3 digits) and, as a live preview, move ▶ to that room if it is on the current page; if it is not, ▶ stays put and the status badge shows the target's page. The buffer clears after 3s idle — it never auto-commits, so typing '1' on the way to '12' cannot drop you into room 1. Backspace/DEL pops a digit. Esc clears the buffer. Enter: if the buffer is non-empty, that absolute room number wins (numbers are absolute across pages — room 16 is typed as '16' on any page; out of range flashes '그런 방은 없습니다' and clears); otherwise the ▶ row wins. A `*` room goes straight to `room`; a `-` room goes to `open_confirm`. P/p/PageUp and N/n/PageDown page by 13 with wraparound, clear the buffer, and put ▶ on the first row of the new page; the status line's '1-13 (1/3 쪽)' updates and a partial last page (rows 27-27) renders its remaining slots blank, not padded with placeholders. R/r forces an immediate rescan and resets the 12s timer; refused with a '[대기중]' badge flash while the AX queue is busy. Q/q and Ctrl-C restore the terminal and exit. Ctrl-L forces a full repaint. Any other key flashes the badge to '[?]' for 300ms, no BEL.

### 창 열기 동의 게이트 (`open_confirm`)

The consent gate for constraint 10, drawn as an inner single-line box over the list so the user keeps their place. The only working open path in the source ends in a hardware double-click at screen coordinates — the in-source comment at AXActionRunner.swift:273-276 records that KakaoTalk rows ignore both AXPress and Enter — and that is never fired implicitly. The text names every consequence including the mouse pointer, and Enter is deliberately NOT bound so a double-Enter from the list cannot roll through the gate.

```
╔══════════════════════════════════════════════════════════════════════════════╗
║  K B B S   카카오톡 통신                              1994-03-17 (목) 21:04  ║
╠══════════════════════════════════════════════════════════════════════════════╣
║ 번호   대화방               마지막 대화                            시각 안읽 ║
╠══════════════════════════════════════════════════════════════════════════════╣
║   1. * 김민수               내일 몇 시에 봐요?                     21:03   2 ║
║   2. * 개발팀               빌드 깨졌어요 확인 부탁드립니다        20:58  14 ║
║ ▶ 3. - 어머니               밥은 먹었니                            20:31     ║
║   4. - 고등학교 3학년 2반 … [사진]                                 20:12   3 ║
║ ┌──────────────────────────────────────────────────────────────────────────┐ ║
║ │ [주의] "어머니" 방은 카카오톡에 열린 창이 없습니다.                      │ ║
║ │                                                                          │ ║
║ │ 창을 열려면 카카오톡이 앞으로 나와서, 목록의 해당 줄을 자동으로 두 번    │ ║
║ │ 누릅니다. 그동안 마우스와 키보드를 건드리지 마세요. 카카오톡 채팅        │ ║
║ │ 목록 창이 가려져 있으면 실패합니다. 실패해도 메시지는 보내지 않습니다.   │ ║
║ │                                                                          │ ║
║ │   Y = 카카오톡에서 창 열기            N / Esc = 취소하고 목록으로        │ ║
║ └──────────────────────────────────────────────────────────────────────────┘ ║
╠══════════════════════════════════════════════════════════════════════════════╣
║  전체 27개 / 1-13 (1/3 쪽) / 갱신 21:04:02                    [확인 대기중]  ║
╠══════════════════════════════════════════════════════════════════════════════╣
║  Y:열기   N/Esc:취소                                                         ║
║                                                    선택> _                   ║
╚══════════════════════════════════════════════════════════════════════════════╝
```

**키:** Y/y commits: keys lock, the box title becomes '창 여는 중' and its body becomes a four-step dot ladder (전면 전환 / 행 좌표 확인 / 두 번 누르기 / 창 대기). The job uses the LIVE row handle already held from ChatListScanner.scan — it does NOT re-run ChatWindowResolver's 200-row rescan (:332-352) just to relocate a row it already has. It guards that the row's AX frame is non-empty and intersects a visible NSScreen, re-reads the frame immediately before clicking, posts one mouseDoubleClick, polls kakao.windows for a title match for ≤2500ms, then reactivates the terminal and tcflush(STDIN_FILENO, TCIFLUSH). Success → `room`. Any guard failure → the box becomes '[실패] 창을 열지 못했습니다. 카카오톡에서 직접 방을 여신 뒤 R 을 누르세요.' with only Esc and R live. N/n/Esc dismisses. Enter is unbound. Ctrl-C restores the terminal and exits even mid-click. Every other key is read and discarded.

### 대화 화면 (`room`)

The conversation — one panel, full screen, replacing the list. Body row 1 is the end-of-tape rule, which is not a scroll position but the literal edge of what KakaoTalk has rendered and therefore the edge of what can ever be read (constraint 7); it is permanent, not a transient warning. Two identical 'ㅋㅋ' at 21:02 both render, because the content dedup that would have eaten them is removed at BOTH :379 and :607. `나?` with the ↑ annotation is the visible form of constraint 9: the geometry guess returned .unknown, the row is still author==nil internally so overlap matching is unaffected, but the user is never told they said something they did not. The two-line notice band below the transcript is the same band the send states reuse, which is why no layout engine is needed — every screen in this family has identical row indices.

```
╔══════════════════════════════════════════════════════════════════════════════╗
║  [ 김민수 ]                                           1994-03-17 (목) 21:06  ║
╠══════════════════════════════════════════════════════════════════════════════╣
║ ──────────────── 여기까지가 카카오톡에 남아 있는 전부입니다 ──────────────── ║
║ 21:01 김민수     │ 형 내일 시간 돼요?                                        ║
║ 21:01 나         │ 응 괜찮아                                                 ║
║ 21:02 김민수     │ ㅋㅋ                                                      ║
║ 21:02 김민수     │ ㅋㅋ                                                      ║
║ 21:02 김민수     │ 그럼 강남역 11번 출구 앞에서 봐요 저번에 갔던 그 국밥집   ║
║                  │ 근처예요 지도 링크 보낼게요                        [링크] ║
║ 21:03 나         │ ㅇㅋ 11시쯤?                                              ║
║ 21:03 나?        │ 넵                                                        ║
║                  │ ↑ 화면 위치로만 추정한 발신자입니다                       ║
║ 21:03 김민수     │ 내일 몇 시에 봐요?                                        ║
║ 21:06 나         │ 11시에 보자                                      [전송중] ║
║                                                                              ║
╠══════════════════════════════════════════════════════════════════════════════╣
║  ●○○ 회선감시 3초주기 · 다음 갱신 1.8초 · 새 글 2통 · 창 살아있음            ║
║                                                                              ║
╠══════════════════════════════════════════════════════════════════════════════╣
║ 입력> 알겠어요 그때 봬요_                                                    ║
╠══════════════════════════════════════════════════════════════════════════════╣
║  Enter:전송  Esc:목록  R:새로고침(입력창 비었을 때)  Q:종료   갱신 21:06:04  ║
╚══════════════════════════════════════════════════════════════════════════════╝
```

**키:** Printable UTF-8, including Hangul syllables assembled by the terminal IME, inserts at the composer caret; the composer scrolls horizontally by display columns once past 70 cells, always keeping the `_` caret visible, with the caret column computed by Width.cells over grapheme clusters. Backspace/DEL deletes one grapheme cluster — a Hangul syllable dies whole, never by scalar. ←/→ move by grapheme cluster. Ctrl-A/Home and Ctrl-E/End jump to the edges. Ctrl-U clears the composer, Ctrl-W deletes the previous word. Hard cap 300 codepoints; further bytes are dropped and the ticker flashes '300자까지'. Enter with a non-empty composer enters the send machine at S1; Enter with an empty composer does nothing (no accidental empty send). R/r, Q/q and P/N are bound ONLY when the composer is empty — otherwise they are letters, which is why the hotkey row says so out loud. Esc always returns to `rooms`: it bumps the AX generation so any in-flight read for this room is discarded on arrival, and keeps the composer text in memory keyed by room title for restoration on re-entry. It does NOT close the KakaoTalk window — kbbs has no code that can. Ctrl-C always quits. Ctrl-L repaints. ●○○ animates at 3Hz from the 100ms main-loop tick, so it is proof the UI is alive even while a 2-second AX call is blocked on the worker.

### 전송 중 (`sending`)

The danger window, and the only moment in the program where the keyboard is not the user's. Same frame as `room`; only the notice band, the composer label and the hotkey row change — no full-screen takeover, because a modal that replaces the transcript hides the very context the user needs if something goes wrong. The five steps are the real state machine, not decoration: step 1 is the DIRTY precheck grafted from 전표, step 2 is the AXValue injection which needs no focus and steals nothing, and only steps 3-4 are dangerous. The elapsed/ceiling counter advances on the 100ms tick so an uncancellable AX call visibly remains alive.

```
╔══════════════════════════════════════════════════════════════════════════════╗
║  [ 김민수 ]                                           1994-03-17 (목) 21:06  ║
╠══════════════════════════════════════════════════════════════════════════════╣
║ ──────────────── 여기까지가 카카오톡에 남아 있는 전부입니다 ──────────────── ║
║ 21:01 김민수     │ 형 내일 시간 돼요?                                        ║
║ 21:01 나         │ 응 괜찮아                                                 ║
║ 21:02 김민수     │ ㅋㅋ                                                      ║
║ 21:02 김민수     │ ㅋㅋ                                                      ║
║ 21:02 김민수     │ 그럼 강남역 11번 출구 앞에서 봐요 저번에 갔던 그 국밥집   ║
║                  │ 근처예요 지도 링크 보낼게요                        [링크] ║
║ 21:03 나         │ ㅇㅋ 11시쯤?                                              ║
║ 21:03 나?        │ 넵                                                        ║
║                  │ ↑ 화면 위치로만 추정한 발신자입니다                       ║
║ 21:03 김민수     │ 내일 몇 시에 봐요?                                        ║
║ 21:06 나         │ 11시에 보자                                      [전송중] ║
║                                                                              ║
╠══════════════════════════════════════════════════════════════════════════════╣
║  [2/5] 카카오톡을 앞으로 가져오는 중 ......  0.6초 / 최대 1.2초              ║
║  1.검사 [완료]  2.기록 [완료]  3.전환 [진행]  4.Enter [대기]  5.확인 [대기]  ║
╠══════════════════════════════════════════════════════════════════════════════╣
║ 보낼 내용> 알겠어요 그때 봬요            << 자판 잠김 - 손을 떼 주세요 >>    ║
╠══════════════════════════════════════════════════════════════════════════════╣
║  Ctrl-C:강제 종료(터미널은 복구됩니다)                       [전송 진행 중]  ║
╚══════════════════════════════════════════════════════════════════════════════╝
```

**키:** Every byte is read off the fd and discarded — reading rather than ignoring, so the tty buffer cannot fill and so that CGEvent keystrokes delivered to the terminal instead of KakaoTalk are consumed rather than queued for replay. The single exception is 0x03 (Ctrl-C), which sets a flag the main loop services within 100ms: it restores termios, leaves the alternate screen, shows the cursor and exit(0) without joining the AX worker. It cannot cancel the in-flight AX call — nothing can — and the screen does not pretend otherwise. tcflush(TCIFLUSH) runs immediately before step 3 and again after step 5, so anything injected into the tty during the foreground flip is thrown away rather than interpreted. The lock is set on the MAIN thread before the job is submitted and cleared on the main thread after restore, so there is no window in which the job is running and the keyboard is live. Past 2.0s the badge becomes '[응답 느림]'; past 6.0s it becomes '[카카오톡 응답 없음 6초]' and the first notice line reads '취소할 수 없습니다. 기다리거나 Ctrl-C 로 종료하세요.'

### 오염 — 카카오톡 입력창에 남의 글자가 있음 (`dirty`)

The grafted 전표 stop, and the reason a lost race cannot send somebody else's half-typed sentence. Step 1 of the send machine read KakaoTalk's composer and found text KBBS did not write — the user typed directly into KakaoTalk, or a previous send was interrupted, or an IME preedit is sitting there. Firing Return now would send that text first. KBBS does not delete text it did not write; it shows it and waits.

```
╔══════════════════════════════════════════════════════════════════════════════╗
║  [ 김민수 ]                                           1994-03-17 (목) 21:06  ║
╠══════════════════════════════════════════════════════════════════════════════╣
║ ──────────────── 여기까지가 카카오톡에 남아 있는 전부입니다 ──────────────── ║
║ 21:01 김민수     │ 형 내일 시간 돼요?                                        ║
║ 21:01 나         │ 응 괜찮아                                                 ║
║ 21:02 김민수     │ ㅋㅋ                                                      ║
║ 21:02 김민수     │ ㅋㅋ                                                      ║
║ 21:02 김민수     │ 그럼 강남역 11번 출구 앞에서 봐요 저번에 갔던 그 국밥집   ║
║                  │ 근처예요 지도 링크 보낼게요                        [링크] ║
║ 21:03 나         │ ㅇㅋ 11시쯤?                                              ║
║ 21:03 나?        │ 넵                                                        ║
║                  │ ↑ 화면 위치로만 추정한 발신자입니다                       ║
║ 21:03 김민수     │ 내일 몇 시에 봐요?                                        ║
║                                                                              ║
║                                                                              ║
╠══════════════════════════════════════════════════════════════════════════════╣
║  [중단] 카카오톡 입력창에 KBBS 가 쓰지 않은 글자가 남아 있습니다.            ║
║   남은 글자 │ 아니 그게 아니라                 Enter 는 보내지 않았습니다.   ║
╠══════════════════════════════════════════════════════════════════════════════╣
║ 입력> 알겠어요 그때 봬요_                                                    ║
╠══════════════════════════════════════════════════════════════════════════════╣
║  C:입력창 비우고 재시도   Esc:취소(그대로 둠)   Q:종료          [전송 중단]  ║
╚══════════════════════════════════════════════════════════════════════════════╝
```

**키:** C/c clears the KakaoTalk input box by setAttribute(kAXValueAttribute, "") — no ⌘A, no keystrokes, no focus change — verifies it reads back trimmed-empty across two reads 60ms apart, and restarts the send machine at S1. Esc cancels and returns to `room` with our draft intact and the residual KakaoTalk text left exactly as found. Q/q and Ctrl-C quit. Every other key is swallowed. This same band, with '남은 글자' replaced by '글자 수가 맞지 않습니다 (입력 중인 한글이 남아 있을 수 있습니다)', is what the IME-preedit guard raises when kAXNumberOfCharacters disagrees with the injected body's length. It is also reachable from the post-Return verify when residual text appears after the fact, in which case the pending line is already marked 미확인 and C only cleans up.

### 확인 불가 (`failed`)

Every terminal failure lands in this band. The rule is that the text must state exactly what state the world is in: whether Return was posted, whether the message is sitting in KakaoTalk's composer, and whether it may already have gone out. The draft is never destroyed. The variant shown is the only genuinely unknowable one — Return went out and the composer could not be proven empty with a live handle — and it is the one case where Enter is disabled, because retrying could double-send a message that may already have delivered. The string '전송 완료' does not exist in the binary; a message only loses its [전송중] marker when a later 3-second poll re-reads it out of KakaoTalk's own transcript.

```
╔══════════════════════════════════════════════════════════════════════════════╗
║  [ 김민수 ]                                           1994-03-17 (목) 21:06  ║
╠══════════════════════════════════════════════════════════════════════════════╣
║ ──────────────── 여기까지가 카카오톡에 남아 있는 전부입니다 ──────────────── ║
║ 21:01 김민수     │ 형 내일 시간 돼요?                                        ║
║ 21:01 나         │ 응 괜찮아                                                 ║
║ 21:02 김민수     │ ㅋㅋ                                                      ║
║ 21:02 김민수     │ ㅋㅋ                                                      ║
║ 21:02 김민수     │ 그럼 강남역 11번 출구 앞에서 봐요 저번에 갔던 그 국밥집   ║
║                  │ 근처예요 지도 링크 보낼게요                        [링크] ║
║ 21:03 나         │ ㅇㅋ 11시쯤?                                              ║
║ 21:03 나?        │ 넵                                                        ║
║                  │ ↑ 화면 위치로만 추정한 발신자입니다                       ║
║ 21:03 김민수     │ 내일 몇 시에 봐요?                                        ║
║ 21:06 나         │ 11시에 보자                                      [미확인] ║
║                                                                              ║
╠══════════════════════════════════════════════════════════════════════════════╣
║  [확인불가] Enter 는 보냈지만 입력창이 비워졌는지 확인하지 못했습니다.       ║
║  보내졌을 수도 있습니다. 카카오톡에서 직접 확인하세요. 다시 보내지 않습니다. ║
╠══════════════════════════════════════════════════════════════════════════════╣
║ 입력> _                                                                      ║
╠══════════════════════════════════════════════════════════════════════════════╣
║  Esc:확인  R:새로고침  Q:종료                               [전송 확인불가]  ║
╚══════════════════════════════════════════════════════════════════════════════╝
```

**키:** In the shown 확인불가 variant: Enter is DISABLED, R/r forces an immediate transcript re-read (the fastest way to find out what actually happened; a late match still upgrades the line and clears [미확인]), Esc dismisses the band leaving the [미확인] marker in the transcript for the rest of the session, Q quits. In every other variant Enter retries from S1 with the same body, because nothing was posted. The four other texts are: '[실패] 카카오톡 입력창에 문구를 기록하지 못했습니다. 아무것도 보내지 않았습니다.' (injection never reflected — the most common failure and completely safe, nothing left anywhere); '[실패] 카카오톡이 1.2초 안에 앞으로 나오지 않았습니다. Enter 는 보내지 않았고, 넣었던 문구는 지웠습니다.'; '[실패] Enter 를 보내기 직전에 카카오톡이 앞이 아니었습니다 / 다른 창이 앞에 있었습니다. 보내지 않았습니다.'; '[실패] 대화 창을 놓쳤습니다. Esc 로 목록에 돌아가 다시 여세요.' A 미확인 body is also written once to ~/.kbbs/last-unconfirmed.txt so a crash cannot lose a paragraph the user typed.

### 통신 두절 (`blocked`)

One screen for every way reading can stop: KakaoTalk auto-locked (constraint 13), the room's window minimized or fully occluded (A2), the app quit, the TCC grant revoked mid-session, or three consecutive transcript reads failing. Without it a long-running TUI silently shows an empty chat forever, because isAuthenticated() accepts a lock screen as a usable window — and kbbs cannot be fooled by that particular function because the whole Auth/ directory is deleted and the function does not exist in the binary. It therefore cannot type a passcode and cannot trigger the repeated-wrong-password force-logout at KakaoTalkAuthenticator.swift:672-673, and it says so.

```
╔══════════════════════════════════════════════════════════════════════════════╗
║  K B B S   카카오톡 통신                              1994-03-17 (목) 21:07  ║
╠══════════════════════════════════════════════════════════════════════════════╣
║                                                                              ║
║        ██  ██  ██████   ██████   ██████                                      ║
║        ██ ██   ██   ██  ██   ██  ██   ██      통  신  두  절                 ║
║        ████    ██████   ██████   ██████                                      ║
║        ██ ██   ██   ██  ██   ██  ██   ██                                     ║
║        ██  ██  ██████   ██████   ██████                                      ║
║                                                                              ║
║   카카오톡 창을 읽을 수 없습니다.  (마지막 정상 수신 21:04:02)               ║
║   원인 후보                                                                  ║
║     - 카카오톡이 자동 잠금 상태입니다                                        ║
║     - 카카오톡 창이 최소화되었거나 다른 창에 완전히 가려져 있습니다          ║
║     - 카카오톡이 종료되었습니다                                              ║
║     - 손쉬운 사용 권한이 회수되었습니다                                      ║
║                                                                              ║
║   KBBS 는 암호를 대신 입력하지 않습니다. 여러 번 틀리면 카카오톡이           ║
║   계정을 로그아웃시키기 때문입니다. 잠금 해제는 직접 해주세요.               ║
║                                                                              ║
╠══════════════════════════════════════════════════════════════════════════════╣
║  ●○○ 12초마다 자동 재시도 · 다음 시도 8초 후                    [두절 40초]  ║
║  R:지금 재시도   Esc:목록으로   Q:종료                                       ║
╚══════════════════════════════════════════════════════════════════════════════╝
```

**키:** R/r retries immediately and resets the backoff to 3s: rebuild KakaoTalkApp, rescan windows, re-resolve the MessageTranscriptContext for the last room (a lock/unlock cycle almost certainly invalidated the cached handles). Esc returns to `rooms` — the list is often still readable when one room's window is gone; if the list is also unreadable, this screen re-arms with the list-level message. Q/q and Ctrl-C restore the terminal and exit. Every other key is swallowed, notably Enter and all printable characters, so a user cannot compose a message into a room that has nowhere to send it. The screen also auto-retries on the 12s tick and, on the first healthy probe, returns to whichever screen the user was on with the cursor and draft intact. The '손쉬운 사용 권한이 회수되었습니다' variant cannot recover and offers only Q.

## 5. 전송 상태 기계

Owned by App/Send.swift as one value + driver. States: `idle | armed | precheck | injecting | focusing(startedAt, prevPID) | posting(prevPID) | verifying(startedAt, prevPID) | restoring(prevPID, next) | pending(body, since, polls) | dirty(residual) | failed(Reason)`. Exactly one instance exists process-wide; a second send is impossible because the keys are locked, so there is no outbox and no queue. `Reason = {inputDirty, imeUnstable, injectNotReflected, focusTimeout, notFrontmost, wrongWindow, bodyMutated, enterNoEffect, contextLost}`.

Everything from `precheck` through `restoring` executes inside ONE job on the single serial AX queue. It cannot be split: a poll interleaved between activation and the Return would be catastrophic. After each step the job publishes a `SendStep{index, label, elapsed}` into the mailbox and the main thread repaints the two-line notice band on the next 100ms tick.

--- idle ---
Composer editable. Enter with non-empty trimmed text and the room title NOT in `confirmedRooms` → `armed`. Otherwise → `precheck` directly.

--- armed (one frame, main thread, keys NOT locked) ---
Notice band reads '전송하면 카카오톡이 잠시 앞으로 나옵니다. Enter=전송  Esc=취소'. Asked once per room per session; Enter inserts the title into confirmedRooms and proceeds, Esc returns to idle. Nothing has touched AX.

--- S1 precheck (AX queue, ~80-300ms) — ladder step 1/5 검사 ---
Keys lock on the MAIN thread before the job is submitted, so there is no window in which the job runs and the keyboard is live. Then:
  p1 context alive: `ctx.inputElement.role != nil` and `chatWindow.title != nil`. Either nil → drop the cache, re-resolve MessageContextResolver(interactionMode: .backgroundSafe).resolve(in: window) ONCE. Second failure → failed(.contextLost).
  p2 window identity: scoreQueryMatch(room.title, chatWindow.title) > 0, else failed(.contextLost). Catches KakaoTalk reusing the window for another chat.
  p3 DIRTY + IME guard (grafted from 전표, extended for the preedit hole no design covered): read `v1 = inputElement.stringValue ?? ""`; sleep 60ms; read `v2` and `n = inputElement.numberOfCharacters`. If `v1.trimmed` is non-empty → dirty(v1). If `v1 != v2` → failed(.imeUnstable) with the dirty band's IME text, because a value changing under us with no keystrokes means a composition is in flight. If `n` disagrees with `v1.utf16.count` → failed(.imeUnstable) likewise: kAXValue does not expose an uncommitted Hangul syllable, and this is the only cheap signal that one exists.
  p4 baseline: capture `baselineTail` = the last 40 normalized bodies from the most recent poll snapshot, with occurrence counts. Read failure is non-fatal but marks the transaction evidence-degraded.

--- S2 injecting (AX queue) — ladder step 2/5 기록 ---
  `runner.setTextWithVerification(body, on: ctx.inputElement, label: "composer", attempts: 2)`. Pure `setAttribute(kAXValueAttribute, ...)` (AXActionRunner.swift:95). NEEDS NO FOCUS, POSTS NO HID EVENT, DOES NOT MOVE THE FRONTMOST APP. The terminal is still frontmost; nothing has flashed and nothing has leaked. There is no `typeTextWithVerification` fallback and no `forceTypeIntoChatWindow` — both are deleted from the tree.
  false → failed(.injectNotReflected). Nothing was posted anywhere; the composer keeps the draft. This is the most common failure and it is completely safe.
  true → INDEPENDENT STRICT VERIFY (grafted from 전표): re-read stringValue and require exact `String ==`, NOT the source's `isInputReflected` which accepts `current.contains(expected)` (AXActionRunner.swift:317-320). A loose match would accept a dirty box that happens to hold our text as a substring. Mismatch → clear via setAttribute(""), verify empty, failed(.injectNotReflected).
  → focusing. We now hold positive, strictly-equal, read-back-out-of-KakaoTalk proof that exactly our text is in its composer and nowhere else.

--- S3 focusing (AX queue, budget 1200ms) — ladder step 3/5 전환 ---
  f1 `prevPID = SystemFocusProbe.focusedApplicationPID()` — AXUIElementCreateSystemWide → kAXFocusedApplicationAttribute → kAXPIDAttribute, NOT NSWorkspace.frontmostApplication, which is KVO-backed and can be stale in a process that never pumps a run loop (grafted from 선접속).
  f2 `tcflush(ttyFD, TCIFLUSH)`.
  f3 `kakao.activateForSend()`.
  f4 GATE LOOP, 25ms tick, 1200ms deadline. This replaces SendCommand.swift:263's blind `Thread.sleep(0.1)` — the 100ms sleep IS the race, and it is gone. Require, for TWO consecutive ticks (50ms stable):
       g1 SystemFocusProbe.focusedApplicationPID() == kakaoPID
       g2 kakao.focusedWindow?.title matches the target room title (guards a Return landing in the chat-list window or a different room — the gap 하이텔 left open)
     Deadline exceeded → cleanup path below, failed(.focusTimeout) or failed(.wrongWindow).
  f5 `if !inputElement.isFocused { focusWithVerification(inputElement, attempts: 1) }` — an AX attribute write, not a keystroke. Still unfocused → cleanup, failed(.notFrontmost). A Return posted while the composer is not key fires the window's default action instead of sending.
  CLEANUP PATH (every failure from S3 onward that has not yet posted): setAttribute(kAXValue, "") on the input element, verify it reads back trimmed-empty across 2 attempts 80ms apart, then re-activate prevPID. If the clear cannot be verified, the failure band adds '카카오톡 입력창에 문구가 남아 있을 수 있습니다' and offers C.

--- S4 posting (AX queue) — ladder step 4/5 Enter ---
  Executed with nothing between the guards and the post:
  a1 `guard SystemFocusProbe.focusedApplicationPID() == kakaoPID else → cleanup, failed(.notFrontmost)`
  a2 `guard strictEqual(inputElement.stringValue, body) else → cleanup, failed(.bodyMutated)` — the user typed into KakaoTalk during activation.
  a3 `runner.pressEnterKey()` — exactly one `pressKey(code: 36)` to `.cghidEventTap`. THE MECHANISM IS UNCHANGED; only what surrounds it changed.
  a4 immediately re-read the focused pid into `postPID`.
  NO RETRY, EVER. SendCommand's quick-retry arm posts a SECOND Return; on this path that is a duplicate message in a real chat and a second focus flip.
  The irreducible race is now the handful of Swift instructions between a1 and a3, not 100ms of sleep. If `postPID != kakaoPID` the frontmost changed across the post and even a positive S5 is downgraded to 미확인.

--- S5 verifying (AX queue, 900ms @ 60ms) — ladder step 5/5 확인 ---
  Success requires BOTH, every tick:
   (1) the read is NON-NIL. A dead AX handle reads nil→"" and scores as success at AXActionRunner.swift:168; here it is a FAILURE.
   (2) the value trimmed of whitespace is EMPTY.
  `after != before`, which didEnterEffect (:331-337) accepts and which a KakaoTalk re-render or an IME artefact satisfies, is explicitly REJECTED.
  drained → restoring(next: .pending).  contaminated (non-empty and != body) → restoring(next: .dirty(residual)).  timeout or handle died → restoring(next: .failed(.enterNoEffect)).
  If postPID != kakaoPID, the drained signal alone is not accepted: outcome is forced to .failed(.enterNoEffect) and only a transcript match can clear it.

--- S6 restoring (AX queue, always runs) ---
  `NSRunningApplication(processIdentifier: prevPID)?.activate(options: [])`, then poll SystemFocusProbe up to 800ms for prevPID. The copied core restores only the mouse cursor (AXActionRunner.swift:307-314) and never the keyboard focus; this step is what makes a full-screen TUI survivable. On timeout the ticker shows '단말 복귀 실패 — 이 창을 눌러 주십시오' and the first byte arriving on stdin is swallowed as proof-of-focus. Then, on the MAIN thread: `tcflush(STDIN_FILENO, TCIFLUSH)`, reset the UTF-8 and CSI decoders, unlock keys, transition to `next`.

--- pending(body, since, polls) — THE ONLY PATH TO "SENT" ---
  The composer clears and the transcript renders a LOCAL echo line: `21:06 나  │ 11시에 보자   [전송중]`. This is rendered from App state, not from the transcript, and it is not a claim that anything was delivered.
  On each subsequent 3s poll, `WatchPollingState.consume` returns the newly appended messages. A pending line is promoted when an emitted message satisfies ALL of: `normalizeForDiff(m.body) == normalizeForDiff(p.body)`, `m.author == nil` (it must be a me-attributed row — and because the .unknown case still carries author==nil while exposing `side`/`authorSource` separately, this test is unchanged by the attribution graft), and `abs(m.logicalTimestamp ?? pollTime - p.since) <= 120s`. Matching is FIFO over the pending list and COUNT-AWARE against `baselineTail`, so sending 'ㅋㅋ' into a room that already contains 'ㅋㅋ' still resolves correctly. On promotion the echo is dropped and the real transcript row takes its place with the marker gone.
  `polls == 3` (~9s) with no match → the marker becomes [미확인] and the failure band opens. A [미확인] line keeps trying to match for 5 more minutes; a late match still promotes it. It is NEVER auto-resent and never silently dropped, and its body is written once to ~/.kbbs/last-unconfirmed.txt.

--- dirty(residual) / failed(reason) ---
  dirty → the 오염 band. C clears (verified) and restarts at S1; Esc cancels leaving the residual untouched.
  failed → the failure band with the exact reason text. The body is restored verbatim into the composer and never cleared. Enter retries from S1 for every reason EXCEPT .enterNoEffect, where Enter is disabled because a retry could double-send.

--- KEY LOCKOUT, PRECISELY ---
`InputMode { list, room, compose, modal(Set<Key>), locked }`. In `.locked`, Input.poll() still calls read() every tick and discards the bytes — this prevents the tty buffer filling AND eats CGEvent keystrokes delivered to us instead of KakaoTalk — except 0x03. Set on the main thread before the job is submitted, cleared on the main thread after S6. tcflush at f2 and S6 bounds the damage to bytes arriving strictly between the two flushes, all of which are discarded anyway.

--- SIGNALS ---
Ctrl-C or SIGTERM in any state: the handler writes only a sig_atomic_t; the main loop notices within 100ms, restores the terminal and exit(0) without joining the AX worker. If a send was between S4 and S6 the exit path prints one plain line to the restored tty: '전송 결과 미확인: 카카오톡에서 확인하세요' plus the body. A crash (SIGSEGV/SIGBUS/SIGILL/SIGABRT) runs the async-signal-safe restore and re-raises.

## 6. 동시성

TWO THREADS, ONE SERIAL QUEUE, ZERO LOCKS ON AX STATE. No async/await, no Task, no actors — the copied core is entirely synchronous with 44 `Thread.sleep` sites (I counted; the brief said ~19), and wrapping it in Tasks would create cancellation points that cannot cancel anything, which is precisely the false-certainty failure this design exists to prevent.

MAIN THREAD owns 100% of the model, 100% of rendering, and nothing else. It never makes an Accessibility call — not one, not even `kakao.windows` — and never touches NSWorkspace. Each iteration: (1) `poll(&pollfd{ttyFD, POLLIN}, 1, 100)` — the 100ms timeout is the heartbeat and the only sleep on this thread; (2) if readable, read available bytes into the UTF-8 + CSI accumulator and dispatch complete keys; (3) service the SIGWINCH flag; (4) drain the mailbox; (5) check the two timers and enqueue at most one AX job if the queue is idle; (6) if anything changed, compose 24 strings and flush. Worst-case key-to-echo latency is 100ms regardless of what AX is doing. The clock, the ●○○ indicator and the send ladder's elapsed counter all animate from this loop, which is why the UI visibly stays alive while a 2.4-second `MessageContextResolver` BFS (maxNodes 600 at :194) is blocked on the worker — the animation is proof of liveness, not of progress.

AX THREAD is one `DispatchQueue(label: "kbbs.ax")`, serial, created once. Every AXUIElement call in the entire process runs there: ChatListScanner, MessageContextResolver, TranscriptReader, the send machine, the room open, SystemFocusProbe and the two activate() calls. Jobs are enqueued only by the main thread, at most one outstanding, guarded by a plain `var axBusy: Bool` that only the main thread ever touches.

THE SINGLETON PROBLEM IS SOLVED BY DELETION, NOT BY LOCKING. This is the winner's single best structural decision and it is why it needs zero synchronization code. `ChatIdentityRegistry.swift` (216 LOC) is deleted — I verified by grep that its only three call sites are ChatWindowResolver.swift:124, :344 and ChatsCommand.swift:91, all in files that go. `AXPathCache.swift` (421 LOC) becomes a ~30-line no-op shim preserving exactly the surface its two remaining callers use: `enum AXPathSlot: String, CaseIterable, Codable` (ChatListScanner.swift:299 needs it Hashable for `Set<AXPathSlot>`), `resolve(slot:root:validate:trace:) -> nil`, `remember(...)` no-op, `clear(slots:)` no-op. So AXPathCache.swift:47-56's unsynchronized `cachedDocument` and :245-250's unsynchronized whole-file `Data.write` cease to exist rather than being guarded, ChatListScanner and MessageContextResolver need ZERO edits, and kbbs writes nothing to ~/.kmsg so it cannot clobber concurrent kmsg CLI state in either direction. Compare the alternatives the losers chose: 전표 and 하이텔 sprinkle preconditions into every mutating method of two classes they now own forever; 선접속 retrofits an NSRecursiveLock into both because it chose two AX threads. All three keep 637 lines of upstream code they must keep correct.

HANDLES NEVER CROSS. `UIElement` is `@unchecked Sendable` but no live UIElement ever reaches the main thread. The worker reduces every result to a Sendable value before it enters the mailbox: `TranscriptSnapshot`/`TranscriptMessage` are already declared Sendable (TranscriptReader.swift:4), and `ChatListSnapshotItem` is reduced to a `RoomRow` struct of strings plus an opaque index. Live row handles for the guarded double-click stay in a worker-side table keyed by Int token. This makes the data-race question structural rather than a review discipline.

MAILBOX: `final class Mailbox { let lock = NSLock(); var items: [AXResult] }` — about 15 lines, the only shared mutable state in the program, held for microseconds. The main loop drains it once per tick. No self-pipe is needed because the loop already wakes every 100ms and 100ms of extra latency on an AX result that took 2 seconds is invisible.

CANCELLATION DOES NOT EXIST, SO USE GENERATIONS. Every job carries a monotonically increasing `generation` stamped at enqueue. Esc out of a room, a page turn, R, and quit all bump it; results arriving with a stale generation are read off the mailbox and thrown on the floor. The job still runs to completion and still occupies the queue — Esc is ABANDONMENT, not cancellation, and the status line says so ('작업이 뒤에서 계속됩니다') rather than pretending the work stopped. Three lines, and it eliminates the whole class of "the previous room's transcript lands in this room" bugs.

PRESENTING AN UNCANCELLABLE MULTI-SECOND CALL. The worker stamps `jobStartedAt` and a Korean `jobLabel` into an os_unfair_lock-protected struct before it blocks. Three tiers, all rendered from the main loop: under 2.0s nothing special, the previous frame stays up and the ●○○ cycles at 3Hz; 2.0-6.0s the status badge becomes '[응답 느림]' with a rising counter and the screen stays fully usable; past 6.0s '[카카오톡 응답 없음 Ns]' plus the line '취소할 수 없습니다. 기다리거나 Ctrl-C 로 종료하세요.', which is the literal truth. Ctrl-C always works because it is handled on the main thread and its restore path depends on nothing but a saved `struct termios` and a saved tty fd. Per-call blocking is already bounded to 0.25s by AXUIElementSetMessagingTimeout (UIElement.swift:14-28, env var renamed KBBS_AX_TIMEOUT); it is the hundreds of calls in one walk that add up, which is why the tiers are driven by wall time.

POLL CADENCE (A3). Exactly one timer is ever armed. Room open: 3.0s, `readSnapshot(from: cachedContext, chatWindow:, limit: 60)` — the warm overload WatchCommand uses (:300-334), so the expensive container discovery is paid once per room, not every 3s. List open: 12s. Entering a room disarms the list timer and vice versa, so the AX queue is idle the overwhelming majority of the time. Polls are fully suppressed while a send transaction is live and while axBusy. On failure the interval backs off 3 → 5 → 10 → 15s with the current value on screen; two consecutive failures arm the blocked-screen probe.

RENDERING: no double-buffered frame diff, deliberately. A full frame is 24 lines of at most ~200 UTF-8 bytes, ~4KB, written with a single `write(2)` to ttyFD after `\e[H`, every line terminated by `\e[K`, no `\e[2J` anywhere. That does not flicker on any terminal since the 1980s, and repaints happen at most 10 times a second. A diff engine costs ~120 LOC plus a cell model plus a dirty-tracking bug surface to save 4KB. Rejected. (The one thing a diffing renderer would have bought — cursor-position feedback to self-correct ambiguous glyph widths — is bought instead by the DSR-CPR AmbiguousWidthProbe at boot, for 70 LOC.)

SIGNALS. SIGINT/SIGTERM/SIGHUP/SIGQUIT and SIGWINCH install handlers that write ONLY a `sig_atomic_t`; `poll()` returns EINTR and the flags are serviced at the top of the next iteration. SIGWINCH re-queries TIOCGWINSZ and, below 80x24, renders a single centred '화면을 80x24 이상으로 키워 주십시오' frame until it grows back. SIGPIPE ignored. SIGSEGV/SIGBUS/SIGILL/SIGABRT install a minimal async-signal-safe handler that `write(2)`s `\e[?1049l\e[?25h\e[0m` to the saved tty fd, `tcsetattr`s the file-scope saved termios, and re-raises the default handler — atexit does not run on those, and a crash inside a blocking AX call must never leave the terminal in raw mode. `atexit` plus a `defer` in main cover the ordinary paths.

## 7. 새로 쓰는 모듈

| 줄수 | 파일 | 역할 |
|---:|---|---|
| 80 | `Sources/kbbs/main.swift` | Root ParsableCommand, three flags (--trace, --log, --limit). Order is load-bearing: Paths/TTYOut fd capture → AccessibilityPermission gate (cooked mode, plain print, exit 1 on denial) → KakaoTalkApp(autoLaunch:false) → boot ladder → signal handlers + atexit → Term.enter() → App().run() → Term.restore() in a defer. |
| 170 | `Sources/kbbs/Term/RawMode.swift` | termios save/raw/restore, idempotent and callable from a signal context via a file-scope saved struct; alternate screen \e[?1049h/l; cursor hide/show; ioctl(TIOCGWINSZ); tcflush helpers; handlers for SIGINT/SIGTERM/SIGHUP/SIGQUIT/SIGWINCH (sig_atomic_t only) and the async-signal-safe crash restore for SIGSEGV/SIGBUS/SIGILL/SIGABRT; atexit hook. |
| 140 | `Sources/kbbs/Term/Keys.swift` | poll(2)-based non-blocking reader on the 100ms tick; incremental UTF-8 accumulation so a Hangul syllable arrives whole across read boundaries; CSI/SS3 parsing for arrows, Home/End, PgUp/PgDn with a 25ms lone-Esc grace; control-key mapping; the InputMode gate including .locked, which still read()s and discards bytes while counting them. |
| 110 | `Sources/kbbs/Term/Width.swift` | East Asian Width, deliberately partial: ~30 hardcoded ranges giving 2 for Hangul (1100-115F, 3130-318F, A960-A97F, AC00-D7A3, D7B0-D7FF), CJK (2E80-303E, 3041-33FF, 3400-4DBF, 4E00-9FFF, F900-FAFF, FE30-FE4F), fullwidth (FF00-FF60, FFE0-FFE6), emoji (1F300-1FAFF); 0 for combining marks, VS15/16, ZWJ; ambiguous resolved from WidthProbe. Exposes cells(String) over grapheme clusters, truncate(to:) that never splits a wide cell, pad/rpad, wrap(width:), caretColumn(in:before:). Not the 400+-range full UAX#11 table. |
| 70 | `Sources/kbbs/Term/WidthProbe.swift` | GRAFT from 선접속. One-time boot probe inside the alternate screen: write each ambiguous glyph the UI uses (▶ ● ○ ─ │ ┌ ╔ · ↑ …) at a known column on a scratch row, read the cursor column back with DSR-CPR (ESC[6n) under a 150ms timeout, record the true width. Falls back to 1, honours KBBS_AMBIGUOUS_WIDE. Removes the largest source of box misalignment on CJK-configured terminals and tmux. |
| 90 | `Sources/kbbs/Term/Frame.swift` | Composes exactly 24 strings of exactly 80 cells and flushes them in one write(2) to ttyFD after \e[H with per-line \e[K and no \e[2J. Box helpers (double-line outer, single-line inner modal stamped over a background frame with wide-cell-safe clipping at the edges), dot leaders, centred rules, LR(left,right) alignment. No cell model, no diff. |
| 60 | `Sources/kbbs/Term/TTYOut.swift` | GRAFT from 전표/하이텔. ttyFD = dup(STDOUT_FILENO) captured before anything else, then dup2 of BOTH fd 1 and fd 2 onto ~/.kbbs/kbbs.log. Every surviving print(), every fputs, and the AX trace writer land in the log instead of the frame. The renderer writes only to ttyFD. This is the mechanism behind constraint 6, not a call-ordering convention. |
| 70 | `Sources/kbbs/UI/Theme.swift` | The HiTEL vocabulary: double-line box glyph set, four inlined SGR constants (reverse, bold, dim, reset — 8 ANSI colours only, no 256-colour), the fake retro date formatter, the ●○○ line indicator, the [접속중]/[응답 느림]/[두절] badge set, marker glyphs (* - ▶ [전송중] [미확인]). |
| 70 | `Sources/kbbs/UI/BootLadder.swift` | GRAFT from 하이텔. The ATZ/ATDT/CONNECT ritual and the seven dot-leader checks with real elapsed times, drawn in COOKED mode before raw mode and the alternate screen exist — which is what makes it the legal home for AccessibilityPermission's print() and for the TCC-denied exit path. Doubles as the project's smoke test. Also the 접속 종료 card printed into scrollback after termios is restored. |
| 190 | `Sources/kbbs/UI/ListScreen.swift` | Renders `rooms` and `open_confirm`: the fixed column grid (lead 1 / cursor 1 / num 2 / '. ' 2 / state 1 / sp 1 / name 20 / sp 1 / preview 38 / sp 1 / time 5 / sp 1 / unread 3 / trail 1 = 78), ▶ plus reverse-video bar, * / - marking, EAW-safe truncation with …, paging with a partial last page, the 선택> buffer mirrored onto the cursor, status and hotkey rows, and the inner confirmation box with its four-step open ladder. |
| 250 | `Sources/kbbs/UI/RoomScreen.swift` | Renders the whole conversation family (room / sending / dirty / failed) — one frame, four variants, identical row indices, which is why no layout engine exists. The end-of-tape rule, the time/author/│/body gutter with 57-cell bodies and an 18-cell hanging indent, the 나 / 나? / (이름) attribution markers and the ↑ uncertainty annotation, local pending echo lines with [전송중]/[미확인], the two-line notice band, the composer with horizontal scroll and grapheme-cluster editing, and the ticker. |
| 120 | `Sources/kbbs/UI/BlockedScreen.swift` | The 통신 두 절 screen with its ██ block lettering, the five cause variants (lock / minimized-or-occluded / app quit / permission revoked / repeated read failure), the last-good-receive timestamp, the backoff countdown, and the unrecoverable permission variant that offers only Q. Also the too-small-terminal frame. |
| 170 | `Sources/kbbs/App/Model.swift` | One struct, mutated only on the main thread: screen enum, rooms + page + cursor + numberBuffer, openRoomTitle, snapshot, pendingEchoes, drafts keyed by room title, confirmedRooms, send state, axBusy, generation, lastOkPoll, blockedSince, inputMode, widthTable, timer deadlines. |
| 210 | `Sources/kbbs/App/Loop.swift` | The poll(2) loop, one key-dispatch switch per screen (including the composer-empty gating of R/Q/P/N), the two timers, mailbox drain with generation filtering, SIGWINCH service, the three delay tiers, and the ordered shutdown (draft flush → unconfirmed note → terminal restore → 접속 종료 card). |
| 230 | `Sources/kbbs/App/Send.swift` | The send state machine as a value type plus its driver: armed / precheck (incl. the DIRTY and IME-stability guards) / injecting with strict-equality verify / focusing with the 25ms gate loop / posting with its two immediate guards / verifying with the alive-AND-drained rule / restoring / pending / dirty / failed. Plus the FIFO count-aware pending-echo reconciliation fed by each poll. No AX of its own — it emits job requests and consumes results. |
| 110 | `Sources/kbbs/AX/Worker.swift` | The serial DispatchQueue, the AXJob/AXResult enums, generation stamping and stale-result filtering, the NSLock Mailbox, the handle table (Int token → UIElement / MessageTranscriptContext) that keeps live handles off the main thread, and the jobStartedAt/jobLabel watchdog the delay tiers read. |
| 300 | `Sources/kbbs/AX/Kakao.swift` | The only file that touches AX, and the entire replacement for the deleted 1,332-line ChatWindowResolver. Holds KakaoTalkApp, AXActionRunner and every job body: listRooms (cached chat-list window + ChatListScanner.scan cross-referenced against kakao.windows titles for the * / - flag), openRoom (title scoring ~25 LOC, then one backgroundSafe MessageContextResolver.resolve cached for the room's lifetime), pollTranscript (warm readSnapshot with one context re-resolve on throw), precheckComposer, setComposer, clearComposer, activateAndGate, postReturn, verifyDrained, restoreFocus, openRoomWindow (the frame-guarded, screen-intersection-checked single double-click), and probeHealth. |
| 90 | `Sources/kbbs/AX/SystemFocusProbe.swift` | GRAFT from 선접속. Run-loop-free frontmost detection: AXUIElementCreateSystemWide → kAXFocusedApplicationAttribute → kAXPIDAttribute, because NSWorkspace.frontmostApplication is KVO-backed and can be stale in a process that never pumps a run loop. Plus activate(pid:) and waitForFrontmost(pid:timeout:) as a 25ms poll rather than a sleep. |
| 45 | `Sources/kbbs/AX/Shims.swift` | Two shims that between them save ~640 lines of upstream ownership and one compile break. (a) AXPathCacheShim: AXPathSlot + a no-op AXPathCacheStore.shared with the exact resolve/remember/clear signatures ChatListScanner and MessageContextResolver already call, so neither needs a single edit and the unsynchronized singleton ceases to exist. (b) ChatWindowInteractionMode: the enum lives at ChatWindowResolver.swift:26 but is referenced at MessageContextResolver.swift:13/:19 and TranscriptReader.swift:103/:108, so deleting that file without this 6-line declaration does not compile — a break the winner and 전표 both missed. |
| 95 | `Sources/kbbs/Sync/WatchPollingState.swift` | WatchPollingState lifted VERBATIM from WatchCommand.swift:412-506 (init / replaceBaseline / consume / recentMessages / findOverlap / messagesEquivalent / normalizedAuthor / normalizeForDiff). Zero changes — which is only safe because the attribution graft keeps author==nil for unknown-side rows, preserving messagesEquivalent's empty-author short circuit at :484-487. filterMessagesAfterWatchStart (:336-343) is deliberately NOT ported: it drops every message whose logicalTimestamp is nil and creates a same-minute blind spot at startup. |
| 50 | `Sources/kbbs/Store/Paths.swift` | ~/.kbbs creation at 0700 and the single source of truth for kbbs.log, last-unconfirmed.txt and the drafts file. Also the O_EXCL single-instance lock with a stale-pid check, so two kbbs processes cannot interleave writes to the same log. |
| 90 | `Tests/kbbsTests/WidthTests.swift` | GRAFT from 선접속 — needs no KakaoTalk, no AX permission, runs in CI. Hangul syllables and Jamo are 2, combining marks 0, emoji 2, ASCII 1; truncate never splits a wide cell and never exceeds the budget; pad/rpad are exact; caretColumn matches cells() of the prefix for mixed Hangul/ASCII/emoji strings. |
| 70 | `Tests/kbbsTests/FrameTests.swift` | GRAFT from 선접속. Every screen composer, fed representative model fixtures (including a 25-cell Korean group name, a 3-digit unread, an 어제 timestamp, and a modal stamped over a Hangul transcript), produces exactly 24 rows of exactly 80 cells. This is the single highest-value test in the project: an off-by-one here corrupts every frame and is invisible until you look at it in the wrong terminal. |
| 50 | `Tests/kbbsTests/WrapTests.swift` | Message-body wrapping into 57 cells with an 18-cell hanging indent: break anywhere inside a Hangul run, prefer spaces in Latin runs, never orphan a combining mark, never emit a line wider than the budget. |
| **2930** | | **합계 (신규)** |

유지되는 코어 약 3,100줄을 더해 저장소 총합 **약 6100줄**.

## 8. 복사해 온 코어에 가하는 수정

### 8.0 이미 끝난 것 — 포크 커밋 `c77ac40`

`~/project/kbbs` 는 이미 생성돼 있고 빌드가 통과한다 (9,273줄). 아래는 완료:

- 삭제: `site/`, `video/`, `assets/`, `.github/`, `skills/`, `tools/`, `docs/`(원본),
  `README.en.md`, `VERSIONING.md`, `Package.resolved`
- 삭제: `Update/` (HomebrewUpdater, BinaryMigrator), `UpdateCommand`,
  `MCPServerCommand` (1,001줄), `SendImageCommand`
- 삭제: `tests/` — Swift 소스에 대한 파이썬 문자열 검사였다. private 메서드 이름
  존재만 확인하므로 행위 보장이 없고, 이 프로젝트가 반드시 해야 하는 전송 경로
  리팩터링을 정면으로 막는다. 순수 로직용 Swift 단위 테스트로 대체한다.
- 개명: 패키지 · 타깃 · `Sources/kbbs/` · `@main struct Kbbs` · `KBBS_AX_TIMEOUT`,
  그리고 상태 경로 `~/.config/kbbs/`, `~/.kbbs/chat-registry.json`,
  `~/.kbbs/ax-cache.json`

**설계안과 다르게 판단한 것:** `Plugins/VersionGenPlugin` 과 `Sources/VersionGenTool`
은 **유지한다**. 설계안은 삭제 후 BuildVersion 하드코딩을 권했지만, 이미 동작하고
있고 `kbbs -v` 가 실제 버전을 내며 지우는 쪽이 오히려 손이 더 간다.

### 8.1 남은 수정

- DELETE: `Sources/kbbs/Commands/` 잔여 7개 (AuthCommand, CacheCommand, ChatsCommand,
  InspectCommand, ReadCommand, SendCommand, StatusCommand, WatchCommand),
  `Sources/kbbs/Auth/` 4개 (1,383줄), `KakaoTalk/ChatWindowResolver.swift` (1,332줄),
  `KakaoTalk/ChatIdentityRegistry.swift` (216줄),
  `Accessibility/AXPathCache.swift` (421줄 → 30줄 심으로 치환).
  Package.swift 는 executableTarget 하나 + 테스트 타깃 하나로 정리한다.
  **예외 — `InspectCommand` 는 남긴다.** 의존성을 확인한 결과
  `AccessibilityPermission` · `KakaoTalkApp` · `UIElement` 뿐이고 셋 다 유지된다.
  Auth 도 ChatWindowResolver 도 쓰지 않으므로 남기는 비용이 0 이다. 카카오톡이
  UI 를 바꿨을 때 AX 트리를 들여다볼 유일한 도구라 없으면 눈이 먼다.
  루트는 TUI 로 두고 `defaultSubcommand` 로 묶어 `kbbs inspect` 를 살린다.

<details>
<summary>원래 설계안의 일괄 삭제 지시 (포크 전 기준, 참고용)</summary>

- DELETE outright before any editing: Sources/kmsg/Commands/ (all 10 files, ~4,100 LOC incl. MCPServerCommand 1,001 and SendCommand 546), Sources/kmsg/Auth/ (4 files, 1,383 LOC), Sources/kmsg/Update/ (314), KakaoTalk/ChatWindowResolver.swift (1,332), KakaoTalk/ChatIdentityRegistry.swift (216), Accessibility/AXPathCache.swift (421), Plugins/VersionGenPlugin + Sources/VersionGenTool (~200), plus site/, tools/, scripts/, skills/, video/, .github/workflows/, the Homebrew sync and README.*.md. Package.swift collapses to one executableTarget + one test target, swift-argument-parser as the only dependency, no build plugin, BuildVersion hardcoded.

</details>
- Deleting Auth/ is the largest correctness win, not a size win. It removes the bare print()s at KakaoTalkAuthenticator.swift:136/:209/:636; it removes PasswordPrompt's readLine() and tcsetattr(STDIN_FILENO) at :52/:74-91, whose canPrompt guard only checks isatty and is therefore TRUE for a TUI and protects nothing; it removes the force-log-out-on-repeated-wrong-passcode path at :672-673; and it removes isAuthenticated()'s acceptance of a lock screen as a usable window (:625-628) by removing the function that has the hazard. ReadCommand.swift:95-97 already proves the entire read/send stack works with AuthBootstrap skipped.
- Deleting ChatIdentityRegistry.swift is verified clean: grep confirms its only call sites are ChatWindowResolver.swift:124, ChatWindowResolver.swift:344 and ChatsCommand.swift:91 — all three in deleted files. kbbs therefore never writes ~/.kmsg/chat-registry.json and the long-lived-process clobber hazard against the kmsg CLI is removed rather than managed. Rooms are addressed by list position and window title; --chat-id has no consumer in the MVP.
- Replace AXPathCache.swift with the ~30-line no-op shim in AX/Shims.swift rather than surgically removing it from its callers. ChatListScanner calls AXPathCacheStore.shared.resolve/remember ungated at :120/:137/:177/:189/:196/:208/:222/:229 and needs Set<AXPathSlot> at :299; MessageContextResolver reaches it at :452/:464. The shim is fewer net lines than the edits, touches zero logic I did not write, and deletes 421 lines of unsynchronized mutable state plus the unsynchronized whole-file writes at :245-250.
- ADD ChatWindowInteractionMode to AX/Shims.swift. Verified compile break: the enum is declared at ChatWindowResolver.swift:26 but referenced at MessageContextResolver.swift:13/:19 and TranscriptReader.swift:103/:108, so deleting the resolver without re-declaring it does not build. Six lines; both the winner and 전표 asserted 'no edits to MessageContextResolver' while missing this.
- AXActionRunner.swift: trim 338 → ~130 LOC. DELETE typeTextWithVerification (its `guard let element else { return true }` at :128-132 is half of the constraint-2 leak), typeTextDirect, the private typeText (the actual keyboardSetUnicodeString path — deleting only the nil arm, as 하이텔 proposed, leaves the leak primitive compiled in), and pressEnterWithVerification (its twin `guard let element else { return true }` at :152-155 sits AFTER pressKey(code: 36), so it posts a global HID Return and then reports success having verified nothing — 선접속 kept this function and should not have). DELETE pressCommandW, pressCommandA, pressPaste, pressEscape, pressTabKey, pressShiftTabKey, pressDownArrowKey, pressSpaceKey, clickWithRetry. KEEP waitUntil, focusWithVerification, setTextWithVerification, mouseDoubleClick/postMouseClicks, and expose the private pressKey as exactly one function: `func pressEnterKey()`. If it is not in the binary it cannot leak.
- AXActionRunner.swift:317-320 isInputReflected is `current == expected || current.contains(expected)`. kbbs must never accept the loose arm for send verification: ADD `func valueEquals(_ element: UIElement, _ expected: String) -> Bool` doing an exact String == on a fresh read, and use it for the S2 injection verify and the S4 pre-post body check. setTextWithVerification's internal loose check may stay, but its `true` is never treated as sufficient. Without this, a user's half-typed sentence in KakaoTalk's composer can contain our text as a substring, pass verification, and be sent ahead of it.
- AXActionRunner.swift:331-337 didEnterEffect: rewrite. It currently returns true merely when `after != before`, so a KakaoTalk re-render or an IME artefact scores as a successful send. New contract returns Bool? (nil = cannot tell): liveness probe `element.role != nil` first — a dead handle reads stringValue nil, coerces to "", and scores as success at :168 — then `guard let after = element.stringValue else { return nil }`, then success only when `!before.isEmpty && after.trimmed.isEmpty`. The `after != before` clause is removed entirely.
- AXActionRunner.swift:12-16: the trace writer is hard-wired to FileHandle.standardError, which corrupts the frame. Make it an injectable closure on init (default stderr for any non-TUI use); kbbs passes a writer appending to ~/.kbbs/kbbs.log. Belt and braces — TTYOut also dup2s fd 2 to the same file, because this is the one property that must not depend on a single fix.
- AXActionRunner.swift:277-315 mouseDoubleClick/postMouseClicks: KEPT (without it openRoomWindow cannot open a row — the in-source comment at :273-276 records that KakaoTalk rows expose only AXShowDefaultUI/AXShowAlternateUI and ignore both AXPress and Enter) but fenced: moved behind a RoomOpener-only entry point with `precondition(Worker.currentJobIsUserConfirmedOpen)`, unreachable from the send path.
- TranscriptReader.swift — FIX THE DEDUP AT BOTH CALL SITES (the winner fixed only one). I verified :379 runs `Array(deduplicateMessagesPreservingOrder(messages).suffix(limit))` unconditionally over row-parsed + fallback, and that :607 runs the SAME call at the end of extractFallbackMessages, deduping the fallback list internally before it is ever returned. Since the fallback becomes the dominant source whenever `messages.count < max(3, min(limit/2, 8))` (:373), fixing only :379 still eats two identical 'ㅋㅋ' on the fallback path. (a) Replace :379 with `mergeFallback(rowMessages:fallback:)` which drops only FALLBACK entries whose fingerprint already appears in the row-parsed block and never removes anything from within it. (b) DELETE the call at :607 outright — `return Array(messages.suffix(limit))`. Note that 전표's proposed replacement (CFEqual row-identity dedup in collectTranscriptRows) already exists there as `deduplicateElements(rows)` at :214, so it would have deleted the content dedup with nothing new in its place.
- TranscriptReader.swift:1191 messageFingerprint (author + minute-resolution timeRaw + body): keep under the name `bodyFingerprint` for the pending-echo ledger, and add `positionalFingerprint(_:index:)` for the merge above, so identity and equality stop being the same function.
- TranscriptReader.swift — SURFACE ATTRIBUTION ADDITIVELY (NOT in place). Add `let side: String` and `let authorSource: String` to TranscriptMessage: a stored property each, one line each in the custom init at :121-147, and NOTHING in CodingKeys or encode(to:) since they are debug fields. DO NOT change :852-854 — `.right` and `.unknown` both keep returning `(nil, "default-me")`. This is the one place I overrule the winner: I verified messagesEquivalent (WatchCommand.swift:474-492) short-circuits true when either normalizedAuthor is empty, so returning a non-nil "(불명)" makes the same physical message compare unequal across two polls when the geometry read flickers, breaking the longest-suffix overlap and re-emitting the entire visible tail as new. MessageSide must be raised from `private enum` (:1222) to internal, or carry the raw string. The renderer maps: source=="explicit" → the name; source=="default-me" && side=="right" → 나; source=="default-me" && side=="unknown" → 나? plus the ↑ annotation; "left-unresolved"/"left-time-guard" → ?.
- ChatListScanner.swift — ADDITIVE, ~40 LOC. ChatListDiscovery (:51-55) gains `unreadCount: Int?` and `timeLabel: String?`. Add extractUnread(from:) reading the node whose identifier == "Count Label" (currently rejected at :241-243 and :263-265) and extractTimeLabel(from:) taking the first static text where ChatTextNormalizer.isTimeLikeValue is true (currently filtered at :232/:252-254). Both reuse nodes the scan already visits and the existing rejection filters for title/preview are left exactly as they are, so titles and previews are byte-identical to today.
- MessageContextResolver.swift:105-111: delete the `else { kakao.activate(); focusWithVerification(chatWindow); Thread.sleep(0.05) }` arm and flip the interactionMode default at :19 from .allowUIAutomation to .backgroundSafe. A poll that steals focus is indistinguishable from a send, and 'quiet' must not be a flag someone can forget to pass.
- KakaoTalkApp.swift: delete launch/launchViaOpenCommand/forceOpen/waitForRunningApplication/ensureMainWindow/ensureWindowReopened/activateAndWaitForWindow and printHierarchy (:301-310, a bare print in retained code). Keep init(autoLaunch:false), windows, findWindow(title:), findWindow(titleContaining:), chatListWindow, applicationElement, and activate() renamed to activateForSend() so the only callers left are the send gate and the confirmed room open. Cache the resolved chatListWindow at boot so the unbounded findFirst(identifier:"chatrooms") fallback at :283-288 runs at most once per session.
- UIElement.swift:14-20: rename KMSG_AX_TIMEOUT → KBBS_AX_TIMEOUT, keep the 0.25s default and the 0.05-5.0 clamp. ADD `var isAlive: Bool` reading kAXRoleAttribute and returning true only on AXError.success — this is the conjunct that makes a dead handle a failure rather than the false success at :168. ADD `var numberOfCharacters: Int?` reading kAXNumberOfCharactersAttribute for the IME-preedit cross-check.
- AccessibilityPermission.swift:56-69 printInstructions(): change to `static var instructions: String` and let the caller decide the destination. main.swift prints it to the real stdout from the boot ladder, before raw mode; the TUI renders it in a box if trust is lost mid-session. Reword for kbbs, name the binary's own absolute path from CommandLine.arguments[0], and state that the kmsg grant does not carry over. Drop the auto-open-System-Settings side effect from any TUI path.
- Lift WatchPollingState (WatchCommand.swift:412-506) verbatim. Do NOT port filterMessagesAfterWatchStart (:336-343) or the stabilization sampling loop. Lift the sig_atomic_t pattern at :5-19 as the starting point for RawMode's handlers and extend it with SIGWINCH/SIGHUP/SIGQUIT and the crash set, all of which it lacks.
- Add a `make lint-print` rule that greps `print(`, `keyboardSetUnicodeString`, `pressCommandW` and `NSWorkspace.shared.frontmostApplication` under Sources/ and fails the build. With Auth/, Commands/ and printHierarchy gone, the only legal print site is the boot ladder; the other three greps make reintroduction of a deleted hazard loud rather than silent.
- Add a `make install` target: `swift build -c release && install -m 0755 .build/release/kbbs ~/bin/kbbs && codesign -s - --identifier dev.kbbs --force ~/bin/kbbs`, and develop against ~/bin/kbbs rather than .build/debug/kbbs. A stable path plus a stable ad-hoc signing identity is what keeps the TCC Accessibility grant alive across rebuilds; without it the inner loop for a TUI you run hundreds of times becomes edit → build → System Settings → re-grant → relaunch. No design accounted for this.

## 9. 마일스톤

### M0 — Settle the two untested assumptions and the TCC dev loop, before writing one line of terminal code

**산출물:** A throwaway 120-line `probe` executable in the kmsg tree (never shipped in kbbs) that: (a) resolves the message input element via MessageContextResolver in backgroundSafe mode and prints `element.actionNames()` — the first time anyone has called supportsAction on it, despite SendCommand.swift:160 defining it and using it only for kAXRaiseAction at :483; (b) minimizes a KakaoTalk chat window and re-reads its transcript subtree, printing the row count, to settle A2; (c) prints the warm `readSnapshot(from: cachedContext, limit: 60)` wall time over 20 consecutive reads, to check A3's 3-second budget against reality rather than against cold-CLI figures. Plus `make install` to ~/bin/kbbs with a stable ad-hoc codesign identity, and a confirmation that the grant survives three consecutive rebuilds.

**검증:** Run `./probe` and read three answers off the terminal. If AXConfirm or a send button with AXPress exists, delete steps 3/4/5 of the send machine, the key lockout, the sending band and ~200 LOC before writing them — three of four designers called this the single highest-value work in the project and none of them sequenced it first. If minimized windows DO read, the `-`/`*` distinction narrows and the open_confirm gate becomes rarer. If the warm read is 2s rather than 200ms, the 3s cadence must move to 5s now, not after M4. Then run `swift build -c release && make install` three times and confirm ~/bin/kbbs still appears trusted, without re-granting.

### M1 — Your real chat list, on a 하이텔 screen, printed once

**산출물:** A kbbs tree that compiles and prints the boot ladder followed by ONE static 24×80 room list frame to stdout in cooked mode — no raw mode, no alternate screen, no keys, no threads. Requires: the deletion pass, Package.swift, AX/Shims.swift (AXPathCacheShim + ChatWindowInteractionMode — the tree does not compile without the latter), Store/Paths.swift, Term/TTYOut.swift, Term/Width.swift, Term/Frame.swift, UI/Theme.swift, UI/BootLadder.swift, UI/ListScreen.swift, the ChatListScanner unread/time extras, and the window-title cross-reference that produces * and -.

**검증:** `~/bin/kbbs` prints the ATDT ladder with real elapsed times and then your actual 27 KakaoTalk rooms inside a ╔═╗ frame, with real last messages, real timestamps, real unread counts, and * on the rooms that currently have windows. Pipe it through `awk '{print length}'` after stripping ANSI and confirm the box closes on the right for every line, including the row with your longest Korean group name. Nothing has been typed into KakaoTalk and nothing has taken focus.

### M2 — The list becomes a terminal you can move around in, and it always gives your terminal back

**산출물:** Raw mode + alternate screen + the 100ms poll loop + key decoding (UTF-8 and CSI) + the full signal set including the async-signal-safe crash restore + SIGWINCH and the too-small frame + the DSR-CPR AmbiguousWidthProbe (it needs raw mode, so it lands here) + ListScreen navigation: ▶, mirrored number buffer, P/N paging with a partial last page, R, Q, Ctrl-L. AX calls still run inline on the main thread and still block the UI — that is fine and it is the next milestone's job.

**검증:** Navigate your real chat list with arrows and by typing room numbers; watch ▶ follow the digits. Turn to page 3 and confirm the partial page renders blanks, not placeholders. Then abuse the exit paths: Q, Ctrl-C, `kill -TERM`, `kill -HUP`, resize the window below 80×24 and back, and — the one that matters — attach lldb and force a SIGSEGV mid-frame. In every case the shell must come back in cooked mode with a visible cursor and no alternate screen. Run it inside tmux and confirm the probe reported the right ambiguous width and the right border does not walk.

### M3 — The screen stays alive while KakaoTalk is slow

**산출물:** AX/Worker.swift: the serial queue, the AXJob/AXResult enums, the NSLock mailbox, generation stamping and stale-result discard, the handle table, and the jobStartedAt watchdog. Move every AX call off the main thread. Wire the 12s list poll, the backoff ladder, the [접속중]/[응답 느림]/[카카오톡 응답 없음] tiers, and the ●○○ 3Hz animation.

**검증:** With the list open, put a breakpoint or a `Thread.sleep(5)` in the scan job. The clock keeps ticking, ●○○ keeps cycling, arrows still move ▶ at 100ms, the badge escalates to [응답 느림] then [응답 없음] with a rising counter, and Ctrl-C still exits cleanly mid-call. Then quit KakaoTalk while kbbs is running and watch the backoff ladder count 3 → 5 → 10 → 15 on screen instead of the app hanging or lying.

### M4 — Read your real conversations

**산출물:** Enter on a `*` room opens it (resolveExistingWindowOnly-equivalent title match, one backgroundSafe MessageContextResolver.resolve cached for the room's lifetime), RoomScreen renders the transcript with the end-of-tape rule and the 나 / 나? / name markers, the 3s warm poll runs with WatchPollingState, Esc returns to the list. Includes the TranscriptReader edits: mergeFallback at :379, deletion of the dedup at :607, and the additive side/authorSource fields.

**검증:** Open a room you have been chatting in and watch messages arrive within ~3 seconds without touching anything. Have someone send you 'ㅋㅋ' twice in the same minute and confirm BOTH lines render — that is the dedup fix, tested on the path that actually matters. Find a message whose sender the geometry guess cannot resolve and confirm it says 나? with the ↑ annotation rather than claiming you wrote it. Esc back to the list mid-read and confirm the abandoned result never lands in the wrong room.

### M5 — Nothing fails silently any more

**산출물:** BlockedScreen with all five causes and the health probe that arms after two consecutive failures; open_confirm plus the frame-guarded, screen-intersection-checked single double-click for `-` rooms; mid-session TCC revocation detection.

**검증:** Let KakaoTalk auto-lock (or lock it manually) while a room is open and confirm you get 통신 두 절 with the honest explanation within ~15 seconds rather than a chat that quietly stops updating. Unlock and confirm it resumes with the context re-resolved. Minimize the room's window and confirm the right variant appears. Then pick a `-` room, read the warning, press Y, and watch the four-step ladder; then deliberately cover the KakaoTalk chat-list window with another app and press Y again — it must report failure and must not have clicked anything of yours.

### M6 — Send a message

**산출물:** The composer with grapheme-cluster editing and EAW caret arithmetic, plus the full send machine: armed, precheck with the DIRTY and IME-stability guards, injection with strict-equality verify, the 25ms focus gate, the two pre-post guards, alive-AND-drained verification, focus restore with tcflush, and the pending → [전송중] → promoted-by-poll / [미확인] ledger, with the dirty and failed bands.

**검증:** Send a message to yourself and watch the ladder run, the screen flip to KakaoTalk and back, and the [전송중] marker disappear only when the next 3s poll re-reads your own message out of KakaoTalk's transcript. Then force each failure in turn: type a few characters directly into KakaoTalk's composer and press Enter in kbbs (must stop at 오염 and refuse to delete your text); start a send and immediately ⌘-Tab away (must abort with nothing posted and the injected text cleared); start a send and hold down a key throughout (the discarded bytes must not appear in your composer or in KakaoTalk afterwards). Confirm the string '전송 완료' appears nowhere in the binary: `strings ~/bin/kbbs | grep 완료`.

### M7 — Make it hold up over hours

**산출물:** The three unit-test files (Width, Frame, Wrap) wired into `swift test`; `make lint-print`; per-room draft retention and ~/.kbbs/last-unconfirmed.txt; the 접속 종료 card; memory-growth measurement over a long run.

**검증:** `swift test` passes with no KakaoTalk running and no Accessibility grant — that is the point of those three files. `make lint-print` fails if you reintroduce a print(). Then leave kbbs open on a busy room for four hours and check RSS in Activity Monitor: ~1,200 full transcript re-walks per hour against an Electron-adjacent app is a workload nobody has ever run, and handle churn is the most likely thing to make this unusable in a way no design could predict.

## 10. 아직 사용자가 정해야 할 것

### Should kbbs ever post a hardware double-click at screen coordinates to open a room that has no KakaoTalk window?

- 선택지: (A) Keep the open_confirm gate and the guarded single double-click, as designed here — the user presses Y, sees the warning, and kbbs clicks the row's re-read AX frame after checking it is non-empty and on a visible screen. (B) 전표's position: never open rooms at all. Replace open_confirm with a 창 없음 screen that watches window titles once per second and slides into the conversation the moment the user opens the room in KakaoTalk themselves.
- 권고: (A), but build (B) first — it is 30 lines and zero risk, and it is the correct fallback text when (A) fails anyway. The honest case for (A) is that if your normal KakaoTalk habit is one chat-list window with chats opened on demand, then almost every row is `-` and option (B) makes kbbs a viewer for rooms you already had open, which is barely a product. The honest case against is that the in-source comment at AXActionRunner.swift:273-276 exists precisely because that path is unreliable, and I cannot guard against the row scrolling between the frame read and the click. Ship (A) behind Y, with (B)'s watch-and-wait as the failure screen, and drop (A) if you find it misfiring. Tell me after M0 how many chat windows you typically keep open — that number decides how much this matters.

### Surface the unread badge and the row timestamp in the list, or hold to the locked scope line 'no unread badges beyond what is free'?

- 선택지: (A) Surface both: add `unreadCount: Int?` and `timeLabel: String?` to ChatListDiscovery plus two small extractors, ~40 LOC, additive, existing title/preview behaviour byte-identical. (B) Ship the list with neither, as the winning design proposed, on the grounds that the data is deliberately discarded today and so is not literally free.
- 권고: (A). The retro judge's sharpest criticism of the winner was that a HiTEL board index without a date column is a worse list than the other three ship, and I agree — a BBS index without 시각 does not read as a BBS index. The data is already walked (the nodes are visited and then rejected at ChatListScanner.swift:241-243 and :263-265), the change touches only the rejected branches, and 40 LOC is the cheapest UX win in the whole plan. This is a scope call only you can make, but I would take it.

### Where does the binary live during development, and do you want it codesigned?

- 선택지: (A) `make install` to ~/bin/kbbs with `codesign -s - --identifier dev.kbbs --force`, and develop against that path; .build/debug/kbbs is never granted Accessibility. (B) Grant .build/debug/kbbs directly and re-grant whenever macOS drops it. (C) /usr/local/bin/kbbs, which needs sudo on every install.
- 권고: (A). No design accounted for this and it is the difference between a pleasant and a miserable inner loop: a TUI is developed by running it hundreds of times, `swift build` rewrites the binary every time, and constraint 12 keys TCC trust per binary. A stable path plus a stable ad-hoc identifier is what makes the grant survive. I made this Milestone 0 rather than a README line, but ~/bin vs somewhere else is your filesystem, not mine.

### How much modem ritual do you actually want — the ATZ/ATDT/CONNECT boot ladder, the ●○○ 회선 indicator, the NO CARRIER hangup card?

- 선택지: (A) Keep all three, as designed here (~70 LOC total, all in BootLadder.swift and Theme.swift). (B) Keep only the boot ladder, because it is load-bearing — it is the constraint-6-safe place for permission errors and it doubles as the smoke test — and drop the ●○○ and the hangup card for a plain status line.
- 권고: (A). The ●○○ is not decoration: it is the only thing on screen that proves the process is alive while a 2.4-second uncancellable AX call is blocked, and rendering the 3-second poll as a line indicator is the one place where the retro framing and the technical reality genuinely coincide rather than one hiding the other. The hangup card is pure taste and the cheapest thing to cut later if it wears thin after a week. I am flagging this because it is the element you will react to most strongly in either direction, and it is a five-minute revert.

## 11. 남은 위험

- LOC HONESTY. The winning design claimed 1,195 new lines and a 4,330-line tree. My module table sums to 3,000 new lines (2,790 source + 210 tests) and the retained core is ~3,100 (TranscriptReader 1,247, MessageContextResolver 499, UIElement 412, ChatListScanner ~340 with the extras, KakaoTalkApp ~300 after deletions, AXActionRunner ~130 after trimming, AccessibilityPermission 81, AXError 59, AXConstants 35), so the honest repo total is ~6,100. The judges were right that the original number was optimistic on two files specifically — AX/Kakao.swift is 300 here rather than 220 because it absorbs ten job bodies plus title scoring plus the guarded open, and the App layer is split across Model/Loop/Send at 610 rather than a single 300-line App.swift. I have also added ~600 lines of grafts and tests the winner did not have. Every other design's honest total is higher: 전표 ~7,500, 하이텔 ~6,500 against a claimed 3,090.
- A1 IS STILL A COIN FLIP UNTIL M0 RUNS, AND IT DOMINATES EVERYTHING. If the composer exposes AXConfirm, roughly 200 lines of this design — the focus gate, the key lockout, the sending band, half the failure taxonomy — are unnecessary and the product stops flashing on every message. If it does not, sending is genuinely unpleasant: precheck plus injection plus up to 1.2s of gating plus 0.9s of verification plus 0.8s of focus restore, with the keyboard hard-locked, for every single line. Korean chat is rapid-fire; three 'ㅇㅇ' replies means three screen takeovers and several seconds of locked keyboard. I have made that legible rather than dangerous, which is the right trade against constraint 1, but legible is not pleasant and it is the most likely reason you stop reaching for kbbs.
- THE '*' MARKER IS A TITLE-MATCH GUESS ON TOP OF AN UNTESTED ASSUMPTION. It matches KakaoTalk window titles against chat-list row titles. A2 (occluded or minimized windows expose no readable subtree) has zero AXMinimized references in the source and is untested until M0. Two concrete ways this misleads: a minimized window may still match by title, so a room shows * and then reads empty; and Korean chat lists routinely contain duplicate titles — two contacts named 김현수, or a group renamed to a person's name — so a title collision silently routes you into the wrong room, with no chat-id shown anywhere to notice it by. I deliberately did not display chat-ids because they are ugly and unperiod, which trades away your only means of disambiguation.
- THE 3-SECOND POLL IS AN UNMEASURED WORKLOAD. WatchCommand is a short-lived CLI; kbbs walks KakaoTalk's entire transcript subtree every 3 seconds for hours — roughly 1,200 full subtree walks per hour, each allocating fresh AXUIElement handles, against an app whose accessibility implementation was never built for it. I have no measurement of KakaoTalk's own responsiveness under that load and none of kbbs's memory growth from handle churn. The 1.4-2.4s figures in A3 include process start and auth that an in-process TUI does not pay, so the warm case should be far cheaper — but 'should be' is doing a lot of work, and if the warm read turns out to be 2 seconds the 3s cadence collapses into a permanently-delayed UI. M0 step (c) and M7 exist to find this out early rather than at hour four.
- [미확인] WILL FIRE MORE OFTEN THAN IT SHOULD, AND THAT ERODES THE MARKER. Confirmation requires re-reading your own message out of KakaoTalk's transcript within ~9 seconds. If the room is busy, if KakaoTalk animates the bubble in slowly, if the message scrolls past the rendered tail, or if the AX walk is one of the slow ones, the match is missed and you get [미확인] for a message that plainly went through. The bias is deliberate — a false [미확인] costs annoyance, a false ✓ costs a duplicate or a lost message — but a user who sees the marker on messages they can see in KakaoTalk will eventually stop reading it, which is exactly the failure the design exists to prevent. Nobody has run this reconcile loop against a live KakaoTalk; 9s and 120s are guesses.
- THE IME GUARD IS A HEURISTIC, NOT A PROOF. No design covered the case at all, and my fix — require the composer to read empty and stable across two reads 60ms apart, and cross-check kAXNumberOfCharacters against the injected body's UTF-16 length — is the cheapest available signal, not a real one. kAXValue genuinely does not expose an uncommitted Hangul composition buffer. If KakaoTalk's composer does not implement kAXNumberOfCharacters, or implements it as the committed length only, the cross-check is dead weight and a preedit can still ride out ahead of your message. The mitigation of last resort is that the reconcile then fails to find our exact body and reports [미확인] rather than a false confirmation, so the failure is loud — but the message that went out is not the one you typed.
- ONE THREAD MEANS THE ROOM POLL AND THE LIST POLL CANNOT OVERLAP, WHICH IS A FEATURE UNTIL IT IS NOT. Only one timer is ever armed, so this is fine in the MVP. But if you ever want a background unread indicator for rooms you are not in, the single serial queue becomes the bottleneck and the answer is NOT to add a second thread — 선접속 tried that and had to retrofit locks into two upstream singletons to buy a benefit it admitted might not exist, since KakaoTalk's AX server may serialize requests anyway. The correct answer would be to interleave list scans into the room-poll cadence, which is a real redesign. Worth knowing before you ask for it.
- DELETING ChatWindowResolver WHOLESALE MEANS REWRITING ~70 LINES OF ITS LOGIC FROM MEMORY. Title matching, scoreQueryMatch and the row-open sequence come back as fresh code in AX/Kakao.swift rather than as surviving upstream code. This is still the right call — 하이텔's alternative was an 882-line freehand amputation of interleaved private helpers with no test suite, which the buildability judge correctly called the worst mistake in the set — but the new title scorer will have bugs the old one did not, and the only thing that will catch them is you noticing you entered the wrong room. Consider printing the matched window title in the room title bar during the first week.

## 12. 이 설계가 나온 과정

독립 설계 4개를 서로 다른 우선순위로 만들고 (안전 우선 / 고증 우선 / 체감속도 우선 /
최소코드 우선), 심사 3명이 각자 다른 기준으로 (제약 준수 · 레트로 완성도 · 구현
가능성) 채점한 뒤, 승자에 패자들의 좋은 아이디어를 이식했다.

```
설계                                    제약  레트로  구현   합계
한 화면 한 스레드 (One Frame One Thread)  78     74     88    240  ← 채택
하이텔 호환 단말                          70     86     66    222
전표 (영수증 원장 방식)                   92     70     55    217
선접속 후확인                             75     62     62    199
```

채택 이유: 유일하게 어느 기준에서도 2위 밑으로 내려가지 않았고, 약점이 전부
싼 이식으로 메워지는 반면 2·3위의 약점은 구조적이었다. 특히 동기화 없는 싱글턴
둘을 락으로 감싸는 대신 **삭제**로 해결한 게 결정적이었다 — `ChatIdentityRegistry`
(216줄) 는 호출부 세 곳이 전부 삭제 대상 파일 안에 있어 그냥 지워지고,
`AXPathCache` (421줄) 는 30줄짜리 no-op 심으로 치환되어 호출부 수정이 0이다.

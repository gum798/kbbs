# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is right now

`kbbs` is a fork of the sibling repo `~/project/kmsg` being rebuilt into one
thing: **a HiTEL-style Korean PC-통신 terminal for KakaoTalk** — fullscreen 80×24,
double-line boxes, a numbered board index of chat rooms, a `선택>` prompt. Read
`docs/specs/2026-09-16-kbbs-hitel-tui-design.md`. It is the design, the constraint
list, the module table, the milestone plan and the progress log, and it is the only
document in the repo that describes the product being built.

**README.md, ARCHITECTURE.md and USAGE.md are inherited from kmsg and are stale.**
They document `send`, `read`, `chats`, `watch`, `auth`, `mcp-server`, Homebrew
distribution and `~/.config/kbbs/credentials.json` — all of which were deleted in the
fork (`c77ac40`, `b7a362b`). They also link to files that no longer exist
(`VERSIONING.md`, `README.en.md`, `docs/openclaw.md`). Do not take a fact from them
without grepping for it first, and do not "fix" code to match them.

What actually ships today: the root command (boot ladder → one static list frame) and
`kbbs inspect`. Everything else is unwritten.

## Commands

```bash
make build                      # swift build
make test                       # swift test — 80 XCTest cases, no KakaoTalk, no AX grant
make install                    # release build → ~/bin/kbbs, ad-hoc signed as dev.kbbs
make lint-print                 # fails if a deliberately deleted hazard is reintroduced
make version                    # scripts/headatever.sh show
make release                    # VERSION bump + commit + tag (head.yymmdd.patch)

swift test --filter WidthTests                              # one suite
swift test --filter WidthTests/testHangulSyllableIsTwoCells # one case

~/bin/kbbs                      # the TUI (currently: boot ladder + one list frame)
~/bin/kbbs --demo               # fake rooms, no KakaoTalk, no AX permission needed
~/bin/kbbs --trace              # AX traversal trace to stderr
~/bin/kbbs inspect --depth 5    # dump the AX tree — the only eye you have when
                                # KakaoTalk changes its UI
```

**Develop against `~/bin/kbbs`, never `.build/debug/kbbs`.** macOS keys Accessibility
trust per binary+signature, and `swift build` rewrites the binary every time. A stable
path plus the stable ad-hoc identity `make install` applies is what keeps the TCC grant
alive; without it every rebuild costs a trip to System Settings. This is why `make
install` exists and why it codesigns.

`swift test` and `make lint-print` are the whole CI story — they run with KakaoTalk
closed and no permission granted, by design. Anything that needs a live KakaoTalk is
verified by hand, and what has actually been verified that way is recorded in §13 of
the spec. Append to that section rather than assuming.

## Architecture

```
Kbbs (kbbs.swift)            root ParsableCommand + `inspect` subcommand
   ↓
UI/ (BootLadder, Theme,      pure composition: model values → 24 strings of 80 cells
     ListScreen)             ← Term/Frame guarantees the cell count
   ↓
App/Model.swift              Room, ListState, LinkState — plain Sendable values,
                             main thread only, never holds a UIElement
   ↓
KakaoTalk/ (ChatListScanner, retained kmsg scraper: chat list, transcript context,
  MessageContextResolver,    message extraction. ~2,450 lines we did not write and
  TranscriptReader,          try not to edit — edits are listed in spec §8.1.
  KakaoTalkApp)
   ↓
Accessibility/ (UIElement,   AXUIElement wrapper, bounded search, the surviving
  AXActionRunner, …)         CGEvent primitives
   ↓
macOS Accessibility APIs
```

`AX/Shims.swift` is load-bearing: it re-declares `AXPathSlot`/`AXPathCacheStore` as a
no-op (the real 421-line cache was deleted) and `ChatWindowInteractionMode` (declared in
the deleted `ChatWindowResolver`), so the three retained scraper files compile with zero
edits. Deleting either shim breaks the build.

The target concurrency model, not yet built (spec §6): **two threads, one serial
`DispatchQueue(label: "kbbs.ax")`, zero locks on AX state.** The main thread owns the
model and rendering and makes *no* AX call, ever; it runs a 100 ms `poll(2)` loop. Every
AXUIElement call in the process runs on the one AX queue. Results cross back as Sendable
values through an `NSLock` mailbox, stamped with a generation so abandoned work is
dropped rather than cancelled (the copied core is synchronous — 9 `Thread.sleep`
sites remain after the deletion pass — and cannot be cancelled). Live `UIElement` handles never reach the main thread.

## Rules that are not style preferences

Each of these is a deleted bug or a measured failure, not an opinion.

- **Every AX traversal carries a budget.** `findAll(where:limit:maxNodes:)`, always.
  The unbudgeted `findFirst(where:)`/`findFirst(identifier:)` path was run against a
  real KakaoTalk tree and did not finish in seven minutes; the budgeted call returned in
  one second. New unbudgeted traversals are not acceptable anywhere.
- **Reads never steal focus and never launch KakaoTalk.** `KakaoTalkApp(autoLaunch:
  false)`, `MessageContextResolver` defaults to `.backgroundSafe`. Only a deliberate,
  user-initiated send may call `activate()`. A poll that brings KakaoTalk forward is
  indistinguishable from a send.
- **The deleted send primitives stay deleted.** `keyboardSetUnicodeString`,
  `forceTypeIntoChatWindow`, `typeTextWithVerification`, `pressEnterWithVerification`,
  `pressCommandW`, `NSWorkspace.shared.frontmostApplication`. They reported success
  without verifying anything, which is how a private message ends up typed into whatever
  app happens to be frontmost. `make lint-print` enforces this.
- **The final Enter of a send is a global HID event** (`pressEnterKey`). It goes to
  whatever is frontmost at that instant, and a fullscreen TUI is by definition
  frontmost. This single fact is why the send state machine in spec §5 is as elaborate
  as it is. Do not simplify it away.
- **`print()` is legal only in the boot ladder**, which runs in cooked mode before the
  alternate screen exists. Anywhere else it shears the frame.
- **A frame is exactly 24 rows of exactly 80 cells.** `Frame.render()` enforces it and
  `FrameTests` proves it. Korean is the common case, not an edge case — width bugs are
  invisible until you open the app in a CJK-configured terminal.
- **`~/.kbbs/` only.** Never write `~/.kmsg/`; kmsg is a live sibling product and a
  long-lived process would clobber its state.

## Handover status

Milestones (spec §9, §14). M0 done, M1 code complete and waiting on live verification,
M2 onward unstarted.

Built: `Term/Width`, `Term/Frame`, `UI/Theme`, `UI/BootLadder`, `UI/ListScreen`,
`App/Model`, `Store/Paths`, `Sync/WatchPollingState`, `AX/Shims`. The list screen draws
from real `ChatListScanner` data.

Not built: `Term/RawMode`, `Term/Keys`, `Term/WidthProbe`, `Term/TTYOut`,
`UI/RoomScreen`, `UI/BlockedScreen`, `App/Loop`, `App/Send`, `AX/Worker`, `AX/Kakao`,
`AX/SystemFocusProbe`, `WrapTests`. Nothing reads a conversation or sends anything yet;
there is no raw mode and no key input.

Core edits from spec §8.1 still outstanding:

- `TranscriptReader`: the dedup at :379 and :607 both still drop genuine repeat messages
  (two identical `ㅋㅋ` become one). Replace :379 with a fallback-only merge, delete
  :607's call.
- `TranscriptReader`: `side` / `authorSource` have not been surfaced on
  `TranscriptMessage` — add them additively, and do not change what :852 returns.
- `UIElement`: `isAlive` and `numberOfCharacters` are missing; without `isAlive` a dead
  handle reads as a successful send.
- `AXActionRunner`: `valueEquals` (exact match) does not exist, `isInputReflected`
  still accepts a substring, `didEnterEffect` still returns true on `after != before`,
  and the trace writer is still hard-wired to stderr instead of being injectable.
`KakaoTalkApp`'s front-the-app ladder is done (`5833092`): the seven functions are
deleted, `activate()` is `activateForSend()`, `init` no longer takes `autoLaunch`, and
`make lint-print` fails if any of the names returns. `friendsWindow` is pre-existing
dead code left in place — mentioned, not deleted.

Assumptions A1 (does the composer expose `AXConfirm`?), A2 (do occluded windows expose a
readable subtree?) and A3 (warm read latency) are still unmeasured — the user chose to
proceed on worst-case assumptions rather than spike them. Design decisions that depend
on them are marked in spec §3 and §11.

## The immediate next step

M1's code is finished but has never drawn real data, because at the time it was written
KakaoTalk was running with **every window closed** — the AX tree held only menu bars.
That state is what exposed the two bugs fixed in `cf04e57`, and it is also why nothing
has confirmed that the column widths suit real Korean room names.

So the first thing to do is not to write code:

1. Open KakaoTalk's window and switch to the 「채팅」 tab.
2. `make install && ~/bin/kbbs`
3. Check the frame closes on the right for every row, including the longest group name,
   and that `*` appears on rooms that genuinely have a window open. Strip ANSI and
   measure if in doubt — `FrameTests` proves the composer, not the data.
4. Record the result in spec §13, then start M2.

If it prints `0개`, run `~/bin/kbbs --trace`: the scanner distinguishes "container
unavailable" from "container found but no rows", and the trace is the only thing that
tells you which.

## Commit convention

Conventional commits: `feat(module):`, `fix(module):`, `perf(module):`, `docs:`,
`chore:`. Subject lines in this repo state the behavioural change, not the mechanism —
`fix(ax): stop reads from stealing focus`, not `fix(ax): change default parameter`.

Version bumps go through `make release` / `scripts/headatever.sh` (format
`head.yymmdd.patch`); never hand-edit `VERSION`, and never hardcode a version in Swift —
`BuildVersion` is generated from `VERSION` by the SwiftPM build plugin.

# Sidebar: sections, starring, drag-and-drop + tab coding status (2026-08-26)

Plan: /Users/eddie/.claude/plans/silly-petting-puppy.md

- [x] Part A: tab status word — TabStatus enum on TabModel, set in AppModel/WindowController, label in TabRow
- [x] B1: Support.swift — ProjectSection, ProjectMeta, SidebarMeta, loadMeta/saveMeta
- [x] B2: Support.swift — autoSection + sectioned pure functions
- [x] B3: ContentView.swift — ProjectRow extraction (star button + context menu), sectioned idle rendering, LazyVStack, search-mode flat list, onSubmit fix
- [x] B4: ContentView.swift — ProjectRowDrop / ProjectSectionDrop, liveMove/commitDrop, TabReorderDrop hardening, container onDrop clears both drags
- [x] Build + diff review — full diff verified against plan (Fable); unsigned `xcodebuild` BUILD SUCCEEDED
- [x] Fix local signing: Debug uses macOS/KnifeMacDev.entitlements (no iCloud/push) + Zelig team 5VY7X6W92A; Release keeps CW&T entitlements (now per-config CODE_SIGN_ENTITLEMENTS in project.yml — the xcodegen `entitlements:` block forced one file on all configs). `make mac` + `make install-mac` work again.
- [ ] Manual QA per plan checklist — app installed to /Applications, relaunch to test. Note: locally built Debug apps have CloudKit disabled (runtime guard), so no iOS sync from dev builds.

## Review

- Full diff across the 5 files reviewed against the approved plan — matches (Part A status word; Part B sections/star/drag-drop, order-array + override semantics as designed).
- `xcodebuild … CODE_SIGNING_ALLOWED=NO build` → BUILD SUCCEEDED.
- The CloudKit-entitlement guard in AppModel.swift init is Eddie's pre-existing uncommitted change (verified via relay transcript: seen in a read, not authored) — untouched.
- **Blocker for QA/install**: `make mac` (signed) fails at provisioning before compiling — "No Accounts" + no profile for `com.cwandt.knifeterminal` for CLI xcodebuild. Pre-existing environment state (possibly since the hardened-runtime change, 47ed32b), not caused by these edits. Build from Xcode.app or add the account for CLI builds, then run the QA checklist in the plan.

## Fix round 2 — sidebar project drag felt broken in use (2026-08-27)

Manual QA finally happened (Eddie: "moving projects around in sidebar is not working well").
Five defects found in `apple/macOS/ContentView.swift`, all fixed:

- [x] **Drag start cancelled/glitched.** `.onDrag` wrote `@State` synchronously, re-rendering the
      row while AppKit was opening the drag session. Now deferred via `DispatchQueue.main.async`
      (both project rows and tab rows).
- [x] **List reflowed the instant you picked a row up.** Empty section headers were revealed by
      `|| draggingProject != nil`, pushing every row down mid-drag so the row under the cursor was
      no longer the one grabbed. Headers now always render — layout is fixed while dragging.
- [x] **Drops that snapped back.** The container-level `.onDrop` discarded the live order with a
      bare `rebuild()`, and a project released over the tab list hit `TabReorderDrop`, which
      committed nothing. All four drop targets now funnel through one `endDrag()` that persists
      whatever order is on screen, so releasing anywhere in the sidebar sticks.
- [x] **Section-header drops landed by recency, not where dropped.** Header hover now live-moves
      the row to the top of that section (`liveMove(_:into:)`) and the drop snapshots that order.
- [x] **Two parallel drag optionals** (`draggingTabId` / `draggingProject`) with identical
      `public.plain-text` payloads → replaced by one `SidebarDrag` enum, so a tab dragged over a
      project row (or the reverse) can't be misread as a drag of the target's own kind.
- [x] `commitDrop` takes the path explicitly instead of writing `@State` and reading it back in
      the same call (context-menu "move to …" relied on that round-trip).

Verified: `xcodebuild … CODE_SIGNING_ALLOWED=NO` and `make mac` (signed) both BUILD SUCCEEDED.
The provisioning blocker noted in the previous round is gone — signed CLI builds work again.
Still needs a hands-on pass in the running app: `make install-mac`, relaunch, drag within a
section, across sections, onto a header, onto a collapsed header, and onto blank space.

# Restore every working Claude tab on relaunch (2026-09-09)

Problem: session.json only carries `cmd` for tabs opened from the sidebar (`claude -c`), so
tabs where `claude` was started by hand come back as bare shells, and `-c` resumes "most
recent in cwd" — two tabs in the same project both resume the same conversation.

- [ ] TabModel: `claudeSessionId` (from hook payloads) + `claudeRunning` (pgrep under the tab's shell)
- [ ] AppModel.handleSocketMessage: record `session_id` per tab; clear on SessionEnd
- [ ] saveSession: cmd = `claude --resume <id>` if known, else `claude -c` if claude is live, else restoreCmd
- [ ] SavedTab.fixed: keep the project name pinned only for sidebar-opened tabs (legacy files keep old rule)
- [ ] Build + install

# iOS mirror without CW&T (2026-09-09)

Zelig (5VY7X6W92A) is a paid team, so both apps run under Zelig ids and Zelig's own container:
- [x] CloudSync.containerID reads KnifeCloudContainer (Info.plist ← KNIFE_CLOUD_CONTAINER build setting), CW&T default
- [x] Makefile: XCODEBUILD_FLAGS_IOS + `make install-ios` (devicectl) — committed, pushed to the PR branch
- [x] local.mk (gitignored): com.zelig.knifeterminal / .ios, iCloud.com.zelig.knifeterminal, *.zelig.entitlements (git-excluded), IOS_DEVICE = EC PRO
- [x] Mac: built, installed to /Applications with Zelig container + push entitlements (Xcode auto-provisioning created the App ID + container)
- [x] iOS: built, installed on EC PRO via devicectl
- [ ] Eddie: relaunch Knife on the Mac, open Knife on the phone (same Apple ID as the Mac, eddiemc27@mac.com), confirm tabs appear
- [x] iOS restyle to match the Mac: KnifeStyle.swift (ui()/mono(), TermTheme.current(scheme), RGB→Color), Helvetica Now bundled locally (apple/Fonts/HelveticaNow*, git-excluded), theme backgrounds/accent/attention throughout; built + installed on EC PRO

# Session board (2026-09-09)

One screen with every live agent session as a card: status, the last exchange from its
transcript, and a reply box that types straight into that tab. ⌘⇧B / footer "board" toggles it
in place of the terminal pane; click a card header to jump into the tab.

- [ ] TabModel.runningAgent ("claude" | "codex" | nil) via the existing pgrep; claudeRunning = runningAgent == "claude"
- [ ] TranscriptReader.messages(forCwd:sessionId:) — exact ~/.claude/projects/<slug>/<session>.jsonl when the tab's session id is known, else the newest-in-cwd fallback; chatData(forCwd:sessionId:) wraps it; SyncPublisher passes tab.claudeSessionId
- [ ] KnifeWindowController.showBoard (@Published); AppDelegate View ▸ "Session Board" ⌘⇧B; FooterBar "board" button
- [ ] ContentView: board replaces TerminalPane when showBoard
- [ ] BoardView.swift: adaptive grid of SessionCard (needs-input first), 2 s transcript refresh off the main thread, reply field (text, then CR 0.25 s later, like the phone), header tap → activate tab + close board
- [x] Build + install (signed Debug, BUILD SUCCEEDED) — hands-on check pending Eddie's relaunch

# iOS: readability, status grouping, alerts off (2026-09-10)

- [x] No more one-line truncation: session + project titles wrap to two lines; the nav bar
      shows the full title (middle-truncated) with the project folder beneath it; tool lines
      in the chat expand on tap
- [x] Sessions grouped: needs input / working / idle, counts in the headers, attention color
      on the first — same order as the Mac sidebar and board
- [x] Each row carries the last exchange (Claude's newest reply, or the tool it's running),
      decoded once per sync into a snippet map rather than per row on scroll
- [x] Mirror readability: prose wraps on words, box drawing still on characters; text-size
      menu (small/medium/large) plus "fit Mac width", which solves for the size that makes
      the Mac's own column count fit — landscape then shows the desktop layout unwrapped
- [x] Cleanups: "projects" header is a header again (the sentence moved to a footer), the
      internal device label is gone from the footer
- [x] Notifications: visible pushes are opt-in behind a switch, default off — the alert
      subscription is deleted server-side and the badge cleared when off. Silent sync pushes
      are untouched, so the mirror stays as fresh as before.

# Sidebar grouping is buggy + "active" = worked on in the last 24h (2026-09-14)

Eddie: "its super buggy. also active should be projects that have been worked on in the past 24 hours"

Defects found by reading (grouping shipped without driving the app — see lessons.md):
1. Tab drag across groups: moveTab reorders the flat array but rows are shown grouped, so the
   row doesn't go where dropped and the list reflows under the cursor mid-drag.
2. Clicking a ready / needs-input tab resets its status, so the row jumps out from under the
   cursor into another group. Focusing the window does the same to the current tab.
3. Every keystroke sets status .idle, so a working tab you type into flaps working ↔ active.
4. active/dormant hung off a 3 s process scan: new sessions flash dormant → active.
5. Board cards push/pop the pointing-hand cursor; a card reordering while hovered unbalances
   the stack and the cursor sticks (same bug on the sidebar resize handle).

Plan:
- [x] TabModel.lastActivity (hook events, typing, open), persisted in session.json
- [x] Groups: needs input · working · ready · active (touched < 24h) · dormant — no process scan
- [x] Selected tab keeps the group it was clicked in until you switch away or its status truly changes
- [x] Tab drag only reorders within the dragged tab's group
- [x] Typing clears ready/needs-input but not working unless it's Esc or ^C (interrupts send no Stop hook)
- [x] Cursor: onContinuousHover + set() instead of push/pop (board cards, resize handle)
- [x] Projects: active = touched in the last 24h (was 30 days)
- [x] Build + install (BUILD SUCCEEDED); 14 logic checks pass against the extracted source
      (groups, 24h boundary both sides, old session file, lastActive round-trip, interrupt bytes)
- [ ] Hands-on pass by Eddie: click a ready tab (row should stay put), drag within and across
      groups, type into a working tab, Esc a working tab, hover board cards then move away

## Follow-up: "when clicking on an item in active it doesnt highlight" (2026-09-14)

Cause: the highlight was correct (it marks the clicked tab id) but the row wasn't under the
pointer anymore. The selection pin from the previous round unpinned the old selection on the
next click; that tab left "ready", landed in "active", and shifted the rows being clicked by one.
Hook events on other sessions also reflowed the groups above "active" mid-press.

- [x] Remove the selection pin (WindowController.pinned / displayGroup / sameGroup)
- [x] Freeze group membership while the pointer is over the tab list; order stays live for drags
- [x] Unfreeze on hover exit (animated) and on window resign-key (parked pointer never exits)
- [x] Drag guard compares the group shown on screen, via a closure from the sidebar
- [x] Build + install
- [ ] Hands-on by Eddie: open a ready tab, then click a row in active — highlight should be on
      the row under the pointer; move the pointer off the sidebar and the opened tab slides to active

## 2026-09-25 — merge upstream v1.2.6–v1.2.30 (chat view, git panel, prompts, transcripts)

- [x] Fetch origin (Che-Wei) — 25 commits, 28 files; 10 conflicting files
- [x] Resolve: keep grouped sidebar/board/Helvetica chrome, take chat view + git panel + screen prompts + incremental transcript reader
  - one session-id tracker: upstream's `TabModel.sessionId` (set from any hook, cleared on SessionEnd); my `restoreCommand` still checks claude is running before `--resume`
  - `BoardView` + `SyncPublisher` read transcripts through upstream's `TranscriptReader.source/chat` (hook-reported path, sibling tabs excluded)
  - footer: upstream's bordered buttons in `ui()`; `terminal | chat | board` is one segment
  - project rows: upstream's Finder / repo-page links appended to my rename/star/move menu (`ProjectRow.links`)
  - iOS: upstream's greyed echo + prompt card mapped onto `theme.accent/attention` (my fork dropped `knifeAccent`); tool detail shows when the row is expanded
  - typing still doesn't clear `working` (my flap fix); it does clear `limited`
- [x] `make mac` BUILD SUCCEEDED · `make ios` BUILD SUCCEEDED · KnifeKit `swift test` 9/9
- [ ] Not run live (Claude runs inside Knife — Eddie relaunches): `make install-mac`, then check chat view ⌘⌥C, git panel ⌘⌥B, board segment, a permission prompt in chat, project right-click links
- [ ] Decide: leave ChatPane/GitPanel in Space Mono (upstream) or move their chrome to `ui()` — left as upstream for now to keep future merges clean

## Tab rows: double-click rename + "name | context" (2026-10-05)

First pass landed on the project list (lower sidebar) — Eddie: "i relaunched it but dont see it". Reverted; "top sidebar" = the open tabs.

- [x] Tab row label is `name | context` (context regular weight, dimmed, tail-truncated; tooltip has the full line); board cards and the phone's tab title carry it too
- [x] Context comes from Claude Code's own terminal title (its running summary of the conversation, "✳ …"). Project tabs ignored OSC titles before; now a fixed-name tab routes them into `context` (glyph stripped; "Claude Code"/shell names/the tab's own name or directory ignored, last real one stays)
- [x] Double-click a tab row → "rename tab" alert with name + context fields. A typed context is pinned until cleared; renaming a plain shell fixes its name so titles feed context from then on
- [x] Persisted in session.json (context, contextPinned, fixed) so restored tabs keep their label until Claude re-titles them
- [x] Build + `make install-mac` succeeded
- [ ] Hands-on QA after relaunch: a project tab running Claude shows `name | summary` once Claude titles it; double-click opens the alert on the row clicked; typed context survives a relaunch

## Zach's features → Swift Knife (2026-10-27)

Source: zachcooperdesigns/knife-terminal (remote `zach`), an Electron app in `desktop/` (Windows + a Mac DMG
from GitHub Actions). Its code is reference only — nothing from `desktop/` is merged. Eddie picked three
features to rebuild in the Swift app; the rest (prompt rail, typed-input selection/undo, Ctrl+V screenshot
paste, auto-trust, project folders, text size, contrast nudge, Infinite Machine look, claude on/off) stay open.

- [x] Commit the 10-05 tab-rename WIP on its own first (91a85cf)
- [x] Insert-without-sending: one path that drops text into the active tab (typed for Claude, bracketed paste for a shell, the chat composer when chat view is up)
- [x] Saved prompts: sidebar "prompts" section + a per-repo section (repo = normalized origin remote, so clones/worktrees share); ~/.knife/prompts.json; click inserts, right-click paste/copy/edit/scope/delete, + adds
- [x] Clipboard pile: terminal copies + OSC 52 land in a "clipboard" section (newest first, max 20, shown only when non-empty); click inserts and removes, right-click removes, clear empties
- [x] Project right-click: continue last chat (or switch to the tab that has it), resume chat ▸ recent chats with titles + age (✓ if open), new chat
- [x] `make mac` BUILD SUCCEEDED + unit checks on the pure parts (repo key, chat titles)
- [ ] Hands-on QA after Eddie relaunches: ⌘C and Claude's /copy fill the pile; a prompt click in a Claude tab vs a shell vs chat view; the add sheet (⌘↩ saves); repo section after a cd; project menu checkmarks + switching to an open tab

Notes: chat-view copies aren't captured (SwiftUI text selection has no hook). OSC 52 is caught by a pass-through terminalDelegate (ClipboardTap) — a SwiftTerm upgrade that adds delegate methods needs them forwarded there. The project menu's chat list is built in its own view's body, which SwiftUI runs once per right-click, not per render (measured).

### Batch 2 (Eddie: "do the rest" — he already has screenshot paste)

Four agents in parallel worktrees off 30150a2 (~/Code/.worktrees/knife-zach-*), merged back one at a time:

- [x] input (merged 4eda3f6; model tests 94/94) — Shift+arrow/Home/End highlight of typed input, type/Backspace replace it, ⌘X/⌘C, ⌘Z/⌘⇧Z; mouse selection in the input cuts (main screen only, drops tracking when unsure). Depends on Claude Code keeping the terminal cursor on its caret — if not, it switches itself off there without sending wrong keys. One-row highlights; Shift+Enter, clicks, sidebar inserts end tracking
- [x] textsize — ⌘+/⌘−/⌘0 for every terminal, persisted (36f4d28, on main)
- [ ] contrast — held: SwiftTerm has no per-cell color hook; the palette-nudge fallback greys out black-on-green badges and misses truecolor. Real fix is ~15 lines in SwiftTerm getAttributes (needs a fork/vendored copy — Eddie's call). Attempt kept on zach-port/contrast-palette
- [x] sidebar (merged 8e59586; folder tests 55/55) — claude on/off footer switch (⌘T/+ start claude when on; ⌥⌘T and shift-click = shell; right-click + menu); your own root folders; sidebar folders inside status sections (nested, collapsible, drag to file)
- [x] rail (merged 92b774f; trust+rail tests 91/91) — prompt ticks beside a Claude tab, hover to read, click to scroll back to it; auto-trust folders whose remote owner is yours (~/.knife/config.json trustedOwners) in ~/.claude.json. ~/.knife/config.json pre-created with eddieinfinitemachine, infinite-machine, waldenmeditation (gh account + admin orgs) — the app's own seed would also have trusted cheewee2000 and ramp-public. Gaps: one-line `cd x && claude` races the follow check; SwiftTerm's 500-line scrollback limits how far back the rail can jump outside fullscreen mode
- [x] Merge all four, `make mac`, re-run every logic test
- [~] Infinite Machine look (a6aecda) — REVERTED 09a3c01, Eddie prefers the old look; features keep the old styling.: tokens in ThemeManager (Tone / Color.ink…live), Helvetica Now Display Regular only, numbered section labels, solid ink active tab, 48pt header (repo label + chat title), SF Mono terminal, #00ff57 dot
- [x] All suites green on final main (pile, folders 55, trust/rail 91, input 94); `make install-mac` 19:06
- [ ] Eddie relaunches; hands-on QA of everything above (none of it has been driven by hand)
- [x] Board showed "no live agent sessions" with 22 tabs: transcript LRU (16) thrashed against the board's 2 s full scan, re-parsing ~560 MB every pass; SyncPublisher parsed on main. Fixed in e0f0721, installed. Check after relaunch: board fills within ~10 s of first open

## Expandable projects in the sidebar (2026-10-27)

- [x] ▸ on a hovered project row (trailing, after the star; ▾ stays while open) expands it; persisted in `knife.expandedProjects` (one path per line)
- [x] Up to 8 recent chats under it, one indent deeper: title, ✓ if a tab has it, age; click = switch to that tab or `claude --resume <id>`; right-click open / copy session id; "no chats yet" when empty
- [x] Chats read off the main thread; refreshed on rebuild / window key / pointer leaving the sidebar, never while the pointer is on it (only first loads land then)
- [x] Project row + its chats are one ForEach unit (drag carries them); chats aren't drag sources and a drop on them only ends the drag
- [x] Not in ⌘K search results or "elsewhere" rows; `make mac` + ExpandedProjects tests 13/13
- [ ] Hands-on QA after Eddie relaunches: disclosure click doesn't open a tab; drag a project with chats open, drop on its own chats; rows don't shift while hovering

## Sidebar tabs grouped by repo (2026-10-28)

Replaces the status groups (needs input / working / ready / active / dormant) in the tab list. Same header and row styling.

- [x] Group = the tab's repo (`Repos.key`, so clones and worktrees share one), else its folder ("~" for home), else "shell". Worked out per tab when its cwd changes (at open, OSC 7, the 15 s timer, hover exit), never per render (`TabModel.repoGroup`)
- [x] Group order: any tab needing input, then any working, then the rest; most recent `lastActivity` first within each. Manual order inside a group; drag stays inside its group
- [x] Header = repo name + dimmed count; click folds (`knife.foldedTabGroups`, one key per line). Folded: "▸ n", plus the needs-input dot + word, else the working dot
- [x] Row label drops the name when it matches the header (context alone); renamed tabs keep "name | context"
- [x] Groups stored on the window controller (`tabSections`), so ⌘1–9 / ⌘⇧[ ] / close-lands-on follow what's drawn, folded groups included. Freeze (membership + group order) while the pointer is on the tab list; released on hover exit and resign-key
- [x] `SidebarGroup` removed (sidebar was its only user; iOS has its own)
- [x] Pure logic in TabGroups.swift; tests 43/43 (scratchpad repo-groups-tests); `make mac` BUILD SUCCEEDED
- [x] Activating a tab in a folded group (⌘1–9, next/prev, notification, board, continue chat…) unfolds just that group; folding the active tab's group keeps it folded (`TabGroups.revealing`, on change of activeId only); tests 50/50
- [ ] Hands-on QA after Eddie relaunches (not driven by hand): click rows while statuses change; drag within a group and onto another group's row; fold/unfold, folded header lights up on needs input; cd into another repo in a plain shell; ⌘1–9 vs what's drawn; ⌘1–9 into a folded group opens it; a renamed tab's label

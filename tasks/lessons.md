# Lessons

## SwiftUI drag-and-drop (2026-08-27, sidebar project reorder)

**Never mutate `@State` synchronously inside `.onDrag`.** The re-render lands while AppKit is
opening the drag session and cancels or garbles it. Always
`DispatchQueue.main.async { dragging = item }`.

**Never change list geometry in response to "a drag started."** Revealing extra rows/headers
mid-drag shifts everything under the cursor, so the user is suddenly dragging over a different
row than the one they aimed at. Keep the layout constant for the whole drag.

**Every drop target in a container must commit the drag, including the ones that "aren't for it."**
Sibling targets that accept the same UTI will swallow the drop. Funnel all `performDrop`
implementations (plus the container's catch-all) through one `endDrag()` that persists the live
order — otherwise the row visibly moves and then snaps back.

**One drag-state value, not one optional per kind.** Parallel `draggingTabId` / `draggingProject`
optionals over the same `public.plain-text` payload let each target misread the other's drag. A
single `enum SidebarDrag { case tab(Int), project(String) }` makes the guards exhaustive.

**Pass identity as an argument, don't round-trip it through `@State`.** `dragging = p.path` followed
by a function that reads `dragging` back in the same call is a same-tick state read waiting to break.

## Process

**"BUILD SUCCEEDED" is not QA for anything with a pointer in it.** The first round of this feature
was reviewed against the plan and compiled clean, and every one of the five defects above was
only findable by dragging a row. When a change is interaction-shaped, either drive the real app or
say plainly that it is unverified — don't mark it done.

## Live-regrouping lists (2026-09-14, sidebar status groups — "its super buggy")

Grouping tabs by live status shipped after a clean build and no hands-on pass. Every defect
was structural and findable by reading the code for these four questions first:

**Does anything move rows while the pointer is on the list?** Activating a ready tab cleared its
status, so the row left from under the cursor. The first fix pinned the *selected* row's group,
which only relocated the jump: selecting the next row unpinned the previous one, it slid into the
group being clicked, and the highlight landed a row away from the pointer ("clicking an item in
active doesn't highlight"). Freeze group membership while the pointer is over the list instead —
order stays live so drags still work — and unfreeze on hover exit and on window resign-key.
A fix for "row moves under the cursor" that keys off *selection* will always move something at
the moment of the next click.

**Does drag reorder the model the list is actually drawn from?** Drag moved tabs in the flat
array while rows were drawn grouped, so drops didn't land and the list reshuffled mid-drag.
Constrain the drop to the dragged row's visual group.

**Is membership decided by something slower than the UI?** active/dormant hung off a 3 s
process scan, so new rows flashed into the wrong group. Prefer a value the app already owns
(a timestamp) over polling the outside world.

**Does frequent input flip the grouping key?** Every keystroke reset status, so a busy tab
flapped between groups while typing ahead.

## Technical gotchas from the same round

- **Claude Code renames its process to its version.** The kernel reports "2.1.270", not
  "claude"; match on the executable path (…/claude/versions/…). A name-based scan silently
  found zero agents.
- **A bare Esc never reached onUserInput** (it filters ESC-prefixed bytes to skip terminal
  reports), and interrupts send no Stop hook. Detect a lone 0x1b / 0x03 separately.
- **NSCursor push/pop in SwiftUI hover handlers leaks** when views reorder mid-hover. Use
  onContinuousHover with set().
- **Test extracted code, not a copy.** Pull the real enum/struct out of the source file into a
  swift script so the harness can't drift from what ships.

## "Top sidebar" means the tab list (2026-10-05, tab context line)

Eddie asked for double-click rename and a "name | context" line on "a project in the top
sidebar". I built it on the project list below the tabs; it shipped, he relaunched, and saw
nothing. The sidebar is tabs on top (each titled with its project's name), projects below.

**Rule:** when a request names a place in the UI, open the view and map the words to the
actual layout before coding — "project" in the top half is a tab. If the mapping is not
obvious, state which list is meant in the first line of the reply so the mismatch costs a
sentence, not a build.

## A restyle is not a feature (2026-10-27, Zach port)

Eddie said "do the rest" of Zach's feature list, which included "Infinite Machine look". I shipped
it as a whole-app restyle (fonts, colors, header, no emoji, SF Mono) alongside eight real features;
after relaunching: "i much prefer the way that it looked before." Reverted (09a3c01), features kept.

**Rule:** a change to how the daily-driver app *looks* — type, color, layout chrome — goes in as its
own commit and is shown before it ships: a screenshot or mock first, or behind a setting that
defaults to the current look. "Yes to the list" covers behavior; it doesn't sign off on a new
skin for the whole app.

## A second bundle id starts with empty preferences (2026-11-02, Knife 2)

Knife 2 shipped with a new bundle id, so it read none of Knife 1's `defaults` — including `chime = none`.
It chimed on every wait; Eddie: "the notifs are annoying. i dont need sounds".

**Rule:** when standing up another instance (new bundle id), diff the main app's domain first
(`defaults export com.zelig.knifeterminal -`) and carry over behavioral prefs — `chime` above all. Eddie
runs Knife silent: never introduce a sound that defaults on.

## Never block on a subprocess inside a view body (2026-11-03, "knife keeps quitting")

Right-clicking (or just re-rendering) a sidebar project row segfaulted the app: the row's
`.contextMenu` builder called `Manifest.remote(of:)`, which on a cache miss ran
`git remote get-url` through a login shell and `waitUntilExit()`ed on the main thread.
`waitUntilExit` spins the run loop, SwiftUI's update-cycle observer fires re-entrantly mid-body,
and it jumps through a null pointer (EXC_BAD_ACCESS at 0x0, `UC::DriverCore::continueProcessing`).

**Anything reachable from `body` or a `.contextMenu` builder must be pure and fast**: no
`Process`, no `waitUntilExit`, no nested run loops. Read files directly (git config is plain
text; `Repos.originURL(inConfig:)` parses it) or compute off-main and publish into state.
A `.contextMenu` builder runs on *every* render of the row, not only on right-click.

## Shells under the Knife process are not its tabs (2026-11-17, "why is my knife app so slow")

I counted Knife's child zsh processes (69), called them tabs, and timed the per-tab `pgrep` loop
over all of them: "7.4 s freeze across 69 tabs". Knife had 29 tabs; the other 41 shells belonged
to closed tabs that never exited (the bug found an hour later). The real figure was ~3 s.

**Rule:** ask the app what it has, don't infer it from the process table: `tab status <id>` on
the socket answers "gone" for a closed tab, and session.json lists the open ones. A mismatch
between the two counts is itself the finding.

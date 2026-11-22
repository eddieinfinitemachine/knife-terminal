Eddie's build of Knife Terminal: everything in CW&T's 1.4.33, plus the sidebar work that isn't in CW&T's releases.

**From this fork**
- **Sidebar folders**: right-click a section header → "new folder", then drag projects in. Folders nest ("new folder" from a folder's own menu), so UN › BOOK or AZS › LEVEL instead of one long list.
- **Folders from disk**: right-click a section header (or the empty part of the project list) → "add folder from disk…". Every folder inside it is listed as a project.
- Open tabs grouped by repo under active / dormant, with a "+" on each group to start a new claude session there.
- Expand a project to see its recent Claude chats; right-click a project to flag it for review.
- claude on / off switch for new tabs, and a prompt rail beside Claude tabs.

**New from CW&T since the last build (1.2.31 → 1.4.33)**
- Slash commands in the chat composer, files dropped on the chat view, questions that auto-continue (footer "auto-pick").
- Style profiles in the footer (house, plain, ghostty).
- Collaborative mode: right-click a tab → "Invite to Session…".
- Run a project's jobs on the laptop, another Mac, or the cloud; photos from the phone into a tab.
- Links for paths with spaces and relative paths, VoiceOver support for the terminal, and the 1.4.x round of sync, restore and tab-close fixes.

**Not notarized.** Unzip, drag to Applications, then right-click → Open the first time (or System Settings → Privacy & Security → Open Anyway). If macOS says the app is damaged, run `xattr -dr com.apple.quarantine "/Applications/Knife Terminal.app"`.

This build has no iCloud entitlement, so the iPhone mirror, phone pushes and session invites are off. It does not update itself to CW&T's releases; new builds are posted here.

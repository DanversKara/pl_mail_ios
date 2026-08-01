# What's left

Written at the end of a long session, for whoever picks this up — likely me,
with no memory of any of it. Ordered by what I would do next, not by size.

Current state: 337 tests green, iOS build clean, **not yet pushed** — see the
last section. The app pairs,
syncs, reads, writes, sends, schedules, searches and looks like itself in both
appearances.

---

## Blocked on you, not on work

**Push notifications.** The client half is built and documented in
[PUSH.md](PUSH.md). What is missing is an APNs key, which needs a paid Apple
developer account, and a sender on the plMail side. Until then there is no
background delivery at all — the app checks on foreground and on a background
schedule, and the interface says "last checked N minutes ago" rather than
implying it is live.

**The widget's data.** It installs and renders but cannot read the app's
numbers, because that needs an App Group. Same paid account. It says so on its
face rather than showing a zero it cannot justify.

**A share extension.** Sending *to* plMail from Photos or Safari needs an App
Group or Keychain sharing to hand the data over. Also paid. This is the biggest
remaining hole in attachments and it is not a large piece of work once the
account exists.

---

## Unfinished, on a branch

The reader agent was stopped mid-task. Its two finished commits are merged —
find-in-thread with a match count, and the header "show details" — but the work it had in
flight is on the branch **`worktree-agent-a40b911e6cef28b10`**, as a single
commit marked WIP. Its worktree has been removed; the branch is the only copy.

It touches `PLMailCore/Reader/ThreadFind.swift`, `ThreadFindBar.swift` and an
untracked `UITests/ReaderSmokeTests.swift`, and it stopped midway through
exercising find-in-thread against a seeded thread. Finish it or delete the
branch — do not merge it unread.

**Not started from that brief:** the attachment grid. `AttachmentRow` still
lists filenames where Gmail shows thumbnails, and there is no save or share
without opening. Read `BlobCache` first — this app deliberately does not
download eagerly, because the server is somebody's NAS.

---

## Known gaps, roughly in order

**Threading is per-message, not per-conversation, in one place.** The reader
collapses a long thread well, but the list's participant summary and count come
from denormalised fields recomputed on write. If they ever disagree with the
server, nothing notices. A contract test against a real multi-message thread
would catch it.

**Undo send only reaches as far as the outbox.** The five-second window is
local; once submitted the message is gone. The server deliberately does not
apply its web UI's grace period to JMAP submissions, so a longer window would
have to be entirely ours — which is what schedule-send already does. Worth
unifying the two ideas rather than having a countdown and a schedule that share
no code.

**Filters and rules are invisible.** plMail has them; the app neither shows nor
edits them. Read `src/Jmap/Method/` before promising anything — the pattern in
this codebase is to check what the server supports first and say plainly when
it does not, as the signature editor and label management both ended up doing.

**Conversation actions at scale.** `MailActions` caps a bulk set at 500 because
`maxObjectsInSet` says so, and the app now refuses to silently act on fewer
messages than you asked for. But there is no paging over a larger selection —
"select all" in a mailbox of 5,000 still means "the first 500, twice".

**Attachment picker beyond the obvious.** Photos and local files work. Other
document providers are untested.

**Contacts.** Autocomplete merges synced correspondents with the system address
book, ranked. There is no way to see or edit a contact, and no CardDAV.

---

## Quality debt

**VoiceOver has never had a real pass.** Dynamic Type has — every screen was
walked at accessibility sizes and the list, reader and composer restack rather
than truncate. But nobody has driven the app with the screen curtain on.

**The UI tests flake when run back to back.** Each does a full reset and a live
sign-in against the dev server. Individually reliable; in sequence, not always.
Worth making the reset cheaper rather than adding retries.

**`swift format lint --strict` has two pre-existing failures** in
`IdentitiesView.swift` and `IdentityEditorTests.swift`. Neither is mine and
neither is interesting, but they make the lint output useless as a signal.

**The README screenshots are stale.** They were taken before the restyle, so
they show saturated avatars, a grey-white background and no status column —
none of which the app looks like now. Retaking them needs the dev server up;
Docker died before I could. Reset and reseed first (`app:reset -n`, then the
`app:test:seed-*` commands), because the seeded inbox is thin and reads as test
data in a screenshot.

---

## Things that will bite you

**`swift test` passing is not `xcodebuild` passing.** `PLMailUI` is
`#if os(iOS)` and compiles away entirely on the host, so the whole view layer
can be broken while the test suite is green. This shipped a broken sidebar
once. Always run both.

**A git conflict marker in a `.strings` file is not a syntax error.** The parser
stops at the marker and every key after it silently falls back to English. Line
counts look fine. Use `scripts/resolve-catalogues.py`, or at minimum
`plutil -convert json -o - <file>` and compare *parsed* key counts.

**`String(localized:locale:)` does not choose the translation.** The locale
formats numbers and dates inside the string; the bundle picks the language. A
test asserting German output while passing `locale:` silently tests nothing,
because every lookup falls back to English and every assertion passes.

**Mutation-test the mutation harness.** One agent's run reported all fifteen
mutations surviving. `--filter` had matched zero tests — exit 0 reads as green —
and `git checkout` cannot revert an untracked file, so the mutations were still
in the tree. Commit before mutating and assert the test count per run.

**Free-tier signing.** `App/Config/Signing.xcconfig` points at the `-free`
entitlements by default so a clone builds onto a device with a free Apple ID.
Requesting APNs or an App Group there does not degrade — it fails the build
outright. See [INSTALL-ON-DEVICE.md](INSTALL-ON-DEVICE.md).

**Agents need their own simulator.** Two sharing one device overwrote each
other's builds mid-verification and produced screenshots of the wrong binary.
Create one per agent with `xcrun simctl create` and put the UDID in the brief;
the ones from this session have been deleted.

**`git push` has no credentials here.** `origin` is set to
`git@github.com:karatektus/pl_mail_ios.git` but the SSH key is not available to
this environment, so nothing has been pushed. 47 commits are waiting. If the
remote does not exist yet, create it empty — no README — or the first push will
be rejected as diverged.

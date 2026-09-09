---
id: requirements
title: "macOS menu bar app that converts Korean file names to NFC: v1 requirements"
type: requirements
version: "1.8"
date: "2026-09-10"
lang: en
parents: []
entities:
  - name: NFD
    type: standard
    definition: "Unicode Normalization Form D (decomposed). the form the macOS Finder stores Korean file names in, and the reason they appear broken on Windows as `ㅂㅗㄱㅗㅅㅓ.docx`"
  - name: NFC
    type: standard
    definition: "Unicode Normalization Form C (composed). the form Windows, Linux and most of the web use, and the form Moja aims to leave on disk"
  - name: byte-comparison
    type: constraint
    definition: "the rule that names are compared as Array(name.utf8), never with String ==. Swift's == ignores normalization and calls NFD and NFC equal, so judging by == makes this app do nothing at all"
    code:
      - CoreKit/Sources/CoreKit/Normalizer.swift
      - CoreKit/Tests/CoreKitTests/UnicodeAssumptionTests.swift
  - name: normalizer
    type: component
    definition: "pure function that converts one name component to NFC and decides whether conversion is needed. it uses only the canonical (NFC) mapping, never compatibility (NFKC), which would turn full-width characters and compatibility jamo into different letters and damage the user's name"
    code: [CoreKit/Sources/CoreKit/Normalizer.swift]
  - name: planner
    type: component
    definition: "pure logic that decides the skip rules, the depth-first ordering and the per-batch ceiling without touching the filesystem"
    code: [CoreKit/Sources/CoreKit/Planner.swift]
  - name: renamer
    type: component
    definition: "the layer that converts one name to NFC and verifies it by enumerating the parent directory again to confirm the stored raw bytes are NFC"
    code: [CoreKit/Sources/CoreKit/Renamer.swift]
  - name: folder-watcher
    type: component
    definition: "the layer watching one folder, tying together the FSEvents stream, a 1.5 s debounce, a 3 s ignore list and the recheck of deferred items"
    code:
      - CoreKit/Sources/CoreKit/FolderWatcher.swift
      - CoreKit/Sources/CoreKit/FSEventsStream.swift
      - CoreKit/Sources/CoreKit/WatchPolicy.swift
  - name: batch-converter
    type: component
    definition: "the path that shows the existing items of a watched folder in a preview first and then converts them in one go. cancelling changes nothing"
    code:
      - CoreKit/Sources/CoreKit/BatchConverter.swift
      - App/BatchSession.swift
  - name: scanner
    type: component
    definition: "the layer that walks a watched folder recursively to collect conversion targets. it filters with file-identity so a resolved symlink path does not make it walk the same folder twice"
    code: [CoreKit/Sources/CoreKit/Scanner.swift]
  - name: overflow-guard
    type: constraint
    definition: "the rule that when one event batch holds more than 500 conversion targets, nothing is processed and the state becomes 'too many items, use batch conversion'. the first sync of a cloud folder is what it targets"
    code: [CoreKit/Sources/CoreKit/Planner.swift]
  - name: stability-window
    type: constraint
    definition: "an item last modified less than 2 seconds ago may still be being written, so it is deferred. this rule and T1's 'within 2 seconds' are arithmetically incompatible, which is why T1's target was relaxed to 4 seconds"
    code: [CoreKit/Sources/CoreKit/Planner.swift]
  - name: deferred-recheck
    type: mechanism
    definition: "the device that comes back for an item deferred by the stability window. if the write already finished no new event arrives, so without this the file is never converted"
    code: [CoreKit/Sources/CoreKit/FolderWatcher.swift]
  - name: ignore-list
    type: mechanism
    definition: "the second line of defence against loops, ignoring for 3 seconds any path the app renamed itself. the first line is the rule 'do nothing if it is already NFC'; this list only cuts down needless enumeration and logging"
    code: [CoreKit/Sources/CoreKit/WatchPolicy.swift]
  - name: skip-rule
    type: concept
    definition: "the rule that leaves hidden items, download temp extensions, Office ~$ files, bundle interiors and just-modified items alone. it is the implementation of 'when in doubt, change nothing'"
    code: [CoreKit/Sources/CoreKit/Planner.swift]
  - name: package-boundary
    type: constraint
    definition: "the boundary that renames an app bundle itself but never touches its interior. the test uses URLResourceValues.isPackage rather than NSWorkspace, because a CoreKit that depends on AppKit cannot be tested without the app"
    code:
      - CoreKit/Sources/CoreKit/Planner.swift
      - CoreKit/Sources/CoreKit/Scanner.swift
  - name: login-item
    type: api
    definition: "the login item registered through SMAppService. registration is tied to the app's code signature, so an ad-hoc signed development build, whose signature changes every time, cannot verify T13 meaningfully"
    code: [App/LoginItem.swift]
  - name: log-store
    type: component
    definition: "the record kept only in ~/Library/Logs/Moja/Moja.log. it rotates past 1MB and keeps only the previous file"
    code: [CoreKit/Sources/CoreKit/LogStore.swift]
  - name: acceptance-scenario
    type: concept
    definition: "the 16 scenarios T1-T16 that gate the v1 release. v1.0.0 requires all of them to pass"
  - name: transfer-path
    type: concept
    definition: "the table recording whether a converted NFC file keeps its name after travelling through mail, messengers, cloud, USB or zip to Windows. it is not an app feature but a statement of limits, and it goes into README verbatim"
  - name: xcodegen
    type: script
    definition: "the tool that generates Moja.xcodeproj from project.yml. the .xcodeproj is generated, so it is never edited by hand"
    code: [project.yml]
tags: [requirements, v1, functional-spec, acceptance-criteria, menu-bar-app, korean-filename]
---

# macOS menu bar app that converts Korean file names to NFC: v1 requirements

> Translation of [requirements.md](requirements.md) v1.2. The Korean edition is the source of
> record where wording differs. Do not edit here.

> This document was written to be handed to Claude Code as is, and was implemented up to v0.1.0 in
> the order of §11, "Work instructions". It started as `REQUIREMENTS.md` at the repository root and
> was moved here. Where the implementation diverged from this document, §12 records it.

---

## 0. One line

A macOS menu bar app that watches folders the user picks and, whenever a file or folder name with
decomposed Hangul (NFD) appears, immediately converts it to composed form (NFC).
No server, no login; install it and you are done.

---

## 1. Background and problem

- The macOS Finder stores Korean file names as NFD (decomposed).
  Windows, Linux and most web services use NFC (composed).
- So a `보고서.docx` made on a Mac shows up on Windows as something like `ㅂㅗㄱㅗㅅㅓ.docx`, and
  search, sorting and automation break on the Windows side.
- Limits of the existing answers
  - Bandinamer: manual conversion. Renaming in the Finder or moving to another folder after
    conversion puts it back to NFD.
  - jaso (hsol/jaso, GitHub): it does watch automatically, but it bundles Python 3.11, is unsigned
    and asks for `sudo spctl --master-disable` at install. The developer has declared it unmaintained.
  - CLI tools (convmv, nfd2nfc and so on): unusable for a non-developer.
- The empty slot: a native app at the level of **download, double-click, pick a folder, done**.

---

## 2. Target user

- Someone on a Mac who exchanges Korean file names with Windows users: colleagues, clients, public
  institutions.
- Skill level: assume they have never opened a terminal.
  They can follow a guide as far as "right-click, Open" and
  `시스템 설정 → 개인정보 보호 및 보안 → 그래도 열기`
  (System Settings -> Privacy & Security -> Open Anyway).
- Main scenarios
  1. Sharing a Google Drive or OneDrive sync folder with a Windows colleague.
  2. Making files in Desktop, Downloads or Documents and sending them by mail or messenger.

---

## 3. Scope

### 3.1 In v1

- Real-time watching of one or more chosen folders and automatic NFD to NFC conversion (file and
  folder names, subfolders included)
- Batch conversion of existing items in a chosen folder (preview and confirm before running)
- Menu bar UI, pause and resume watching
- Launch at login option
- Recent conversion history
- Korean UI

### 3.2 Out of v1 (explicit non-goals)

- Reverse conversion, NFC to NFD
- Repair tooling on the Windows side
- Mac App Store distribution (not sandboxed)
- Multilingual UI
- Intervening in transfer paths (mail, messenger, cloud apps). The app is responsible only for
  **the name stored on disk**.
- Notification Center banners (v2 candidate)
- Automatic updates (v2 candidate, Sparkle under consideration)

---

## 4. Functional requirements

Notation: **required** = a v1 release condition, *recommended* = include if possible.

### FR-1. Folder watching (required)

- Watch each registered folder recursively, subfolders included.
- Events watched: creation, rename, move (into the folder).
- Several folders may be registered, each with its own on/off toggle.
- The list of watched folders survives an app restart.
- If a registered folder does not exist at startup (an external disk was detached, say), skip it
  without error and show it in the menu as `연결 안 됨` ("not connected").

### FR-2. Conversion rule (required)

- An item is a conversion target only when the NFC normalization of its name differs from the
  original **byte for byte**.
  (If they are equal, do nothing. This is the core of preventing an infinite loop.)
- Conversion applies to the whole file name, extension included.
- **Skip** the following:
  - hidden files (starting with `.`), `.DS_Store`
  - download temporaries: extensions `.download`, `.crdownload`, `.part`, `.partial`, `.tmp`, `.temp`
  - Office temporaries: names starting with `~$`
  - package and bundle **interiors**: `.app`, `.photoslibrary`, `.bundle`, `.framework`, `.pkg`, and
    any directory for which `NSWorkspace.isFilePackage` is true. (The bundle's own name is a
    conversion target.)
  - user-defined exclusion patterns (*recommended*; a list of extensions is enough for v1)
- An item modified within the last **2 seconds** may still be being written, so defer it.
  Re-examine after a 1.5 s debounce following the event.

### FR-3. Rename implementation (required, has a trap)

- APFS is normalization-insensitive and normalization-preserving. That is, it treats `한글.txt`
  (NFD) and `한글.txt` (NFC) as **the same name**.
- So `FileManager.moveItem(at:to:)` can fail on the judgement that the destination "already exists".
  The order to follow:
  1. Call POSIX `rename(2)` directly. (It should work on the same principle as a case-only rename.)
  2. If 1 fails, rename to a temporary name (original + `.nfc-tmp-<uuid>`) and then to the final NFC
     name.
  3. After the change, always list the directory again and verify that the **bytes actually stored**
     are NFC. (Check the `unicodeScalars` of the string `FileManager.contentsOfDirectory` returns.)
- On verification failure, record the item as "failed" and do not retry. (The next event retries it
  naturally.)

### FR-4. Folder rename ordering (required)

- When handling several items at once, process **the deepest path first**.
  Renaming a parent folder first invalidates the paths below it.
- After renaming a folder, list what is under it again and process that.

### FR-5. Loop and overflow prevention (required)

- Events caused by the app's own rename are filtered naturally by FR-2's "ignore it if it equals the
  NFC form" rule. In addition, any path the app changed within the last 3 seconds goes on an ignore
  list.
- If one event batch would process more than 500 items, process nothing and show the state
  `항목이 많습니다 — 일괄 변환을 사용하세요` ("too many items, use batch conversion") in the menu.
  (This prevents an overflow during the initial replication of a sync folder.)

### FR-6. Batch conversion (required)

- The menu offers "convert existing items" for one watched folder.
- Show a **preview window** first: the number of targets, the before/after name list (up to 200
  shown, the rest as "and N more"), and the count and reasons for skipped items.
- Run only when the user presses the convert button. Show success and failure counts afterwards.
- Pause real-time watching of that folder during the batch and resume when it finishes.

### FR-7. Menu bar UI (required)

Clicking the menu bar icon brings up the menu below. There is no separate main window.

```
[아이콘] 감시 중 (3개 폴더)            ← 상태 줄, 클릭 불가
────────────────────────────
✓ 데스크탑                              ← 폴더별 토글
✓ 다운로드
  구글 드라이브/공유 (연결 안 됨)
────────────────────────────
폴더 추가…
폴더 관리…                              ← 제거·순서 (간단한 시트)
────────────────────────────
기존 항목 일괄 변환 ▸  데스크탑 / 다운로드 / …
최근 변환 내역…                          ← 마지막 100건, 시간·경로·전/후
────────────────────────────
감시 일시정지                            ← 토글 시 아이콘이 흐려짐
로그인 시 자동 실행                       ← 체크 표시
────────────────────────────
도움말 / 정보
종료
```

- Icon: SF Symbol `hat.widebrim`. It exists from macOS 15 on, so 13 and 14 fall back to
  `graduationcap`.
  Watching = default, paused = translucent, has errors = a small badge
  (the hat symbols have no badge variant, so the exclamation mark at the lower right is composited
  by hand).
- No Dock icon (`LSUIElement = true`).

### FR-8. First-run onboarding (required)

- One small window on first run:
  1. two sentences on what the app does
  2. an "add folder" button leading to `NSOpenPanel` (directory selection, multiple allowed)
  3. a note that macOS will show a permission prompt for Desktop, Documents or Downloads
  4. a "launch at login" checkbox (on by default)
- Onboarding reappears until at least one folder has been added.

### FR-9. Launch at login (required)

- Use `SMAppService.mainApp` (macOS 13+).
- On registration failure (the user declined in System Settings), show the state in the menu and
  point to `시스템 설정 → 일반 → 로그인 항목` (System Settings -> General -> Login Items).

### FR-10. Logging (required)

- In memory: the last 100 conversions (time, original path, new name, result).
- On disk: append to `~/Library/Logs/<app name>/<app name>.log`. Rotate past 1MB, keeping only the
  most recent one.
- Privacy: logs stay local. The app makes no network calls of any kind.

### FR-11. Settings persistence (required)

- Stored in `UserDefaults`: the list of watched folder paths with their toggles, the paused state,
  and whether onboarding is complete.
- Since the app is not sandboxed, security-scoped bookmarks are unnecessary; path strings suffice.

---

## 5. Non-functional requirements

| Item | Target |
|---|---|
| Supported OS | macOS 13 Ventura or later (uses MenuBarExtra and SMAppService) |
| Architecture | Universal (Apple Silicon and Intel) |
| Language and framework | Swift 5.9+, SwiftUI (MenuBarExtra) with AppKit only where needed. No external runtime such as Python |
| Third-party dependencies | zero for v1. If unavoidable, only through SwiftPM |
| App size | under 10MB |
| Idle footprint | CPU near 0% while watching, memory under 30MB (as read in Activity Monitor) |
| Network | none. No outbound connection of any kind |
| Sandbox | not applied (no App Store distribution). Hardened Runtime is applied |
| Accessibility | menu items must be readable by VoiceOver |
| Principle on failure | when in doubt, **change nothing**. A failed rename is recorded quietly and never interrupts the user's work |

---

## 6. Technical design guide

Claude Code may use its own judgement, but the choices below are already validated; follow them
absent a specific reason.

- **Project generation**: generate the Xcode project with XcodeGen (`project.yml`).
  Never edit `.xcodeproj` by hand. Keep build and archive reproducible through `xcodebuild` scripts.
- **Folder watching**: FSEvents (`FSEventStreamCreate`) with `kFSEventStreamCreateFlagFileEvents`,
  latency 1.0 s. `DispatchSource` only sees the top folder, so it is not used.
- **Normalization**: `String.precomposedStringWithCanonicalMapping` (= NFC).
  Compare through `unicodeScalars` or `utf8` bytes. **Never use** the `==` operator; it ignores
  normalization.
- **Renaming**: see FR-3. Calling `rename(2)` directly is the first choice.
- **Concurrency**: file work on a single serial queue. UI on the main actor.
- **Module structure (proposed)**
  ```
  App/                 - entry point, MenuBarExtra, onboarding views
  Core/Normalizer      - pure functions: name to NFC, decide whether conversion is needed (tested)
  Core/Renamer         - rename attempt and verification (FR-3)
  Core/Watcher         - FSEvents wrapper, debounce, ignore list
  Core/Planner         - path ordering (deepest first), skip rules (FR-2, FR-4)
  Core/Store           - settings, logs
  ```
- **Tests**: `Normalizer` and `Planner` are pure logic, so unit test them with XCTest.
  `Renamer` gets an integration test that creates NFD files in a temporary directory.

---

## 7. Test scenarios (acceptance criteria)

All of these must pass for the v1 release.

The command that creates an NFD file (to be provided as a test fixture script):
```bash
touch "$(printf '한글 문서.txt' | iconv -f utf-8 -t utf-8-mac)"
```

| # | Scenario | Expected |
|---|---|---|
| T1 | create a file with an NFD name in a watched folder | converted to NFC within 4 s. one log entry (originally 2 s, see §12.4a) |
| T2 | create a file already in NFC | nothing happens. zero log entries |
| T3 | edit an NFC file's Korean name in the Finder (the Finder stores NFD) | it goes back to NFC |
| T4 | drag an NFD file from another folder into a watched one | converted to NFC |
| T5 | an NFD file three subfolders deep | converted |
| T6 | NFD files inside an NFD-named folder | files first, folder after. all converted, no path errors |
| T7 | downloading a file with a Korean name in Safari or Chrome | untouched while `.download`. converted after completion if needed |
| T8 | start watching while a Korean-named document is open in Word | the `~$` temporary is ignored. saving works normally |
| T9 | an `.app` bundle in a watched folder (NFD resources inside) | the bundle interior is untouched |
| T10 | copy 1,000 NFD files into a watched folder at once | the overflow state is shown. batch conversion can handle it |
| T11 | detach an external watched disk and restart the app | no error, shown as `연결 안 됨`. watching resumes on reconnect |
| T12 | batch conversion preview | count and before/after names correct. `취소` changes nothing |
| T13 | turn on launch at login and log back in | present in the menu bar |
| T14 | create an NFD file while paused | unchanged. converted on resume (rescan) |
| T15 | leave watching idle for 24 hours | memory stays under 30MB, no crash |
| T16 | zip a converted file and open it on Windows | Korean displays correctly |

### 7.1 Transfer path verification (for the README, not an app feature)

Record in a table whether a converted NFC file arrives intact on the receiving (Windows) side
through each path below. This table goes into README verbatim.

| Path | Result | Notes |
|---|---|---|
| KakaoTalk file sharing (`카카오톡 파일 공유`) | `유지됨` (survived) | verified 2026-09-09 |
| Slack file sharing (`슬랙 파일 공유`) | `유지됨` (survived) | verified 2026-09-09 |
| Google Drive upload (`구글 드라이브 업로드`) | `깨짐` (broken) | verified 2026-09-09 |
| OneDrive sync (`원드라이브 동기화`) | `미검증` (unverified) | |
| iCloud Drive to iCloud for Windows (`아이클라우드 드라이브 → 윈도우 iCloud`) | `깨짐` (broken) | verified 2026-09-09 |
| USB flash drive, exFAT (`USB 메모리 (exFAT)`) | `깨짐` (broken) | the app cannot fix this. see rename-measurements §2.3 |
| Finder's built-in zip (`파인더 기본 압축(zip)`) | `미검증` (unverified) | zip's missing UTF-8 flag is a known problem, but nobody has opened one on Windows to check (T16) |
| AirDrop to iPhone to Windows (`AirDrop → 아이폰 → 윈도우`) | `미검증` (unverified) | |

Results take one of three values. `유지됨` (survived) means the composed name the app produced
arrived intact on the receiving side, `깨짐` (broken) means something along the transfer path
decomposed it again, and `미검증` (unverified) means nobody has checked yet. Wording like
"변환됨" (converted) is never used, because it reads equally well as the app having fixed the name
and as the transfer path having damaged it.

A mail attachment cannot be recorded as one row in the table above. The party that encodes the
attachment's file name into the MIME header is the sending client, while the party that stores that
name and hands it back out on download is the receiving mail service, so the result varies with
each combination of the two providers. KakaoTalk and Slack do not have this problem because sender
and receiver are on the same provider; it applies only to mail, which crosses providers. Verify and
record each combination separately, and never conclude that one combination being correct makes
another one correct.

| Sender | Receiver | Result | Notes |
|---|---|---|---|
| Naver Mail, web (`네이버 메일 (웹)`) | Naver Mail (`네이버 메일`) | `유지됨` (survived) | verified 2026-09-09 |
| Naver Mail, web (`네이버 메일 (웹)`) | Gmail (`지메일`) | `깨짐` (broken) | verified 2026-09-09 |
| Gmail, web (`지메일 (웹)`) | Gmail (`지메일`) | `깨짐` (broken) | verified 2026-09-09 |
| Gmail, web (`지메일 (웹)`) | Naver Mail (`네이버 메일`) | `유지됨` (survived) | verified 2026-09-09 |
| macOS Mail app (`macOS 기본 메일 앱`) | Naver Mail (`네이버 메일`) | `유지됨` (survived) | verified 2026-09-09 |
| macOS Mail app (`macOS 기본 메일 앱`) | Gmail (`지메일`) | `유지됨` (survived) | verified 2026-09-09 |

This verification did not record whether the receiving side was opened in a web browser or received
in a mail app. The paragraph below calls for that axis, so fill it into the notes when these
combinations are verified again.

The result may also diverge depending on whether the receiving side downloads through a web browser
or receives in a mail app such as Outlook. Splitting that axis into its own columns would inflate
the table too far, so record which one it was in the Notes column at verification time.

---

## 8. Distribution

- Build: `xcodebuild archive` to a `.app`, zipped with `ditto -c -k --keepParent`. A DMG is optional
  for v1.
- Signing
  - First pass: ad-hoc signature plus Hardened Runtime, without a Developer ID.
    Put the "unidentified developer" workaround in README with screenshots (as of Sequoia:
    `시스템 설정 → 개인정보 보호 및 보안 → 그래도 열기`).
  - Second pass (after gauging reception): join the Apple Developer Program, sign with Developer ID,
    notarize with `notarytool`, then staple.
    Script this as `scripts/release.sh`, taking account details from environment variables.
- Channel: GitHub Releases. A Homebrew cask later (*recommended*).
- Versioning: SemVer. v1.0.0 = every acceptance criterion above passes.

---

## 9. README requirements

- A shape understandable within three seconds of landing: one line of problem, one line of solution,
  a download button, three install screenshots.
- The transfer path verification table (§7.1).
- State the relationship to existing tools: Bandinamer (manual conversion) and jaso (same approach,
  distribution unfinished). Link both and say in one sentence what slot this app fills ("the version
  you only have to install").
- State the limits: the app changes only the name on disk. Some apps may rename again during
  transfer (see the verification table).
- Privacy: no network traffic, logs stay local.
- Licence: MIT.

---

## 10. Open questions (Claude Code must not settle these alone; ask in the first report)

1. **App name**. Candidates: 한글잇기 / 자모잇기 / 이음. The English bundle ID follows once the name
   is settled.
2. **Default watched folders**: whether onboarding pre-checks Desktop, Downloads and Documents, or
   starts empty.
3. **Resume behaviour after a pause**: whether a full rescan is the default, or only events after
   the resume are seen.

### 10.1 Decisions (2026-09-04)

| # | Item | Decision |
|---|---|---|
| 1 | App name | **Moja / 모자**. Bundle ID `dev.liampark.moja` |
| 2 | Default watched folders | onboarding **presents Desktop, Downloads and Documents pre-checked**, but nothing is registered until the user presses add |
| 3 | Resume behaviour | **full rescan**. If there are more than 500 targets, hand off to the batch conversion preview instead of converting automatically (consistent with FR-5) |

---

## 11. Work instructions (execution order for Claude Code)

1. Read this document and **ask the three open questions in §10 first**. Write no code before the
   answers arrive.
2. Once answered, create the XcodeGen `project.yml` and the directory structure, and confirm an
   empty menu bar app launches. (Commit 1)
3. Implement `Core/Normalizer` and `Core/Planner` with unit tests. Tests come first. (Commit 2)
4. Implement `Core/Renamer` and verify FR-3's APFS trap with integration tests (T1-T6). At this
   stage, **measure** whether `rename(2)` really changes the stored form and report the result.
   (Commit 3)
5. Implement `Core/Watcher` (FSEvents, debounce, ignore list, overflow guard). (Commit 4)
6. Attach the menu bar UI, onboarding, settings persistence, login item and logging. (Commit 5)
7. Batch conversion with preview. (Commit 6)
8. Run T1-T15 of §7 one by one and produce the results table. Fix and re-verify what fails.
   (Commit 7)
9. `scripts/build.sh`, `scripts/release.sh`, the test fixture script, a README draft. (Commit 8)
10. At the end of each stage, report in three lines **what was done and what is uncertain**.
    If something had to be implemented differently from the document, say why.

Principles:

- When in doubt, change nothing. Code that could lose the user's files is blocked ahead of any
  convenience.
- Ask before adding a third-party dependency.
- Korean UI text is polite, short, and keeps technical terms (NFD/NFC) to the help screen.

---

## 12. Where the implementation diverged (updated during development)

Where the implementation differs from the document, and why. This is the record called for by work
instruction 10.

### 12.1 FR-3: `renamex_np(RENAME_EXCL)` becomes the first choice

The measurements are in [rename-measurements](../research/rename-measurements.en.md).
FR-3's premise **holds**: on APFS, `rename(2)` really does change the bytes stored on disk from NFD
to NFC.

The first choice changes to `renamex_np(src, dst, RENAME_EXCL)` all the same. Measurement showed it
succeeds outright, with no `EEXIST`, even on a volume that ignores normalization, and the stored
bytes become NFC. It behaves and performs like `rename(2)` while adding the guarantee that a
genuinely different destination file is never overwritten.

```
1. renamex_np(src, dst, RENAME_EXCL)
   |- success       -> go to step 5, verification
   |- ENOTSUP(45)   -> driver does not support it (exFAT and the like). go to step 3
   `- EEXIST(17)    -> go to step 3
2. (not applicable)
3. compare (st_dev, st_ino) from lstat(src) and lstat(dst)
   |- same file      -> a volume ignoring normalization. proceed with rename(2) (safe)
   `- different file -> a real collision. stop and record it. never overwrite
4. if it still does not change, two-step fallback: src -> src + ".nfc-tmp-<uuid>" -> dst
5. verify: enumerate the parent directory again and confirm the stored raw bytes are NFC
```

The "different file" branch in step 3 did not arise on any local volume (APFS, HFS+, exFAT). It
stays anyway: SMB and NFS were not measured, the cost is a single `lstat`, and what is lost when it
is wrong is the user's file.

**Correcting a planning-stage error**: exFAT was taken to be a "normalization-sensitive" volume on
which `rename(2)` would overwrite a coexisting counterpart. Measurement showed the macOS exFAT
driver ignores normalization and forces NFD, so coexistence is impossible to begin with.

### 12.1a FR-3 verification: Foundation is fine for reading

The `FileManager.contentsOfDirectory` verification FR-3 specified **is valid**. The enumeration APIs
preserve the bytes on disk (the comparison must be on bytes, not `==`).

Conversely, **Foundation cannot be used for writing**. `NSString.fileSystemRepresentation` and
`URL.withUnsafeFileSystemRepresentation` **decompose the path to NFD**, so
`FileManager.moveItem(at:to:)` does not fail: it **succeeds while writing NFD**. That is the real
reason FR-3 called for direct POSIX calls.

Build paths directly with `String.withCString` or `Array(name.utf8)`.

### 12.1b Volume capability probe (new)

On HFS+ and exFAT the kernel forces names to NFD, so storing NFC is impossible by any method. To
stop infinite retries, **measure once per volume**: create a hidden temporary file with an NFC name
in the target directory, check the stored form, delete it immediately, and cache the result by
`st_dev`. Matching on the `f_fstypename` string is not used, because it can depend on the server
implementation, as with SMB.

An unsupported volume is shown as `이 디스크(exFAT)는 변환을 지원하지 않습니다`
("this disk (exFAT) does not support conversion") and skipped.

### 12.2 FR-2: `NSWorkspace` is not used for package detection

FR-2 named `NSWorkspace.isFilePackage`, but that drags AppKit into the pure logic layer.
Foundation's `URLResourceValues.isPackage` (`.isPackageKey`) gives the same verdict.

### 12.3 §6 module structure: `Core/*` split into a local SwiftPM package, `CoreKit`

Work instructions 3 and 4 demand "tests first", but an XCTest bundle attached to the app target has
to launch the host app every time, which makes the TDD loop slow. As a local package,
`swift test --package-path CoreKit` runs in seconds. Module names and the division of
responsibility are exactly as documented. Only `SMAppService` (the login item) needs the main
bundle, so it stays in the App layer.

### 12.4 §5 language: Swift 5 language mode, not Swift 6

The toolchain is Swift 6.3 and a new Xcode 26 project defaults to Swift 6 mode. But FSEvents is
built on a C callback with a context pointer, which collides head-on with strict concurrency. The
"single serial queue plus main actor" model §6 specified is upheld directly through `@MainActor`
discipline, and the move to Swift 6 mode is deferred past the v1 release. The document's
"Swift 5.9+" requirement is satisfied.

### 12.4a T1's "within 2 seconds" is incompatible with FR-2

Measured: **3.09 seconds** from creating a decomposed name in a watched folder to it becoming
composed.

Broken down, the 2 seconds T1 asks for is arithmetically impossible.

| Step | Time | Basis |
|---|---|---|
| FSEvents latency | 0.3 s | §6 proposed 1.0 s. reduced to chase T1 |
| debounce | 1.5 s | FR-2 |
| -> first examination | 1.8 s | the file is 1.8 s old |
| stability window not met | — | caught by FR-2's "defer if within 2 seconds", so **deferred** |
| recheck | +1.5 s | see §12.4b |
| -> actual conversion | **about 3.1 s** | |

FR-2 says "defer anything modified within 2 seconds". For a file to be older than 2 seconds, at
least 2 seconds must pass, and event delivery and processing add to that. **As long as FR-2 holds,
T1's 2 seconds is unreachable.** Keeping the 1.0 s FSEvents latency from §6 would have made it
3.8 seconds.

Options (a decision is needed):

1. **Relax T1's target to 4 seconds**: leave the safety rule alone. 3.1 seconds is hard for a user
   to tell apart. *Recommended.*
2. Shorten the stability window from 2 s to 0.5 s: T1 passes, but the risk of touching a file
   mid-write rises. It conflicts with §5's "when in doubt, change nothing".
3. Process immediately when the file size has not changed between two examinations: accuracy rises
   but state tracking grows, and a file paused mid-append is still not caught.

**Decision (2026-09-04): option 1.** T1's target was relaxed to 4 seconds (reflected in the §7
table). The 2-second stability window stays. Not touching a file mid-write matters more than one
second of responsiveness.

### 12.4b Rechecking deferred items (new)

FR-2 only said "re-examine after a 1.5 s debounce following the event", but **nothing comes back**
for an item that examination deferred as "still being written". The write may already have
finished, in which case no new event arrives. Left alone, that file keeps its decomposed name
forever.

`FolderWatcher` schedules another sweep of the same folder 1.5 s later whenever a deferred item
exists.

### 12.4c Duplicate folder scanning (found during implementation)

The same folder can arrive as several path strings. FSEvents gives the resolved path
(`/private/var/…`) while the settings hold the original (`/var/…`). Filtering duplicates by string
walks the same folder twice, doubling the item count and miscalculating the overflow verdict by the
same factor. `Scanner` filters duplicates by ``FileIdentity`` (`st_dev`, `st_ino`), not by path.

### 12.5 Volumes where conversion is impossible (measured)

**On HFS+ and exFAT the kernel forces file names back to NFD.** Even creating the name directly as
NFC stores NFD, so no rename strategy can work. The volume capability probe of §12.1b filters them
out, showing `이 디스크(exFAT)는 변환을 지원하지 않습니다` and skipping them.

This directly affects the **USB flash drive, exFAT** row of the transfer path table. Copying a file
converted to NFC onto an exFAT USB stick makes macOS store NFD again. Moja cannot fix it, so it is
stated in README's limitations.

SMB, NFS and cloud sync folders are still unmeasured. Passing a path to
`scripts/probe-volume.swift` produces the same table. That happens in commit 7.

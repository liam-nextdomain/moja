---
id: acceptance-results
title: "Acceptance criteria results"
type: verification
version: "1.2"
date: "2026-09-11"
lang: en
parents:
  - id: requirements
    version: "1.0"
    sections: ["7", "12.4a"]
    note: "the result of verifying T1-T16 of §7 against the real app"
  - id: rename-measurements
    version: "1.0"
    sections: ["2.3", "2.4"]
    note: "the basis for T16's exFAT constraint and the shell globbing trap"
entities:
  - name: acceptance-runner
    type: script
    definition: "automated verifier that launches the real app and checks T1-T11 and T14 with real files. the app takes MOJA_DEFAULTS_SUITE and MOJA_LOG_DIR so the user's settings and logs are never touched, and every file name is handled byte by byte"
    code: [scripts/acceptance.swift]
  - name: unverified-scenario
    type: concept
    definition: "T15 (24 hours idle) and T16 (opening on Windows), left because this environment offers no way to check them. the last thing blocking v1.0.0"
  - name: reconnect-recovery
    type: mechanism
    definition: "recovery that releases the watcher of a folder that went 'not connected' and listens for volume mount notifications, running a secondary sweep only while at least one folder is disconnected, for network shares that send no notification"
    code:
      - App/AppModel.swift
      - CoreKit/Sources/CoreKit/FolderWatcher.swift
tags: [verification, acceptance, release-gate, unverified]
---

# Acceptance criteria results

> Translation of [acceptance-results.md](acceptance-results.md) v1.2. The Korean edition is the
> source of record where wording differs. Do not edit here.

Verification results for T1-T16 of requirements §7.

- Verified: 2026-09-05. T13 alone was checked separately on 2026-09-11.
- Target: `Moja.app` (Debug build), macOS 27.0, Apple Silicon.
  T13 was checked against the v0.1.0 release build installed in `/Applications`.
- Automated: `swift scripts/acceptance.swift`. It launches the real app and checks with real files.
  The user's settings and logs are never touched (the app takes the `MOJA_DEFAULTS_SUITE` and
  `MOJA_LOG_DIR` environment variables).

---

## 1. Results

| # | Scenario | Result | Method | Notes |
|---|---|---|---|---|
| T1 | create a file with a decomposed name | ✅ | auto | converted in about 3.1 s, one log entry. the target is 4 s (requirements §12.4a) |
| T2 | create a file already in composed form | ✅ | auto | nothing happens, zero log entries |
| T3 | save the name back in decomposed form | ✅ | auto | reverted in about 1.6 s |
| T4 | drag in from another folder | ✅ | auto | converted in about 3.3 s |
| T5 | a file three subfolders deep | ✅ | auto | |
| T6 | decomposed files inside a decomposed folder | ✅ | auto | files first, folders after; no path errors |
| T7 | a file still downloading | ✅ | auto | untouched while `.download`, converted once complete |
| T8 | a temporary file from an editor | ✅ | auto | `~$` entries left alone |
| T9 | an app bundle | ✅ | auto | only the bundle name changes; the inside is left alone |
| T10 | 1,000 files dropped at once | ✅ | auto | flagged as an overflow; nothing touched |
| T11 | detach an external disk and restart | ✅ | auto | runs without error; watching resumes on reconnect |
| T12 | batch conversion preview | ✅ | manual | count and before/after names correct; `취소` changes nothing |
| T13 | launch at login, then re-login | ✅ | manual | in the menu bar right after the re-login. the build is ad-hoc signed, so it must be checked again after a Developer ID signature |
| T14 | created while paused, then resumed | ✅ | auto | untouched while paused, converted by the rescan on resume |
| T15 | 24 hours idle | ⏳ | — | **unverified** (see §2) |
| T16 | zip it and open on Windows | ⏳ | — | **unverified** (see §2) |

The 12 automated checks can be re-run at any time with `scripts/acceptance.swift`.

```sh
./scripts/build.sh
swift scripts/acceptance.swift
```

### T13: launch at login

Checked by hand on 2026-09-11. With launch at login turned on in a Release build installed in
`/Applications`, the app was in the menu bar right after logging back in. The system boot time
and the app's process start time matched, and the login item registration pointed at
`/Applications/Moja.app`.

The app used for the check is the same binary as the v0.1.0 release asset. The executable inside
the distributed zip and the executable of the installed copy matched by SHA-256.

`5904ca7d58796c8edd1a09a3f4dc72b7383d3928960f52c192f1a93ee3dc2d89`

So this result applies as-is to the build users actually download. The release note's wording,
`이 배포본으로 확인했다` ("checked with this distributed build"), rests on this.

The build is still **ad-hoc signed**, though. Nothing was rebuilt after it was installed, so the
signature stayed the same and the registration was able to survive. Attaching a Developer ID
signature changes the code signature and invalidates the existing registration, so whether
re-registration then works correctly **has to be checked again**.

---

## 2. Not yet verified

Stated plainly: there was no way to check the two below in this environment.

### T15: 24 hours idle (memory under 30MB)

It needs 24 hours. The following were checked instead.

- the ignore list really does drop expired entries (the 1,000-entry cleanup test in `WatchPolicyTests`)
- the debounce restarts its clock after draining
- no crash while the acceptance script launched the app repeatedly and dropped in 1,000 files

**To do**: leave it running for a day and read the memory figure in Activity Monitor.

### T16: opening on Windows

It needs a Windows machine. There is, however, a **confirmed constraint**: the macOS exFAT and
HFS+ drivers force file names to be stored in decomposed form
([rename-measurements](../research/rename-measurements.en.md)). So copying a file converted to
composed form onto an exFAT USB stick makes macOS turn it back into decomposed form.
**This is not something Moja can fix.**

**To do**: compress with Finder's built-in zip and open it on Windows. Fill in the transfer path
table in requirements §7.1 at the same time.

---

## 3. Fixed during verification

**T11: watching did not resume after reconnect.** On the first run the app survived the disk being
pulled and showed `연결 안 됨` ("not connected"), but re-attaching the disk did not bring watching
back. The watcher still occupied its slot after failing to start, so no new one was created.

The fix: when a folder goes `연결 안 됨`, release its watcher and listen for `NSWorkspace` volume
mount notifications. For the case where no notification arrives (a network share), run a 30-second
secondary sweep, but **only while at least one folder is disconnected**.

---

## 4. Notes on method

Never prepare a file name test through the shell. zsh normalizes globbing results into composed
form, so a command like `cp staging/* watched/` copies decomposed names as composed ones. T10 was
prepared that way once and nearly produced the wrong conclusion, that "the app converted all 600
files". The app had correctly done nothing at all to files that were already composed.

The acceptance script handles every file name byte by byte and uses `ditto` or a direct `rename(2)`
for bulk input.

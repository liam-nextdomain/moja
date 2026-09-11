---
id: rename-measurements
title: "Measuring what `rename(2)` stores"
type: measurement
version: "1.2"
date: "2026-09-11"
lang: en
parents:
  - id: requirements
    version: "1.0"
    sections: ["FR-3", "6", "11"]
    note: "measures the premise behind FR-3: whether rename(2) changes the bytes on disk"
entities:
  - name: renamex_np
    type: api
    definition: "POSIX rename extension taking a RENAME_EXCL flag. on APFS it succeeds without EEXIST even though the volume ignores normalization, and rewrites the stored bytes as NFC. exFAT returns ENOTSUP(45) and HFS+ returns EEXIST(17)"
    code:
      - CoreKit/Sources/CoreKit/POSIXFile.swift
      - CoreKit/Sources/CoreKit/Renamer.swift
  - name: guarded-move
    type: mechanism
    definition: "the rename gate that folds EEXIST/ENOTSUP handling and the inode comparison into one function used by both the first attempt and the two-step fallback. a fallback using only renamex_np dies on exFAT at the temporary-name step with ENOTSUP, so it reports a plain failure instead of 'unsupported' and retries forever"
    code: [CoreKit/Sources/CoreKit/Renamer.swift]
  - name: file-identity
    type: mechanism
    definition: "the (st_dev, st_ino) pair. it decides whether a destination is the same file or a real collision, and it also filters out the same folder arriving twice, once by its resolved path and once by the symlink"
    code:
      - CoreKit/Sources/CoreKit/POSIXFile.swift
      - CoreKit/Sources/CoreKit/Scanner.swift
  - name: volume-capability-probe
    type: mechanism
    definition: "a once-per-volume measurement: create a hidden temporary file with an NFC name in the target directory, read back the stored form, delete it immediately, and cache the answer by st_dev. matching on the f_fstypename string is not used because SMB depends on the server implementation and drivers change"
    code: [CoreKit/Sources/CoreKit/VolumeCapabilities.swift]
  - name: unsupported-volume
    type: concept
    definition: "a volume such as HFS+ or exFAT whose kernel driver forces names back to NFD, so that even creating an NFC name directly stores NFD and no strategy can convert it. shown as '이 디스크(exFAT)는 변환을 지원하지 않습니다' and left alone"
    code: [CoreKit/Sources/CoreKit/VolumeCapabilities.swift]
  - name: banned-foundation-api
    type: constraint
    definition: "FileManager.moveItem, createFile(atPath:), NSString.fileSystemRepresentation, URL.withUnsafeFileSystemRepresentation. they decompose the path to NFD, so they do not fail: they succeed while writing NFD. reading (directory enumeration) is safe"
    code:
      - CoreKit/Sources/CoreKit/CoreKit.swift
      - CoreKit/Sources/CoreKit/DirectoryReader.swift
  - name: zsh-globbing-trap
    type: concept
    definition: "zsh normalizes globbing results to NFC, so a command like `cp staging/* watched/` copies NFD names as NFC. this is why a file name test must never be prepared through the shell"
  - name: probe-volume
    type: script
    definition: "the measurement script that rebuilds the §1 table once a new volume is mounted and its path is passed in. it never goes through Foundation's path conversion"
    code: [scripts/probe-volume.swift]
tags: [measurement, filesystem, apfs, hfs-plus, exfat, posix, unicode-normalization, foundation-limits, transfer-path]
---

# Measuring what `rename(2)` stores

> Translation of [rename-measurements.md](rename-measurements.md) v1.0. The Korean edition is the
> source of record where wording differs. Do not edit here.

An answer to requirements §11, item 4: "**measure** whether `rename(2)` actually changes the stored
form". The whole product rests on that premise, so it was measured before commit 2 began.

- Measured: 2026-09-04
- Environment: macOS 27.0 (build 26A5425a), Apple Silicon, Swift 6.3.3
- Method: disk images per filesystem via `hdiutil`, measured directly through POSIX calls.
  No Foundation path conversion; only `open(2)`, `rename(2)` and `readdir(3)`.
- Test name: `한글.txt`
  - NFC `ed959ceab8802e747874` (10 bytes)
  - NFD `e18492e185a1e186abe18480e185b3e186af2e747874` (22 bytes)

---

## 1. Summary

| Filesystem | Stores NFC | Normalization | `rename(2)` converts | `renamex_np(RENAME_EXCL)` | NFD and NFC coexist |
|---|---|---|---|---|---|
| **APFS** | ✅ yes | ignored | ✅ **yes** | ✅ succeeds | no |
| **APFS (case sensitive)** | ✅ yes | ignored | — | — | no |
| **HFS+** | ❌ kernel forces NFD | ignored | ❌ no | `EEXIST` | no |
| **exFAT** | ❌ kernel forces NFD | ignored | ❌ no | `ENOTSUP (45)` | no |
| SMB / NFS | **not measured** | ? | ? | ? | ? |

**The core finding**: on APFS both `rename(2)` and `renamex_np(RENAME_EXCL)` really do change the
bytes on disk from NFD to NFC. The expectation that it would work like a case-only rename held.
**The product's premise stands.**

---

## 2. Results by item

### 2.1 APFS: everything passes

```
A. normalization preserved   created as NFD, stored as NFD        (preserving)
B. normalization ignored     a file created as NFD lstats via its NFC path  (insensitive)
C. rename(2)                 succeeded, stored bytes ed959ceab880... -> NFC ✅
D. renamex_np(EXCL)          succeeded, stored bytes NFC ✅
E. NFD and NFC coexist       no (creating the NFC name gives EEXIST)
H. NFC created directly      stored as NFC ✅
```

`renamex_np(RENAME_EXCL)` **succeeded outright, with no `EEXIST`**. On a volume that ignores
normalization the destination could reasonably be considered to exist already, but it was not: the
kernel recognizes source and destination as the same file and handles it normally. So
**`RENAME_EXCL` can be the first-choice path.** It is safer than a plain `rename(2)` while
performing and behaving identically.

Case-sensitive APFS also stores NFC and still ignores normalization.

### 2.2 HFS+: cannot convert

Even when the name is created **directly** as NFC, the disk stores NFD. The kernel's HFS+ driver
forces the name apart. Neither `rename(2)` nor the two-step temporary-name fallback helps.

`renamex_np` returns `EEXIST`.

### 2.3 exFAT: cannot convert (contrary to expectation)

During planning exFAT was taken to be a "normalization-sensitive" volume, on which `rename(2)`
could overwrite a coexisting counterpart file. **That was wrong.**

Measured on a clean exFAT image:

- creating the name directly as NFC still stores NFD (the kernel forces it, as on HFS+)
- normalization is **ignored** (a file created as NFD is found through its NFC path)
- therefore NFD and NFC cannot coexist either
- `renamex_np` gives `ENOTSUP (45)`: this driver does not support it

So the macOS exFAT driver cannot store NFC in the first place, and the overwrite accident cannot
happen.

**Affects T16 and the transfer path table**: copying an NFC file to a `USB 메모리(exFAT)`
(USB flash drive, exFAT) makes macOS store it back as NFD. Moja cannot fix this. It belongs in
README's limitations.

### 2.4 The trap: the shell lies

During measurement `ls` and zsh globbing showed exFAT file names as NFC, which led to a wrong
conclusion once. Comparing the raw output of `readdir(3)`, `getattrlistbulk(2)` and `/bin/ls`
directly showed **all three agreeing on NFD**; the one normalizing was zsh.

**Never confirm file name normalization through the shell.** Always look at the raw bytes.

---

## 3. How far Foundation can be trusted ⚠️

FR-3 named `FileManager.contentsOfDirectory` as its verification method, so that was measured too.
A file with an NFC name was placed on disk and each API was asked what it returns.

| API | Result | Verdict |
|---|---|---|
| `FileManager.contentsOfDirectory(atPath:)` | NFC | ✅ usable for reading |
| `FileManager.contentsOfDirectory(at:)` (URL) | NFC | ✅ |
| `FileManager.enumerator(atPath:)` | NFC | ✅ |
| `String.withCString` | NFC | ✅ use for building paths |
| `NSString.fileSystemRepresentation` | **NFD** | ❌ never use for writing |
| `URL.withUnsafeFileSystemRepresentation` | **NFD** | ❌ never use for writing |

**Reading is safe.** The directory enumeration APIs preserve the bytes on disk, so FR-3's
verification method is valid. (The comparison must be on bytes, not `==`.)

**Writing is dangerous.** `fileSystemRepresentation` decomposes the path to NFD. Every API that
takes such a path (`FileManager.moveItem(at:to:)`, `createFile(atPath:)`, any URL-based file
operation) **cannot produce an NFC name.** Told to write NFC, it stores NFD.

This is the real reason FR-3 called for `rename(2)` directly. The document only said "`moveItem`
may fail because it judges the destination to already exist", but the problem is more fundamental.
**`moveItem` writes NFD even when it succeeds.**

---

## 4. What the design takes from this

### 4.1 Rename order (FR-3, updates requirements §12.1)

```
1. renamex_np(src, dst, RENAME_EXCL)
   |- success       -> go to verification
   |- ENOTSUP(45)   -> exFAT and the like. go to step 3 (compare inodes, then rename)
   `- EEXIST(17)    -> lstat(dst) and compare inodes
                        |- same file      -> proceed with rename(2) (safe)
                        `- different file -> stop, record a collision. never overwrite
2. on failure, two-step fallback: src -> src+".nfc-tmp-<uuid>" -> dst
3. verify: enumerate the parent directory again and confirm the stored bytes are NFC
```

Measurement shows the "different file" branch after `EEXIST` does not arise on local volumes. It
stays anyway: SMB and NFS were not measured, the cost is a single `lstat`, and what is lost when it
is wrong is the user's file.

**exFAT's `ENOTSUP` has to be handled on the fallback path too.** This was hit during commit 3. If
the two-step fallback uses only `renamex_np`, exFAT fails at the very first step of renaming to a
temporary name with `ENOTSUP`, so it is reported as a plain failure rather than "this volume is not
supported", and every incoming event retries forever. That is why `EEXIST`/`ENOTSUP` handling and
the inode comparison are folded into one function (`guardedMove`) used by both the first attempt
and the fallback.

### 4.2 Volume capability probe (new)

On HFS+ and exFAT no number of attempts converts to NFC. Infinite retries have to be stopped.

Filtering on the `f_fstypename` string is fragile (SMB varies with the server implementation, and
drivers change). Instead, **measure once per volume**:

1. create a hidden temporary file with an NFC name in the target directory
2. enumerate and check the stored bytes
3. delete it immediately
4. cache the result by `st_dev`

A volume that does not preserve NFC is shown as `이 디스크(exFAT)는 변환을 지원하지 않습니다`
("this disk (exFAT) does not support conversion") and quietly skipped.

### 4.3 The banned list

`Renamer`, `Watcher` and `Planner` must not use any of these.

- `FileManager.moveItem` / `createFile(atPath:)`: they write NFD
- `NSString.fileSystemRepresentation` / `URL.withUnsafeFileSystemRepresentation`
- comparing names with `String ==`: it ignores normalization
- verifying results through the shell (`ls`, globbing): zsh normalizes

Build paths directly with `String.withCString` or `Array(name.utf8)`.

---

## 5. Still unmeasured

What "measured" means here is the **volume normalization behaviour** of §1's table. It is taken by
mounting the volume and probing it with POSIX calls, which is why an account and a client are
needed. What happens to a name once the file is actually sent to someone else is a different kind
of measurement, and §6 covers it separately.

| Item | Why not | When |
|---|---|---|
| SMB / NFS network volumes | needs a server | commit 7 (around T11) |
| Google Drive, OneDrive (FileProvider) | needs an account and client | commit 7 |
| iCloud Drive | needs an account | commit 7 |

Google Drive and iCloud Drive were measured as transfer paths in §6. That result says nothing about
the volume's normalization behaviour: a recipient seeing a decomposed name tells you nothing about
whether `rename(2)` changes the stored bytes on that volume. Treating the two as one measurement
records a result that was never obtained.

The measurement script now lives at `scripts/probe-volume.swift`, so mounting the volume and
passing its path rebuilds the same table.

---

## 6. Transfer paths, measured

§1 through §3 dealt with the bytes written to disk. This section deals with what the name looks
like at the other end once the file is sent to someone else. **It is a different kind of
measurement.** The earlier work read stored bytes directly through POSIX calls; this one sent files
for real and checked the result by eye.

- Measured on: not recorded (before the v0.1.0 release)
- Method: take a file Moja had converted to NFC, send it down each path, read the name on Windows
- Limits: browser and client versions were not controlled, and each path was checked once

### 6.1 File sharing

| Path | Result |
|---|---|
| `카카오톡 파일 공유` (KakaoTalk file share) | preserved |
| `슬랙 파일 공유` (Slack file share) | preserved |
| `구글 드라이브 업로드` (Google Drive upload) | decomposed |
| `아이클라우드 드라이브 → 윈도우 iCloud` (iCloud Drive → iCloud for Windows) | decomposed |
| `파인더 기본 압축 (zip)` (Finder's built-in zip) | not verified (T16) |
| `원드라이브 동기화` (OneDrive sync) | not verified |
| `AirDrop → 아이폰 → 윈도우` (AirDrop → iPhone → Windows) | not verified |

### 6.2 Mail attachments

| Sent from | Received at | Result |
|---|---|---|
| `네이버 메일 (웹)` (Naver Mail, web) | `네이버 메일` (Naver Mail) | preserved |
| `네이버 메일 (웹)` (Naver Mail, web) | `지메일` (Gmail) | decomposed |
| `지메일 (웹)` (Gmail, web) | `지메일` (Gmail) | decomposed |
| `지메일 (웹)` (Gmail, web) | `네이버 메일` (Naver Mail) | preserved |
| `macOS 기본 메일 앱` (macOS Mail) | `네이버 메일` (Naver Mail) | preserved |
| `macOS 기본 메일 앱` (macOS Mail) | `지메일` (Gmail) | preserved |

**The deciding variable is the sender, not the recipient.** Send from macOS Mail and the name
survives wherever it lands; send from a webmail client and it survives only when the recipient is
on Naver Mail. Putting this the other way round in user-facing guidance tells everyone who works
with a Gmail correspondent that the app is useless to them, which is false.

### 6.3 The cause was not established

Which stage re-decomposes the name is unknown. It was never narrowed down to the sending client
reading the file name, the relaying server storing it, or the receiving client writing it out. So
"outside what Moja can reach" is an inference drawn from observation, not an established fact.

The distinction matters because if the cause turns out to sit in the sending client, there may
still be room for the app to intervene. Establishing it means reading the bytes at each stage.

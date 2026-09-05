# `rename(2)` 저장 정규화 실측

요구사항 11장 4번 "`rename(2)`가 실제로 저장 형식을 바꾸는지 **반드시 실측**"에 대한 답.
제품 전체가 이 전제에 걸려 있어 커밋 2 착수 전에 먼저 측정했다.

- 측정일: 2026-09-04
- 환경: macOS 27.0 (빌드 26A5425a), Apple Silicon, Swift 6.3.3
- 방법: `hdiutil`로 파일시스템별 디스크 이미지를 만들어 POSIX 호출로 직접 측정.
  Foundation의 경로 변환을 거치지 않고 `open(2)`/`rename(2)`/`readdir(3)`만 사용.
- 테스트 이름: `한글.txt`
  - NFC `ed959ceab8802e747874` (10바이트)
  - NFD `e18492e185a1e186abe18480e185b3e186af2e747874` (22바이트)

---

## 1. 결론 요약

| 파일시스템 | NFC 저장 | 정규화 무시 | `rename(2)` 변환 | `renamex_np(RENAME_EXCL)` | NFD·NFC 공존 |
|---|---|---|---|---|---|
| **APFS** | ✅ 가능 | 무시 | ✅ **바꿈** | ✅ 성공 | 불가 |
| **APFS (대소문자 구분)** | ✅ 가능 | 무시 | — | — | 불가 |
| **HFS+** | ❌ 커널이 NFD 강제 | 무시 | ❌ 안 바뀜 | `EEXIST` | 불가 |
| **exFAT** | ❌ 커널이 NFD 강제 | 무시 | ❌ 안 바뀜 | `ENOTSUP (45)` | 불가 |
| SMB / NFS | **미측정** | ? | ? | ? | ? |

**핵심**: APFS에서 `rename(2)`와 `renamex_np(RENAME_EXCL)` 모두 디스크에 저장된
바이트를 NFD → NFC로 실제로 바꾼다. 대소문자만 바꾸는 rename과 같은 원리로 동작할
것이라는 예상이 맞았다. **제품의 전제가 성립한다.**

---

## 2. 항목별 결과

### 2.1 APFS: 전부 통과

```
A. 정규화 보존       NFD로 만들면 NFD 그대로 저장  (preserving)
B. 정규화 무시       NFD로 만든 파일이 NFC 경로로 lstat 됨  (insensitive)
C. rename(2)         성공, 저장 바이트 ed959ceab880... → NFC ✅
D. renamex_np(EXCL)  성공, 저장 바이트 NFC ✅
E. NFD·NFC 공존      불가 (NFC 생성 시 EEXIST)
H. NFC 직접 생성     NFC로 저장됨 ✅
```

`renamex_np(RENAME_EXCL)`가 **`EEXIST` 없이 바로 성공**했다. 정규화 무시 볼륨이라
목적지가 "이미 존재"한다고 볼 법한데 그렇지 않았다. 커널이 원본과 목적지를 같은
파일로 인식하고 정상 처리한다. 따라서 **`RENAME_EXCL`이 1순위 경로가 될 수 있다.**
평범한 `rename(2)`보다 안전하면서 성능·동작이 동일하다.

대소문자 구분 APFS도 NFC 저장이 되고, 여전히 정규화는 무시한다.

### 2.2 HFS+: 변환 불가

NFC 이름으로 **직접 생성해도** 디스크에는 NFD로 저장된다. 커널의 HFS+ 드라이버가
이름을 강제로 분해한다. `rename(2)`도, 2단계 임시 이름 폴백도 소용없다.

`renamex_np`는 `EEXIST`를 돌려준다.

### 2.3 exFAT: 변환 불가 (예상과 달랐음)

계획 단계에서 exFAT을 "정규화 구분(normalization-sensitive)" 볼륨으로 보고,
`rename(2)`가 공존하는 상대 파일을 덮어쓸 수 있다고 판단했다. **틀렸다.**

깨끗한 exFAT 이미지에서 측정한 결과:
- NFC 이름으로 직접 생성해도 NFD로 저장된다 (HFS+와 동일하게 커널이 강제 변환)
- 정규화를 **무시**한다 (NFD로 만든 파일이 NFC 경로로 조회됨)
- 따라서 NFD·NFC 공존도 불가능하다
- `renamex_np`는 `ENOTSUP (45)`: 이 드라이버는 지원하지 않는다

즉 macOS의 exFAT 드라이버에서는 애초에 NFC를 저장할 수 없고, 덮어쓰기 사고도
일어나지 않는다.

**T16과 전송 경로 검증표에 영향**: "USB 메모리(exFAT)"로 NFC 파일을 복사하면
macOS가 NFD로 되돌려 저장한다. Moja가 고칠 수 있는 문제가 아니다. README의 한계
항목에 넣어야 한다.

### 2.4 함정: 셸이 거짓말을 한다

측정 중 `ls`와 zsh 글로빙이 exFAT 파일명을 NFC로 보여 주는 바람에 한 차례
잘못된 결론에 도달했다. `readdir(3)`·`getattrlistbulk(2)`·`/bin/ls`의 원시 출력을
직접 대조한 결과 **셋 다 NFD로 일치**했고, 정규화한 쪽은 zsh였다.

**파일명 정규화를 셸로 확인하면 안 된다.** 항상 원시 바이트를 봐야 한다.

---

## 3. Foundation을 어디까지 믿을 수 있는가 ⚠️

FR-3이 검증 방법으로 `FileManager.contentsOfDirectory`를 지정했기에 함께 측정했다.
디스크에 NFC 이름으로 파일을 만들어 두고 각 API가 무엇을 돌려주는지 확인했다.

| API | 결과 | 판정 |
|---|---|---|
| `FileManager.contentsOfDirectory(atPath:)` | NFC | ✅ 읽기에 사용 가능 |
| `FileManager.contentsOfDirectory(at:)` (URL) | NFC | ✅ |
| `FileManager.enumerator(atPath:)` | NFC | ✅ |
| `String.withCString` | NFC | ✅ 경로 생성에 사용 |
| `NSString.fileSystemRepresentation` | **NFD** | ❌ 쓰기에 사용 금지 |
| `URL.withUnsafeFileSystemRepresentation` | **NFD** | ❌ 쓰기에 사용 금지 |

**읽기 방향은 안전하다.** 디렉터리 열거 API는 디스크의 바이트를 그대로 보존하므로
FR-3의 검증 방법이 유효하다. (단 비교는 `==`가 아니라 바이트로 해야 한다.)

**쓰기 방향은 위험하다.** `fileSystemRepresentation`은 경로를 NFD로 분해한다.
이 경로를 쓰는 모든 API(`FileManager.moveItem(at:to:)`, `createFile(atPath:)`,
`URL` 기반 파일 조작)는 **NFC 이름을 만들 수 없다.** NFC로 바꾸라고 시켜도
NFD로 저장된다.

FR-3이 `rename(2)` 직접 호출을 지시한 진짜 이유가 이것이다. 문서는 "`moveItem`이
목적지가 이미 존재한다고 판단해 실패할 수 있다"고만 적었지만, 실제 문제는 더
근본적이다. **`moveItem`은 성공해도 NFD를 쓴다.**

---

## 4. 설계에 반영할 것

### 4.1 이름 변경 순서 (FR-3 / REQUIREMENTS 12.1 갱신)

```
1. renamex_np(src, dst, RENAME_EXCL)
   ├─ 성공        → 검증으로
   ├─ ENOTSUP(45) → exFAT 등. 아래 3번(inode 비교 후 rename)으로
   └─ EEXIST(17)  → lstat(dst)와 inode 비교
                     ├─ 같은 파일 → rename(2)로 진행 (안전)
                     └─ 다른 파일 → 중단, "충돌"로 기록. 절대 덮어쓰지 않는다
2. 실패 시 2단계 폴백: src → src+".nfc-tmp-<uuid>" → dst
3. 검증: 부모 디렉터리를 다시 열거해 저장 바이트가 NFC인지 확인
```

측정 결과 로컬 볼륨에서는 `EEXIST` 후 "다른 파일" 분기가 발생하지 않는다.
그래도 남겨 둔다. SMB/NFS를 측정하지 못했고, 비용은 `lstat` 한 번뿐이며,
틀렸을 때 잃는 것이 사용자 파일이기 때문이다.

**exFAT의 `ENOTSUP`은 폴백 경로에서도 처리해야 한다.** 커밋 3 구현 중 실제로 걸렸다.
2단계 폴백이 `renamex_np`만 쓰면 exFAT에서는 임시 이름으로 바꾸는 첫 단계부터
`ENOTSUP`으로 실패해, "이 볼륨은 지원 안 함"이 아니라 일반 실패로 보고된다.
그러면 이벤트가 올 때마다 영원히 재시도한다. 그래서 `EEXIST`/`ENOTSUP` 처리와
inode 비교를 한 함수(`guardedMove`)로 묶어 첫 시도와 폴백 양쪽에서 쓴다.

### 4.2 볼륨 능력 판별 (신규)

HFS+·exFAT에서는 몇 번을 시도해도 NFC로 바뀌지 않는다. 무한 재시도를 막아야 한다.

`f_fstypename` 문자열로 거르는 방법은 취약하다 (SMB는 서버 구현에 따라 다르고,
드라이버가 바뀔 수 있다). 대신 **볼륨당 1회 실측**한다:

1. 대상 디렉터리에 NFC 이름의 숨김 임시 파일을 만든다
2. 열거해서 저장된 바이트를 확인한다
3. 즉시 지운다
4. 결과를 `st_dev` 기준으로 캐시한다

NFC가 보존되지 않는 볼륨은 "이 디스크는 변환을 지원하지 않습니다"로 표시하고
조용히 건너뛴다.

### 4.3 금지 목록

`Renamer`·`Watcher`·`Planner`에서 다음을 쓰지 않는다.

- `FileManager.moveItem` / `createFile(atPath:)`: NFD를 쓴다
- `NSString.fileSystemRepresentation` / `URL.withUnsafeFileSystemRepresentation`
- `String ==` 로 이름 비교: 정규화를 무시한다
- 셸(`ls`·글로빙)로 결과 검증: zsh가 정규화한다

경로는 `String.withCString` 또는 `Array(name.utf8)`로 직접 만든다.

---

## 5. 남은 미측정 항목

| 항목 | 왜 못 했나 | 언제 |
|---|---|---|
| SMB / NFS 네트워크 볼륨 | 서버가 필요 | 커밋 7 (T11 주변) |
| 구글 드라이브 · 원드라이브 (FileProvider) | 계정·클라이언트 필요 | 커밋 7 |
| iCloud Drive | 계정 필요 | 커밋 7 |

측정 스크립트는 `scripts/probe-volume.swift`로 옮겨 두었으므로,
해당 볼륨을 마운트한 뒤 경로만 넘기면 같은 표를 다시 만들 수 있다.

---
id: requirements
title: "macOS 한글 파일명 자동 NFC 변환 메뉴바 앱: v1 요구사항"
type: requirements
version: "1.2"
date: "2026-09-06"
parents: []
entities:
  - name: NFD
    type: standard
    definition: "유니코드 정규화 형식 D(자소 분리형). macOS 파인더가 한글 파일 이름을 저장하는 형태이고, Windows에서 `ㅂㅗㄱㅗㅅㅓ.docx`로 깨져 보이는 원인이다"
  - name: NFC
    type: standard
    definition: "유니코드 정규화 형식 C(조합형). Windows·리눅스·대부분의 웹이 쓰는 형태이고 Moja가 디스크에 남기려는 목표 형태다"
  - name: byte-comparison
    type: constraint
    definition: "이름 비교를 String ==가 아니라 Array(name.utf8)로 하는 규칙. Swift의 ==는 정규화를 무시해 NFD와 NFC를 같다고 답하므로, ==로 판단하면 이 앱은 아무것도 하지 않는다"
    code:
      - CoreKit/Sources/CoreKit/Normalizer.swift
      - CoreKit/Tests/CoreKitTests/UnicodeAssumptionTests.swift
  - name: normalizer
    type: component
    definition: "이름 한 성분을 NFC로 바꾸고 변환이 필요한지 판정하는 순수 함수. 정준(NFC) 매핑만 쓰고 호환(NFKC) 매핑은 쓰지 않는다. NFKC는 전각 문자와 호환 자모를 다른 글자로 바꿔 사용자의 이름을 훼손한다"
    code: [CoreKit/Sources/CoreKit/Normalizer.swift]
  - name: planner
    type: component
    definition: "건너뛰기 규칙, 깊이 우선 정렬, 한 배치 상한을 파일시스템에 접근하지 않고 결정하는 순수 로직"
    code: [CoreKit/Sources/CoreKit/Planner.swift]
  - name: renamer
    type: component
    definition: "이름 하나를 NFC로 바꾸고 부모 디렉터리를 다시 열거해 저장된 원시 바이트가 NFC인지 검증하는 계층"
    code: [CoreKit/Sources/CoreKit/Renamer.swift]
  - name: folder-watcher
    type: component
    definition: "FSEvents 스트림, 1.5초 디바운스, 3초 무시 목록, 미뤄진 항목 재확인을 묶어 폴더 하나를 감시하는 계층"
    code:
      - CoreKit/Sources/CoreKit/FolderWatcher.swift
      - CoreKit/Sources/CoreKit/FSEventsStream.swift
      - CoreKit/Sources/CoreKit/WatchPolicy.swift
  - name: batch-converter
    type: component
    definition: "감시 폴더의 기존 항목을 미리보기로 먼저 보여 준 뒤 한 번에 변환하는 경로. 취소하면 아무것도 바뀌지 않는다"
    code:
      - CoreKit/Sources/CoreKit/BatchConverter.swift
      - App/BatchSession.swift
  - name: scanner
    type: component
    definition: "감시 폴더를 재귀로 훑어 변환 대상을 모으는 계층. 심볼릭 링크가 풀린 경로 때문에 같은 폴더를 두 번 훑지 않도록 file-identity로 거른다"
    code: [CoreKit/Sources/CoreKit/Scanner.swift]
  - name: overflow-guard
    type: constraint
    definition: "한 이벤트 배치의 변환 대상이 500개를 넘으면 하나도 처리하지 않고 '항목이 많습니다, 일괄 변환을 쓰세요' 상태로 넘기는 폭주 방지 규칙. 클라우드 폴더의 첫 동기화가 표적이다"
    code: [CoreKit/Sources/CoreKit/Planner.swift]
  - name: stability-window
    type: constraint
    definition: "최종 수정 후 2초가 지나지 않은 항목은 아직 쓰는 중일 수 있어 미룬다. 이 규칙과 T1의 '2초 안에'는 산술적으로 양립할 수 없어 T1 기준을 4초로 완화했다"
    code: [CoreKit/Sources/CoreKit/Planner.swift]
  - name: deferred-recheck
    type: mechanism
    definition: "안정화 대기에 걸려 미뤄진 항목을 다시 보러 오는 장치. 저장이 이미 끝났으면 새 이벤트가 오지 않으므로, 이것이 없으면 그 파일은 영영 변환되지 않는다"
    code: [CoreKit/Sources/CoreKit/FolderWatcher.swift]
  - name: ignore-list
    type: mechanism
    definition: "앱이 직접 바꾼 경로를 3초간 무시하는 2차 루프 방어선. 1차 방어선은 '이미 NFC면 아무것도 하지 않는다'는 규칙이고, 이 목록은 불필요한 열거와 로그를 줄일 뿐이다"
    code: [CoreKit/Sources/CoreKit/WatchPolicy.swift]
  - name: skip-rule
    type: concept
    definition: "숨김 항목, 다운로드 임시 확장자, Office ~$ 파일, 번들 내부, 방금 수정된 항목을 건드리지 않는 규칙. '확신이 없으면 바꾸지 않는다'의 구현체다"
    code: [CoreKit/Sources/CoreKit/Planner.swift]
  - name: package-boundary
    type: constraint
    definition: "앱 꾸러미 안쪽은 건드리지 않고 꾸러미 자체의 이름만 바꾸는 경계. 판별에는 NSWorkspace가 아니라 URLResourceValues.isPackage를 쓴다. CoreKit이 AppKit에 의존하면 앱 없이 테스트할 수 없기 때문이다"
    code:
      - CoreKit/Sources/CoreKit/Planner.swift
      - CoreKit/Sources/CoreKit/Scanner.swift
  - name: login-item
    type: api
    definition: "SMAppService로 등록하는 로그인 항목. 등록이 앱의 코드 서명에 묶이므로 매번 달라지는 ad-hoc 서명 개발 빌드로는 T13을 의미 있게 검증할 수 없다"
    code: [App/LoginItem.swift]
  - name: log-store
    type: component
    definition: "~/Library/Logs/Moja/Moja.log에만 남기는 기록. 1MB가 넘으면 회전하고 직전 것 하나만 보관한다"
    code: [CoreKit/Sources/CoreKit/LogStore.swift]
  - name: acceptance-scenario
    type: concept
    definition: "v1 릴리스 조건인 16개 시나리오 T1~T16. 전부 통과해야 v1.0.0이다"
  - name: transfer-path
    type: concept
    definition: "변환된 NFC 파일이 메일·메신저·클라우드·USB·zip을 거쳐 Windows에 도착했을 때 이름이 유지되는지 기록하는 표. 앱 기능이 아니라 한계 고지용이고 README에 그대로 들어간다"
  - name: xcodegen
    type: script
    definition: "project.yml에서 Moja.xcodeproj를 만드는 도구. .xcodeproj는 생성물이라 손으로 고치지 않는다"
    code: [project.yml]
tags: [requirements, v1, functional-spec, acceptance-criteria, menu-bar-app, korean-filename]
---

# macOS 한글 파일명 자동 NFC 변환 메뉴바 앱: v1 요구사항

> 이 문서는 Claude Code에 그대로 전달하는 용도로 작성되었고, 11장 "작업 지시"의 순서대로
> v0.1.0까지 구현되었다. 처음에는 저장소 뿌리의 `REQUIREMENTS.md`였고 지금 자리로 옮겼다.
> 구현이 이 문서와 달라진 지점은 12장에 적어 두었다.

---

## 0. 한 줄 요약

사용자가 지정한 폴더를 상시 감시하다가, 한글 자소가 분리된(NFD) 파일·폴더명이 생기면
즉시 조합형(NFC)으로 바꿔 주는 macOS 메뉴바 상주 앱.
서버 없음, 로그인 없음, 설치하면 끝.

---

## 1. 배경과 문제

- macOS 파인더는 한글 파일명을 NFD(자소 분리형)로 저장한다.
  Windows·리눅스·대부분의 웹 서비스는 NFC(조합형)를 쓴다.
- 그래서 맥에서 만든 `보고서.docx`가 Windows에서는 `ㅂㅗㄱㅗㅅㅓ.docx`처럼 보이고,
  Windows 쪽에서 검색·정렬·자동화가 깨진다.
- 기존 해결책의 한계
  - 반디네이머: 수동 변환. 변환 후 파인더에서 이름을 바꾸거나 다른 폴더로 옮기면 다시 NFD로 돌아간다.
  - jaso(hsol/jaso, GitHub): 자동 감시 기능은 있으나 Python 3.11 번들, 무서명,
    설치 시 `sudo spctl --master-disable` 요구. 개발자가 유지보수 중단을 선언.
  - CLI(convmv, nfd2nfc 등): 비개발자는 사용 불가.
- 비어 있는 자리: **다운로드 → 더블클릭 → 폴더 선택 → 끝** 수준의 네이티브 앱.

---

## 2. 목표 사용자

- 맥을 쓰지만 Windows 사용자(직장 동료·거래처·공공기관)와 한글 파일명을 주고받는 사람.
- 기술 수준: 터미널을 열어본 적 없다고 가정한다.
  "우클릭 → 열기"와 "시스템 설정 → 개인정보 보호 및 보안 → 그래도 열기" 정도는 안내 문서를 보고 따라 할 수 있다.
- 주 사용 시나리오
  1. 구글 드라이브/원드라이브 동기화 폴더를 Windows 동료와 공유한다.
  2. 데스크탑·다운로드·문서 폴더에서 파일을 만들어 메일·메신저로 보낸다.

---

## 3. 범위

### 3.1 v1에 포함

- 지정 폴더(복수) 실시간 감시 및 NFD → NFC 자동 변환 (파일명·폴더명, 하위 폴더 포함)
- 지정 폴더의 기존 항목 일괄 변환 (실행 전 미리보기 + 확인)
- 메뉴바 상주 UI, 감시 일시정지/재개
- 로그인 시 자동 실행 옵션
- 최근 변환 내역 보기
- 한국어 UI

### 3.2 v1에서 제외 (명시적 비목표)

- NFC → NFD 역변환
- Windows 쪽 복구 도구
- Mac App Store 배포 (샌드박스 미적용)
- 다국어 UI
- 전송 경로(메일·메신저·클라우드 앱) 개입. 앱은 **디스크에 저장된 이름**만 책임진다.
- 알림 센터 배너 (v2 후보)
- 자동 업데이트 (v2 후보, Sparkle 검토)

---

## 4. 기능 요구사항

표기: **필수** = v1 릴리스 조건, *권장* = 가능하면 포함.

### FR-1. 폴더 감시 (필수)

- 사용자가 등록한 폴더 각각에 대해 하위 폴더까지 재귀 감시한다.
- 감시 대상 이벤트: 생성, 이름 변경, 이동(폴더 안으로 들어옴).
- 감시 폴더는 여러 개 등록 가능하며, 폴더별로 켜기/끄기 토글을 제공한다.
- 감시 폴더 목록은 앱 재시작 후에도 유지된다.
- 앱 시작 시 등록된 폴더가 존재하지 않으면(외장 디스크 분리 등) 오류 없이 건너뛰고 메뉴에 "연결 안 됨"으로 표시한다.

### FR-2. 변환 규칙 (필수)

- 이름의 NFC 정규화 결과가 원래 이름과 **바이트 단위로** 다를 때만 변환 대상이다.
  (같으면 아무것도 하지 않는다. 무한 루프를 막는 핵심이다)
- 변환은 파일명 전체(확장자 포함)에 적용한다.
- 다음은 **건너뛴다**:
  - 숨김 파일(`.`으로 시작), `.DS_Store`
  - 다운로드 중 임시 파일: 확장자가 `.download`, `.crdownload`, `.part`, `.partial`, `.tmp`, `.temp`인 항목
  - Office 임시 파일: 이름이 `~$`로 시작하는 항목
  - 패키지/번들 내부: `.app`, `.photoslibrary`, `.bundle`, `.framework`, `.pkg` 및 `NSWorkspace.isFilePackage`가 true인 디렉터리의 **내부**. (번들 자체의 이름은 변환 대상)
  - 사용자 지정 제외 패턴 (*권장*, v1은 확장자 목록 정도면 충분)
- 최종 수정 시각이 현재로부터 **2초 이내**인 항목은 아직 쓰는 중일 수 있으므로 미룬다.
  이벤트 후 1.5초 디바운스 뒤 다시 검사한다.

### FR-3. 이름 변경 구현 (필수, 함정 있음)

- APFS는 정규화 무시(normalization-insensitive)·정규화 보존(normalization-preserving)이다.
  즉 `한글.txt`(NFD)와 `한글.txt`(NFC)를 **같은 이름**으로 취급한다.
- 따라서 `FileManager.moveItem(at:to:)`는 목적지가 "이미 존재"한다고 판단해 실패할 수 있다.
  대응 순서:
  1. POSIX `rename(2)`를 직접 호출한다. (대소문자만 바꾸는 rename과 같은 원리로 동작해야 함)
  2. 1이 실패하면 임시 이름(원본 + `.nfc-tmp-<uuid>`)으로 바꾼 뒤 최종 NFC 이름으로 다시 바꾼다.
  3. 변경 후 반드시 디렉터리를 다시 나열해 **실제 저장된 바이트**가 NFC인지 검증한다.
     (`FileManager.contentsOfDirectory`가 돌려주는 문자열의 `unicodeScalars`를 확인)
- 검증 실패 시 해당 항목은 "실패"로 기록하고 재시도하지 않는다. (다음 이벤트 때 자연 재시도)

### FR-4. 폴더명 변환 순서 (필수)

- 한 번에 여러 항목을 처리할 때는 **경로가 깊은 것부터** 처리한다.
  상위 폴더를 먼저 바꾸면 하위 경로가 무효가 된다.
- 폴더명을 바꾼 뒤에는 그 폴더 아래를 다시 나열해 처리한다.

### FR-5. 무한 루프·폭주 방지 (필수)

- 앱 자신의 rename이 발생시키는 이벤트는 FR-2의 "NFC와 같으면 무시" 규칙으로 자연히 걸러진다.
  추가로 최근 3초 안에 앱이 직접 바꾼 경로는 무시 목록에 넣는다.
- 한 번의 이벤트 배치에서 처리하는 항목이 500개를 넘으면 처리하지 않고
  메뉴에 "항목이 많습니다 — 일괄 변환을 사용하세요" 상태를 띄운다. (동기화 폴더 초기 복제 시 폭주 방지)

### FR-6. 일괄 변환 (필수)

- 메뉴에서 감시 폴더 하나를 골라 "기존 항목 일괄 변환"을 실행할 수 있다.
- 실행 전에 **미리보기 창**을 띄운다: 변환 대상 개수, 변경 전/후 이름 목록(최대 200개 표시, 나머지는 "외 N개"), 건너뛴 항목 수와 이유.
- 사용자가 "변환" 버튼을 눌러야 실행한다. 실행 후 성공/실패 개수를 보여준다.
- 일괄 변환 중에는 그 폴더의 실시간 감시를 잠시 멈추고, 끝나면 재개한다.

### FR-7. 메뉴바 UI (필수)

메뉴바 아이콘을 클릭하면 아래 메뉴가 나온다. 별도 메인 창은 없다.

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

- 아이콘: SF Symbol `hat.widebrim`. macOS 15부터 있는 심볼이라 13·14에서는
  `graduationcap`으로 내려간다.
  감시 중 = 기본, 일시정지 = 반투명, 오류 있음 = 작은 배지
  (모자 계열에는 배지 변형이 없어 오른쪽 아래 느낌표를 직접 합성한다).
- Dock 아이콘은 표시하지 않는다 (`LSUIElement = true`).

### FR-8. 첫 실행 온보딩 (필수)

- 첫 실행 시 작은 창 하나로 안내한다:
  1. 무엇을 하는 앱인지 두 문장
  2. "폴더 추가" 버튼 → NSOpenPanel (디렉터리 선택, 복수 선택 가능)
  3. 데스크탑·문서·다운로드를 고르면 macOS가 권한 창을 띄운다는 안내 문구
  4. "로그인 시 자동 실행" 체크박스 (기본 켬)
- 온보딩은 폴더를 하나 이상 추가하기 전까지 다시 뜬다.

### FR-9. 로그인 시 자동 실행 (필수)

- `SMAppService.mainApp` 사용 (macOS 13+).
- 등록 실패 시(사용자가 시스템 설정에서 거부) 메뉴에 상태를 표시하고
  "시스템 설정 → 일반 → 로그인 항목"으로 안내한다.

### FR-10. 로그 (필수)

- 메모리: 최근 100건 변환 내역 (시각, 원래 경로, 새 이름, 결과).
- 파일: `~/Library/Logs/<앱이름>/<앱이름>.log`에 append. 1MB 넘으면 회전(최근 1개만 보관).
- 개인정보: 로그는 로컬에만 남는다. 어떤 네트워크 통신도 하지 않는다.

### FR-11. 설정 저장 (필수)

- `UserDefaults`에 저장: 감시 폴더 경로 목록과 각 토글, 일시정지 상태, 온보딩 완료 여부.
- 샌드박스를 쓰지 않으므로 security-scoped bookmark는 불필요. 경로 문자열로 충분하다.

---

## 5. 비기능 요구사항

| 항목 | 기준 |
|---|---|
| 지원 OS | macOS 13 Ventura 이상 (MenuBarExtra, SMAppService 사용) |
| 아키텍처 | Universal (Apple Silicon + Intel) |
| 언어·프레임워크 | Swift 5.9+, SwiftUI(MenuBarExtra) + 필요한 곳만 AppKit. 외부 런타임(Python 등) 금지 |
| 서드파티 의존성 | v1은 0개를 목표. 불가피하면 SwiftPM으로만 |
| 앱 크기 | 10MB 이하 |
| 유휴 자원 | 감시 중 CPU 0%대, 메모리 30MB 이하 (Activity Monitor 기준) |
| 네트워크 | 없음. 어떤 outbound 연결도 하지 않는다 |
| 샌드박스 | 미적용 (App Store 배포 안 함). Hardened Runtime은 적용 |
| 접근성 | 메뉴 항목은 VoiceOver로 읽힐 것 |
| 실패 시 원칙 | 확신이 없으면 **바꾸지 않는다**. 이름 변경 실패는 조용히 기록하고 사용자 작업을 방해하지 않는다 |

---

## 6. 기술 설계 가이드

Claude Code가 판단해도 되지만, 아래는 검증된 선택이므로 특별한 이유가 없으면 따른다.

- **프로젝트 생성**: XcodeGen(`project.yml`)으로 Xcode 프로젝트를 생성한다.
  `.xcodeproj`를 손으로 편집하지 않는다. 빌드·아카이브는 `xcodebuild` 스크립트로 재현 가능하게.
- **폴더 감시**: FSEvents (`FSEventStreamCreate`) + `kFSEventStreamCreateFlagFileEvents`, latency 1.0초.
  `DispatchSource`는 최상위 폴더만 보므로 쓰지 않는다.
- **정규화**: `String.precomposedStringWithCanonicalMapping` (= NFC).
  비교는 `unicodeScalars` 또는 `utf8` 바이트로 한다. `==` 연산자는 정규화를 무시하므로 **쓰지 않는다**.
- **이름 변경**: FR-3 참조. `rename(2)` 직접 호출을 1순위로.
- **동시성**: 파일 처리는 단일 직렬 큐. UI는 메인 액터.
- **모듈 구조 (제안)**
  ```
  App/                 – 진입점, MenuBarExtra, 온보딩 뷰
  Core/Normalizer      – 순수 함수: 이름 → NFC, 변환 필요 여부 판정 (테스트 대상)
  Core/Renamer         – rename 시도·검증 (FR-3)
  Core/Watcher         – FSEvents 래퍼, 디바운스, 무시 목록
  Core/Planner         – 경로 정렬(깊이 우선), 건너뛰기 규칙 (FR-2, FR-4)
  Core/Store           – 설정, 로그
  ```
- **테스트**: `Normalizer`, `Planner`는 순수 로직이므로 XCTest로 단위 테스트.
  `Renamer`는 임시 디렉터리에 NFD 파일을 만들어 통합 테스트.

---

## 7. 테스트 시나리오 (수용 기준)

아래 전부 통과해야 v1 릴리스.

NFD 파일을 만드는 명령 (테스트 픽스처 스크립트로 제공할 것):
```bash
touch "$(printf '한글 문서.txt' | iconv -f utf-8 -t utf-8-mac)"
```

| # | 시나리오 | 기대 결과 |
|---|---|---|
| T1 | 감시 폴더에 NFD 이름 파일 생성 | 4초 안에 NFC로 바뀜. 로그 1건 (원래 2초 → 12.4a 참조) |
| T2 | 이미 NFC인 파일 생성 | 아무 일도 없음. 로그 0건 |
| T3 | 파인더에서 NFC 파일 이름을 한글로 수정 (파인더는 NFD로 저장) | 다시 NFC로 돌아옴 |
| T4 | 다른 폴더에서 NFD 파일을 감시 폴더로 드래그 | NFC로 바뀜 |
| T5 | 하위 폴더 3단계 안에 NFD 파일 | 바뀜 |
| T6 | NFD 이름의 폴더 안에 NFD 파일들 | 파일 먼저, 폴더 나중. 전부 바뀌고 경로 오류 없음 |
| T7 | 사파리/크롬으로 한글 이름 파일 다운로드 중 | `.download` 동안 건드리지 않음. 완료 후 필요하면 변환 |
| T8 | 워드로 한글 이름 문서를 연 상태에서 감시 시작 | `~$` 임시 파일 무시. 문서 저장 정상 |
| T9 | 감시 폴더 안에 `.app` 번들 (내부에 NFD 리소스) | 번들 내부는 건드리지 않음 |
| T10 | 감시 폴더에 NFD 파일 1,000개를 한 번에 복사 | 폭주 방지 상태 표시. 일괄 변환으로 처리 가능 |
| T11 | 외장 디스크 감시 폴더 분리 후 앱 재시작 | 오류 없음, "연결 안 됨" 표시. 다시 연결하면 감시 재개 |
| T12 | 일괄 변환 미리보기 | 개수·전후 이름 정확. "취소"하면 아무것도 안 바뀜 |
| T13 | 로그인 시 자동 실행 켜고 재로그인 | 메뉴바에 떠 있음 |
| T14 | 일시정지 중 NFD 파일 생성 | 안 바뀜. 재개하면 그때 바뀜(재스캔) |
| T15 | 감시 24시간 방치 | 메모리 30MB 이하 유지, 크래시 없음 |
| T16 | 변환된 파일을 zip으로 압축해 Windows에서 열기 | 한글 정상 표시 |

### 7.1 전송 경로 검증 (README용, 앱 자체 기능 아님)

변환된 NFC 파일을 아래 경로로 보냈을 때 받는 쪽(Windows)에서 정상인지 표로 기록한다.
이 표는 README에 그대로 들어간다.

| 경로 | 결과 | 비고 |
|---|---|---|
| macOS 기본 메일 앱 첨부 | | |
| Gmail 웹 첨부 (사파리/크롬) | | |
| 카카오톡 맥 | | |
| 슬랙 맥 | | |
| 구글 드라이브 데스크탑 동기화 | | |
| 원드라이브 동기화 | | |
| 아이클라우드 드라이브 → 윈도우 iCloud | | |
| USB 메모리 (exFAT) | | |
| 파인더 기본 압축(zip) | | |
| AirDrop → 아이폰 → 윈도우 | | |

---

## 8. 배포

- 빌드: `xcodebuild archive` → `.app` → `ditto -c -k --keepParent`로 zip. DMG는 v1에서 선택.
- 서명
  - 1차: Developer ID 없이 ad-hoc 서명 + Hardened Runtime.
    README에 "확인되지 않은 개발자" 우회 절차(Sequoia 이후 기준: 시스템 설정 → 개인정보 보호 및 보안 → "그래도 열기")를 스크린샷과 함께 넣는다.
  - 2차(반응 확인 후): Apple Developer Program 가입 → Developer ID 서명 → `notarytool`로 공증 → stapler.
    이 절차를 스크립트(`scripts/release.sh`)로 만들어 두되, 계정 정보는 환경변수로 받는다.
- 배포 채널: GitHub Releases. 나중에 Homebrew cask 등록(*권장*).
- 버전: SemVer. v1.0.0 = 위 수용 기준 전부 통과.

---

## 9. README 요구사항

- 첫 화면에서 3초 안에 이해되는 구성: 문제 한 줄 → 해결 한 줄 → 다운로드 버튼 → 설치 3단계 스크린샷.
- 전송 경로 검증 표 (7장).
- 기존 도구와의 관계를 명시한다: 반디네이머(수동 변환), jaso(같은 접근, 배포 미완)를 다룬다.
  두 프로젝트를 링크하고 이 앱이 채우는 자리("설치만 하면 되는 버전")를 한 문장으로.
- 한계 명시: 앱은 디스크의 이름만 바꾼다. 일부 앱은 전송 시 이름을 다시 바꿀 수 있다 (검증 표 참조).
- 개인정보: 네트워크 통신 없음, 로그는 로컬.
- 라이선스: MIT.

---

## 10. 미결 사항 (Claude Code는 이 항목을 임의로 정하지 말고 첫 보고에서 질문할 것)

1. **앱 이름**. 후보: 한글잇기 / 자모잇기 / 이음. 영문 번들 ID는 이름 확정 후.
2. **기본 감시 폴더**: 온보딩에서 데스크탑·다운로드·문서를 미리 체크해 둘지, 빈 상태로 시작할지.
3. **일시정지 시 재개 동작**: 재개 시 전체 재스캔(FR-14 기준)이 기본인지, 재개 이후 이벤트만 볼지.

### 10.1 결정 (2026-09-04)

| # | 항목 | 결정 |
|---|---|---|
| 1 | 앱 이름 | **Moja / 모자**. 번들 ID `dev.liampark.moja` |
| 2 | 기본 감시 폴더 | 온보딩에서 데스크탑·다운로드·문서를 **미리 체크한 상태로 제시**하되, 사용자가 "추가"를 눌러야 실제 등록 |
| 3 | 재개 동작 | **전체 재스캔**. 대상이 500개를 넘으면 자동 변환 대신 일괄 변환 미리보기로 넘긴다 (FR-5와 일관) |

---

## 11. 작업 지시 (Claude Code 실행 순서)

1. 이 문서를 읽고 **10장 미결 사항 3개를 먼저 질문**한다. 답을 받기 전에는 코드를 쓰지 않는다.
2. 답을 받으면 XcodeGen `project.yml`과 디렉터리 구조를 만들고, 빈 메뉴바 앱이 뜨는 것까지 확인한다. (커밋 1)
3. `Core/Normalizer`, `Core/Planner`를 단위 테스트와 함께 구현한다. 테스트가 먼저다. (커밋 2)
4. `Core/Renamer`를 구현하고 FR-3의 APFS 함정을 통합 테스트(T1~T6)로 검증한다. 이 단계에서 `rename(2)`가 실제로 저장 형식을 바꾸는지 **반드시 실측**해서 결과를 보고한다. (커밋 3)
5. `Core/Watcher`(FSEvents, 디바운스, 무시 목록, 폭주 방지)를 구현한다. (커밋 4)
6. 메뉴바 UI, 온보딩, 설정 저장, 로그인 항목, 로그를 붙인다. (커밋 5)
7. 일괄 변환 + 미리보기. (커밋 6)
8. 7장 T1~T15를 하나씩 수행하고 결과표를 만든다. 실패한 항목은 고치고 재검증. (커밋 7)
9. `scripts/build.sh`, `scripts/release.sh`, 테스트 픽스처 스크립트, README 초안. (커밋 8)
10. 각 단계가 끝날 때마다 **무엇을 했고, 무엇이 불확실한지** 3줄로 보고한다.
    문서와 다르게 구현해야 했다면 그 이유를 적는다.

원칙:
- 확신 없으면 바꾸지 않는다. 사용자 파일을 잃게 만드는 코드는 어떤 편의보다 우선해서 막는다.
- 서드파티 의존성을 추가하기 전에 물어본다.
- 한국어 UI 문구는 존댓말, 짧게, 기술 용어(NFD/NFC)는 "도움말"에서만 쓴다.

---

## 12. 요구사항 대비 구현 차이 (구현 중 갱신)

문서와 다르게 구현한 곳과 그 이유. 작업 지시 10번의 기록이다.

### 12.1 FR-3: `renamex_np(RENAME_EXCL)`을 1순위로 둔다

실측 결과는 [rename-measurements](../research/rename-measurements.md)에 있다.
FR-3의 전제는 **성립한다**: APFS에서 `rename(2)`는 디스크에 저장된 바이트를 실제로
NFD → NFC로 바꾼다.

다만 1순위를 `renamex_np(src, dst, RENAME_EXCL)`로 바꾼다. 측정해 보니 정규화 무시
볼륨에서도 `EEXIST` 없이 바로 성공하며 저장 바이트가 NFC로 바뀐다. `rename(2)`와
동작·성능이 같으면서, 목적지가 진짜 다른 파일일 때 덮어쓰지 않는다는 보장이 붙는다.

```
1. renamex_np(src, dst, RENAME_EXCL)
   ├─ 성공        → 5번 검증으로
   ├─ ENOTSUP(45) → 드라이버 미지원(exFAT 등). 3번으로
   └─ EEXIST(17)  → 3번으로
2. (해당 없음)
3. lstat(src)와 lstat(dst)의 (st_dev, st_ino) 비교
   ├─ 같은 파일  → 정규화 무시 볼륨. rename(2)로 진행 (안전)
   └─ 다른 파일  → 진짜 충돌. 중단하고 "충돌"로 기록. 절대 덮어쓰지 않는다
4. 그래도 안 바뀌면 2단계 폴백: src → src + ".nfc-tmp-<uuid>" → dst
5. 검증: 부모 디렉터리를 다시 열거해 저장된 원시 바이트가 NFC인지 확인
```

3번의 "다른 파일" 분기는 로컬 볼륨(APFS·HFS+·exFAT) 어디서도 발생하지 않았다.
그래도 남긴다. SMB/NFS를 측정하지 못했고, 비용은 `lstat` 한 번이며, 틀렸을 때
잃는 것이 사용자 파일이다.

**계획 단계의 오판 정정**: exFAT을 "정규화 구분" 볼륨으로 보고 `rename(2)`가 공존하는
상대 파일을 덮어쓴다고 판단했으나, 실측 결과 macOS의 exFAT 드라이버는 정규화를
무시하고 NFD를 강제하므로 공존 자체가 불가능하다.

### 12.1a FR-3 검증 방법: 읽기는 Foundation을 써도 된다

FR-3이 지정한 `FileManager.contentsOfDirectory` 기반 검증은 **유효하다**. 열거 API는
디스크의 바이트를 그대로 보존한다 (비교는 `==`가 아니라 바이트로 해야 한다).

반대로 **쓰기 방향의 Foundation은 쓸 수 없다**. `NSString.fileSystemRepresentation`과
`URL.withUnsafeFileSystemRepresentation`이 경로를 **NFD로 분해**하기 때문에,
`FileManager.moveItem(at:to:)`는 실패하는 게 아니라 **성공하면서 NFD를 쓴다**.
FR-3이 POSIX 직접 호출을 지시한 진짜 이유가 이것이다.

경로는 `String.withCString` 또는 `Array(name.utf8)`로 직접 만든다.

### 12.1b 볼륨 능력 판별 (신규)

HFS+와 exFAT은 커널이 이름을 NFD로 강제 변환해서 어떤 방법으로도 NFC 저장이
불가능하다. 무한 재시도를 막기 위해 **볼륨당 1회 실측**한다: 대상 디렉터리에 NFC
이름의 숨김 임시 파일을 만들어 저장 형태를 확인하고 즉시 지운 뒤, 결과를 `st_dev`
기준으로 캐시한다. `f_fstypename` 문자열 판별은 SMB처럼 서버 구현에 좌우되는
경우가 있어 쓰지 않는다.

지원하지 않는 볼륨은 "이 디스크는 변환을 지원하지 않습니다"로 표시하고 건너뛴다.

### 12.2 FR-2: 패키지 판별에 `NSWorkspace`를 쓰지 않는다

FR-2는 `NSWorkspace.isFilePackage`를 지목했으나, 순수 로직 계층에 AppKit을 끌어들이게 된다.
Foundation의 `URLResourceValues.isPackage`(`.isPackageKey`)로 같은 판정을 얻는다.

### 12.3 6장 모듈 구조: `Core/*`를 로컬 SwiftPM 패키지 `CoreKit`으로 분리

작업 지시 3·4번이 "테스트가 먼저"를 요구하는데, 앱 타깃에 붙은 XCTest 번들은 호스트 앱을
매번 띄워야 해서 TDD 루프가 느리다. 로컬 패키지로 두면 `swift test --package-path CoreKit`이
몇 초 만에 돈다. 모듈 이름과 책임 분할은 문서 그대로다. `SMAppService`(로그인 항목)만
메인 번들이 필요하므로 App 계층에 남긴다.

### 12.4 5장 언어: Swift 6가 아닌 Swift 5 언어 모드

툴체인은 Swift 6.3이고 Xcode 26 신규 프로젝트는 Swift 6 모드가 기본이다. 그러나 FSEvents는
C 콜백 + 컨텍스트 포인터 구조라 strict concurrency와 정면으로 부딪힌다. 6장이 지정한
"단일 직렬 큐 + 메인 액터" 모델을 `@MainActor` 규율로 직접 지키고, Swift 6 모드 전환은
v1 릴리스 이후로 미룬다. 문서의 "Swift 5.9+" 요건은 만족한다.

### 12.4a T1의 "2초 안에"는 FR-2와 양립할 수 없다 ⚠️ 판단 필요

측정값: 감시 폴더에 분해된 이름의 파일을 만들고 조합형으로 바뀌기까지 **3.09초**.

분해해 보면 T1이 요구하는 2초는 산술적으로 불가능하다.

| 단계 | 시간 | 근거 |
|---|---|---|
| FSEvents 지연 | 0.3초 | 6장은 1.0초 제안. T1에 맞추려 줄였다 |
| 디바운스 | 1.5초 | FR-2 |
| → 1차 검사 시점 | 1.8초 | 파일 나이 1.8초 |
| 안정화 대기 미달 | — | FR-2의 "2초 이내면 미룬다"에 걸려 **연기** |
| 재확인 | +1.5초 | 아래 12.4b |
| → 실제 변환 | **약 3.1초** | |

FR-2는 "수정된 지 2초 이내면 미룬다"고 정했다. 파일의 나이가 2초를 넘으려면 최소
2초가 지나야 하고, 여기에 이벤트 전달과 처리 시간이 더해진다. **FR-2를 지키는 한
T1의 2초는 도달할 수 없다.** 6장의 FSEvents 지연 1.0초를 그대로 썼다면 3.8초였다.

선택지 (결정 필요):

1. **T1 기준을 4초로 완화**: 안전 규칙을 그대로 둔다. 3.1초는 사용자가 체감하기
   어려운 차이다. *권장.*
2. 안정화 대기를 2초 → 0.5초로 단축: T1은 만족하지만 저장 중인 파일을 건드릴
   위험이 커진다. 5장의 "확신이 없으면 바꾸지 않는다"와 충돌한다.
3. 파일 크기가 두 번의 검사 사이에 변하지 않았으면 즉시 처리: 정확도는 오르지만
   상태 추적이 늘고, 이어쓰기 중 잠깐 멈춘 파일은 여전히 못 가린다.

**결정 (2026-09-04): 1번.** T1의 기준치를 4초로 완화했다 (7장 표에 반영).
안정화 대기 2초는 그대로 둔다. 저장 중인 파일을 건드리지 않는 쪽이
1초의 반응 속도보다 중요하다.

### 12.4b 미뤄진 항목의 재확인 (신규)

FR-2는 "이벤트 후 1.5초 디바운스 뒤 다시 검사한다"고만 적었지만, 그 검사에서
"아직 쓰는 중"으로 미뤄진 항목을 **다시 보러 오는 장치가 없다**. 파일 저장은 이미
끝났을 수 있고, 그렇다면 새 이벤트가 오지 않는다. 그대로 두면 그 파일은 영영
분해된 이름으로 남는다.

`FolderWatcher`는 미뤄진 항목이 있으면 1.5초 뒤 같은 폴더를 다시 훑도록 예약한다.

### 12.4c 폴더 중복 스캔 (구현 중 발견)

같은 폴더가 여러 경로 문자열로 들어올 수 있다. FSEvents는 심볼릭 링크를 푼 경로
(`/private/var/…`)를 주는데 설정에는 원래 경로(`/var/…`)가 들어 있다. 문자열로
중복을 거르면 같은 폴더를 두 번 훑어 항목 수가 두 배가 되고, 폭주 판정도 두 배로
잘못 계산된다. `Scanner`는 경로가 아니라 ``FileIdentity``(`st_dev`, `st_ino`)로
중복을 거른다.

### 12.5 변환이 불가능한 볼륨 (측정 완료)

**HFS+와 exFAT은 커널이 파일명을 강제로 NFD로 되돌린다.** NFC 이름으로 직접 생성해도
NFD로 저장되므로 어떤 rename 전략으로도 불가능하다. 12.1b의 볼륨 능력 판별로 걸러
"이 디스크는 변환을 지원하지 않습니다"로 표시하고 건너뛴다.

이는 요구사항의 전송 경로 검증표 중 **USB 메모리(exFAT)** 항목에 직접 영향을 준다.
NFC로 바뀐 파일을 exFAT USB에 복사하면 macOS가 다시 NFD로 저장한다. Moja가 고칠 수
있는 문제가 아니므로 README의 한계 항목에 명시한다.

SMB·NFS·클라우드 동기화 폴더는 아직 측정하지 못했다. `scripts/probe-volume.swift`에
경로를 넘기면 같은 표를 만들 수 있다. 커밋 7에서 수행한다.

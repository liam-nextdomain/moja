# 모자 (Moja)

> 맥에서 만든 `보고서.docx`가 Windows에서 `ㅂㅗㄱㅗㅅㅓ.docx`로 깨져 보이는 문제를 없앱니다.
> 폴더를 지정해 두면, 자소가 분리된 한글 파일명을 알아서 조합형으로 되돌립니다.

메뉴바에 상주하는 작은 macOS 앱입니다. 서버 없음, 로그인 없음, 네트워크 통신 없음.

> **개발 중입니다 (v0.1.0).** 아직 변환 기능이 들어 있지 않습니다.
> 진행 상황은 [REQUIREMENTS.md](REQUIREMENTS.md)의 작업 지시를 참고하세요.

---

## 요구 사항

- macOS 13 Ventura 이상
- Apple Silicon / Intel (Universal)

## 개발 환경

```sh
brew install xcodegen          # 빌드 도구 (앱 자체의 서드파티 의존성은 0개)

./scripts/build.sh             # 빌드 후 build/Build/Products/Debug/Moja.app
./scripts/test.sh              # CoreKit 단위 테스트
open Moja.xcodeproj            # Xcode에서 열기 (project.yml에서 생성됨)
```

`Moja.xcodeproj`는 **생성물**입니다. 빌드 설정은 [project.yml](project.yml)에서만 바꾸세요.

### 테스트 픽스처

자소가 분리된(NFD) 이름의 파일을 만들어 줍니다. 대상 폴더를 반드시 인자로 넘겨야 합니다.

```sh
./scripts/make-nfd-fixtures.sh ~/tmp/moja-test
```

## 구조

```
App/       진입점, 메뉴바 UI, 온보딩          — SwiftUI + 필요한 곳만 AppKit
CoreKit/   변환 로직 (Normalizer/Planner/     — 순수 Foundation, UI 의존 없음
           Renamer/Watcher/Store)               swift test로 단독 검증
scripts/   빌드·테스트·릴리스·픽스처
```

## 기존 도구와의 관계

*(작성 예정 — 반디네이머, [jaso](https://github.com/hsol/jaso)와의 비교)*

## 전송 경로 검증

*(작성 예정 — 요구사항 7장의 검증표)*

## 한계

이 앱은 **디스크에 저장된 이름**만 바꿉니다. 일부 앱은 파일을 전송할 때 이름을 다시
바꿀 수 있으며, 그 경우는 위 검증표에 기록합니다.

## 개인정보

네트워크 통신을 하지 않습니다. 로그는 `~/Library/Logs/Moja/`에만 남습니다.

## 라이선스

[MIT](LICENSE)

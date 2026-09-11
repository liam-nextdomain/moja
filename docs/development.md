# Moja 개발 문서

사용자용 설치 안내와 사용법은 [README.md](../README.md)에 있습니다.

```sh
brew install xcodegen          # 빌드 도구. 앱 자체의 서드파티 의존성은 0개

./scripts/build.sh             # 빌드 → build/Build/Products/Debug/Moja.app
./scripts/test.sh              # CoreKit 단위·통합 테스트 (138개)
./scripts/release.sh           # 릴리스 빌드 → zip
swift scripts/acceptance.swift  # 수용 기준 자동 검증 (실제 앱을 띄워 확인)
swift scripts/make-appicon.swift     # 앱 아이콘 PNG 재생성 (design/app-icon.svg에서)
swift scripts/make-menubar-icon.swift # 메뉴바 아이콘 PNG 재생성 (같은 SVG에서)
open Moja.xcodeproj            # Xcode에서 열기
```

`Moja.xcodeproj`는 **자동으로 생성되는 파일**입니다. 빌드 설정은
[project.yml](../project.yml)에서만 바꿉니다.

## 구조

```
App/       메뉴바 UI, 온보딩, 창 관리        SwiftUI + 필요한 곳만 AppKit
CoreKit/   변환 로직                        순수 Foundation, UI 의존 없음
           Normalizer  이름 → 조합형 판정·변환
           Planner     건너뛰기 규칙, 깊이 우선 정렬, 폭주 방지
           Renamer     이름 변경과 검증
           Watcher     FSEvents, 디바운스, 무시 목록
           Store       설정, 로그
scripts/   빌드·테스트·릴리스·수용 검증·픽스처·지식 베이스 도구
design/    아이콘 원본 (app-icon.svg)                    앱·메뉴바 아이콘 PNG가 모두 여기서 파생된다
kb/wiki/   요구사항, 측정 기록, 수용 결과                지식 그래프가 관계를 잇는다
kb/raw/    외부 원자료 (볼륨 실측 출력, 참고 문헌)       쓴 뒤 고치지 않는다
docs/      개발 문서(이 파일), README 스크린샷
```

## 앱 아이콘

`design/app-icon.svg`가 유일한 원본입니다. 아이콘을 바꿀 때에는 이 SVG만 고친 다음 아래 명령을
실행하면, `App/Resources/Assets.xcassets/AppIcon.appiconset/`의 PNG 열 장과 `Contents.json`이
전부 다시 만들어집니다. 자산 카탈로그의 `AppIcon` 슬롯은 벡터를 직접 받지 못하기 때문에 PNG가
필요하며, 큰 PNG 한 장을 축소하는 대신 각 슬롯의 픽셀 크기로 벡터에서 직접 그립니다.

```sh
swift scripts/make-appicon.swift
```

생성된 PNG는 파생물이지만 저장소에 함께 넣어 둡니다. XcodeGen이 만든 프로젝트를 내려받아 곧바로
빌드할 수 있어야 하기 때문입니다.

## 메뉴바 아이콘

메뉴바 아이콘도 같은 `design/app-icon.svg`에서 나옵니다. 그 안의 `#cap` 그룹만 뽑아 두 벌을
굽기 때문에, 앱 아이콘과 메뉴바 아이콘의 모양이 서로 어긋날 일이 없습니다.

| 자산 이름 | 언제 보이는가 | 모습 |
|---|---|---|
| `MenuBarCap` | 평상시 | 윤곽선만 남긴 모자 |
| `MenuBarCapFilled` | 이름을 바꾸는 동안 | 속을 채운 모자 |

```sh
swift scripts/make-menubar-icon.swift
```

두 이미지는 캔버스 크기가 같으므로 서로 바뀌어도 메뉴바 항목이 옆으로 움직이지 않습니다. 채움은
모자 전체를 통으로 칠하는 방식이 아니라, 칠한 다음 원본의 검은 선을 도로 파내는 방식입니다.
통으로 칠하면 챙과 크라운이 한 덩어리로 뭉쳐서 16pt 크기에서는 모자로 보이지 않습니다.

두 자산 모두 template 이미지로 표시되므로, 밝은 메뉴바에서는 검게 어두운 메뉴바에서는 희게
칠해집니다. `Contents.json`의 `template-rendering-intent`가 그 역할을 맡습니다. 이 한 줄이
빠지면 어느 쪽에서도 원본 색 그대로 나옵니다.

채운 모자로 바뀌는 조건은 `App/AppModel.swift`의 `isConverting`이 정합니다. 실시간 감시가
수행하는 변환은 수십 밀리초 만에 끝나기 때문에 걸린 시간만큼만 채우면 사용자가 아무것도 보지
못합니다. 그래서 이름이 한 번 바뀌면 1.2초 동안 켜 두고, 그 사이에 또 바뀌면 시간을 처음부터
다시 잽니다. 일괄 변환은 실제로 도는 내내 켭니다.

## 테스트 파일 만들기

자소가 분리된 이름의 파일을 만들어 줍니다. 대상 폴더를 반드시 인자로 넘겨야 합니다.

```sh
./scripts/make-nfd-fixtures.sh ~/tmp/moja-test
```

> **주의**: 파일 이름 시험을 셸로 준비하면 안 됩니다. zsh는 글로빙 결과를 조합형으로
> 정규화하기 때문에, `cp staging/* watched/` 같은 명령은 분해형 이름을 조합형으로
> **바꿔서** 복사합니다. 실제로 이 문제를 겪은 적이 있습니다
> ([kb/wiki/research/rename-measurements.md](../kb/wiki/research/rename-measurements.md) 2.4절).

## 고친 것을 설치본에 반영하기

`./scripts/build.sh`가 만드는 것은 `build/Build/Products/Debug/Moja.app`이고, 평소에 쓰는
`/Applications/Moja.app`은 손대지 않습니다. 그래서 코드를 고치고 빌드만 해서는 메뉴바에 예전
버전이 그대로 보입니다. 실제로 쓰는 앱에 반영하려면 릴리스 빌드를 만들어 직접 교체해야 합니다.

```sh
osascript -e 'quit app "Moja"'                     # 실행 중이면 먼저 종료합니다
./scripts/release.sh                               # build/export/Moja.app 과 zip 을 만듭니다
ditto build/export/Moja.app /Applications/Moja.app
```

`/Applications`는 관리자 계정이 소유하므로 `sudo`가 필요하지 않습니다. `cp -R` 대신 `ditto`를
쓰는 이유는 확장 속성과 서명 자원을 온전히 옮기기 위해서입니다.

감시 폴더 설정은 `UserDefaults`에, 변환 기록은 `~/Library/Logs/Moja/`에 남으므로 앱을 교체해도
그대로 유지됩니다.

> **로그인 항목을 확인하세요**: `SMAppService`는 등록을 앱의 코드 서명에 묶습니다. Developer ID
> 없이 ad-hoc으로 서명하는 동안에는 빌드할 때마다 서명이 달라지므로, 앱을 교체한 다음 자동
> 실행이 꺼져 있을 수 있습니다. 교체한 뒤 메뉴에서 한 번 확인하시기 바랍니다
> ([App/LoginItem.swift](../App/LoginItem.swift)).

## 문서

- [kb/wiki/spec/requirements.md](../kb/wiki/spec/requirements.md): v1 요구사항과 구현이 문서와 달라진 지점
- [kb/wiki/research/rename-measurements.md](../kb/wiki/research/rename-measurements.md): 파일시스템별 실측 결과
- [kb/wiki/spec/acceptance-results.md](../kb/wiki/spec/acceptance-results.md): 수용 기준 검증 결과
- [kb/wiki/index.md](../kb/wiki/index.md): 지식 베이스 전체 색인

## 릴리스까지 남은 일

v1.0.0은 수용 기준 16개를 전부 통과해야 합니다. 현재 12개는 자동으로 통과했고, 2개는 사람이
직접 확인했습니다.

<!-- roadmap:release-checklist:start -->
- [x] **T13** 로그인 시 자동 실행: 설치본에서 실제 재로그인으로 확인했습니다
- [ ] **T13 재확인** Developer ID 서명을 붙이면 코드 서명이 달라져 로그인 항목
      등록이 무효가 되므로, 서명 뒤에 한 번 더 확인합니다
- [ ] **T15** 24시간 방치: 메모리 30MB 이하 유지 확인
- [ ] **T16** Windows에서 열기: 파인더 기본 압축으로 묶어 확인합니다
- [ ] 전송 경로 검증: 12건 중 10건을 확인했습니다. 원드라이브 동기화와 AirDrop 경유가 남았습니다
- [x] README의 전송 경로 표와 메일 조합표 채우기: 확인한 결과를 반영했습니다.
      아직 확인하지 못한 행은 미검증으로 남겨 두었습니다
- [x] 설치 안내 스크린샷 3장: macOS 골든게이트 기준입니다. 이전 버전 화면은 표로만 안내합니다
- [ ] Developer ID 서명 + 공증 (`scripts/release.sh`에 절차는 준비됨)
- [ ] Homebrew cask 등록
<!-- roadmap:release-checklist:end -->

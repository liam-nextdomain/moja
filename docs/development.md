# Moja 개발 문서

사용자용 설치 안내와 사용법은 [README.md](../README.md)에 있습니다.

```sh
brew install xcodegen          # 빌드 도구. 앱 자체의 서드파티 의존성은 0개

./scripts/build.sh             # 빌드 → build/Build/Products/Debug/Moja.app
./scripts/test.sh              # CoreKit 단위·통합 테스트 (138개)
./scripts/release.sh           # 릴리스 빌드 → zip
swift scripts/acceptance.swift # 수용 기준 자동 검증 (실제 앱을 띄워 확인)
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
kb/wiki/   요구사항, 측정 기록, 수용 결과                지식 그래프가 관계를 잇는다
kb/raw/    외부 원자료 (볼륨 실측 출력, 참고 문헌)       쓴 뒤 고치지 않는다
docs/      개발 문서(이 파일), README 스크린샷
```

## 테스트 파일 만들기

자소가 분리된 이름의 파일을 만들어 줍니다. 대상 폴더를 반드시 인자로 넘겨야 합니다.

```sh
./scripts/make-nfd-fixtures.sh ~/tmp/moja-test
```

> **주의**: 파일 이름 시험을 셸로 준비하면 안 됩니다. zsh는 글로빙 결과를 조합형으로
> 정규화하기 때문에, `cp staging/* watched/` 같은 명령은 분해형 이름을 조합형으로
> **바꿔서** 복사합니다. 실제로 이 문제를 겪은 적이 있습니다
> ([kb/wiki/research/rename-measurements.md](../kb/wiki/research/rename-measurements.md) 2.4절).

## 문서

- [kb/wiki/spec/requirements.md](../kb/wiki/spec/requirements.md): v1 요구사항과 구현이 문서와 달라진 지점
- [kb/wiki/research/rename-measurements.md](../kb/wiki/research/rename-measurements.md): 파일시스템별 실측 결과
- [kb/wiki/spec/acceptance-results.md](../kb/wiki/spec/acceptance-results.md): 수용 기준 검증 결과
- [kb/wiki/index.md](../kb/wiki/index.md): 지식 베이스 전체 색인

## 릴리스까지 남은 일

v1.0.0은 수용 기준 16개를 전부 통과해야 합니다. 현재 12개는 자동으로 통과했고, 1개는 사람이
직접 확인했습니다.

<!-- roadmap:release-checklist:start -->
- [ ] **T13** 로그인 시 자동 실행: 실제 재로그인으로 확인합니다.
      ad-hoc 서명에서는 의미가 없으므로 서명을 붙인 뒤에 확인해야 합니다
- [ ] **T15** 24시간 방치: 메모리 30MB 이하 유지 확인
- [ ] **T16** Windows에서 열기: 파인더 기본 압축으로 묶어 확인합니다
- [ ] 전송 경로 검증: 12건 중 10건을 확인했습니다. 원드라이브 동기화와 AirDrop 경유가 남았습니다
- [x] README의 전송 경로 표와 메일 조합표 채우기: 확인한 결과를 반영했습니다.
      아직 확인하지 못한 행은 미검증으로 남겨 두었습니다
- [x] 설치 안내 스크린샷 3장: macOS 골든게이트 기준입니다. 이전 버전 화면은 표로만 안내합니다
- [ ] Developer ID 서명 + 공증 (`scripts/release.sh`에 절차는 준비됨)
- [ ] Homebrew cask 등록
<!-- roadmap:release-checklist:end -->

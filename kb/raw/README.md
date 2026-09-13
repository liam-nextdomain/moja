# kb/raw: 외부 원자료

여기 있는 파일은 **증거**다. Moja가 쓴 글이 아니라 바깥에서 온 것을 그대로 옮겨 둔 것이다.
`kb/wiki/`의 문서가 이 자료를 해석하고 요약한다.

Moja의 기존 문서 세 편은 전부 직접 작성한 것이라 대응하는 원자료가 없다. 그래서 이 폴더는
오랫동안 비어 있었고, 지금은 T16 확인 기록 한 편만 들어와 있다.

## 무엇이 여기로 오는가

| 하위 폴더 | 내용 | 예 |
|---|---|---|
| `measurements/` | `swift scripts/probe-volume.swift`의 출력 그대로 | SMB 공유, 클라우드 동기화 폴더, USB의 정규화 성질 |
| `acceptance/` | 사람이 확인한 수용 기준의 원본 기록 | T13 재로그인 확인, T15 24시간 메모리 측정값 |
| `references/` | 외부 문헌에서 옮겨 온 부분 | `renamex_np(2)` man page, zip의 UTF-8 플래그 규격 |
| `reports/` | 사용자가 이슈로 알려 온 전송 경로 결과 | "카카오톡으로 보냈더니 정상이었다" |

`kb/wiki/research/rename-measurements.md` 5절이 아직 측정하지 못한 세 가지를 적어 두었다.
그것들을 측정하면 출력이 `measurements/`로 온다.

## 규칙

**한 번 쓰면 고치지 않는다.** 원자료를 다듬으면 그건 더 이상 증거가 아니다. 해석은
`kb/wiki/`에서 한다. 측정이 틀렸다고 판단되면 새 파일을 추가하고 위키 쪽에서 두 결과를
비교해 설명한다.

**frontmatter를 쓰지 않는다.** `kb/raw/`는 지식 그래프에 들어가지 않는다. 대신 파일 맨 위에
출처 헤더를 둔다.

```markdown
# exFAT USB의 정규화 성질

**Source:** swift scripts/probe-volume.swift /Volumes/USB
**Collected:** 2026-09-12
**Published:** N/A (직접 측정)
**Volume:** exfat, /Volumes/USB
```

**파일 이름은 `YYYY-MM-DD-설명.md`.** 소문자 kebab-case, 60자 이내. 발행일을 모르는 문헌은
날짜를 빼고 헤더의 `Published`를 `Unknown`으로 둔다.

**실제 사용자의 파일 이름·경로·로그를 넣지 않는다.** Moja가 사용자에게 한 약속은 "인터넷에
아무것도 보내지 않습니다"인데, 지식 베이스가 그 약속이 새는 자리가 되면 안 된다. 예시가
필요하면 `한글.txt`, `보고서.docx` 같은 합성 이름을 쓴다. 홈 디렉터리 경로는 `~/`로 줄인다.

## 인용하는 법

`kb/wiki/`의 문서는 본문 머리에서 원자료를 가리킨다. 경로는 그 문서 기준 상대 경로다.

```markdown
> Raw: [2026-09-12-probe-smb-share.md](../../raw/measurements/2026-09-12-probe-smb-share.md)
```

# 지식 베이스 색인

Moja가 아는 것을 모아 둔 곳이다. 질문이 있으면 여기서 문서를 고르기 전에
`swift scripts/kb.swift query "질문"`을 먼저 돌린다. 문서 전체가 아니라 필요한 절만 돌려준다.

## spec

v1이 무엇을 해야 하는지, 그리고 그것이 실제로 되는지 확인한 기록.

| 문서 | 요약 | 갱신 |
|---|---|---|
| [v1 요구사항](spec/requirements.md) | FR-1~FR-11, 수용 기준 T1~T16, 그리고 구현이 문서와 달라진 지점을 적은 12장 | 2026-09-05 |
| [수용 기준 결과](spec/acceptance-results.md) | T1~T16 검증 결과. 12개 자동 통과, 1개 사람 확인, 3개 미검증 | 2026-09-05 |

## research

macOS 파일시스템·POSIX·Foundation이 실제로 어떻게 동작하는지 측정한 기록.

| 문서 | 요약 | 갱신 |
|---|---|---|
| [`rename(2)` 저장 정규화 실측](research/rename-measurements.md) | APFS는 변환할 수 있고 HFS+·exFAT은 커널이 NFD를 강제한다. Foundation 쓰기 API 금지 목록의 근거 | 2026-09-05 |

---

원자료는 [kb/raw/](../raw/README.md)에 있다. 문서 사이의 관계는 [graph.json](graph.json)이,
변경 이력은 [log.md](log.md)가 담는다.

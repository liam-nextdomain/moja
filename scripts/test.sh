#!/usr/bin/env bash
#
# CoreKit 테스트. 앱을 띄우지 않으므로 몇 초 안에 끝난다 — TDD 루프용.
#
#   ./scripts/test.sh                     # 전부
#   ./scripts/test.sh NormalizerTests     # 특정 스위트
#
set -euo pipefail

cd "$(dirname "$0")/.."

if [ $# -gt 0 ]; then
    swift test --package-path CoreKit --filter "$1"
    exit 0
fi

swift test --package-path CoreKit

# 지식 베이스 도구. 파서가 맞는지, 그래프가 만들어지는지 본다.
#
# `kb.swift check`는 여기 넣지 않는다. 그건 도구가 아니라 **문서**의 결함(끊긴 심볼,
# 풀리지 않는 절 참조)을 보고하는 린트라서, 문서를 손보는 중에는 빨간불이 정상이다.
# 필요할 때 `swift scripts/kb.swift check`로 따로 돌린다.
echo
echo "── 지식 베이스 ──"
swift scripts/kb.swift selftest
swift scripts/kb.swift build

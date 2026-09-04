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
else
    swift test --package-path CoreKit
fi

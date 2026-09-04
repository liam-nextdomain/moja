#!/usr/bin/env bash
#
# Moja 빌드. .xcodeproj는 생성물이므로 매번 project.yml에서 다시 만든다.
#
#   ./scripts/build.sh            # Debug
#   ./scripts/build.sh Release
#
set -euo pipefail

cd "$(dirname "$0")/.."
CONFIG="${1:-Debug}"

if ! command -v xcodegen >/dev/null 2>&1; then
    echo "error: xcodegen이 없습니다. 'brew install xcodegen' 후 다시 실행하세요." >&2
    exit 1
fi

echo "==> project.yml → Moja.xcodeproj"
xcodegen generate --quiet

echo "==> xcodebuild ($CONFIG)"
xcodebuild \
    -project Moja.xcodeproj \
    -scheme Moja \
    -configuration "$CONFIG" \
    -derivedDataPath build \
    -quiet \
    build

APP="build/Build/Products/$CONFIG/Moja.app"
echo
echo "==> 결과: $APP"
lipo -archs "$APP/Contents/MacOS/Moja"
codesign -dv "$APP" 2>&1 | grep -E '^(Identifier|Signature|CodeDirectory)' || true

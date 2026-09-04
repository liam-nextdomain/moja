#!/usr/bin/env bash
#
# 릴리스 빌드 → Moja.app → zip. 요구사항 8장.
#
#   ./scripts/release.sh
#       ad-hoc 서명. Developer ID가 없을 때의 1차 배포용.
#       받는 사람은 "확인되지 않은 개발자" 경고를 우회해야 한다 (README 참조).
#
#   SIGN_IDENTITY="Developer ID Application: 이름 (TEAMID)" \
#   NOTARY_PROFILE=moja ./scripts/release.sh
#       서명 + 공증 + stapler. 2차 배포용.
#
# 계정 정보는 스크립트에 넣지 않는다. 공증은 미리 저장해 둔 키체인 프로파일을 쓴다:
#   xcrun notarytool store-credentials moja \
#       --apple-id <애플 ID> --team-id <팀 ID> --password <앱 암호>
#
set -euo pipefail

cd "$(dirname "$0")/.."

SIGN_IDENTITY="${SIGN_IDENTITY:--}"      # 기본값 '-' = ad-hoc
NOTARY_PROFILE="${NOTARY_PROFILE:-}"
ARCHIVE="build/Moja.xcarchive"
EXPORT_DIR="build/export"
APP="$EXPORT_DIR/Moja.app"

if ! command -v xcodegen >/dev/null 2>&1; then
    echo "error: xcodegen이 없습니다. 'brew install xcodegen' 후 다시 실행하세요." >&2
    exit 1
fi

VERSION="$(sed -n 's/^ *MARKETING_VERSION: *"\{0,1\}\([^"]*\)"\{0,1\} *$/\1/p' project.yml | head -1)"
[ -n "$VERSION" ] || { echo "error: project.yml에서 버전을 읽지 못했습니다." >&2; exit 1; }

echo "==> 모자 $VERSION / 서명 ID: $SIGN_IDENTITY"

xcodegen generate --quiet
rm -rf "$ARCHIVE" "$EXPORT_DIR"

echo "==> 아카이브"
xcodebuild archive \
    -project Moja.xcodeproj \
    -scheme Moja \
    -configuration Release \
    -archivePath "$ARCHIVE" \
    -derivedDataPath build \
    -quiet \
    CODE_SIGN_IDENTITY="$SIGN_IDENTITY"

mkdir -p "$EXPORT_DIR"
cp -R "$ARCHIVE/Products/Applications/Moja.app" "$APP"

# 아카이브 산출물을 그대로 믿지 않고 다시 서명한다.
# Xcode는 ad-hoc 서명 시 Hardened Runtime을 꺼 버리는 경우가 있어, 여기서 확실히 켠다.
echo "==> 서명"
SIGN_ARGS=(--force --options runtime
           --entitlements App/Resources/Moja.entitlements
           --sign "$SIGN_IDENTITY")
# ad-hoc 서명에는 타임스탬프를 붙일 수 없다. Developer ID 서명에는 반드시 붙인다.
if [ "$SIGN_IDENTITY" = "-" ]; then
    SIGN_ARGS+=(--timestamp=none)
else
    SIGN_ARGS+=(--timestamp)
fi
codesign "${SIGN_ARGS[@]}" "$APP"
codesign --verify --strict --verbose=2 "$APP"

echo "==> 확인"
lipo -archs "$APP/Contents/MacOS/Moja"
codesign -dv --verbose=2 "$APP" 2>&1 | grep -E '^(Identifier|CodeDirectory|Signature)'
du -sh "$APP" | awk '{print "  크기: " $1}'

ZIP="build/Moja-$VERSION.zip"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"

if [ -n "$NOTARY_PROFILE" ]; then
    echo "==> 공증"
    xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$APP"
    rm -f "$ZIP"
    ditto -c -k --keepParent "$APP" "$ZIP"   # stapler를 거친 앱으로 다시 압축
    xcrun stapler validate "$APP"
    echo "==> 공증 완료. 받는 사람은 바로 열 수 있습니다."
else
    echo
    echo "==> 공증하지 않았습니다 (NOTARY_PROFILE 미설정)."
    echo "    ad-hoc 배포입니다. 받는 사람은 처음 열 때 시스템 설정 →"
    echo "    개인정보 보호 및 보안 → \"그래도 열기\"를 거쳐야 합니다."
    echo "    README의 설치 안내를 함께 전달하세요."
fi

echo
echo "==> 완료: $ZIP"

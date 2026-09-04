#!/usr/bin/env bash
#
# 릴리스 빌드 → .app → zip. 요구사항 8장.
#
#   ./scripts/release.sh                       # ad-hoc 서명 (1차 배포)
#   SIGN_IDENTITY="Developer ID Application: ..." \
#   NOTARY_PROFILE=moja ./scripts/release.sh   # 서명 + 공증 (2차)
#
# 계정 정보는 코드에 넣지 않는다. 공증은 미리 저장해 둔 키체인 프로파일을 쓴다:
#   xcrun notarytool store-credentials moja \
#       --apple-id <id> --team-id <team> --password <앱 암호>
#
# ⚠️ 이 스크립트의 공증 경로는 아직 실행해 본 적이 없다 (Developer ID 미보유).
#    커밋 8에서 검증한다.
#
set -euo pipefail

cd "$(dirname "$0")/.."

SIGN_IDENTITY="${SIGN_IDENTITY:--}"     # 기본값 '-' = ad-hoc
NOTARY_PROFILE="${NOTARY_PROFILE:-}"
ARCHIVE="build/Moja.xcarchive"
EXPORT_DIR="build/export"

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' App/Resources/Info.plist 2>/dev/null || echo unknown)"
if [ "$VERSION" = "\$(MARKETING_VERSION)" ] || [ "$VERSION" = "unknown" ]; then
    VERSION="$(grep -E '^\s*MARKETING_VERSION:' project.yml | head -1 | sed 's/.*: *"\{0,1\}\([^"]*\)"\{0,1\}/\1/')"
fi

echo "==> 버전 $VERSION / 서명 ID: $SIGN_IDENTITY"

xcodegen generate --quiet
rm -rf "$ARCHIVE" "$EXPORT_DIR"

xcodebuild archive \
    -project Moja.xcodeproj \
    -scheme Moja \
    -configuration Release \
    -archivePath "$ARCHIVE" \
    -derivedDataPath build \
    CODE_SIGN_IDENTITY="$SIGN_IDENTITY" \
    -quiet

mkdir -p "$EXPORT_DIR"
cp -R "$ARCHIVE/Products/Applications/Moja.app" "$EXPORT_DIR/"
APP="$EXPORT_DIR/Moja.app"

# 아카이브 산출물을 그대로 믿지 않고 다시 서명한다 (Hardened Runtime 확실히 적용).
codesign --force --deep --options runtime --timestamp"$([ "$SIGN_IDENTITY" = "-" ] && echo '=none')" \
    --sign "$SIGN_IDENTITY" \
    --entitlements App/Resources/Moja.entitlements \
    "$APP"
codesign --verify --strict --verbose=2 "$APP"

ZIP="build/Moja-$VERSION.zip"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"

if [ -n "$NOTARY_PROFILE" ]; then
    echo "==> 공증"
    xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$APP"
    rm -f "$ZIP"
    ditto -c -k --keepParent "$APP" "$ZIP"   # staple된 앱으로 다시 압축
    xcrun stapler validate "$APP"
else
    echo "==> 공증 건너뜀 (NOTARY_PROFILE 미설정)."
    echo "    ad-hoc 배포입니다. 사용자는 시스템 설정 → 개인정보 보호 및 보안 →"
    echo "    '그래도 열기'를 거쳐야 합니다. README 설치 안내를 확인하세요."
fi

echo
echo "==> 완료: $ZIP"
lipo -archs "$APP/Contents/MacOS/Moja"

#!/usr/bin/env bash
#
# 테스트용 NFD(자소 분리) 이름 파일·폴더를 만든다. 요구사항 7장 픽스처.
#
#   ./scripts/make-nfd-fixtures.sh /path/to/scratch-dir
#
# 안전장치:
#   - 대상 디렉터리를 반드시 인자로 받는다. 현재 디렉터리에 흩뿌리지 않는다.
#   - 대상이 없으면 만들지만, 홈 디렉터리·루트 같은 곳은 거부한다.
#   - 기존 파일을 덮어쓰지 않는다.
#
set -euo pipefail

if [ $# -ne 1 ]; then
    echo "usage: $0 <대상 디렉터리>" >&2
    exit 2
fi

TARGET="$1"

case "$(cd "$(dirname "$TARGET")" 2>/dev/null && pwd)/$(basename "$TARGET")" in
    "$HOME" | "/" | "/Users" | "$HOME/Desktop" | "$HOME/Documents" | "$HOME/Downloads")
        echo "error: '$TARGET'에는 만들지 않습니다. 빈 임시 폴더를 지정하세요." >&2
        exit 1
        ;;
esac

mkdir -p "$TARGET"
cd "$TARGET"

# NFC → NFD 변환. macOS의 iconv는 'utf-8-mac'을 자소 분리형으로 취급한다.
nfd() { printf '%s' "$1" | iconv -f utf-8 -t utf-8-mac; }

make_file() {
    local name; name="$(nfd "$1")"
    if [ -e "$name" ]; then echo "  건너뜀 (이미 있음): $1"; return; fi
    : > "$name"
    echo "  파일: $1"
}

make_dir() {
    local name; name="$(nfd "$1")"
    mkdir -p "$name"
    echo "  폴더: $1"
}

echo "==> $PWD 에 NFD 픽스처 생성"

# T1: 평범한 NFD 파일
make_file "한글 문서.txt"
make_file "보고서 최종.docx"

# T2 대조군: 이미 NFC인 파일 (변환되면 안 됨) — 일부러 iconv를 거치지 않는다
[ -e "이미 조합형.txt" ] || : > "이미 조합형.txt"
echo "  파일(NFC 대조군): 이미 조합형.txt"

# T5: 하위 3단계
make_dir "1단계/2단계/3단계"
make_file "1단계/2단계/3단계/깊은 파일.txt"

# T6: NFD 폴더 안의 NFD 파일들
make_dir "자료 모음"
make_file "자료 모음/첨부 1.pdf"
make_file "자료 모음/첨부 2.pdf"

# 건너뛰어야 하는 것들 (FR-2)
make_file ".숨김 파일.txt"
make_file "받는 중.download"
make_file "임시 문서.tmp"
make_file "~\$열린 문서.docx"

echo "==> 완료. 확인:"
echo "    ls '$PWD' | while read -r f; do printf '%s → ' \"\$f\"; printf '%s' \"\$f\" | xxd -p | head -c 60; echo; done"

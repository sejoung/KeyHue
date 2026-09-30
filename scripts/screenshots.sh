#!/usr/bin/env bash
# 웹사이트(site/)용 이미지를 다시 만든다. UI를 바꾼 뒤 실행해 매뉴얼 이미지를 최신으로 유지한다.
#
#   scripts/screenshots.sh            # 다시 만들어 site/assets에 덮어쓴다
#   scripts/screenshots.sh --check    # 다시 만들어 커밋된 이미지와 비교만 한다(UI 회귀 확인, ADR 0022)
#                                     # 렌더링 결과와 차이 이미지는 .artifacts/screenshots/<시각>/에 남는다
#
# - site/assets/screens/<en|ko>/settings-*.png : 실제 설정 창 SwiftUI 뷰 렌더링 (KeyHue --render-screenshots)
# - site/assets/icon.png, favicon.png           : docs/icon.png → 투명 모서리 앱 아이콘
# - site/assets/menubar-mask.png, hud-mask.png  : 카멜레온 실루엣(CSS mask로 색을 입힌다)
# - site/assets/screens/hud-*.png               : 전환 HUD(ABC·한국어·일본어·Caps Lock)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
ASSETS="site/assets"
WORK="build/work/site"

echo "==> build"
swift build --product KeyHue
BIN_DIR="$(swift build --show-bin-path)"
# 번들 없이 실행하므로 실행 파일 옆에 번역과 카멜레온 실루엣을 둔다(Bundle.main = 실행 파일 폴더).
cp -R Resources/*.lproj "$BIN_DIR/"
mkdir -p "$WORK"
swift scripts/make-menubar-icon.swift docs/icon.png "$WORK/MenuBarIcon" 64 HUDIcon >/dev/null
cp "$WORK/MenuBarIcon/"HUDIcon*.png "$BIN_DIR/"

if [[ "${1:-}" == "--check" ]]; then
    # shellcheck source=scripts/artifacts.sh
    source scripts/artifacts.sh
    OUT="$(artifacts_dir screenshots)"
    OUT="${OUT#"$ROOT/"}"
    "$BIN_DIR/KeyHue" --render-screenshots "$OUT" >/dev/null
    STATUS=0
    for expected in "$ASSETS"/screens/*.png "$ASSETS"/screens/*/*.png; do
        rel="${expected#"$ASSETS/screens/"}"
        diff_png="$OUT/${rel%.png}.diff.png"
        if result="$(swift scripts/compare-images.swift "$expected" "$OUT/$rel" 0.005 "$diff_png")"; then
            echo "    ok       $rel ($result)"
        else
            echo "    CHANGED  $rel ($result) → $diff_png"
            STATUS=1
        fi
    done
    if (( STATUS )); then
        echo "설정 창 모양이 바뀌었습니다. 의도한 변경이면 scripts/screenshots.sh로 이미지를 갱신하세요."
    fi
    echo "    렌더링 결과: $OUT"
    exit "$STATUS"
fi

echo "==> settings screenshots"
rm -rf "$ASSETS/screens"
"$BIN_DIR/KeyHue" --render-screenshots "$ASSETS/screens"

echo "==> icons"
mkdir -p "$WORK"
swift scripts/make-icon.swift docs/icon.png "$WORK/AppIcon.iconset" >/dev/null
cp "$WORK/AppIcon.iconset/icon_256x256@2x.png" "$ASSETS/icon.png"
cp "$WORK/AppIcon.iconset/icon_32x32@2x.png" "$ASSETS/favicon.png"
swift scripts/make-menubar-icon.swift docs/icon.png "$WORK/MenuBarIcon" >/dev/null
cp "$WORK/MenuBarIcon/MenuBarIcon@2x.png" "$ASSETS/menubar-mask.png"
cp "$WORK/MenuBarIcon/HUDIcon@2x.png" "$ASSETS/hud-mask.png"

ls -la "$ASSETS" "$ASSETS/screens"/*

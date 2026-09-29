#!/usr/bin/env bash
# 웹사이트(site/)용 이미지를 다시 만든다. UI를 바꾼 뒤 실행해 매뉴얼 이미지를 최신으로 유지한다.
#
#   scripts/screenshots.sh
#
# - site/assets/screens/<en|ko>/settings-*.png : 실제 설정 창 SwiftUI 뷰 렌더링 (KeyHue --render-screenshots)
# - site/assets/icon.png, favicon.png           : docs/icon.png → 투명 모서리 앱 아이콘
# - site/assets/menubar-mask.png                : 메뉴바 카멜레온 실루엣(CSS mask로 색을 입힌다)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
ASSETS="site/assets"
WORK="build/work/site"

echo "==> build"
swift build --product KeyHue
BIN_DIR="$(swift build --show-bin-path)"
# 번들 없이 실행하므로 실행 파일 옆에 번역을 둔다(Bundle.main = 실행 파일 폴더).
cp -R Resources/*.lproj "$BIN_DIR/"

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

ls -la "$ASSETS" "$ASSETS/screens"/*

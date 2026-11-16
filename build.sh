#!/bin/zsh
# ビルドして ~/Applications/AIAppshot.app にインストールする
set -e
cd "$(dirname "$0")"

swift build -c release

APP=build/AIAppshot.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/AIAppshot "$APP/Contents/MacOS/"
cp Info.plist "$APP/Contents/"

# 開発用の証明書があれば使う（再ビルドしても権限が消えにくい）。なければ ad-hoc 署名
IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null | grep -m1 "Apple Development" | sed -E 's/.*"(.*)"/\1/')
codesign --force --sign "${IDENTITY:--}" "$APP"
echo "signed with: ${IDENTITY:-ad-hoc}"

pkill -x AIAppshot 2>/dev/null || true
rm -rf ~/Applications/AIAppshot.app
mkdir -p ~/Applications
cp -R "$APP" ~/Applications/
echo "installed: ~/Applications/AIAppshot.app"

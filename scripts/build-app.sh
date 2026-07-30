#!/bin/zsh
set -euo pipefail

project_dir="${0:A:h:h}"
build_dir="$project_dir/.build"
app_dir="$project_dir/dist/NotificationTicker.app"
install_dir="/Applications/NotificationTicker.app"

cd "$project_dir"
export CLANG_MODULE_CACHE_PATH="$build_dir/clang-module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$build_dir/swiftpm-module-cache"
swift build -c release --disable-sandbox --scratch-path "$build_dir"

mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"
cp "$build_dir/release/NotificationTicker" "$app_dir/Contents/MacOS/NotificationTicker"
cp "$project_dir/Resources/Info.plist" "$app_dir/Contents/Info.plist"
cp "$project_dir/Resources/AppIcon.icns" "$app_dir/Contents/Resources/AppIcon.icns"
chmod +x "$app_dir/Contents/MacOS/NotificationTicker"
xattr -cr "$app_dir"
xattr -d com.apple.FinderInfo "$app_dir" 2>/dev/null || true
xattr -d 'com.apple.fileprovider.fpfs#P' "$app_dir" 2>/dev/null || true
codesign --force --deep --sign - "$app_dir"

# Google Drive 配下のバンドルは TCC（アクセシビリティ）の許可が安定しないため、
# 必ずローカルの /Applications に配置してからそこで実行する。
pkill -x NotificationTicker 2>/dev/null || true
rm -rf "$install_dir"
cp -R "$app_dir" "$install_dir"
xattr -cr "$install_dir"
codesign --force --deep --sign - "$install_dir"

echo "$install_dir"

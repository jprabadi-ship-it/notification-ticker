#!/bin/zsh
set -euo pipefail

project_dir="${0:A:h:h}"
build_dir="$project_dir/.build"
dist_app="$project_dir/dist/NotificationTicker.app"
install_dir="/Applications/NotificationTicker.app"

# Apple Development 証明書で署名する。アドホック（--sign -）だと TCC が cdhash で
# アプリを識別するため、リビルドのたびにアクセシビリティ許可が外れる。
# 証明書署名なら identity で識別され、リビルド後も許可が維持される。
signing_identity="Apple Development: jprabadi@gmail.com (32MDKWG8PQ)"

cd "$project_dir"
export CLANG_MODULE_CACHE_PATH="$build_dir/clang-module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$build_dir/swiftpm-module-cache"
swift build -c release --disable-sandbox --scratch-path "$build_dir"

# バンドルの組み立てと署名は /tmp で行う。Google Drive 配下では署名直後に
# 拡張属性が付き直り、codesign が detritus not allowed で失敗するため。
staging=$(mktemp -d)
trap 'rm -rf "$staging"' EXIT
app_dir="$staging/NotificationTicker.app"

mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"
cp "$build_dir/release/NotificationTicker" "$app_dir/Contents/MacOS/NotificationTicker"
cp "$project_dir/Resources/Info.plist" "$app_dir/Contents/Info.plist"
cp "$project_dir/Resources/AppIcon.icns" "$app_dir/Contents/Resources/AppIcon.icns"
chmod +x "$app_dir/Contents/MacOS/NotificationTicker"
codesign --force --deep --sign "$signing_identity" "$app_dir"
codesign --verify --strict "$app_dir"

# Google Drive 配下のバンドルは TCC（アクセシビリティ）の許可が安定しないため、
# 必ずローカルの /Applications に配置してからそこで実行する。
pkill -x NotificationTicker 2>/dev/null || true
rm -rf "$install_dir"
cp -R "$app_dir" "$install_dir"
codesign --verify --strict "$install_dir"

# make-dmg.sh が使う dist/ のコピーも署名済みのものへ置き換える。
mkdir -p "$project_dir/dist"
rm -rf "$dist_app"
cp -R "$app_dir" "$dist_app"

echo "$install_dir"

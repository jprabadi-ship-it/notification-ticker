#!/bin/zsh
set -euo pipefail

# 配布用の .dmg を作る。build-app.sh が組み立てた .app をそのまま収める。
# Google Drive 配下では拡張属性が付き直して hdiutil が失敗するため、
# 作業は /tmp で行い、完成品だけを dist/ へ戻す。

project_dir="${0:A:h:h}"
app_dir="$project_dir/dist/NotificationTicker.app"

"$project_dir/scripts/build-app.sh" >/dev/null

version=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$app_dir/Contents/Info.plist")
dmg_name="NotificationTicker-$version.dmg"
staging=$(mktemp -d)
work=$(mktemp -d)
trap 'rm -rf "$staging" "$work"' EXIT

cp -R "$app_dir" "$staging/NotificationTicker.app"
xattr -cr "$staging/NotificationTicker.app"
# ドラッグ＆ドロップでインストールできるよう /Applications への近道を置く。
ln -s /Applications "$staging/Applications"

# 出力先を srcfolder の外に置く。中に置くと作成中の .dmg 自身を取り込もうとする。
out="$work/$dmg_name"
hdiutil create -volname "NotificationTicker" -srcfolder "$staging" \
    -ov -format UDZO "$out" >/dev/null

mkdir -p "$project_dir/dist"
rm -f "$project_dir/dist/$dmg_name"
cp "$out" "$project_dir/dist/$dmg_name"

echo "$project_dir/dist/$dmg_name"

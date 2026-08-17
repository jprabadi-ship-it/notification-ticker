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

# Apple の公証を通し、結果をステープルする。これで初回起動の
# 「開発元を確認できません」が出なくなる。鍵は App Store Connect の APIキー。
notary_key="$HOME/.appstoreconnect/private_keys/AuthKey_73NPSB9J6V.p8"
notary_key_id="73NPSB9J6V"
notary_issuer="69a6de6e-c18d-47e3-e053-5b8c7c11a4d1"

echo "notarizing (数分かかります)..." >&2
xcrun notarytool submit "$out"     --key "$notary_key" --key-id "$notary_key_id" --issuer "$notary_issuer"     --wait >&2
xcrun stapler staple "$out" >&2

mkdir -p "$project_dir/dist"
rm -f "$project_dir/dist/$dmg_name"
cp "$out" "$project_dir/dist/$dmg_name"

echo "$project_dir/dist/$dmg_name"

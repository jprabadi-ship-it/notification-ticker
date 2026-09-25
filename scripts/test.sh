#!/bin/zsh
set -euo pipefail

# build-app.sh と同じく、作業場所を Google Drive の外に置いてテストを走らせる。
# プロジェクト直下で素の `swift test` を打つと .build が同期フォルダに作られ、
# I/O 待ちで固まることがある。
project_dir="${0:A:h:h}"
build_dir="/tmp/NotificationTicker-build"

cd "$project_dir"
export CLANG_MODULE_CACHE_PATH="$build_dir/clang-module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$build_dir/swiftpm-module-cache"
swift test --disable-sandbox --scratch-path "$build_dir" "$@"

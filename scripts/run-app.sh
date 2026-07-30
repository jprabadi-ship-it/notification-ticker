#!/bin/zsh
set -euo pipefail

project_dir="${0:A:h:h}"
installed_app="$("$project_dir/scripts/build-app.sh" | tail -1)"
open "$installed_app"

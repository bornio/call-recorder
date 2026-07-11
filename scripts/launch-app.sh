#!/bin/zsh
set -euo pipefail

repo_root="${0:A:h:h}"
app_path="$repo_root/.build/Call Recorder.app"
if [[ ! -d "$app_path" ]]; then
  "$repo_root/scripts/build-app.sh" debug >/dev/null
fi
open "$app_path"

#!/bin/zsh
set -euo pipefail

version="${1:-}"
if ! print -r -- "$version" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?$'; then
  print -u2 "usage: $0 <version>"
  exit 64
fi

repo_root="${0:A:h:h}"
app_path="$repo_root/.build/Call Recorder.app"
executable="$app_path/Contents/MacOS/CallRecorder"
output_directory="$repo_root/.build/releases"
dmg_name="Call-Recorder-$version-Apple-Silicon.dmg"
dmg_path="$output_directory/$dmg_name"
checksum_path="$dmg_path.sha256"

if [[ ! -d "$app_path" || ! -x "$executable" ]]; then
  print -u2 "build the release app before packaging it"
  exit 66
fi

architectures="$(lipo -archs "$executable")"
if [[ "$architectures" != "arm64" ]]; then
  print -u2 "expected an arm64 executable, found: $architectures"
  exit 65
fi

codesign --verify --strict --verbose=2 "$app_path"

staging_directory="$(mktemp -d "${TMPDIR:-/tmp}/call-recorder-dmg.XXXXXX")"
trap 'rm -rf "$staging_directory"' EXIT

mkdir -p "$output_directory"
rm -f "$dmg_path" "$checksum_path"
ditto "$app_path" "$staging_directory/Call Recorder.app"
ln -s /Applications "$staging_directory/Applications"

hdiutil create \
  -volname "Call Recorder" \
  -srcfolder "$staging_directory" \
  -format UDZO \
  -ov \
  "$dmg_path"
hdiutil verify "$dmg_path"

(
  cd "$output_directory"
  shasum -a 256 "$dmg_name" > "$dmg_name.sha256"
)

print "$dmg_path"
print "$checksum_path"

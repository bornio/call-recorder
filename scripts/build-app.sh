#!/bin/zsh
set -euo pipefail

configuration="${1:-release}"
case "$configuration" in
  debug|release) ;;
  *)
    print -u2 "usage: $0 [debug|release]"
    exit 64
    ;;
esac

app_version="${APP_VERSION:-}"
if [[ -n "$app_version" ]] && \
    ! print -r -- "$app_version" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?$'; then
  print -u2 "APP_VERSION must be a semantic version such as 1.2.3"
  exit 64
fi

build_number="${BUILD_NUMBER:-}"
if [[ -n "$build_number" ]] && \
    ! print -r -- "$build_number" | grep -Eq '^[0-9]+$'; then
  print -u2 "BUILD_NUMBER must contain only digits"
  exit 64
fi

repo_root="${0:A:h:h}"
cd "$repo_root"

swift build --configuration "$configuration" --product CallRecorder \
  -Xswiftc -warnings-as-errors \
  -Xcc -Werror
bin_path="$(swift build --configuration "$configuration" --show-bin-path)"
app_path="$repo_root/.build/Call Recorder.app"
contents="$app_path/Contents"

rm -rf "$app_path"
mkdir -p "$contents/MacOS" "$contents/Resources"
cp "$bin_path/CallRecorder" "$contents/MacOS/CallRecorder"
cp "$repo_root/App/Info.plist" "$contents/Info.plist"
cp "$repo_root/App/Assets/AppIcon.icns" "$contents/Resources/AppIcon.icns"

if [[ -n "$app_version" ]]; then
  /usr/libexec/PlistBuddy \
    -c "Set :CFBundleShortVersionString $app_version" \
    "$contents/Info.plist"
fi

if [[ -n "$build_number" ]]; then
  /usr/libexec/PlistBuddy \
    -c "Set :CFBundleVersion $build_number" \
    "$contents/Info.plist"
fi

chmod 755 "$contents/MacOS/CallRecorder"
codesign --force --sign - --timestamp=none "$app_path"
codesign --verify --strict --verbose=2 "$app_path"

print "$app_path"

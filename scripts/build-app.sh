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
local_signing_identity="${CALL_RECORDER_LOCAL_SIGNING_IDENTITY:-Call Recorder Local Code Signing}"
login_keychain="${CALL_RECORDER_LOCAL_KEYCHAIN:-$HOME/Library/Keychains/login.keychain-db}"
signing_identity="${CODE_SIGN_IDENTITY:-}"
signing_identity_label="$signing_identity"

if [[ -z "$signing_identity" && -f "$login_keychain" ]]; then
  signing_identity="$({
    security find-identity -v -p codesigning "$login_keychain" 2>/dev/null || true
  } | awk -v label="\"$local_signing_identity\"" '
    index($0, label) {
      if (found) exit 2
      found = 1
      print $2
    }
  ')" || {
    print -u2 "Multiple local signing identities named '$local_signing_identity' were found."
    print -u2 "Remove the duplicate or set CODE_SIGN_IDENTITY explicitly."
    exit 1
  }
  if [[ -n "$signing_identity" ]]; then
    signing_identity_label="$local_signing_identity"
  fi
fi

if [[ -n "$signing_identity" && "$signing_identity" != "-" ]]; then
  print -u2 "Signing with persistent identity: $signing_identity_label"
  codesign --force --sign "$signing_identity" "$app_path"
else
  print -u2 "warning: persistent local signing identity not found; using ad-hoc signing"
  print -u2 "run scripts/create-local-signing-identity.sh once to preserve macOS permissions"
  codesign --force --sign - --timestamp=none "$app_path"
fi
codesign --verify --strict --verbose=2 "$app_path"

print "$app_path"

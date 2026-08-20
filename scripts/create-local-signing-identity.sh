#!/bin/zsh
set -euo pipefail

identity_name="${CALL_RECORDER_LOCAL_SIGNING_IDENTITY:-Call Recorder Local Code Signing}"
keychain_path="${CALL_RECORDER_LOCAL_KEYCHAIN:-$HOME/Library/Keychains/login.keychain-db}"

if [[ "$identity_name" == *$'\n'* || "$identity_name" == */* ]]; then
  print -u2 "The local signing identity name cannot contain a slash or newline."
  exit 64
fi

if [[ ! -f "$keychain_path" ]]; then
  print -u2 "Login Keychain not found at $keychain_path"
  exit 1
fi

find_identity_hash() {
  security find-identity -v -p codesigning "$keychain_path" 2>/dev/null |
    awk -v label="\"$identity_name\"" '
      index($0, label) {
        if (found) exit 2
        found = 1
        print $2
      }
    '
}

if identity_hash="$(find_identity_hash)" && [[ -n "$identity_hash" ]]; then
  print "Local signing identity already exists: $identity_name"
  print "$identity_hash"
  exit 0
fi

temporary_directory="$(mktemp -d "${TMPDIR%/}/call-recorder-signing.XXXXXX")"
trap 'rm -rf "$temporary_directory"' EXIT INT TERM
certificate_path="$temporary_directory/certificate.pem"
private_key_path="$temporary_directory/private-key.pem"
archive_path="$temporary_directory/identity.p12"

if security find-certificate -c "$identity_name" -p "$keychain_path" \
    >"$certificate_path" 2>/dev/null; then
  security add-trusted-cert \
    -r trustRoot \
    -p codeSign \
    -k "$keychain_path" \
    "$certificate_path"
else
  openssl req \
    -new \
    -newkey rsa:3072 \
    -x509 \
    -sha256 \
    -nodes \
    -days 3650 \
    -subj "/CN=$identity_name/O=Call Recorder Local Development" \
    -addext "basicConstraints=critical,CA:FALSE" \
    -addext "keyUsage=critical,digitalSignature" \
    -addext "extendedKeyUsage=critical,codeSigning" \
    -keyout "$private_key_path" \
    -out "$certificate_path" \
    >/dev/null 2>&1

  archive_password="$(openssl rand -hex 32)"
  openssl pkcs12 \
    -export \
    -legacy \
    -name "$identity_name" \
    -inkey "$private_key_path" \
    -in "$certificate_path" \
    -out "$archive_path" \
    -passout "pass:$archive_password"

  security import "$archive_path" \
    -k "$keychain_path" \
    -f pkcs12 \
    -P "$archive_password" \
    -x \
    -T /usr/bin/codesign
  security add-trusted-cert \
    -r trustRoot \
    -p codeSign \
    -k "$keychain_path" \
    "$certificate_path"
fi

identity_hash="$(find_identity_hash)" || {
  print -u2 "Multiple local signing identities named '$identity_name' were found."
  exit 1
}
if [[ -z "$identity_hash" ]]; then
  print -u2 "The certificate was imported but is not available as a code-signing identity."
  exit 1
fi

print "Created local signing identity: $identity_name"
print "$identity_hash"

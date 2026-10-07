#!/usr/bin/env bash
# Creates a self-signed code-signing identity ("DroidBridge Local Signing") in its own keychain, so
# local builds keep the same signature and macOS keeps the Accessibility permission across rebuilds.
# Then build with:
#   SIGN_IDENTITY="DroidBridge Local Signing" SIGN_KEYCHAIN=~/Library/Keychains/droidbridge-signing.keychain-db \
#   SIGN_KEYCHAIN_PASSWORD_FILE=~/.config/droidbridge/keychain-password scripts/build-app.sh
set -euo pipefail
KC=$HOME/Library/Keychains/droidbridge-signing.keychain-db
PWFILE=$HOME/.config/droidbridge/keychain-password
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/cert.cnf" <<CNF
[req]
distinguished_name=dn
x509_extensions=ext
prompt=no
[dn]
CN=DroidBridge Local Signing
[ext]
basicConstraints=critical,CA:false
keyUsage=critical,digitalSignature
extendedKeyUsage=critical,codeSigning
CNF
openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$TMP/cert.cnf" -keyout "$TMP/key.pem" -out "$TMP/cert.pem" 2>/dev/null
P12PASS=$(openssl rand -hex 16)
openssl pkcs12 -export -legacy -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -out "$TMP/id.p12" -passout "pass:$P12PASS" 2>/dev/null \
  || openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -out "$TMP/id.p12" -passout "pass:$P12PASS"

mkdir -p "$(dirname "$PWFILE")"
openssl rand -hex 16 > "$PWFILE"
chmod 600 "$PWFILE"
security create-keychain -p "$(cat "$PWFILE")" "$KC"
security set-keychain-settings "$KC"
security unlock-keychain -p "$(cat "$PWFILE")" "$KC"
security import "$TMP/id.p12" -k "$KC" -P "$P12PASS" -T /usr/bin/codesign
security set-key-partition-list -S apple-tool:,apple: -s -k "$(cat "$PWFILE")" "$KC" >/dev/null
# codesign only finds identities in keychains on the search list.
security list-keychains -d user -s $(security list-keychains -d user | tr -d '"') "$KC"
security find-identity -p codesigning "$KC"

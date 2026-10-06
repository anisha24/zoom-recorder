#!/bin/bash
# One-time setup: creates a local self-signed code-signing identity in your login keychain so the
# app keeps the same signature across rebuilds and macOS privacy permissions stick.
# The private key is generated on this Mac, imported straight into the keychain and never stored
# in the project.
set -euo pipefail

NAME="Zoom Recorder Local Signing"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-certificate -c "$NAME" "$KEYCHAIN" >/dev/null 2>&1; then
    echo "\"$NAME\" already exists in the login keychain."
    exit 0
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

cat > "$WORK/cert.cnf" <<EOF
[req]
distinguished_name = dn
prompt = no
x509_extensions = ext
[dn]
CN = $NAME
[ext]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
subjectKeyIdentifier = hash
EOF

/usr/bin/openssl req -x509 -newkey rsa:3072 -sha256 -days 3650 -nodes \
    -config "$WORK/cert.cnf" -keyout "$WORK/key.pem" -out "$WORK/cert.pem" 2>/dev/null
# `security import` only understands the traditional "RSA PRIVATE KEY" PEM encoding.
/usr/bin/openssl rsa -in "$WORK/key.pem" -out "$WORK/key.rsa.pem" 2>/dev/null

security import "$WORK/key.rsa.pem" -k "$KEYCHAIN" -t priv -f openssl -T /usr/bin/codesign
security import "$WORK/cert.pem" -k "$KEYCHAIN" -t cert -f pemseq

echo "Created \"$NAME\". Rebuild with ./scripts/install.sh"

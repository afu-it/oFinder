#!/bin/bash
# make-signing-cert.sh — create the local code-signing identity once.
#
# Why this exists: TCC remembers an app by its code signature. An ad-hoc
# signature is the binary's own hash, so every rebuild looks like a different
# app to macOS and permissions such as Full Disk Access are dropped. A stable
# certificate keeps them.
#
# The certificate is self-signed and trusted only in your login keychain. It
# proves nothing to anyone else — it exists so the signature stays the same
# from one build to the next.
set -euo pipefail

NAME="${1:-R2 Finder Self-Signed}"

if security find-identity -v -p codesigning | grep -qF "$NAME"; then
    echo "already present: $NAME"
    exit 0
fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

cat > "$work/req.cnf" <<EOF
[ req ]
distinguished_name = dn
x509_extensions = v3
prompt = no
[ dn ]
CN = $NAME
[ v3 ]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
# Apple's "code signing" certificate extension, which codesign looks for.
1.2.840.113635.100.6.1.13 = critical,DER:0500
EOF

openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
    -keyout "$work/key.pem" -out "$work/cert.pem" -config "$work/req.cnf" 2>/dev/null

# Legacy PBE and MAC: OpenSSL 3 defaults to algorithms Apple's `security`
# cannot read, and the import fails with "MAC verification failed".
openssl pkcs12 -export -macalg sha1 \
    -certpbe PBE-SHA1-3DES -keypbe PBE-SHA1-3DES \
    -inkey "$work/key.pem" -in "$work/cert.pem" \
    -out "$work/identity.p12" -passout pass:temp -name "$NAME" 2>/dev/null

KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
security import "$work/identity.p12" -k "$KEYCHAIN" -P temp -A
# Imported is not enough: codesign refuses an identity that is not trusted for
# code signing, so mark it trusted for that purpose only.
security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" "$work/cert.pem"

security find-identity -v -p codesigning | grep -F "$NAME"
echo "done — Scripts/bundle.sh will pick this up automatically"

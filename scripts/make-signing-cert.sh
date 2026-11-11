#!/bin/zsh
# Makes a self-signed code-signing certificate, "PromptPad Local Signing", in your login keychain.
# Signing every build with the same certificate lets macOS keep PromptPad's Accessibility and
# Input Monitoring permissions across rebuilds. Remove it any time in Keychain Access (PromptPad's
# uninstall also removes it). Valid for 30 years; to replace it, delete it in Keychain Access and run this again
# (macOS then asks for the permissions once more, because the signature changed).
set -e
NAME="PromptPad Local Signing"
if security find-certificate -c "$NAME" >/dev/null 2>&1; then echo "Already there: $NAME"; exit 0; fi
D=$(mktemp -d); trap 'rm -rf "$D"' EXIT
cat > "$D/cert.cnf" <<CNF
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
CNF
/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -keyout "$D/key.pem" -out "$D/cert.pem" -days 10950 -config "$D/cert.cnf" >/dev/null 2>&1
PASS=$(/usr/bin/openssl rand -hex 12)
/usr/bin/openssl pkcs12 -export -inkey "$D/key.pem" -in "$D/cert.pem" -name "$NAME" -out "$D/cert.p12" -passout pass:$PASS >/dev/null 2>&1
security import "$D/cert.p12" -k ~/Library/Keychains/login.keychain-db -P "$PASS" -T /usr/bin/codesign
echo "Made: $NAME. The first build may ask for keychain access: choose Always Allow."

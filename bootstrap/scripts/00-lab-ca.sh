#!/usr/bin/env zsh
# Idempotent: reuses an existing CA in ~/.kc-lab-ca
set -euo pipefail
CA_DIR=${CA_DIR:-$HOME/.kc-lab-ca}
mkdir -p "$CA_DIR" && chmod 700 "$CA_DIR" && cd "$CA_DIR"

[[ -f ca.key ]] || openssl genrsa -out ca.key 4096
[[ -f ca.crt ]] || openssl req -x509 -new -key ca.key -sha256 -days 825 \
  -subj "/CN=keycloak-lab root CA" \
  -addext "basicConstraints=critical,CA:TRUE" \
  -addext "keyUsage=critical,keyCertSign,cRLSign" \
  -out ca.crt

# Trust it system-wide (Safari, Chrome, Apple-native tools)
sudo security add-trusted-cert -d -r trustRoot \
  -k /Library/Keychains/System.keychain ca.crt

openssl x509 -in ca.crt -noout -subject -enddate

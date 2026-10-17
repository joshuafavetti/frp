#!/usr/bin/env bash
# Generate the mTLS PKI for frp.
#
#   scripts/gen-certs.sh ca                     # once: create the CA in pki/ (name: $CA_NAME, default "Private CA")
#   scripts/gen-certs.sh server <dns-name>...   # server cert -> server/tls/
#   scripts/gen-certs.sh client <name>          # client cert -> pki/clients/<name>.tar.gz
#
# pki/ holds the CA private key: move it offline once certs are issued.
# server/tls/ is what the frps container mounts; copy a client bundle to
# client/tls/ on the client machine.
set -euo pipefail

cd "$(dirname "$0")/.."
PKI=pki
TLS=server/tls
CA_DAYS=1825
CERT_DAYS=365
umask 077

need_ca() {
  [[ -f $PKI/ca.key && -f $PKI/ca.crt ]] || { echo "No CA found; run: $0 ca" >&2; exit 1; }
}

sign() { # <out-prefix> <subject> <extfile>
  openssl req -new -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes \
    -keyout "$1.key" -out "$1.csr" -subj "$2" 2>/dev/null
  openssl x509 -req -in "$1.csr" -CA $PKI/ca.crt -CAkey $PKI/ca.key -CAcreateserial \
    -days $CERT_DAYS -sha256 -extfile "$3" -out "$1.crt" 2>/dev/null
  rm -f "$1.csr" "$3"
}

case "${1:-}" in
  ca)
    [[ -e $PKI/ca.key ]] && { echo "CA already exists in $PKI/" >&2; exit 1; }
    mkdir -p $PKI
    openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes \
      -keyout $PKI/ca.key -out $PKI/ca.crt -days $CA_DAYS -sha256 \
      -subj "/CN=${CA_NAME:-Private CA}" \
      -addext "basicConstraints=critical,CA:TRUE,pathlen:0" \
      -addext "keyUsage=critical,keyCertSign,cRLSign"
    echo "CA created: $PKI/ca.crt (keep $PKI/ca.key offline)"
    ;;

  server)
    shift; [[ $# -ge 1 ]] || { echo "usage: $0 server <dns-name>..." >&2; exit 1; }
    need_ca
    mkdir -p $TLS
    # The container (uid 65532) must be able to enter the dir; umask 077 would
    # otherwise make it owner-only. The key itself stays 0400.
    chmod 0755 $TLS
    # Re-issuing: the old files are read-only (and the key owned by 65532), so
    # remove them first; that only needs write access to the directory.
    rm -f $TLS/server.key $TLS/server.crt $TLS/ca.crt
    ext=$(mktemp)
    san=$(printf 'DNS:%s,' "$@"); san=${san%,}
    printf '%s\n' "basicConstraints=critical,CA:FALSE" \
      "keyUsage=critical,digitalSignature" "extendedKeyUsage=serverAuth" \
      "subjectAltName=$san" > "$ext"
    sign $TLS/server "/CN=$1" "$ext"
    cp $PKI/ca.crt $TLS/ca.crt
    chmod 0444 $TLS/ca.crt $TLS/server.crt
    chmod 0400 $TLS/server.key
    echo "Server cert written to $TLS/. The container runs as uid 65532, so run:"
    echo "  sudo chown 65532:65532 $TLS/server.key"
    ;;

  client)
    shift; [[ $# -eq 1 ]] || { echo "usage: $0 client <name>" >&2; exit 1; }
    need_ca
    dir=$PKI/clients/$1
    [[ -e $dir ]] && { echo "$dir already exists" >&2; exit 1; }
    mkdir -p "$dir"
    ext=$(mktemp)
    printf '%s\n' "basicConstraints=critical,CA:FALSE" \
      "keyUsage=critical,digitalSignature" "extendedKeyUsage=clientAuth" > "$ext"
    sign "$dir/client" "/CN=$1" "$ext"
    cp $PKI/ca.crt "$dir/ca.crt"
    # Single archive for transfer; contains the private key, so it's 0600 (umask).
    tar -czf "$dir.tar.gz" -C "$dir" ca.crt client.crt client.key
    echo "Client bundle: $dir.tar.gz (ca.crt, client.crt, client.key)"
    echo "Copy it to the client securely and unpack into client/tls/ (see README)."
    ;;

  *)
    sed -n '2,11p' "$0"; exit 1
    ;;
esac

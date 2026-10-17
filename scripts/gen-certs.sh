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

. scripts/lib.sh

need_ca() {
  [[ -f $PKI/ca.key && -f $PKI/ca.crt ]] || die "no CA found in $PKI/; create one first: ${BOLD}$0 ca${RESET}"
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
    [[ -e $PKI/ca.key ]] && die "a CA already exists in $PKI/"
    mkdir -p $PKI
    out=$(openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes \
      -keyout $PKI/ca.key -out $PKI/ca.crt -days $CA_DAYS -sha256 \
      -subj "/CN=${CA_NAME:-Private CA}" \
      -addext "basicConstraints=critical,CA:TRUE,pathlen:0" \
      -addext "keyUsage=critical,keyCertSign,cRLSign" 2>&1) || die "openssl failed: $out"
    info "CA created: $PKI/ca.crt ${RESET}${DIM}(\"${CA_NAME:-Private CA}\")${RESET}"
    note "Keep ${BOLD}$PKI/ca.key${RESET} offline once you've issued the certs you need."
    ;;

  server)
    shift; [[ $# -ge 1 ]] || die "usage: $0 server <dns-name>..."
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
    info "Server cert written to $TLS/ ${RESET}${DIM}(valid $CERT_DAYS days for: $*)${RESET}"
    next "The container runs as uid 65532, so run: ${BOLD}sudo chown 65532:65532 $TLS/server.key${RESET}"
    ;;

  client)
    shift; [[ $# -eq 1 ]] || die "usage: $0 client <name>"
    need_ca
    dir=$PKI/clients/$1
    [[ -e $dir ]] && die "$dir already exists (to re-issue: rm -rf $dir $dir.tar.gz)"
    mkdir -p "$dir"
    ext=$(mktemp)
    printf '%s\n' "basicConstraints=critical,CA:FALSE" \
      "keyUsage=critical,digitalSignature" "extendedKeyUsage=clientAuth" > "$ext"
    sign "$dir/client" "/CN=$1" "$ext"
    cp $PKI/ca.crt "$dir/ca.crt"
    # Single archive for transfer; contains the private key, so it's 0600 (umask).
    tar -czf "$dir.tar.gz" -C "$dir" ca.crt client.crt client.key
    info "Client bundle: $dir.tar.gz ${RESET}${DIM}(ca.crt, client.crt, client.key; valid $CERT_DAYS days)${RESET}"
    next "Copy it to the client securely (it contains a private key), e.g. ${BOLD}scp $dir.tar.gz user@$1:~/${RESET}"
    next "Unpack it into client/tls/ there (README Part 2, step 2)"
    ;;

  *)
    sed -n '2,11p' "$0"; exit 1
    ;;
esac

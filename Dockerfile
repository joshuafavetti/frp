# syntax=docker/dockerfile:1

# Bumping frp: update FRP_VERSION and both checksums from the release's
# frp_sha256_checksums.txt. Hardcoding the sums catches a tampered release
# even if the checksum file on GitHub was replaced too.
ARG FRP_VERSION=0.71.1
ARG FRP_SHA256_AMD64=1d9875210972a5d1a62b2dc4c48df45ab0af05d3ca1b5e494a014428259df803
ARG FRP_SHA256_ARM64=8edf590b0c396fa42f9c147121a76af83cfc2002b08f5aef0ea1008c43482019

# ---------- download + verify ----------
FROM alpine:3.23@sha256:85fe1e81d6758c208f3e1eed4338a1997e19d4be002d4dd32d3100c9a8c010a0 AS fetch
ARG FRP_VERSION FRP_SHA256_AMD64 FRP_SHA256_ARM64 TARGETARCH
RUN apk add --no-cache curl tar
RUN set -eu; \
    case "$TARGETARCH" in \
      amd64) SUM="$FRP_SHA256_AMD64" ;; \
      arm64) SUM="$FRP_SHA256_ARM64" ;; \
      *) echo "unsupported arch: $TARGETARCH" >&2; exit 1 ;; \
    esac; \
    F="frp_${FRP_VERSION}_linux_${TARGETARCH}"; \
    curl -fsSL --proto '=https' --tlsv1.2 -o /tmp/frp.tgz \
      "https://github.com/fatedier/frp/releases/download/v${FRP_VERSION}/${F}.tar.gz"; \
    echo "${SUM}  /tmp/frp.tgz" | sha256sum -c -; \
    tar -xzf /tmp/frp.tgz -C /tmp; \
    mv "/tmp/${F}" /frp

# ---------- server ----------
FROM gcr.io/distroless/static-debian12:nonroot@sha256:afa5c872c891853ca7fcf1f12c3edb23f7eeef36189728842dd51042ff57f7ab AS frps
# Root-owned and read-only: the nonroot process can't modify its own binary.
COPY --from=fetch --chown=0:0 --chmod=0555 /frp/frps /usr/bin/frps
USER 65532:65532
EXPOSE 7000
ENTRYPOINT ["/usr/bin/frps"]
CMD ["-c", "/etc/frp/frps.toml"]

# ---------- client ----------
FROM gcr.io/distroless/static-debian12:nonroot@sha256:afa5c872c891853ca7fcf1f12c3edb23f7eeef36189728842dd51042ff57f7ab AS frpc
COPY --from=fetch --chown=0:0 --chmod=0555 /frp/frpc /usr/bin/frpc
USER 65532:65532
ENTRYPOINT ["/usr/bin/frpc"]
CMD ["-c", "/etc/frp/frpc.toml"]

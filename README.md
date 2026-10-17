# frp server (hardened)

Docker Compose setup for an [frp](https://github.com/fatedier/frp) server (`frps`) with:

- Release tarball verified against a hardcoded SHA-256; base images pinned by digest
- Distroless, non-root, read-only container with all capabilities dropped
- Mutual TLS required for every client, plus a token as a second factor
- Restricted client port range, dashboard disabled

## Setup

```bash
# 1. Secrets
cp .env.example .env
sed -i "s/^FRP_TOKEN=.*/FRP_TOKEN=$(openssl rand -hex 32)/" .env
chmod 600 .env

# 2. PKI
scripts/gen-certs.sh ca
scripts/gen-certs.sh server frp.example.com
sudo chown 65532:65532 tls/server.key
scripts/gen-certs.sh client laptop     # one per client

# 3. Run
docker compose up -d --build
docker compose logs -f
```

Then move `pki/ca.key` somewhere offline. You only need it to issue new certs.

## Client config (`frpc.toml`)

Copy `pki/clients/<name>/` to the client as `tls/` and use:

```toml
serverAddr = "frp.example.com"
serverPort = 7000

transport.tls.enable        = true
transport.tls.certFile      = "/etc/frp/tls/client.crt"
transport.tls.keyFile       = "/etc/frp/tls/client.key"
transport.tls.trustedCaFile = "/etc/frp/tls/ca.crt"
transport.tls.serverName    = "frp.example.com"

auth.method           = "token"
auth.token            = "{{ .Envs.FRP_TOKEN }}"
auth.additionalScopes = ["HeartBeats", "NewWorkConns"]

# stcp: nothing is exposed publicly; only a visitor with secretKey can connect.
[[proxies]]
name      = "ssh"
type      = "stcp"
secretKey = "{{ .Envs.FRP_STCP_SECRET }}"
localIP   = "127.0.0.1"
localPort = 22
```

For a public `tcp` proxy instead, pick a `remotePort` within `allowPorts` in
`config/frps.toml` and publish it in `compose.yaml`.

## Upgrading frp

1. Set `FRP_VERSION` in `Dockerfile` and the `image:` tag in `compose.yaml`.
2. Replace both `FRP_SHA256_*` with values from the release's `frp_sha256_checksums.txt`.
3. `docker compose up -d --build`

## Further hardening (host)

- Firewall port 7000 to known client IPs if they're static.
- Keep the `docker` group small: its members can read `FRP_TOKEN` via `docker inspect`.
- Certs expire after 1 year; reissue with `scripts/gen-certs.sh`.

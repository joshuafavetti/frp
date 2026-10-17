# frp server (hardened)

Docker Compose setup for an [frp](https://github.com/fatedier/frp) server (`frps`), so you can reach services on machines behind NAT through a public server.

```
 [visitor]  ──┐                    ┌── [client]  ── service (e.g. ssh :22)
 (your laptop)│   mTLS + token     │   (machine behind NAT)
              └──►  [frps :7000] ◄─┘
                   (public server)
```

| Role | What it is | What it runs |
|---|---|---|
| **Server** | Public host, reachable on port 7000 | `frps`, using this repo |
| **Client** | Machine whose service you want to reach | `frpc` with `[[proxies]]` |
| **Visitor** | Machine you connect *from* (stcp only) | `frpc` with `[[visitors]]` |

Security model:

- **Certificates:** every client and visitor needs a cert signed by your CA (mTLS) **and** the shared token.
- **stcp proxies:** services are never exposed on a public port; only a visitor with the matching `secretKey` can reach them.
- **Container:** distroless, non-root, read-only, all capabilities dropped.
- **Supply chain:** the frp release is checked against a hardcoded SHA-256, and base images are pinned by digest.

---

## Part 1: Server

Do this once, on the public host. It needs Docker with Compose and `openssl`.

### 1. Clone and set the token

```bash
git clone git@github.com:joshuafavetti/frp.git && cd frp
cp .env.example .env
sed -i "s/^FRP_TOKEN=.*/FRP_TOKEN=$(openssl rand -hex 32)/" .env
chmod 600 .env
```

Every client and visitor needs this token. Keep it safe.

### 2. Create the CA and server certificate

Use the DNS name clients will connect to:

```bash
scripts/gen-certs.sh ca
scripts/gen-certs.sh server frp.example.com
sudo chown 65532:65532 tls/server.key   # container runs as uid 65532
```

### 3. Open the firewall

Allow inbound **TCP 7000**. If your clients have static IPs, allow those IPs only.

### 4. Start it

```bash
docker compose up -d --build
docker compose logs -f   # expect: "frps started successfully"
```

### 5. Issue a cert for each client and visitor

On the server, give each machine its own name:

```bash
scripts/gen-certs.sh client home-pc
scripts/gen-certs.sh client laptop
```

Each command creates `pki/clients/<name>/` containing `ca.crt`, `client.crt` and `client.key`.

Copy that folder to the machine securely, for example:

```bash
scp -r pki/clients/home-pc user@home-pc:~/frpc/tls
```

Then give it the token from `.env` over a secure channel.

### 6. Protect the CA key

Once you've issued the certs you need, move `pki/ca.key` off the server, for example to an encrypted USB drive or a password manager. You only need it to issue new certs. Certs expire after 1 year.

---

## Part 2: Client (the machine with the service)

This machine needs Docker. It only makes outbound connections to the server on port 7000.

### 1. Set up the folder

```bash
mkdir -p ~/frpc && cd ~/frpc
# tls/ should already be here from server step 5
sudo chown -R 65532:65532 tls && sudo chmod 400 tls/client.key

cat > .env <<EOF
FRP_TOKEN=<token from the server's .env>
FRP_STCP_SECRET=$(openssl rand -hex 32)
EOF
chmod 600 .env
```

`FRP_STCP_SECRET` is the per-service password. The visitor needs the same value.

### 2. Write `frpc.toml`

```toml
serverAddr = "frp.example.com"
serverPort = 7000

transport.tls.enable        = true
transport.tls.certFile      = "/etc/frp/tls/client.crt"
transport.tls.keyFile       = "/etc/frp/tls/client.key"
transport.tls.trustedCaFile = "/etc/frp/tls/ca.crt"
transport.tls.serverName    = "frp.example.com"   # must match the server cert

auth.method           = "token"
auth.token            = "{{ .Envs.FRP_TOKEN }}"
auth.additionalScopes = ["HeartBeats", "NewWorkConns"]

# Expose local SSH privately. Add one [[proxies]] block per service.
[[proxies]]
name      = "home-pc-ssh"           # must be unique across all clients
type      = "stcp"
secretKey = "{{ .Envs.FRP_STCP_SECRET }}"
localIP   = "127.0.0.1"
localPort = 22
```

### 3. Run it

This uses frp's official image, pinned by digest, with the same hardening as the server:

```bash
docker run -d --name frpc --restart unless-stopped \
  --network host \
  --user 65532:65532 --read-only --cap-drop ALL \
  --security-opt no-new-privileges:true \
  --pids-limit 100 --memory 64m \
  --env-file .env \
  -v $PWD/frpc.toml:/etc/frp/frpc.toml:ro \
  -v $PWD/tls:/etc/frp/tls:ro \
  ghcr.io/fatedier/frpc:v0.71.1@sha256:7a0a18bc9c83dc106a7e5213a890f521affdf90d595829c56b0ed8481377d50e \
  -c /etc/frp/frpc.toml

docker logs -f frpc   # expect: "start proxy success"
```

`--network host` lets `localIP = "127.0.0.1"` reach services on the host. frpc only makes outbound connections, so this doesn't open anything.

---

## Part 3: Visitor (the machine you connect from)

You need this for `stcp` proxies. Set up the folder exactly as in Part 2 step 1, with its own cert from server step 5. In `.env`, use the **same** `FRP_STCP_SECRET` as the client.

### `frpc.toml`

Use the same server, TLS and auth lines as the client, then:

```toml
[[visitors]]
name       = "home-pc-ssh-visitor"
type       = "stcp"
serverName = "home-pc-ssh"          # the client's proxy name
secretKey  = "{{ .Envs.FRP_STCP_SECRET }}"
bindAddr   = "127.0.0.1"            # local only
bindPort   = 6000
```

Run it with the same `docker run` command as the client, then connect:

```bash
ssh -p 6000 user@127.0.0.1
```

---

## Alternative: public `tcp` proxy (no visitor)

If a service needs to be reachable by anyone, for example a game server, use `type = "tcp"` on the client:

```toml
[[proxies]]
name       = "game"
type       = "tcp"
localIP    = "127.0.0.1"
localPort  = 25565
remotePort = 6000      # must be within allowPorts in config/frps.toml (6000-6009)
```

Then on the **server**, uncomment or add `- "6000:6000"` under `ports:` in `compose.yaml` and run `docker compose up -d`. The port is now open to the internet, so the service must handle its own authentication.

---

## Maintenance

**Upgrading frp:**

1. Set `FRP_VERSION` in `Dockerfile` and the `image:` tag in `compose.yaml`.
2. Replace both `FRP_SHA256_*` values with the ones from the release's `frp_sha256_checksums.txt`.
3. On the server, run `docker compose up -d --build`.
4. On clients and visitors, update the `ghcr.io/fatedier/frpc` tag and digest.

**Revoking a client:** frp doesn't support revocation lists, so do one of the following:

- rotate `FRP_TOKEN`, which affects every client;
- re-create the CA and reissue all certs.

Short cert lifetimes keep the exposure window small.

**Host hardening:** keep the `docker` group small. Its members can read `FRP_TOKEN` with `docker inspect`.

## Troubleshooting

| Symptom | Likely cause |
|---|---|
| `tls: bad certificate` / `certificate signed by unknown authority` | Client is using a cert or `ca.crt` from a different CA |
| `x509: certificate is valid for X, not Y` | `serverName` in frpc.toml doesn't match the name given to `gen-certs.sh server` |
| `token in login doesn't match` | `FRP_TOKEN` differs between server and client |
| `port not allowed` | `remotePort` is outside `allowPorts` |
| `open /etc/frp/tls/...: permission denied` | Key isn't owned by uid 65532 (`sudo chown 65532:65532 ...`) |
| Visitor connects but hangs | `secretKey` or `serverName` doesn't match the client's proxy |

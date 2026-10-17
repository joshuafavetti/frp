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

To host public websites on multiple domains through Nginx Proxy Manager, see [Part 4](#part-4-websites-via-nginx-proxy-manager).

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

## Part 4: Websites via Nginx Proxy Manager

Use this to serve websites on any number of domains from apps running on clients. Nginx Proxy Manager (NPM) handles public HTTPS and Let's Encrypt certificates. frps routes each request to the right client by its `Host` header.

```
internet ──443──► NPM ──► frps:8080 (vhost, internal only) ──► frpc ──► app on client
frpc ──7000 (mTLS, direct, NOT through NPM)──► frps
```

Port 7000 stays published directly from frps. Don't route it through NPM, not even with NPM's "Streams" feature.

### Server: one-time setup

**1. Create a shared Docker network:**

```bash
docker network create proxy
```

**2. Enable the vhost port** in `config/frps.toml` by uncommenting:

```toml
vhostHTTPPort = 8080
```

Do **not** add 8080 to `ports:` in `compose.yaml`. Only NPM should be able to reach it.

**3. Join frps to the network.** In `compose.yaml`, uncomment `networks: [proxy]` under the service and the `networks:` block at the bottom. Then run:

```bash
docker compose up -d
```

**4. Run NPM on the same network.** If NPM is already running, add `networks: [proxy]` plus the same external `networks:` block to its compose file. Otherwise, create a separate folder, for example `~/npm/compose.yaml`:

```yaml
services:
  npm:
    image: jc21/nginx-proxy-manager:2.16.0   # pin a version; never use :latest
    container_name: npm
    restart: unless-stopped
    ports:
      - "80:80"            # needed for Let's Encrypt
      - "443:443"
      - "127.0.0.1:81:81"  # admin UI: localhost only
    volumes:
      - ./data:/data
      - ./letsencrypt:/etc/letsencrypt
    networks: [proxy]

networks:
  proxy:
    external: true
```

```bash
cd ~/npm && docker compose up -d
```

**5. Open the firewall** for inbound **TCP 80 and 443**. Leave port 81 closed.

**6. Secure the admin UI.** It's only reachable through an SSH tunnel:

```bash
ssh -L 8181:127.0.0.1:81 user@your-server
```

Open http://localhost:8181 and set a strong admin email and password straight away. Never publish port 81.

### Adding a website

Do these three steps for each site.

**1. DNS:** create an A/AAAA record pointing the domain, for example `app1.com`, at the server's public IP.

**2. Client:** add an `http` proxy to the client's `frpc.toml`, then run `docker restart frpc`:

```toml
[[proxies]]
name          = "app1"                         # unique across all clients
type          = "http"
localIP       = "127.0.0.1"
localPort     = 3000                           # the app's local port
customDomains = ["app1.com", "www.app1.com"]
```

**3. NPM:** go to **Hosts → Proxy Hosts → Add Proxy Host**:

| Tab | Field | Value |
|---|---|---|
| Details | Domain Names | `app1.com`, `www.app1.com` (must match `customDomains` exactly) |
| | Scheme | `http` |
| | Forward Hostname / IP | `frps` |
| | Forward Port | `8080` |
| | Block Common Exploits | On |
| | Websockets Support | On, if the app uses websockets |
| SSL | SSL Certificate | Request a new certificate (Let's Encrypt) |
| | Force SSL, HTTP/2, HSTS | On |

To require a login in front of a site, create an **Access List** in NPM and attach it to the proxy host.

### Notes

- **These sites are public.** Unlike stcp, anyone can reach them, so each app needs its own authentication or an NPM Access List.
- **frps can't limit which domains a client claims.** A client with a valid cert could register another client's domain. NPM only forwards domains you've added as proxy hosts, which limits the damage, and only clients you issued certs to can connect at all.
- **NPM is now the most exposed component.** It runs as root inside its container and has had security bugs. Keep it pinned and updated on purpose, and watch its releases.
- **Traffic is encrypted end to end:** HTTPS from browser to NPM, then frp's mTLS tunnel from frps to the client. Only the hop from NPM to frps on the private Docker network is plain HTTP.

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
| NPM shows `502 Bad Gateway` | frps and NPM aren't on the same `proxy` network, or `vhostHTTPPort` isn't enabled |
| frps returns `404 Not Found` page | Domain in NPM doesn't match any client's `customDomains`, or that client's frpc isn't connected |
| Let's Encrypt fails in NPM | DNS doesn't point at the server yet, or port 80 is blocked |

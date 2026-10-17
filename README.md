# frp (hardened)

Docker Compose setup for both sides of [frp](https://github.com/fatedier/frp): the **server** (`frps`) on a public host, and **clients** (`frpc`) on machines behind NAT. Use it to reach services on those machines, or to publish websites from them.

```
 [visitor]  ──┐                    ┌── [client]  ── service (e.g. ssh :22)
 (your laptop)│   mTLS + token     │   (machine behind NAT)
              └──►  [frps :7000] ◄─┘
                   (public server)
```

| Role | What it is | Folder |
|---|---|---|
| **Server** | Public host, reachable on port 7000 | `server/` |
| **Client** | Machine whose service you want to reach | `client/` with `[[proxies]]` |
| **Visitor** | Machine you connect *from* (stcp only) | `client/` with `[[visitors]]` |

One machine can be both a client and a visitor; just add both kinds of blocks to its `frpc.toml`.

**Security model:**

- **Authentication:** every client needs a cert signed by your CA (mTLS) **and** the shared token.
- **Private services (stcp):** never exposed on a public port; only a visitor with the matching `secretKey` can reach them.
- **Containers:** both sides are distroless, non-root and read-only, with all capabilities dropped.
- **Supply chain:** frp release tarballs are checked against a hardcoded SHA-256, and base images are pinned by digest.

## Repo layout

```
Dockerfile               # builds both frps and frpc (shared, checksum-verified)
scripts/gen-certs.sh     # CA, server and client certificates (run on the server)
server/
  compose.yaml
  compose.npm.yaml       # optional: join NPM's external network
  frps.toml.example      # copy to frps.toml
  .env.example           # copy to .env
client/
  compose.yaml
  frpc.toml.example      # copy to frpc.toml
  .env.example           # copy to .env
```

Your own `frps.toml`, `frpc.toml`, `.env`, `tls/` and `pki/` are gitignored, so `git pull` never overwrites them.

---

## Part 1: Server

Do this once, on the public host. It needs Docker with Compose, and `openssl`.

### 1. Clone and configure

```bash
git clone git@github.com:joshuafavetti/frp.git && cd frp
cp server/frps.toml.example server/frps.toml
cp server/.env.example server/.env
sed -i "s/^FRP_TOKEN=.*/FRP_TOKEN=$(openssl rand -hex 32)/" server/.env
chmod 600 server/.env
```

Every client needs `FRP_TOKEN`. Keep it safe.

### 2. Create the CA and server certificate

Use the public DNS name clients will connect to:

```bash
scripts/gen-certs.sh ca
scripts/gen-certs.sh server frp.example.com
sudo chown 65532:65532 server/tls/server.key   # containers run as uid 65532
```

### 3. Open the firewall

Allow inbound **TCP 7000**. If your clients have static IPs, allow only those.

### 4. Start it

```bash
cd server
docker compose up -d --build
docker compose logs -f   # expect: "frps started successfully"
```

### 5. Issue a cert for each client

Run this from the repo root on the server, with one unique name per machine:

```bash
scripts/gen-certs.sh client home-pc
scripts/gen-certs.sh client laptop
```

Each command creates `pki/clients/<name>.tar.gz` containing `ca.crt`, `client.crt` and `client.key`. You'll copy it to that machine in Part 2. It contains a private key, so only transfer it over a secure channel like `scp`.

### 6. Protect the CA key

Once you've issued the certs you need, move `pki/ca.key` off the server, for example to an encrypted USB drive or a password manager. You only need it to issue new certs. Certs expire after 1 year.

---

## Part 2: Client

Do this on each machine behind NAT. It needs Docker with Compose, and only makes outbound connections to the server on port 7000.

### 1. Clone and configure

```bash
git clone git@github.com:joshuafavetti/frp.git && cd frp/client
cp frpc.toml.example frpc.toml
cp .env.example .env
chmod 600 .env
```

Edit `.env`:

| Variable | Value |
|---|---|
| `FRP_SERVER_ADDR` | The server's DNS name, same as in `gen-certs.sh server` |
| `FRP_TOKEN` | The `FRP_TOKEN` from the server's `server/.env` |
| `FRP_STCP_SECRET` | `openssl rand -hex 32`. Needed only for stcp, and the visitor must use the same value |

### 2. Install the certificate

**On the server**, send this machine's bundle from the repo root:

```bash
scp pki/clients/home-pc.tar.gz user@home-pc:~/
```

**On the client**, unpack it into `client/tls/`, set ownership for the container user, and delete the archive:

```bash
cd ~/frp/client
mkdir -p tls
tar -xzf ~/home-pc.tar.gz -C tls
sudo chown -R 65532:65532 tls
sudo chmod 400 tls/client.key
shred -u ~/home-pc.tar.gz   # contains the private key
ls -ln tls                  # expect ca.crt, client.crt, client.key owned by 65532
```

### 3. Choose what to expose

`frpc.toml` has commented examples. Uncomment the one you need:

| Example | Use it for | Public? |
|---|---|---|
| `stcp` proxy | Private access to a service, e.g. SSH | No; a visitor is needed (Part 3) |
| `http` proxy | A website on your domain via NPM (Part 4) | Yes |
| `tcp` proxy | A raw public port, e.g. a game server (Part 5) | Yes |

For example, private SSH:

```toml
[[proxies]]
name      = "home-pc-ssh"        # must be unique across all clients
type      = "stcp"
secretKey = "{{ .Envs.FRP_STCP_SECRET }}"
localIP   = "127.0.0.1"
localPort = 22
```

### 4. Start it

```bash
docker compose up -d --build
docker compose logs -f   # expect: "login to server success" and "start proxy success"
```

After editing `frpc.toml`, apply the changes with `docker compose restart`.

The client uses `network_mode: host`, so `localIP = "127.0.0.1"` reaches services on the machine itself. frpc only makes outbound connections, so this doesn't open anything.

---

## Part 3: Visitor (connecting to an stcp service)

The visitor is the machine you connect *from*, for example your laptop. Set it up exactly like Part 2, with its own cert from server step 5. In `.env`, use the **same** `FRP_STCP_SECRET` as the client whose service you want to reach.

In `frpc.toml`, uncomment the visitor block:

```toml
[[visitors]]
name       = "home-pc-ssh-visitor"
type       = "stcp"
serverName = "home-pc-ssh"          # the client's proxy name
secretKey  = "{{ .Envs.FRP_STCP_SECRET }}"
bindAddr   = "127.0.0.1"            # local only
bindPort   = 6000
```

Start it with `docker compose up -d --build`, then connect:

```bash
ssh -p 6000 user@127.0.0.1
```

---

## Part 4: Websites via Nginx Proxy Manager

Use this to serve websites on any number of domains from apps running on clients. Nginx Proxy Manager (NPM) on the server handles public HTTPS and Let's Encrypt. frps routes each request to the right client by its `Host` header.

```
internet ──443──► NPM ──► frps:8080 (vhost, internal only) ──► frpc ──► app on client
frpc ──7000 (mTLS, direct, NOT through NPM)──► frps
```

Port 7000 stays published directly from frps. Don't route it through NPM, not even with NPM's "Streams" feature.

### Server: one-time setup

frps joins the Docker network that NPM is already on, so NPM can reach it at `http://frps:8080`. That network is *external* to this compose project, and NPM owns it. The override file `server/compose.npm.yaml` handles this, and you turn it on from `.env`, so you don't edit `compose.yaml`.

**1. Find NPM's network.**

*If NPM is already running*, list its networks:

```bash
docker inspect npm -f '{{range $k, $v := .NetworkSettings.Networks}}{{$k}} {{end}}'
```

Use your NPM container's name if it isn't `npm`; `docker ps` shows it. The output is usually `proxy`, or `<folder>_default` such as `npm_default` if NPM's compose file doesn't define a network. Use that name in step 3.

*If NPM isn't running yet*, create a network and start NPM on it. Make a separate folder, for example `~/npm/compose.yaml`:

```bash
docker network create proxy
```

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

**2. Enable the vhost port** in `server/frps.toml` by uncommenting:

```toml
vhostHTTPPort = 8080
```

Do **not** add 8080 to `ports:` in `server/compose.yaml`. Only NPM should be able to reach it.

**3. Join frps to NPM's network.** In `server/.env`, uncomment and set:

```bash
COMPOSE_FILE=compose.yaml:compose.npm.yaml
PROXY_NETWORK=proxy          # the name from step 1
```

Then recreate frps and check it joined:

```bash
cd server && docker compose up -d
docker inspect frps -f '{{range $k, $v := .NetworkSettings.Networks}}{{$k}} {{end}}'
# expect: server_default proxy
```

frps stays on its own default network too; the published port 7000 works the same. If the network doesn't exist, compose stops with `network proxy declared as external, but could not be found`. Check the name from step 1.

**4. Open the firewall** for inbound **TCP 80 and 443**. Leave port 81 closed.

**5. Secure the admin UI.** It's only reachable through an SSH tunnel:

```bash
ssh -L 8181:127.0.0.1:81 user@your-server
```

Open http://localhost:8181 and set a strong admin email and password straight away. Never publish port 81.

### Adding a website

Do these three steps for each site.

**1. DNS:** create an A/AAAA record pointing the domain, for example `app1.com`, at the server's public IP.

**2. Client:** uncomment or add an `http` proxy in `client/frpc.toml`, then run `docker compose restart`:

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

## Part 5: Public TCP port (no visitor)

If a raw TCP service needs to be reachable by anyone, for example a game server:

**1. Client:** uncomment the `tcp` example in `client/frpc.toml`:

```toml
[[proxies]]
name       = "game"
type       = "tcp"
localIP    = "127.0.0.1"
localPort  = 25565
remotePort = 6000      # must be within allowPorts in server/frps.toml (6000-6009)
```

**2. Server:** uncomment or add `- "6000:6000"` under `ports:` in `server/compose.yaml`, open the port in the firewall, then run `docker compose up -d`.

The port is now open to the internet, so the service must handle its own authentication.

---

## Maintenance

**Upgrading frp** (both sides build from the same `Dockerfile`):

1. Set `FRP_VERSION` in `Dockerfile`, and the `image:` tag in `server/compose.yaml` and `client/compose.yaml`.
2. Replace both `FRP_SHA256_*` values with the ones from the release's `frp_sha256_checksums.txt`.
3. Commit and push. Then on each machine, run `git pull`, followed by `docker compose up -d --build` in `server/` or `client/`.

**Pulling repo updates:** your configs and secrets are gitignored, so `git pull` is safe. Afterwards, check the `.example` files for new options you might want.

**Revoking a client:** frp doesn't support revocation lists, so do one of the following:

- rotate `FRP_TOKEN`, which affects every client;
- re-create the CA and reissue all certs.

Short cert lifetimes keep the exposure window small.

**Host hardening:** on every machine, keep the `docker` group small. Its members can read `FRP_TOKEN` with `docker inspect`.

## Troubleshooting

| Symptom | Likely cause |
|---|---|
| `tls: bad certificate` / `certificate signed by unknown authority` | Client is using a cert or `ca.crt` from a different CA |
| `x509: certificate is valid for X, not Y` | `FRP_SERVER_ADDR` doesn't match the name given to `gen-certs.sh server` |
| `token in login doesn't match` | `FRP_TOKEN` differs between server and client |
| `port not allowed` | `remotePort` is outside `allowPorts` |
| `proxy name [...] is already in use` | Two clients use the same proxy `name` |
| `open /etc/frp/tls/...: permission denied` | The `tls/` folder isn't `755` (`chmod 755 tls`), or the key isn't owned by uid 65532 (`sudo chown 65532:65532 tls/*.key`) |
| `bind source path does not exist: .../frpc.toml` (or `frps.toml`, `tls`) | You haven't copied the `.example` file, or haven't installed the certs, yet |
| Visitor connects but hangs | `secretKey` or `serverName` doesn't match the client's proxy |
| NPM shows `502 Bad Gateway` | frps isn't on NPM's network (check `COMPOSE_FILE` / `PROXY_NETWORK` in `server/.env`), or `vhostHTTPPort` isn't enabled |
| frps returns `404 Not Found` page | Domain in NPM doesn't match any client's `customDomains`, or that client's frpc isn't connected |
| Let's Encrypt fails in NPM | DNS doesn't point at the server yet, or port 80 is blocked |

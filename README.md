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
scripts/npm-network.sh   # server, interactive: connect frps to Nginx Proxy Manager's network
scripts/client-network.sh  # client, interactive: add services, connect other compose apps' networks
scripts/lib.sh           # shared helpers for the two scripts above
server/
  compose.yaml
  compose.npm.yaml       # optional: join NPM's external network
  404.html               # generic "site can't be reached" page replacing frp's branded 404
  frps.toml.example      # copy to frps.toml
  .env.example           # copy to .env
client/
  compose.yaml
  compose.override.yaml.example  # optional: frpc joins other apps' networks (the script writes it)
  frpc.toml.example      # copy to frpc.toml
  .env.example           # copy to .env
```

Your own `frps.toml`, `frpc.toml`, `compose.override.yaml`, `.env`, `tls/` and `pki/` are gitignored, so `git pull` never overwrites them.

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
cd ..
```

### 5. Connect to the right Docker network

Decide now whether frps will sit behind Nginx Proxy Manager (NPM), and confirm it's on the right network. A wrong network is the usual cause of `502 Bad Gateway` later. The helper script does both, from the repo root:

```bash
scripts/npm-network.sh
```

```
  1) Connect frps to NPM's network
  2) Disconnect (default: frps on its own network only, no NPM)
  3) Check the current setup (changes nothing)
```

| Your setup | Choose |
|---|---|
| **No NPM**, or only stcp/tcp proxies (the default) | **3) Check**: confirms frps is in default mode. Nothing to configure. |
| **NPM on this server**. Start it first if needed; see [Part 4](#part-4-websites-via-nginx-proxy-manager), step 1 | **1) Connect**: finds NPM's network, updates `server/.env` and `server/frps.toml`, recreates frps, then runs the check automatically |

The check looks like this when it passes:

```
Checking frps network setup:
  [ OK ] frps is running, on: npm_default server_default
  [ OK ] vhostHTTPPort is enabled in server/frps.toml
  [ OK ] frps is on PROXY_NETWORK=npm_default
  [ OK ] NPM container 'npm' is on npm_default too, so NPM can reach http://frps:8080
```

Each `[FAIL]` line says what's wrong and how to fix it. For example, frps might not have been recreated yet, or NPM might be on a different network than `PROXY_NETWORK`. In default mode, a `[WARN]` means NPM is running but frps isn't connected to it; that's fine if you don't proxy websites through NPM.

Run **3) Check** again any time you change NPM or `server/.env`. Run as your normal user; if Docker needs root, the script offers to use `sudo` for docker commands only.

### 6. Issue a cert for each client

Run this from the repo root on the server, with one unique name per machine:

```bash
scripts/gen-certs.sh client home-pc
scripts/gen-certs.sh client laptop
```

Each command creates `pki/clients/<name>.tar.gz` containing `ca.crt`, `client.crt` and `client.key`. You'll copy it to that machine in Part 2. It contains a private key, so only transfer it over a secure channel like `scp`.

### 7. Protect the CA key

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

### 3. Start it

```bash
docker compose up -d --build
docker compose logs -f   # expect: "login to server success"
```

frpc starts with nothing exposed. Next, add the services you want to reach.

### 4. Add services

Run the helper script from the repo root (`~/frp`):

```bash
scripts/client-network.sh
```

```
Network mode: host networking (default)
Proxies in frpc.toml: 0
  1) Connect frpc to more app networks (keeps existing ones)
  2) Add a service (proxy) to frpc.toml (keeps existing ones)
  3) Disconnect frpc from an app's network
  4) Back to host networking (default: reach services on 127.0.0.1)
  5) Check the current setup (changes nothing)
```

Which option to pick depends on where the service runs:

| The service runs... | Choose | localIP |
|---|---|---|
| **Directly on this machine** (e.g. SSH), or in a container with `network_mode: host` or a published port | **2) Add a service** | `127.0.0.1` |
| **In a Docker container from another compose file** (e.g. Home Assistant on `8123`) | **1) Connect**: frpc joins that app's network and then offers to add its services; no ports need publishing | the container's service name |

For each service, the script asks for:
- a proxy name;
- localIP and localPort, pre-filled from what it detects;
- how it should be reachable:

| Type | Use it for | Public? |
|---|---|---|
| `http` | A website on your domain via NPM on the server (Part 4) | Yes |
| `stcp` | Private access, e.g. SSH; only a visitor with the secret can connect (Part 3) | No |
| `tcp` | A raw public port on the server, e.g. a game server (Part 5) | Yes |

It appends a `[[proxies]]` block to `frpc.toml`, recreates frpc and checks the result:

```
Checking frpc network setup:
  [ OK ] App-network mode, frpc is on: client_default ha_default media_default
  [ OK ] frpc is on ha_default
  [ OK ] frpc is on media_default
  [ OK ] frpc is logged in to the server
  [ OK ] Proxy 'homeassistant' -> 'homeassistant' resolves on ha_default
  [ OK ] Proxy 'homeassistant' registered with the server
  [ OK ] Proxy 'jellyfin' -> 'media-web-1' resolves on media_default
  [ OK ] Proxy 'jellyfin' registered with the server
```

**Adding more later:** run the script again. **1) Connect** adds networks for new apps, and **2) Add a service** adds proxies. Existing networks and proxies are always kept, and a duplicate proxy name is refused. For an `http` proxy, the script also reminds you to add the matching NPM proxy host on the server.

**Editing `frpc.toml` by hand:** commented examples are in the file. Apply the changes with `docker compose up -d --force-recreate`. A plain `restart` can keep reading the old file, because many editors save by replacing it, which a single-file bind mount doesn't follow. Then run the script's **5) Check**.

### Exposing services from other Docker containers

When the service runs in another compose project, **1) Connect** is the better choice over publishing its port to `127.0.0.1`:

- **Nothing is published on the host.** frpc reaches the container directly on its Docker network, and you can drop `ports:` from that app's compose file if it was only there for frpc.
- **frpc sees only what you connect.** In host mode, frpc can reach *every* service on the machine's localhost.
- **One frpc serves every app.** Connect as many app networks as you need, in one run or over time.

How it works:

- **`client/compose.override.yaml`:** the script writes this file, which is gitignored. Compose loads it automatically. It takes frpc off host networking (`network_mode: !reset null`, which needs Docker Compose 2.24+) and attaches it to each app network as an external network. For a hand-written version, see `client/compose.override.yaml.example`.
- **Service names:** proxies use the container's service name as `localIP`, for example `homeassistant`, and its *container* port as `localPort`. Docker DNS resolves the name on the shared network.
- **Name clashes:** if two connected apps have a service with the same name, for example both have `web`, the script uses the unique container name instead, such as `media-web-1`. The check warns about ambiguous names.

Things to know:

- **`127.0.0.1` means frpc's own container** once frpc is on app networks. The check flags any proxy still using it.
- **Containers with `network_mode: host`** have no network to join. The script lists them; keep frpc in host mode and use `127.0.0.1`.
- **Visitors need host networking.** Off host networking, a visitor's `bindAddr` is inside the container and can't be reached from this machine. Keep visitor machines on host networking (option 4).
- **Home Assistant behind a proxy:** requests now come from frpc's container IP, not `127.0.0.1`. In `trusted_proxies`, use the app network's subnet:

  ```bash
  docker network inspect ha_default -f '{{range .IPAM.Config}}{{.Subnet}}{{end}}'   # e.g. 172.18.0.0/16
  ```

  ```yaml
  http:
    use_x_forwarded_for: true
    trusted_proxies:
      - 172.18.0.0/16
  ```

- **Disconnecting an app** with option 3 leaves its proxies in `frpc.toml`. The check reports them as `doesn't match any container`, so remove those blocks.

---

## Part 3: Visitor (connecting to an stcp service)

The visitor is the machine you connect *from*, for example your laptop. Set it up exactly like Part 2, with its own cert from Part 1, step 6. In `.env`, use the **same** `FRP_STCP_SECRET` as the client whose service you want to reach.

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

frps has to join the Docker network NPM is on, so NPM can reach it at `http://frps:8080`. That network belongs to NPM, so to this project it's *external*. Its name depends on how NPM was started, so nothing in this repo hardcodes it:

- `server/compose.npm.yaml` is an optional override that attaches frps to the network named in `PROXY_NETWORK`.
- It's switched on by `COMPOSE_FILE` in `server/.env`.
- `scripts/npm-network.sh` detects the right values and sets them for you.

**Default case (no NPM):** leave `COMPOSE_FILE` and `PROXY_NETWORK` commented out in `server/.env`, which is how they ship. frps then stays on its own `server_default` network only, and nothing here applies.

**1. Make sure NPM is running.** If it already is, skip to step 2. Otherwise, start it from a separate folder, for example `~/npm/compose.yaml`:

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
```

```bash
cd ~/npm && docker compose up -d
```

This compose file defines no network, so NPM lands on its compose default network, `npm_default` (named after the folder). The script handles that, as well as a named shared network such as `proxy`.

**2. Connect frps to NPM's network with the helper script.** Run it from the repo root as your normal user, not with `sudo`. If Docker needs root, it offers to use `sudo` for docker commands only, so `server/.env` keeps its owner.

```bash
scripts/npm-network.sh
```

It's interactive and confirms each change before applying it:

```
  1) Connect frps to NPM's network
  2) Disconnect (default: frps on its own network only, no NPM)
  3) Check the current setup (changes nothing)
What do you want to do? [1-3] 1
Found NPM container 'npm'. Use it? [Y/n] y
'npm' is on network 'npm_default'. Connect frps to it? [Y/n] y

Planned changes:
  server/.env:  COMPOSE_FILE=compose.yaml:compose.npm.yaml
  server/.env:  PROXY_NETWORK=npm_default
  server/frps.toml:  enable vhostHTTPPort = 8080

Apply these changes? [Y/n] y
Start/recreate frps now and check the result? [Y/n] y

Checking frps network setup:
  [ OK ] frps is running, on: npm_default server_default
  [ OK ] vhostHTTPPort is enabled in server/frps.toml
  [ OK ] frps is on PROXY_NETWORK=npm_default
  [ OK ] NPM container 'npm' is on npm_default too, so NPM can reach http://frps:8080

==> Done. In NPM, forward proxy hosts to:  http://frps:8080
```

To verify later without changing anything, choose **3) Check**.

How it handles each NPM setup:

| NPM's networking | What the script does |
|---|---|
| Its own compose network, e.g. `npm_default` (the default) | Detects it and offers it |
| A shared network, e.g. `proxy` | Detects it and offers it |
| Several networks | Shows a menu to pick one, or type a name |
| Only Docker's built-in `bridge` | Explains why that can't work (no name resolution), and offers to create `proxy` and connect NPM to it |
| `network_mode: host` | Changes nothing, and prints the alternative: publish `127.0.0.1:8080:8080` and forward to `127.0.0.1:8080` |
| Container not detected (custom image name) | Lists running containers and asks for the name |

To undo it later, run the script again and choose **2) Disconnect**. That comments the two lines back out, recreates frps on its own network only, and runs the check.

#### Changing the network later

Sometimes NPM moves to a different network: you add a shared `proxy` network to its compose file, rename its folder (which renames `<folder>_default`), or replace it. frps has to follow.

**With the script:** run `scripts/npm-network.sh` again and choose **1) Connect**. It detects NPM's current network, overwrites `PROXY_NETWORK`, recreates frps and checks the result. If you're not sure whether anything changed, choose **3) Check** first.

**By hand:** set the new name in `server/.env` and re-run compose:

```bash
sed -i -E 's|^#?[[:space:]]*PROXY_NETWORK=.*|PROXY_NETWORK=proxy|' server/.env   # new network name
(cd server && docker compose up -d)
scripts/npm-network.sh   # choose 3) Check
```

Compose notices the change, then recreates frps and moves it from the old network to the new one; you don't need `down`. NPM's proxy hosts don't need editing, because they still forward to `frps:8080`.

**NPM's `docker compose down` and the shared network:** if frps is attached to NPM's default network (e.g. `npm_default`), NPM's `down` prints `Network npm_default Resource is still in use` and leaves the network in place. That's expected and harmless. When NPM comes back up, it rejoins the same network and reaches frps again. If you do want that network removed, disconnect frps first (script option **2**).

<details>
<summary>Manual alternative (no script)</summary>

These commands detect the values instead of hardcoding them. Run them from the repo root:

```bash
# Find NPM's container and its first user-defined network
NPM=$(docker ps --format '{{.Names}} {{.Image}}' | awk '$2 ~ /nginx-proxy-manager/ {print $1; exit}')
NET=$(docker inspect "$NPM" -f '{{range $k, $v := .NetworkSettings.Networks}}{{$k}}{{"\n"}}{{end}}' \
      | grep -vxE 'bridge|host|none' | head -1)
echo "NPM container: ${NPM:-not found}   network: ${NET:-none usable}"

# Write them into server/.env (replaces the commented lines) and enable the vhost port
sed -i -E "s|^#?[[:space:]]*COMPOSE_FILE=.*|COMPOSE_FILE=compose.yaml:compose.npm.yaml|; \
           s|^#?[[:space:]]*PROXY_NETWORK=.*|PROXY_NETWORK=$NET|" server/.env
sed -i -E 's|^#[[:space:]]*(vhostHTTPPort[[:space:]]*=)|\1|' server/frps.toml

(cd server && docker compose up -d)
docker inspect frps -f '{{range $k, $v := .NetworkSettings.Networks}}{{$k}} {{end}}'
```

If `NET` comes out empty, NPM is only on the built-in `bridge` network. In that case:

1. Create a shared network: `docker network create proxy`.
2. Add it to NPM's compose file as an external network, and recreate NPM.
3. Re-run the commands above.

If you have more than one NPM container, or NPM is on several networks, set `NPM` or `NET` by hand.

To disconnect: `sed -i -E 's/^(COMPOSE_FILE|PROXY_NETWORK)=/# &/' server/.env && (cd server && docker compose up -d)`.

</details>

Either way, never add 8080 to `ports:` in `server/compose.yaml`; only NPM should be able to reach it. If `PROXY_NETWORK` names a network that doesn't exist, compose stops with `network ... declared as external, but could not be found`.

**3. Open the firewall** for inbound **TCP 80 and 443**. Leave port 81 closed.

**4. Secure the admin UI.** It's only reachable through an SSH tunnel:

```bash
ssh -L 8181:127.0.0.1:81 user@your-server
```

Open http://localhost:8181 and set a strong admin email and password straight away. Never publish port 81.

### Adding a website

Do these three steps for each site.

**1. DNS:** create an A/AAAA record pointing the domain, for example `app1.com`, at the server's public IP.

**2. Client:** run `scripts/client-network.sh` → **2) Add a service** (or **1) Connect** for a containerized app) and choose `http`. By hand, add a block like this to `client/frpc.toml`, then run `docker compose up -d --force-recreate`:

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

### Hiding that you use frp

Out of the box, frps answers unknown or offline domains with a branded page ("The server is powered by frp"). This repo replaces it, and the other giveaways are covered here.

**What's already handled:**

| Giveaway | How it's hidden |
|---|---|
| frp's branded 404 page | `custom404Page` in `server/frps.toml` serves `server/404.html`, a plain page that looks like a browser's own "This site can't be reached" error. It still returns HTTP 404. |
| `Server: frp/<version>` header | NPM (nginx) replaces upstream `Server` headers with its own, so it never reaches visitors. Never publish port 8080 directly. |
| CA named `frp-ca`, which anyone connecting to port 7000 can see | New CAs are named `Private CA`, or `CA_NAME="..." scripts/gen-certs.sh ca` to choose. |

**Existing installs:** `git pull` doesn't change your `server/frps.toml`, so add this line, then run `(cd server && docker compose up -d --force-recreate)`:

```toml
custom404Page = "/etc/frp/404.html"
```

`scripts/npm-network.sh` → **3) Check** warns while it's missing. A CA created before this change is still named `frp-ca`. Renaming it means re-creating the CA and re-issuing every cert, so only do it if that matters to you.

**Customizing the page:** edit `server/404.html`, then recreate frps. It's a tracked file, so `git pull` will only conflict if the repo's copy also changes.

**Going further (optional):**

- **Unknown domains in NPM:** go to *Settings → Default Site* and choose **No Response (444)**. Requests for domains you haven't set up then get no reply at all, and the browser shows its own genuine error.
- **The same for offline services:** in a proxy host's *Advanced* tab, you can turn frps's 404 into a dropped connection:

  ```nginx
  proxy_intercept_errors on;
  error_page 404 = @gone;
  location @gone { return 444; }
  ```

  This also swallows the app's *own* 404 pages, so only use it for sites where that's acceptable.
- **Port 7000** is frp's well-known default, and port scanners label it. Anyone who connects sees only a TLS service that demands a client certificate. To be less recognisable, change `bindPort` in `server/frps.toml`, the published port in `server/compose.yaml`, and `serverPort` in every client's `frpc.toml` to the same uncommon port. Update the firewall to match.

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

**Renewing certificates** (they last 1 year; check with `openssl x509 -enddate -noout -in server/tls/server.crt`). Bring `pki/ca.key` back first, then:

```bash
# Server cert: re-issue with the same names, then recreate frps
scripts/gen-certs.sh server frp.example.com
sudo chown 65532:65532 server/tls/server.key
(cd server && docker compose up -d --force-recreate)

# Client cert: remove the old bundle, re-issue, then install it as in Part 2, step 2
rm -rf pki/clients/home-pc pki/clients/home-pc.tar.gz
scripts/gen-certs.sh client home-pc
```

On the client, after unpacking the new bundle, run `docker compose up -d --force-recreate`.

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
| NPM shows `502 Bad Gateway` | frps isn't on NPM's network, or `vhostHTTPPort` isn't enabled. Run `scripts/npm-network.sh` → **3) Check** to see which |
| "This site can't be reached" page (frps's 404) | Domain in NPM doesn't match any client's `customDomains`, or that client's frpc isn't connected |
| Let's Encrypt fails in NPM | DNS doesn't point at the server yet, or port 80 is blocked |
| Client proxy `start error` / app not reachable through frp | Run `scripts/client-network.sh` → **5) Check**; it tests login, each proxy's `localIP`, and registration |
| frpc ignores edits to `frpc.toml` | It was restarted rather than recreated; run `docker compose up -d --force-recreate` |
| `services.frpc.network_mode` / `!reset` error from compose | Docker Compose is older than 2.24; update it to use app networks |

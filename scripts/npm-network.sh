#!/usr/bin/env bash
# Interactively connect frps to the Docker network Nginx Proxy Manager uses
# (or disconnect it). Detects NPM's container and networks, then updates
# server/.env (COMPOSE_FILE, PROXY_NETWORK) and server/frps.toml
# (vhostHTTPPort). Every change is confirmed first.
#
#   scripts/npm-network.sh
set -euo pipefail

cd "$(dirname "$0")/.."
ENV=server/.env
TOML=server/frps.toml
OVERRIDE="compose.yaml:compose.npm.yaml"

die()  { echo "error: $*" >&2; exit 1; }
info() { echo "==> $*"; }

ask_yn() { # <question> <default y|n>
  local hint=$([[ $2 == y ]] && echo "Y/n" || echo "y/N") reply
  read -rp "$1 [$hint] " reply || die "no input"
  reply=${reply:-$2}
  [[ $reply =~ ^[Yy] ]]
}

pick() { # <prompt> <options...>; sets PICKED to the chosen option
  local prompt=$1; shift
  local i=1 opt n
  for opt in "$@"; do echo "  $i) $opt"; i=$((i + 1)); done
  while :; do
    read -rp "$prompt [1-$#] " n || die "no input"
    [[ $n =~ ^[0-9]+$ ]] && (( n >= 1 && n <= $# )) && { PICKED=${!n}; return; }
    echo "  Enter a number from 1 to $#."
  done
}

valid_name() { [[ $1 =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]]; }

set_env() { # <key> <value>: replace an existing (possibly commented) line, else append
  if grep -qE "^#?[[:space:]]*$1=" "$ENV"; then
    sed -i -E "s|^#?[[:space:]]*$1=.*|$1=$2|" "$ENV"
  else
    echo "$1=$2" >> "$ENV"
  fi
}

comment_env() { sed -i -E "s|^($1=.*)|# \1|" "$ENV"; }

container_networks() {
  docker inspect -f '{{range $k, $v := .NetworkSettings.Networks}}{{$k}}{{"\n"}}{{end}}' "$1" | sed '/^$/d'
}

# ---------- preflight ----------
[[ -t 0 ]] || die "this script is interactive; run it from a terminal"
command -v docker >/dev/null || die "docker not found"
(( EUID != 0 )) || die "run as your normal user (not sudo) so .env keeps its owner; the script uses sudo for docker if needed"
if ! docker info >/dev/null 2>&1; then
  # Use sudo for docker only, so edited files stay owned by the user.
  command -v sudo >/dev/null && ask_yn "Docker needs root here. Use sudo for docker commands?" y \
    || die "can't talk to Docker (join the docker group, or allow sudo)"
  docker() { sudo docker "$@" </dev/null; }  # sudo would otherwise eat typed input
  docker info >/dev/null 2>&1 || die "can't talk to Docker, even with sudo"
fi
[[ -f $ENV ]] || die "$ENV not found; set up the server first (README Part 1)"

if [[ ! -f $TOML ]]; then
  ask_yn "$TOML not found. Copy it from frps.toml.example?" y || die "$TOML is required"
  cp server/frps.toml.example "$TOML"
fi

echo
echo "frps <-> Nginx Proxy Manager network setup"
echo
pick "What do you want to do?" \
  "Connect frps to NPM's network" \
  "Disconnect (default: frps on its own network only, no NPM)"

# ---------- disconnect ----------
if [[ $PICKED == Disconnect* ]]; then
  if ! grep -qE "^COMPOSE_FILE=.*compose\.npm\.yaml" "$ENV"; then
    info "Already disconnected; nothing to change."
    exit 0
  fi
  ask_yn "Comment out COMPOSE_FILE and PROXY_NETWORK in $ENV?" y || exit 0
  comment_env COMPOSE_FILE
  comment_env PROXY_NETWORK
  info "Updated $ENV."
  if ask_yn "Recreate frps now so it leaves the network?" y; then
    (cd server && docker compose up -d)
  fi
  exit 0
fi

# ---------- find the NPM container ----------
mapfile -t found < <(docker ps --format '{{.Names}}\t{{.Image}}' | awk -F'\t' '$2 ~ /nginx-proxy-manager/ {print $1}')
manual="Enter a container name myself"

if (( ${#found[@]} == 0 )); then
  echo "No running container using an nginx-proxy-manager image was found."
  echo "Running containers:"
  docker ps --format '  {{.Names}}  ({{.Image}})'
  PICKED=$manual
elif (( ${#found[@]} == 1 )); then
  if ask_yn "Found NPM container '${found[0]}'. Use it?" y; then PICKED=${found[0]}; else PICKED=$manual; fi
else
  echo "Several NPM containers are running:"
  pick "Which one?" "${found[@]}" "$manual"
fi

npm=$PICKED
if [[ $npm == "$manual" ]]; then
  read -rp "NPM container name: " npm
  [[ -n $npm ]] || die "no container given"
fi
docker inspect "$npm" >/dev/null 2>&1 || die "container '$npm' not found"

# ---------- pick the network ----------
mode=$(docker inspect -f '{{.HostConfig.NetworkMode}}' "$npm")
if [[ $mode == host ]]; then
  cat <<EOF

'$npm' uses host networking, so it can't join a Docker network and doesn't
need to. Instead, publish the vhost port on localhost only and point NPM at it:

  1. In $TOML, set:  vhostHTTPPort = 8080
  2. In server/compose.yaml, under ports, add:  - "127.0.0.1:8080:8080"
  3. In NPM, forward proxy hosts to 127.0.0.1 port 8080.

Nothing was changed.
EOF
  exit 0
fi

mapfile -t nets < <(container_networks "$npm" | grep -vxE 'bridge|host|none' || true)
other="Enter a network name myself"

if (( ${#nets[@]} == 0 )); then
  cat <<EOF

'$npm' is only on Docker's built-in 'bridge' network. Containers there can't
reach each other by name, so frps needs a shared user-defined network.

Recommended: create one and add it to NPM's compose file, so it persists:

  docker network create proxy

  # in NPM's compose.yaml:
  services:
    <npm service>:
      networks: [proxy]
  networks:
    proxy:
      external: true

EOF
  if ask_yn "Create network 'proxy' and connect '$npm' to it now? (Lasts until NPM's container is recreated.)" n; then
    docker network inspect proxy >/dev/null 2>&1 || docker network create proxy >/dev/null
    docker network connect proxy "$npm"
    info "Connected '$npm' to 'proxy'. Add it to NPM's compose file to make it permanent."
    net=proxy
  else
    echo "Set up the network, then run this script again."
    exit 0
  fi
elif (( ${#nets[@]} == 1 )); then
  if ask_yn "'$npm' is on network '${nets[0]}'. Connect frps to it?" y; then net=${nets[0]}; else net=$other; fi
else
  echo "'$npm' is on several networks:"
  pick "Which should frps join?" "${nets[@]}" "$other"
  net=$PICKED
fi

if [[ $net == "$other" ]]; then
  read -rp "Network name: " net
fi
valid_name "$net" || die "invalid network name: '$net'"
docker network inspect "$net" >/dev/null 2>&1 || die "network '$net' doesn't exist (docker network ls)"

# ---------- review and apply ----------
vhost_on=$(grep -cE '^[[:space:]]*vhostHTTPPort[[:space:]]*=' "$TOML" || true)

echo
echo "Planned changes:"
echo "  $ENV:  COMPOSE_FILE=$OVERRIDE"
echo "  $ENV:  PROXY_NETWORK=$net"
(( vhost_on )) || echo "  $TOML:  enable vhostHTTPPort = 8080"
echo
ask_yn "Apply these changes?" y || { echo "Nothing was changed."; exit 0; }

set_env COMPOSE_FILE "$OVERRIDE"
set_env PROXY_NETWORK "$net"
if (( ! vhost_on )); then
  if grep -qE '^#[[:space:]]*vhostHTTPPort[[:space:]]*=' "$TOML"; then
    sed -i -E 's|^#[[:space:]]*(vhostHTTPPort[[:space:]]*=.*)|\1|' "$TOML"
  else
    printf '\nvhostHTTPPort = 8080\n' >> "$TOML"
  fi
fi
info "Updated $ENV$( (( vhost_on )) || echo " and $TOML")."

if ask_yn "Recreate frps now (docker compose up -d)?" y; then
  (cd server && docker compose up -d)
  echo
  info "frps networks: $(container_networks frps | tr '\n' ' ')"
fi

port=$(grep -E '^[[:space:]]*vhostHTTPPort' "$TOML" | grep -oE '[0-9]+' | head -1)
cat <<EOF

Done. In NPM, forward proxy hosts to:  http://frps:${port:-8080}
EOF

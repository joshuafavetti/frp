#!/usr/bin/env bash
# Interactively connect frps to the Docker network Nginx Proxy Manager uses
# (or disconnect it). Detects NPM's container and networks, then updates
# server/.env (COMPOSE_FILE, PROXY_NETWORK) and server/frps.toml
# (vhostHTTPPort). Every change is confirmed first. Option 3 only checks
# that frps and NPM share the configured network.
#
#   scripts/npm-network.sh
set -euo pipefail

cd "$(dirname "$0")/.."
ENV=server/.env
TOML=server/frps.toml
OVERRIDE="compose.yaml:compose.npm.yaml"

. scripts/lib.sh

set_env() { # <key> <value>: replace an existing (possibly commented) line, else append
  if grep -qE "^#?[[:space:]]*$1=" "$ENV"; then
    sed -i -E "s|^#?[[:space:]]*$1=.*|$1=$2|" "$ENV"
  else
    echo "$1=$2" >> "$ENV"
  fi
}

comment_env() { sed -i -E "s|^($1=.*)|# \1|" "$ENV"; }

# ---------- preflight ----------
docker_preflight
[[ -f $ENV ]] || die "$ENV not found; set up the server first (README Part 1)"

if [[ ! -f $TOML ]]; then
  ask_yn "$TOML not found. Copy it from frps.toml.example?" y || die "$TOML is required"
  cp server/frps.toml.example "$TOML"
fi

find_npm() { # names of running containers from an nginx-proxy-manager image
  docker ps --format '{{.Names}}\t{{.Image}}' | awk -F'\t' '$2 ~ /nginx-proxy-manager/ {print $1}'
}

env_value() { grep -E "^$1=" "$ENV" | tail -1 | cut -d= -f2- || true; }

# ---------- check ----------
# Verifies frps is on the network .env says, and that NPM is on it too.
check() {
  local net npm nets npm_nets

  if [[ $(docker inspect -f '{{.State.Running}}' frps 2>/dev/null) != true ]]; then
    bad "frps isn't running. Start it: ${BOLD}(cd server && docker compose up -d)${RESET}"
    return
  fi
  nets=$(container_networks frps | paste -sd' ')
  ok "frps is running, on: ${BOLD}$nets${RESET}"

  mapfile -t found < <(find_npm)

  if ! env_value COMPOSE_FILE | grep -q 'compose\.npm\.yaml'; then
    ok "Default mode: frps isn't joined to any NPM network ${DIM}(COMPOSE_FILE not set in $ENV)${RESET}"
    if (( ${#found[@]} )); then
      warn "NPM is running (${found[*]}) but frps isn't connected to it."
      warn "If NPM should proxy websites to frps, run this script again and choose ${BOLD}1) Connect${RESET}."
    fi
    return
  fi

  net=$(env_value PROXY_NETWORK)
  [[ -n $net ]] || { bad "COMPOSE_FILE is set but PROXY_NETWORK is empty in $ENV"; return; }

  if grep -qE '^[[:space:]]*vhostHTTPPort[[:space:]]*=' "$TOML"; then
    ok "vhostHTTPPort is enabled in $TOML"
  else
    bad "vhostHTTPPort isn't enabled in $TOML, so NPM has nothing to forward to"
  fi

  if grep -qE '^[[:space:]]*custom404Page[[:space:]]*=' "$TOML"; then
    ok "Custom 404 page is set, so frp's branded error page is hidden"
  else
    warn "frps shows its branded \"powered by frp\" 404 page. To hide it, add to $TOML:"
    warn "  ${BOLD}custom404Page = \"/etc/frp/404.html\"${RESET}   (then recreate frps)"
  fi

  if ! docker network inspect "$net" >/dev/null 2>&1; then
    bad "PROXY_NETWORK=${BOLD}$net${RESET} doesn't exist (docker network ls)"
    return
  fi

  if [[ " $nets " == *" $net "* ]]; then
    ok "frps is on PROXY_NETWORK=${BOLD}$net${RESET}"
  else
    bad "frps isn't on ${BOLD}$net${RESET} yet. Recreate it: ${BOLD}(cd server && docker compose up -d --force-recreate)${RESET}"
  fi

  if (( ${#found[@]} == 0 )); then
    bad "No running NPM container found (nginx-proxy-manager image)"
    return
  fi
  for npm in "${found[@]}"; do
    npm_nets=$(container_networks "$npm" | paste -sd' ')
    if [[ " $npm_nets " == *" $net "* ]]; then
      ok "NPM container '$npm' is on ${BOLD}$net${RESET} too, so NPM can reach ${BOLD}http://frps:$(grep -E '^[[:space:]]*vhostHTTPPort' "$TOML" | grep -oE '[0-9]+' | head -1)${RESET}"
    else
      bad "NPM container '$npm' is on: ${npm_nets:-nothing}, not ${BOLD}$net${RESET}. Choose ${BOLD}1) Connect${RESET} to switch frps to NPM's network."
    fi
  done
}

checks() { run_checks "Checking frps network setup" check; }

title "frps ${ARROW} Nginx Proxy Manager network setup"
if env_value COMPOSE_FILE | grep -q 'compose\.npm\.yaml'; then
  kv "Currently" "connected to NPM's network ($(env_value PROXY_NETWORK))"
else
  kv "Currently" "default (frps on its own network only)"
fi
echo
pick "What do you want to do?" \
  "Connect frps to NPM's network" \
  "Disconnect (default: frps on its own network only, no NPM)" \
  "Check the current setup (changes nothing)"

if [[ $PICKED == Check* ]]; then
  checks
  exit
fi

# ---------- disconnect ----------
if [[ $PICKED == Disconnect* ]]; then
  if ! grep -qE "^COMPOSE_FILE=.*compose\.npm\.yaml" "$ENV"; then
    info "Already disconnected; nothing to change."
    exit 0
  fi
  section "Planned changes"
  change "$ENV" "comment out COMPOSE_FILE and PROXY_NETWORK"
  echo
  ask_yn "Apply this change?" y || { hint "Nothing was changed."; exit 0; }
  comment_env COMPOSE_FILE
  comment_env PROXY_NETWORK
  info "Updated $ENV."
  if ask_yn "Recreate frps now so it leaves the network?" y; then
    (cd server && docker compose up -d --force-recreate)
    checks || true
  fi
  exit 0
fi

# ---------- find the NPM container ----------
section "NPM container"
mapfile -t found < <(find_npm)
manual="Enter a container name myself"

if (( ${#found[@]} == 0 )); then
  note "No running container using an nginx-proxy-manager image was found."
  hint "Running containers:"
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
  ask npm "NPM container name"
  [[ -n $npm ]] || die "no container given"
fi
docker inspect "$npm" >/dev/null 2>&1 || die "container '$npm' not found"

# ---------- pick the network ----------
section "Network"
mode=$(docker inspect -f '{{.HostConfig.NetworkMode}}' "$npm")
if [[ $mode == host ]]; then
  note "'$npm' uses host networking, so it can't join a Docker network and doesn't need to."
  echo "Instead, publish the vhost port on localhost only and point NPM at it:"
  echo
  echo "  1. In $TOML, set:"
  echo 'vhostHTTPPort = 8080' | code
  echo "  2. In server/compose.yaml, under ports, add:"
  echo '- "127.0.0.1:8080:8080"' | code
  echo "  3. In NPM, forward proxy hosts to 127.0.0.1 port 8080."
  echo
  hint "Nothing was changed."
  exit 0
fi

mapfile -t nets < <(container_networks "$npm" | grep -vxE 'bridge|host|none' || true)
other="Enter a network name myself"

if (( ${#nets[@]} == 0 )); then
  note "'$npm' is only on Docker's built-in 'bridge' network."
  echo "Containers there can't reach each other by name, so frps needs a shared"
  echo "user-defined network. Recommended: create one and add it to NPM's compose"
  echo "file, so it persists:"
  echo
  code <<'EOF'
docker network create proxy

# in NPM's compose.yaml:
services:
  <npm service>:
    networks: [proxy]
networks:
  proxy:
    external: true
EOF
  echo
  if ask_yn "Create network 'proxy' and connect '$npm' to it now? (Lasts until NPM's container is recreated.)" n; then
    docker network inspect proxy >/dev/null 2>&1 || docker network create proxy >/dev/null
    docker network connect proxy "$npm"
    info "Connected '$npm' to 'proxy'."
    next "Add it to NPM's compose file to make it permanent."
    net=proxy
  else
    hint "Set up the network, then run this script again."
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
  ask net "Network name"
fi
valid_name "$net" || die "invalid network name: '$net'"
docker network inspect "$net" >/dev/null 2>&1 || die "network '$net' doesn't exist (docker network ls)"

# ---------- review and apply ----------
vhost_on=$(grep -cE '^[[:space:]]*vhostHTTPPort[[:space:]]*=' "$TOML" || true)

section "Planned changes"
change "$ENV" "COMPOSE_FILE=$OVERRIDE"
change "$ENV" "PROXY_NETWORK=$net"
(( vhost_on )) || change "$TOML" "enable vhostHTTPPort = 8080"
echo
ask_yn "Apply these changes?" y || { hint "Nothing was changed."; exit 0; }

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

port=$(grep -E '^[[:space:]]*vhostHTTPPort' "$TOML" | grep -oE '[0-9]+' | head -1)
echo
if ask_yn "Start/recreate frps now and check the result?" y; then
  (cd server && docker compose up -d --force-recreate)   # also re-reads frps.toml
  checks || exit 1
  echo
  info "Done."
  next "In NPM, forward proxy hosts to ${BOLD}http://frps:${port:-8080}${RESET}"
else
  echo
  next "Start frps: ${BOLD}(cd server && docker compose up -d)${RESET}, then re-run this script and choose ${BOLD}3) Check${RESET}"
  next "In NPM, forward proxy hosts to ${BOLD}http://frps:${port:-8080}${RESET}"
fi

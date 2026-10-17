# Shared helpers for the interactive scripts. Source it; don't run it.

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

container_networks() {
  docker inspect -f '{{range $k, $v := .NetworkSettings.Networks}}{{$k}}{{"\n"}}{{end}}' "$1" | sed '/^$/d'
}

# Interactive-terminal, non-root and Docker access checks. If Docker needs
# root, offers to wrap docker in sudo so edited files stay owned by the user.
docker_preflight() {
  [[ -t 0 ]] || die "this script is interactive; run it from a terminal"
  command -v docker >/dev/null || die "docker not found"
  (( EUID != 0 )) || die "run as your normal user (not sudo) so edited files keep their owner; the script uses sudo for docker if needed"
  if ! docker info >/dev/null 2>&1; then
    command -v sudo >/dev/null && ask_yn "Docker needs root here. Use sudo for docker commands?" y \
      || die "can't talk to Docker (join the docker group, or allow sudo)"
    docker() { sudo docker "$@" </dev/null; }  # sudo would otherwise eat typed input
    docker info >/dev/null 2>&1 || die "can't talk to Docker, even with sudo"
  fi
}

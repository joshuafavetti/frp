# Shared helpers for the scripts in this directory. Source it; don't run it.

# ---------- style ----------
# Colour only on a terminal, and never when NO_COLOR is set (https://no-color.org).
if [[ -t 1 && -z ${NO_COLOR:-} && ${TERM:-} != dumb ]]; then
  BOLD=$'\e[1m' DIM=$'\e[2m' RED=$'\e[31m' GREEN=$'\e[32m' YELLOW=$'\e[33m' CYAN=$'\e[36m' RESET=$'\e[0m'
else
  BOLD='' DIM='' RED='' GREEN='' YELLOW='' CYAN='' RESET=''
fi
# Unicode symbols only in a UTF-8 locale.
case "${LC_ALL:-${LC_CTYPE:-${LANG:-}}}" in
  *[Uu][Tt][Ff]-8* | *[Uu][Tt][Ff]8*) RULE='─' ARROW='→' TICK='✔' CROSS='✘' ;;
  *)                                  RULE='-' ARROW='->' TICK='OK' CROSS='X' ;;
esac

die()     { echo "${RED}${BOLD}error:${RESET} $*" >&2; exit 1; }
info()    { echo "${GREEN}${BOLD}==>${RESET} ${BOLD}$*${RESET}"; }
note()    { echo "${YELLOW}${BOLD}!${RESET} $*"; }          # caution the user should read
hint()    { echo "${DIM}$*${RESET}"; }                      # secondary detail
next()    { echo "  ${CYAN}${ARROW}${RESET} $*"; }           # a follow-up step for the user
section() { echo; echo "${BOLD}$*${RESET}"; }
kv()      { printf '  %s%-14s%s %s\n' "$DIM" "$1" "$RESET" "${BOLD}$2${RESET}"; }

title() { # <text>: script banner
  local line
  printf -v line '%*s' "${#1}" ''
  echo
  echo "${BOLD}${CYAN}$1${RESET}"
  echo "${CYAN}${line// /$RULE}${RESET}"
}

code() { # stdin: config or commands, shown indented and highlighted
  awk -v c="$CYAN" -v r="$RESET" '{ print "    " c $0 r }'
}

change() { # <file> <what>: one line of a "Planned changes" list
  printf '  %s%s%s  %s\n' "$CYAN" "$1" "$RESET" "$2"
}

# ---------- prompts ----------
ask_yn() { # <question> <default y|n>
  local hint=$([[ $2 == y ]] && echo "Y/n" || echo "y/N") reply
  read -rp "${BOLD}$1${RESET} ${DIM}[$hint]${RESET} " reply || die "no input"
  reply=${reply:-$2}
  [[ $reply =~ ^[Yy] ]]
}

ask() { # <var> <question> [default]: free-text answer into <var>
  local __reply
  read -rp "  ${BOLD}$2${RESET}${3:+ ${DIM}[$3]${RESET}}: " __reply || die "no input"
  printf -v "$1" '%s' "${__reply:-${3:-}}"
}

pick() { # <prompt> <options...>; sets PICKED to the chosen option
  local prompt=$1; shift
  local i=1 opt main n
  for opt in "$@"; do
    main=${opt%%  (*}; main=${main%% (*}           # dim any "(detail)" after the label
    printf '  %s%2d)%s %s%s%s\n' "$CYAN$BOLD" "$i" "$RESET" "$main" "$DIM${opt#"$main"}" "$RESET"
    i=$((i + 1))
  done
  while :; do
    read -rp "${BOLD}$prompt${RESET} ${DIM}[1-$#]${RESET} " n || die "no input"
    [[ $n =~ ^[0-9]+$ ]] && (( n >= 1 && n <= $# )) && { PICKED=${!n}; return; }
    echo "  ${YELLOW}Enter a number from 1 to $#.${RESET}"
  done
}

# ---------- checks ----------
# A check function calls ok/bad/warn; run_checks counts them and prints a summary.
ok()   { echo "  ${GREEN}[ OK ]${RESET} $*"; }
bad()  { echo "  ${RED}${BOLD}[FAIL]${RESET} $*"; fail=$((fail + 1)); }
warn() { echo "  ${YELLOW}[WARN]${RESET} $*"; warns=$((warns + 1)); }

run_checks() { # <heading> <function>: returns non-zero if anything failed
  local fail=0 warns=0 w=""
  section "$1"
  "$2" || true
  (( warns )) && w=", $warns warning$( (( warns > 1 )) && echo s)"
  echo
  if (( fail )); then
    echo "${RED}${BOLD}$CROSS $fail problem$( (( fail > 1 )) && echo s) found${RESET}$w ${DIM}(see [FAIL] above)${RESET}"
  else
    echo "${GREEN}${BOLD}$TICK All checks passed${RESET}$w"
  fi
  (( fail == 0 ))
}

# ---------- docker ----------
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

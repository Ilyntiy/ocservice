#!/bin/bash
# install.sh — ocservice installer and updater — https://github.com/Ilyntiy/ocservice

set -euo pipefail

G=$'\033[0;32m'; Y=$'\033[0;33m'; R=$'\033[0;31m'; C=$'\033[0;36m'; N=$'\033[0m'
LINE="==========================================="

info()   { printf '  %s[+]%s %s\n' "$G" "$N" "$*"; }
warn()   { printf '  %s[!]%s %s\n' "$Y" "$N" "$*"; }
die()    { printf '  %s[x]%s %s\n' "$R" "$N" "$*" >&2; exit 1; }
header() { printf '\n%s%s\n  %s\n%s%s\n' "$C" "$LINE" "$*" "$LINE" "$N"; }

prompt() {
  local _v
  read -rp "      $2${3:+ [$3]}: " _v
  printf -v "$1" '%s' "${_v:-${3:-}}"
}

confirm() {
  local _a
  read -rp "      $1 (y/n): " _a
  [[ $_a == [yY] ]]
}

q() { printf "'%s'" "${1//\'/\'\\\'\'}"; }

header "ocservice installer"

[[ $EUID -eq 0 ]] || die "Run with sudo: sudo ./install.sh"
REAL_USER=${SUDO_USER:-}
[[ -n $REAL_USER && $REAL_USER != root ]] || die "Run from a regular user account via sudo, not as root."
REAL_HOME=$(getent passwd "$REAL_USER" | cut -d: -f6)
REAL_GROUP=$(id -gn "$REAL_USER")
[[ -d $REAL_HOME ]] || die "Home directory of $REAL_USER not found."

REPO_DIR=$(dirname "$(realpath "$0")")
SYMLINK=/usr/local/bin/ocservice
SUDOERS=/etc/sudoers.d/ocservice
SCRIPTS=(ocservice gen-client gen-login user-center)
JOURNAL_GROUP=systemd-journal

for c in openssl systemctl sudo visudo runuser realpath stat install usermod getent shred; do
  command -v "$c" >/dev/null || die "Required command not found: $c"
done
SYSTEMCTL=$(command -v systemctl)
OPENSSL=$(command -v openssl)

oc_value() {
  sed -nE "/^[[:space:]]*$1[[:space:]]*=/{s/^[^=]*=[[:space:]]*//;s/[[:space:]]+\$//;s/^\"(.*)\"\$/\1/;p;q}" "$OCSERV_CONF"
}

parse_ocserv_conf() {
  local line re='passwd=([^],]+)'
  HAS_CERT=0; HAS_PLAIN=0; PARSED_USER_FILE=""
  while IFS= read -r line; do
    line=${line#\"}; line=${line%\"}
    if [[ $line == certificate* ]]; then HAS_CERT=1; fi
    if [[ $line == plain* ]]; then
      HAS_PLAIN=1
      if [[ $line =~ $re ]]; then PARSED_USER_FILE=${BASH_REMATCH[1]}; fi
    fi
  done < <(sed -nE '/^[[:space:]]*(enable-)?auth[[:space:]]*=/{s/^[^=]*=[[:space:]]*//;s/[[:space:]]+$//;p}' "$OCSERV_CONF")

  if [[ $HAS_CERT == 1 && $HAS_PLAIN == 1 ]]; then DETECTED_MODE=both
  elif [[ $HAS_CERT == 1 ]]; then DETECTED_MODE=cert
  elif [[ $HAS_PLAIN == 1 ]]; then DETECTED_MODE=plain
  else DETECTED_MODE=""
  fi

  PARSED_CONFIG_PER_USER=$(oc_value config-per-user); PARSED_CONFIG_PER_USER=${PARSED_CONFIG_PER_USER%/}
  PARSED_SERVER_CERT=$(oc_value server-cert)
  PARSED_SERVER_KEY=$(oc_value server-key)
  PARSED_CRL=$(oc_value crl)
}

safe_path() { [[ $1 =~ ^/[A-Za-z0-9._/@+-]+$ ]]; }

chain_ok() {
  local p=$1 uid mode
  while :; do
    if [[ ! -L $p ]]; then
      read -r uid mode < <(stat -c '%u %a' -- "$p") || return 1
      [[ $uid == 0 ]] && (( (8#$mode & 8#022) == 0 )) || return 1
    fi
    [[ $p == / ]] && return 0
    p=$(dirname -- "$p")
  done
}

root_safe() {
  local real
  real=$(realpath -e -- "$1" 2>/dev/null) || return 1
  chain_ok "$1" && chain_ok "$real"
}

user_file_dir_ok() {
  local dir base f rc=0
  dir=$(dirname -- "$USER_FILE"); base=$(basename -- "$USER_FILE")
  [[ -d $dir ]] || return 0
  shopt -s nullglob dotglob
  for f in "$dir"/*; do
    case ${f##*/} in
      "$base"|"$base.tmp") ;;
      *) rc=1; break ;;
    esac
  done
  shopt -u nullglob dotglob
  return "$rc"
}

fix_home_ownership() {
  local p=$1
  while [[ $p == "$REAL_HOME"/* ]]; do
    if [[ $(stat -c %u -- "$p") == 0 ]]; then
      chown "$REAL_USER:$REAL_GROUP" -- "$p"
      info "Fixed ownership: $p"
    fi
    p=$(dirname -- "$p")
  done
}

make_user_dir() {
  local d=$1 mode=$2 a=$1
  while [[ ! -e $a ]]; do a=$(dirname -- "$a"); done
  fix_home_ownership "$a"
  runuser -u "$REAL_USER" -- mkdir -p -- "$d" || die "Cannot create $d as $REAL_USER."
  fix_home_ownership "$d"
  chmod "$mode" -- "$d"
}

make_owned_dir() {
  install -d -m "$2" -o "$REAL_USER" -g "$REAL_GROUP" -- "$1"
  chown "$REAL_USER:$REAL_GROUP" -- "$1"
  chmod "$2" -- "$1"
}

make_user_file() {
  [[ -e $1 ]] || install -m "$2" -o "$REAL_USER" -g "$REAL_GROUP" /dev/null "$1"
  chown "$REAL_USER:$REAL_GROUP" -- "$1"
  chmod "$2" -- "$1"
}

detect_default_conf() {
  local c
  c=$("$SYSTEMCTL" cat ocserv 2>/dev/null | grep -oE '(-c|--config)[= ][^[:space:]]+' | head -n1 | sed -E 's/^(-c|--config)[= ]//') || true
  printf '%s' "${c:-/etc/ocserv/ocserv.conf}"
}

detect_default_prefix() {
  local bin
  bin=$("$SYSTEMCTL" cat ocserv 2>/dev/null | sed -nE 's/^[[:space:]]*ExecStart=[-@+!]*([^[:space:]]+).*/\1/p' | head -n1) || true
  if [[ $bin == */sbin/ocserv ]]; then printf '%s' "${bin%/sbin/ocserv}"; else printf '/opt/ocserv'; fi
}

ask_fresh() {
  local default addr port port_suffix camo secret

  header "ocserv configuration"
  default=$(detect_default_conf)
  while :; do
    prompt OCSERV_CONF "Path to ocserv.conf" "$default"
    [[ -f $OCSERV_CONF ]] && break
    warn "File not found: $OCSERV_CONF"
  done
  OCSERV_CONF=$(realpath -e -- "$OCSERV_CONF")
  parse_ocserv_conf
  if [[ $(oc_value use-occtl) != true ]]; then
    warn "use-occtl = true is not set in ocserv.conf — status, kick and ban features will not work."
    confirm "Continue anyway?" || exit 1
  else
    info "use-occtl = true"
  fi

  header "ocserv installation prefix"
  info "Directory passed to --prefix when building ocserv: PREFIX/bin/occtl, PREFIX/bin/ocpasswd."
  info "For distribution packages use /usr."
  default=$(detect_default_prefix)
  while :; do
    prompt OCSERV_PREFIX "ocserv prefix" "$default"
    OCSERV_PREFIX=${OCSERV_PREFIX%/}
    [[ -x $OCSERV_PREFIX/bin/occtl ]] && break
    warn "occtl not found at $OCSERV_PREFIX/bin/occtl"
  done

  header "Authentication mode"
  info "Detected from ocserv.conf: ${DETECTED_MODE:-unknown}"
  while :; do
    prompt AUTH_MODE "Auth mode (cert/plain/both)" "${DETECTED_MODE:-cert}"
    [[ $AUTH_MODE =~ ^(cert|plain|both)$ ]] && break
    warn "Enter cert, plain or both."
  done
  if [[ -n $DETECTED_MODE && $AUTH_MODE != "$DETECTED_MODE" ]]; then
    warn "Auth mode differs from ocserv.conf ($DETECTED_MODE)."
  fi

  if [[ $AUTH_MODE != plain ]]; then
    header "Certificates"
    while :; do
      prompt EASYRSA_DIR "Path to easy-rsa directory" "$REAL_HOME/easy-rsa"
      EASYRSA_DIR=${EASYRSA_DIR%/}
      [[ -f $EASYRSA_DIR/easyrsa && -d $EASYRSA_DIR/pki ]] && break
      warn "easyrsa or pki/ not found in $EASYRSA_DIR"
    done
    prompt VPN_CLIENTS_DIR "Directory for generated .p12 files" "$REAL_HOME/vpn-clients"
    VPN_CLIENTS_DIR=${VPN_CLIENTS_DIR%/}
  else
    EASYRSA_DIR=""; VPN_CLIENTS_DIR=""
  fi

  header "Server identity"
  prompt SERVER_NAME "Server name (menu header, CA name in .p12)" ""
  [[ -n $SERVER_NAME ]] || die "Server name cannot be empty."
  prompt addr "Server address (domain or IP, without https://)" ""
  [[ -n $addr ]] || die "Server address cannot be empty."

  port=$(oc_value tcp-port); port=${port:-443}
  if [[ $port == 443 ]]; then port_suffix=""; else port_suffix=":$port"; fi
  camo=$(oc_value camouflage)
  secret=$(oc_value camouflage_secret)
  if [[ $camo == true && -n $secret ]]; then
    SERVER_URL="https://$addr$port_suffix/?$secret"
    info "Camouflage detected — gateway URL: $SERVER_URL"
  else
    SERVER_URL="https://$addr$port_suffix/"
    info "Gateway URL: $SERVER_URL"
  fi
  if ! confirm "Is this gateway URL correct?"; then
    while :; do
      prompt SERVER_URL "Gateway URL (http:// or https://)" ""
      [[ $SERVER_URL =~ ^https?:// ]] && break
      warn "URL must start with http:// or https://"
    done
  fi
  prompt DOCS_URL "Docs / channel URL (optional)" ""

  header "Security"
  while :; do
    prompt PASSWORD_LENGTH "Generated password length" "20"
    [[ $PASSWORD_LENGTH =~ ^[1-9][0-9]*$ ]] && (( PASSWORD_LENGTH >= 8 )) && break
    warn "Password length must be a number >= 8."
  done

  header "Install location"
  prompt INSTALL_DIR "Install scripts to" "$REAL_HOME/bin/ocservice"
  INSTALL_DIR=${INSTALL_DIR%/}
  CONF_FILE=$INSTALL_DIR/ocservice.conf

  NAMES_ENABLED=yes
  NAMES_FILE=$INSTALL_DIR/names
  NAMES_USED_FILE=$INSTALL_DIR/names_used
  CERT_CACHE_FILE=$INSTALL_DIR/cert_cache
  OLD_HISTORY=""
}

load_existing() {
  set +u
  # shellcheck source=/dev/null
  source "$CONF_FILE"
  set -u
  [[ -n ${OCSERV_CONF:-} && -f $OCSERV_CONF ]] || die "OCSERV_CONF in $CONF_FILE is missing or invalid."
  [[ -n ${OCSERV_PREFIX:-} ]] || die "OCSERV_PREFIX is not set in $CONF_FILE."
  [[ -n ${SERVER_NAME:-} ]] || die "SERVER_NAME is not set in $CONF_FILE."
  [[ ${AUTH_MODE:-} =~ ^(cert|plain|both)$ ]] || die "AUTH_MODE in $CONF_FILE must be cert, plain or both."

  OCSERV_PREFIX=${OCSERV_PREFIX%/}
  parse_ocserv_conf
  if [[ -n $DETECTED_MODE && $AUTH_MODE != "$DETECTED_MODE" ]]; then
    warn "AUTH_MODE=$AUTH_MODE differs from ocserv.conf ($DETECTED_MODE)."
  fi

  EASYRSA_DIR=${EASYRSA_DIR:-}; EASYRSA_DIR=${EASYRSA_DIR%/}
  VPN_CLIENTS_DIR=${VPN_CLIENTS_DIR:-}; VPN_CLIENTS_DIR=${VPN_CLIENTS_DIR%/}
  if [[ $AUTH_MODE == plain ]]; then EASYRSA_DIR=""; VPN_CLIENTS_DIR=""; fi
  if [[ $AUTH_MODE != plain && ( -z $EASYRSA_DIR || -z $VPN_CLIENTS_DIR ) ]]; then
    die "EASYRSA_DIR and VPN_CLIENTS_DIR must be set in $CONF_FILE for AUTH_MODE=$AUTH_MODE."
  fi

  PASSWORD_LENGTH=${PASSWORD_LENGTH:-20}
  SERVER_URL=${SERVER_URL:-}
  DOCS_URL=${DOCS_URL:-}
  NAMES_ENABLED=${NAMES_ENABLED:-yes}
  NAMES_FILE=${NAMES_FILE:-$INSTALL_DIR/names}
  NAMES_USED_FILE=${NAMES_USED_FILE:-$INSTALL_DIR/names_used}
  CERT_CACHE_FILE=${CERT_CACHE_FILE:-$INSTALL_DIR/cert_cache}
  OLD_HISTORY=${USER_HISTORY:-}
}

resolve_from_ocserv_conf() {
  if [[ $AUTH_MODE != cert ]]; then
    USER_FILE=$PARSED_USER_FILE
  else
    USER_FILE=""
  fi
  CONFIG_PER_USER=$PARSED_CONFIG_PER_USER
  SERVER_CERT=$PARSED_SERVER_CERT
  if [[ $AUTH_MODE != plain ]]; then CRL_FILE=$PARSED_CRL; else CRL_FILE=""; fi
  OCCTL=$OCSERV_PREFIX/bin/occtl
  OCPASSWD=$OCSERV_PREFIX/bin/ocpasswd
  USER_HISTORY=$INSTALL_DIR/user-history.log
}

validate() {
  local p conf_dir cpu_real

  header "Validating environment"

  [[ -x $OCCTL ]] || die "occtl not found: $OCCTL"
  for p in "$OCCTL" "$SYSTEMCTL" "$OPENSSL" "$OCSERV_CONF" ${SERVER_CERT:+"$SERVER_CERT"} ${CRL_FILE:+"$CRL_FILE"}; do
    safe_path "$p" || die "Unsupported characters in path: $p"
  done

  for p in "$OCCTL" "$SYSTEMCTL" "$OPENSSL"; do
    if ! root_safe "$p"; then
      die "$p: the file and every directory up to / must be owned by root and not writable by group or others.
      Granting passwordless sudo on it would give $REAL_USER root access.
      Install ocserv to a root-owned prefix (e.g. /opt/ocserv) and re-run install.sh."
    fi
  done
  info "sudo targets are root-owned: occtl, systemctl, openssl"

  conf_dir=$(dirname -- "$OCSERV_CONF")
  if ! root_safe "$OCSERV_CONF"; then
    warn "$OCSERV_CONF or one of its parent directories is writable by a non-root user."
    warn "ocserv runs as root — whoever can modify its config can gain root."
    if [[ $conf_dir != "$REAL_HOME"/* && $(stat -c %U -- "$conf_dir") == "$REAL_USER" ]]; then
      warn "$conf_dir is owned by $REAL_USER — earlier ocservice versions did this when ocpasswd lived there."
      if confirm "Return ownership of $conf_dir to root?"; then
        chown root:root -- "$conf_dir"
        chmod go-w -- "$conf_dir"
        info "Fixed: $conf_dir"
      fi
    fi
  fi
  if [[ -e $OCSERV_PREFIX/sbin/ocserv ]] && ! root_safe "$OCSERV_PREFIX/sbin/ocserv"; then
    warn "$OCSERV_PREFIX/sbin/ocserv is writable by a non-root user — ocserv runs as root."
  fi

  if ! "$SYSTEMCTL" cat ocserv >/dev/null 2>&1; then
    warn "systemd unit 'ocserv' not found — 'Restart ocserv' in the menu will not work."
  fi

  [[ -n $CONFIG_PER_USER ]] || die "config-per-user is not set in $OCSERV_CONF.
      Add e.g. 'config-per-user = /etc/ocserv/config-per-user', restart ocserv and re-run install.sh."
  cpu_real=$(realpath -m -- "$CONFIG_PER_USER")
  if [[ $cpu_real == / || $conf_dir == "$cpu_real" || $conf_dir == "$cpu_real"/* ]]; then
    die "config-per-user ($CONFIG_PER_USER) must be a dedicated directory, not a parent of $OCSERV_CONF."
  fi

  if [[ $AUTH_MODE != cert ]]; then
    [[ -n $USER_FILE ]] || die "No plain[passwd=...] found in auth/enable-auth in $OCSERV_CONF."
    [[ -x $OCPASSWD ]] || die "ocpasswd not found: $OCPASSWD"
    if ! user_file_dir_ok; then
      die "$USER_FILE must be the only file in its directory.
      ocpasswd writes a temporary file next to it, so $REAL_USER needs write access to that directory,
      and that directory must not contain anything else (such as ocserv.conf). Move it, for example:
        sudo install -d -m 700 -o $REAL_USER -g $REAL_GROUP /etc/ocserv/ocpasswd.d
        sudo mv $USER_FILE /etc/ocserv/ocpasswd.d/ocpasswd
      then set auth = \"plain[passwd=/etc/ocserv/ocpasswd.d/ocpasswd]\" in $OCSERV_CONF,
      restart ocserv and re-run install.sh."
    fi
  fi

  if [[ -z $SERVER_CERT ]]; then
    warn "server-cert not found in $OCSERV_CONF — certificate expiry will show n/a."
  fi

  if [[ $AUTH_MODE != plain ]]; then
    if [[ -z $CRL_FILE ]]; then
      warn "crl is not set in $OCSERV_CONF — revoked certificates are NOT rejected by ocserv."
      warn "Add 'crl = $EASYRSA_DIR/pki/crl.pem', restart ocserv and re-run install.sh."
    elif [[ $(realpath -m -- "$CRL_FILE") != "$(realpath -m -- "$EASYRSA_DIR/pki/crl.pem")" ]]; then
      die "ocserv reads the CRL from $CRL_FILE, but easy-rsa writes it to $EASYRSA_DIR/pki/crl.pem.
      Users deleted in ocservice would still be able to connect.
      Set 'crl = $EASYRSA_DIR/pki/crl.pem' in $OCSERV_CONF, run '$OCSERV_PREFIX/bin/occtl reload' and re-run install.sh."
    fi
  fi
  info "Environment OK"
}

summary() {
  header "Summary"
  echo "      Install dir:      $INSTALL_DIR"
  echo "      ocserv.conf:      $OCSERV_CONF"
  echo "      OCSERV_PREFIX:    $OCSERV_PREFIX"
  echo "      AUTH_MODE:        $AUTH_MODE"
  if [[ $AUTH_MODE != plain ]]; then
    echo "      EASYRSA_DIR:      $EASYRSA_DIR"
    echo "      VPN_CLIENTS_DIR:  $VPN_CLIENTS_DIR"
  fi
  if [[ $AUTH_MODE != cert ]]; then
    echo "      USER_FILE:        $USER_FILE"
  fi
  echo "      CONFIG_PER_USER:  $CONFIG_PER_USER"
  echo "      SERVER_CERT:      ${SERVER_CERT:-(not set)}"
  if [[ $AUTH_MODE != plain ]]; then
    echo "      CRL:              ${CRL_FILE:-(not set)}"
  fi
  echo "      SERVER_NAME:      $SERVER_NAME"
  echo "      SERVER_URL:       $SERVER_URL"
  echo "      DOCS_URL:         ${DOCS_URL:-(not set)}"
  echo "      PASSWORD_LENGTH:  $PASSWORD_LENGTH"
  echo
  confirm "Proceed?" || exit 0
}

install_files() {
  local s new

  header "Installing scripts"
  make_user_dir "$INSTALL_DIR" 0755
  for s in "${SCRIPTS[@]}"; do
    install -m 0755 -o "$REAL_USER" -g "$REAL_GROUP" -- "$REPO_DIR/bin/$s" "$INSTALL_DIR/$s"
    info "Installed: $INSTALL_DIR/$s"
  done
  install -m 0644 -o "$REAL_USER" -g "$REAL_GROUP" -- "$REPO_DIR/bin/ocnames" "$INSTALL_DIR/ocnames"
  info "Installed: $INSTALL_DIR/ocnames"

  if [[ ! -e $NAMES_FILE ]]; then
    if [[ -f $REPO_DIR/names ]]; then
      install -m 0644 -o "$REAL_USER" -g "$REAL_GROUP" -- "$REPO_DIR/names" "$NAMES_FILE"
    else
      make_user_file "$NAMES_FILE" 0644
    fi
    info "Installed name pool: $NAMES_FILE"
  fi

  ln -sfn -- "$INSTALL_DIR/ocservice" "$SYMLINK"
  info "Symlink: $SYMLINK -> $INSTALL_DIR/ocservice"

  header "Setting up directories and files"

  new=$INSTALL_DIR/user-history.log
  if [[ -n $OLD_HISTORY && $OLD_HISTORY != "$new" && -f $OLD_HISTORY ]]; then
    if [[ -e $new ]]; then
      warn "Both $OLD_HISTORY and $new exist — old file left in place, merge manually if needed."
    else
      mv -- "$OLD_HISTORY" "$new"
      info "Moved $OLD_HISTORY -> $new"
    fi
  fi
  make_user_file "$USER_HISTORY" 0600
  make_user_file "$CERT_CACHE_FILE" 0600
  make_user_file "$NAMES_USED_FILE" 0644
  info "user-history.log, cert_cache, names_used: $INSTALL_DIR"

  make_owned_dir "$CONFIG_PER_USER" 0755
  info "config-per-user: $CONFIG_PER_USER"

  if [[ $AUTH_MODE != plain ]]; then
    make_user_dir "$VPN_CLIENTS_DIR" 0700
    info "vpn-clients: $VPN_CLIENTS_DIR (700)"
  fi

  if [[ $AUTH_MODE != cert ]]; then
    make_owned_dir "$(dirname -- "$USER_FILE")" 0700
    make_user_file "$USER_FILE" 0600
    info "ocpasswd: $USER_FILE (600)"
  fi
}

write_conf() {
  local tmp

  header "Writing ocservice.conf"
  if [[ -f $CONF_FILE ]]; then
    install -m 0600 -o "$REAL_USER" -g "$REAL_GROUP" -- "$CONF_FILE" "$CONF_FILE.bak"
    info "Backup: $CONF_FILE.bak"
  fi

  tmp=$(mktemp)
  {
    cat <<EOF
# ocservice.conf — ocservice configuration
# Generated by install.sh on $(date '+%Y-%m-%d %H:%M').
#
# Re-running install.sh regenerates this file: your values are kept,
# the previous version is saved as ocservice.conf.bak.
# Values in the "Parsed from ocserv.conf" section are re-read from ocserv.conf
# on every run — change them in ocserv.conf, not here.

# =============================================================================
# ocserv
# =============================================================================

# Path to ocserv.conf (opened by "Edit ocserv.conf" in the menu via sudoedit)
OCSERV_CONF=$(q "$OCSERV_CONF")

# ocserv installation prefix (the directory passed to --prefix at build time;
# /usr for distribution packages). Must be owned by root.
OCSERV_PREFIX=$(q "$OCSERV_PREFIX")

# ocserv control tools (derived from OCSERV_PREFIX)
OCCTL=$(q "$OCCTL")
OCPASSWD=$(q "$OCPASSWD")

# =============================================================================
# Authentication mode
# =============================================================================

# Controls which user types ocservice creates and shows.
# Must match what is enabled in ocserv.conf:
#   cert  — certificate auth only  (auth = "certificate")
#   plain — password auth only     (auth = "plain[passwd=...]")
#   both  — both methods           (auth = "plain[passwd=...]" + enable-auth = "certificate")
AUTH_MODE=$(q "$AUTH_MODE")

# =============================================================================
# Parsed from ocserv.conf
# =============================================================================

# Directory with per-user settings (config-per-user directive)
CONFIG_PER_USER=$(q "$CONFIG_PER_USER")

# Server TLS certificate (server-cert directive) — expiry is shown in the main menu
SERVER_CERT=$(q "$SERVER_CERT")

# Certificate revocation list (crl directive) — expiry is shown in the main menu.
# Must be easy-rsa's pki/crl.pem so that deleted users are rejected immediately.
CRL_FILE=$(q "$CRL_FILE")
EOF
    if [[ $AUTH_MODE != cert ]]; then
      cat <<EOF

# Password file (passwd= in the plain[] auth directive).
# Must be the only file in its directory: ocpasswd writes a temporary file next to it.
USER_FILE=$(q "$USER_FILE")
EOF
    fi
    cat <<EOF

# =============================================================================
# Certificates
# =============================================================================

# easy-rsa directory (contains the easyrsa script and pki/)
EASYRSA_DIR=$(q "$EASYRSA_DIR")

# Where generated .p12 client files are stored (mode 700)
VPN_CLIENTS_DIR=$(q "$VPN_CLIENTS_DIR")

# =============================================================================
# System tools
# =============================================================================

# Resolved by install.sh. The same paths are used in $SUDOERS,
# so do not change them here — re-run install.sh instead.
SYSTEMCTL=$(q "$SYSTEMCTL")
OPENSSL=$(q "$OPENSSL")

# =============================================================================
# Security
# =============================================================================

# Length of generated passwords for .p12 files and login users (min 8)
PASSWORD_LENGTH=$(q "$PASSWORD_LENGTH")

# =============================================================================
# Server identity — shown to new users after creation
# =============================================================================

# Display name: main menu header and CA name inside .p12 files
SERVER_NAME=$(q "$SERVER_NAME")

# Gateway URL for clients. With camouflage enabled it includes the secret:
#   https://vpn.example.com/?secret
SERVER_URL=$(q "$SERVER_URL")

# Optional link to your docs, onboarding guide or Telegram channel
DOCS_URL=$(q "$DOCS_URL")

# =============================================================================
# Username pool
# =============================================================================

# yes — offer a random free name from NAMES_FILE when creating a user
# no  — always ask for the name
NAMES_ENABLED=$(q "$NAMES_ENABLED")

# One name per line; lines starting with # are ignored. Edit any time.
NAMES_FILE=$(q "$NAMES_FILE")

# Names already issued from the pool. Managed automatically.
NAMES_USED_FILE=$(q "$NAMES_USED_FILE")

# =============================================================================
# Managed automatically
# =============================================================================

# Certificate dates cache for User Management Center.
# If certificates are created or revoked outside ocservice, run
# "r — Rebuild certificate cache" in User Management Center.
CERT_CACHE_FILE=$(q "$CERT_CACHE_FILE")

# Log of user creations, deletions, kicks and unbans
USER_HISTORY=$(q "$USER_HISTORY")
EOF
  } > "$tmp"
  install -m 0600 -o "$REAL_USER" -g "$REAL_GROUP" -- "$tmp" "$CONF_FILE"
  rm -f -- "$tmp"
  info "Written: $CONF_FILE (600)"
}

write_sudoers() {
  local tmp c

  header "Configuring sudo"
  tmp=$(mktemp)
  {
    printf '# ocservice — generated by install.sh on %s. Do not edit: re-run install.sh instead.\n' "$(date '+%Y-%m-%d %H:%M')"
    for c in "show status" "show users" "show ip ban points" "show user *" \
             "disconnect user *" "terminate user *" "unban ip *" "reload"; do
      printf '%s ALL=(root) NOPASSWD: %s -n %s\n' "$REAL_USER" "$OCCTL" "$c"
    done
    printf '%s ALL=(root) NOPASSWD: %s restart ocserv\n' "$REAL_USER" "$SYSTEMCTL"
    if [[ -n $SERVER_CERT ]] && ! runuser -u "$REAL_USER" -- test -r "$SERVER_CERT"; then
      printf '%s ALL=(root) NOPASSWD: %s x509 -enddate -noout -in %s\n' "$REAL_USER" "$OPENSSL" "$SERVER_CERT"
    fi
    if [[ -n $CRL_FILE ]] && ! runuser -u "$REAL_USER" -- test -r "$CRL_FILE"; then
      printf '%s ALL=(root) NOPASSWD: %s crl -nextupdate -noout -in %s\n' "$REAL_USER" "$OPENSSL" "$CRL_FILE"
    fi
    printf '%s ALL=(root) sudoedit %s\n' "$REAL_USER" "$OCSERV_CONF"
  } > "$tmp"
  chmod 0440 "$tmp"

  if ! visudo -c -f "$tmp" >/dev/null; then
    rm -f -- "$tmp"
    die "Generated sudoers failed validation — $SUDOERS left unchanged."
  fi
  install -m 0440 -o root -g root -- "$tmp" "$SUDOERS"
  rm -f -- "$tmp"
  info "Written and validated: $SUDOERS"
}

setup_journal() {
  JOURNAL_ADDED=0
  if ! getent group "$JOURNAL_GROUP" >/dev/null; then
    warn "Group $JOURNAL_GROUP not found — 'View ocserv log' may require root."
    return 0
  fi
  if id -nG "$REAL_USER" | tr ' ' '\n' | grep -qx "$JOURNAL_GROUP"; then
    info "$REAL_USER is in $JOURNAL_GROUP"
  else
    usermod -aG "$JOURNAL_GROUP" "$REAL_USER"
    JOURNAL_ADDED=1
    info "Added $REAL_USER to $JOURNAL_GROUP"
  fi
}

cleanup_client_keys() {
  local crt name eku f found key_real server_key_real="" files=() names=()

  [[ $AUTH_MODE != plain && -d $EASYRSA_DIR/pki/issued ]] || return 0
  if [[ -n $PARSED_SERVER_KEY ]]; then
    server_key_real=$(realpath -m -- "$PARSED_SERVER_KEY")
  fi

  shopt -s nullglob
  for crt in "$EASYRSA_DIR"/pki/issued/*.crt; do
    name=$(basename -- "$crt" .crt)
    eku=$("$OPENSSL" x509 -in "$crt" -noout -text 2>/dev/null | awk '/X509v3 Extended Key Usage/ {getline; print; exit}') || true
    [[ $eku == *"TLS Web Client Authentication"* && $eku != *"TLS Web Server Authentication"* ]] || continue
    found=0
    for f in "$EASYRSA_DIR/pki/private/$name.key" \
             "$EASYRSA_DIR/pki/inline/private/$name.inline" \
             "$EASYRSA_DIR/pki/inline/$name.inline"; do
      [[ -f $f ]] || continue
      key_real=$(realpath -m -- "$f")
      [[ $key_real == "$server_key_real" ]] && continue
      if [[ $f == *.inline ]] && ! grep -q "PRIVATE KEY" -- "$f"; then continue; fi
      files+=("$f"); found=1
    done
    if [[ $found == 1 ]]; then names+=("$name"); fi
  done
  shopt -u nullglob

  [[ ${#files[@]} -gt 0 ]] || return 0

  header "Client private keys"
  warn "Unencrypted private keys found for ${#names[@]} client certificate(s):"
  printf '        %s\n' "${names[@]}"
  info "They are not needed after the .p12 export. .p12 files are kept."
  if confirm "Securely delete these private keys?"; then
    shred -u -- "${files[@]}"
    info "Deleted ${#files[@]} file(s)."
  else
    info "Skipped."
  fi
}

INSTALL_DIR=""
CONF_FILE=""
if [[ -L $SYMLINK ]]; then
  candidate=$(dirname "$(readlink -f "$SYMLINK")")
  if [[ -f $candidate/ocservice.conf ]]; then
    INSTALL_DIR=$candidate
    CONF_FILE=$candidate/ocservice.conf
  fi
fi

if [[ -n $CONF_FILE ]]; then
  header "Existing installation found"
  info "Install directory: $INSTALL_DIR"
  confirm "Update ocservice at $INSTALL_DIR?" || exit 0
  load_existing
  resolve_from_ocserv_conf
  validate
else
  ask_fresh
  resolve_from_ocserv_conf
  validate
  summary
fi

install_files
write_conf
write_sudoers
setup_journal
cleanup_client_keys

header "Done"
info "Run: ocservice"
if [[ $JOURNAL_ADDED == 1 ]]; then
  warn "Log out and back in for $JOURNAL_GROUP membership to take effect ('View ocserv log')."
fi
if [[ $AUTH_MODE != plain ]]; then
  info "Existing certificate users: run 'r — Rebuild certificate cache' in User Management Center."
fi
echo
echo "  To uninstall (back up cert_cache, names_used, user-history.log first):"
echo "    rm -rf $INSTALL_DIR"
echo "    sudo rm $SYMLINK $SUDOERS"
echo

#!/bin/bash

# install.sh — ocservice installer
# Part of ocservice

set -e

# =============================================================================
# Helpers
# =============================================================================

_GRN="\033[0;32m"
_YLW="\033[0;33m"
_RED="\033[0;31m"
_CYN="\033[0;36m"
_RST="\033[0m"

info()    { echo -e "  ${_GRN}[+]${_RST} $*"; }
warn()    { echo -e "  ${_YLW}[!]${_RST} $*"; }
error()   { echo -e "  ${_RED}[x]${_RST} $*"; exit 1; }
ask()     { read -rp "      $*" ; }
confirm() { read -rp "      $* (y/n): " _yn; [[ "$_yn" == "y" ]]; }

divider() { echo -e "${_CYN}-------------------------------------------${_RST}"; }
header()  { echo; echo -e "${_CYN}===========================================${_RST}"; echo -e "  ${_CYN}$*${_RST}"; echo -e "${_CYN}===========================================${_RST}"; }

# =============================================================================
# Check root
# =============================================================================

header "ocservice installer"

if [[ $EUID -ne 0 ]]; then
  error "Please run as root: sudo ./install.sh"
fi

REAL_USER="${SUDO_USER:-$USER}"
REAL_HOME=$(eval echo "~$REAL_USER")

# =============================================================================
# Check dependencies
# =============================================================================

header "Checking dependencies"

for cmd in openssl easyrsa; do
  if command -v "$cmd" &>/dev/null; then
    info "$cmd found: $(command -v "$cmd")"
  else
    warn "$cmd not found in PATH — you may need to set EASYRSA_DIR manually"
  fi
done

# =============================================================================
# Path to ocserv.conf
# =============================================================================

header "ocserv configuration"

while true; do
  ask "Path to ocserv.conf: " ; OCSERV_CONF="$REPLY"
  if [[ -f "$OCSERV_CONF" ]]; then
    info "Found: $OCSERV_CONF"
    break
  else
    warn "File not found: $OCSERV_CONF"
  fi
done

# Check use-occtl
occtl_val=$(grep -E '^\s*use-occtl\s*=' "$OCSERV_CONF" | awk -F'=' '{print $2}' | tr -d ' ')
if [[ "$occtl_val" != "true" ]]; then
  warn "use-occtl is not set to true in ocserv.conf!"
  warn "Many features (status, connections, kick, ban) will not work."
  warn "Add 'use-occtl = true' to ocserv.conf and restart ocserv."
  confirm "Continue anyway?" || exit 1
else
  info "use-occtl = true ✓"
fi

# Parse USER_FILE from auth directive
parsed_user_file=$(grep -E '^\s*auth\s*=.*plain\[passwd=' "$OCSERV_CONF" \
  | grep -oP '(?<=passwd=)[^],]+' | head -1)

# Parse CONFIG_PER_USER
parsed_config_per_user=$(grep -E '^\s*config-per-user\s*=' "$OCSERV_CONF" \
  | awk -F'=' '{print $2}' | tr -d ' ' | head -1)

# =============================================================================
# OCSERV_PREFIX
# =============================================================================

header "ocserv installation prefix"
info "This is the directory you passed to --prefix when building ocserv."
info "Expected layout: PREFIX/bin/occtl, PREFIX/bin/ocpasswd, PREFIX/sbin/ocserv"
echo
ask "ocserv prefix: " ; OCSERV_PREFIX="$REPLY"
[[ -z "$OCSERV_PREFIX" ]] && error "ocserv prefix cannot be empty."

if [[ ! -x "$OCSERV_PREFIX/bin/occtl" ]]; then
  warn "occtl not found at $OCSERV_PREFIX/bin/occtl"
  confirm "Continue anyway?" || exit 1
else
  info "occtl found ✓"
fi

# =============================================================================
# EASYRSA_DIR
# =============================================================================

header "easy-rsa directory"

ask "Path to easy-rsa: " ; EASYRSA_DIR="$REPLY"
EASYRSA_DIR="${EASYRSA_DIR:-/home/$REAL_USER/easy-rsa}"

if [[ ! -f "$EASYRSA_DIR/easyrsa" ]]; then
  warn "easyrsa not found at $EASYRSA_DIR/easyrsa"
  confirm "Continue anyway?" || exit 1
else
  info "easyrsa found ✓"
fi

# =============================================================================
# VPN_CLIENTS_DIR
# =============================================================================

header "VPN clients directory"
info "Directory where generated .p12 certificate files will be stored."
echo
ask "VPN clients dir [/home/$REAL_USER/vpn-clients]: " ; VPN_CLIENTS_DIR="$REPLY"
VPN_CLIENTS_DIR="${VPN_CLIENTS_DIR:-/home/$REAL_USER/vpn-clients}"

# =============================================================================
# AUTH_MODE
# =============================================================================

header "Authentication mode"
echo "      cert  — certificate auth only"
echo "      plain — login/password auth only"
echo "      both  — both methods enabled"
echo

while true; do
  ask "Auth mode [both]: " ; AUTH_MODE="$REPLY"
  AUTH_MODE="${AUTH_MODE:-both}"
  if [[ "$AUTH_MODE" =~ ^(cert|plain|both)$ ]]; then
    info "Auth mode: $AUTH_MODE"
    break
  else
    warn "Invalid value. Enter: cert, plain or both"
  fi
done

# =============================================================================
# USER_FILE
# =============================================================================

if [[ "$AUTH_MODE" != "cert" ]]; then
  header "ocpasswd file path"
  info "Parsed from ocserv.conf: ${parsed_user_file:-(not found)}"
  echo
  ask "Path to ocpasswd [${parsed_user_file:-/home/$REAL_USER/ocserv/etc/ocpasswd}]: " ; USER_FILE="$REPLY"
  USER_FILE="${USER_FILE:-${parsed_user_file:-/home/$REAL_USER/ocserv/etc/ocpasswd}}"
else
  USER_FILE="${parsed_user_file:-/home/$REAL_USER/ocserv/etc/ocpasswd}"
fi

# =============================================================================
# CONFIG_PER_USER
# =============================================================================

header "config-per-user directory"
info "Parsed from ocserv.conf: ${parsed_config_per_user:-(not found)}"
echo
ask "Path to config-per-user [${parsed_config_per_user:-/home/$REAL_USER/ocserv/etc/config-per-user}]: " ; CONFIG_PER_USER="$REPLY"
CONFIG_PER_USER="${CONFIG_PER_USER:-${parsed_config_per_user:-/home/$REAL_USER/ocserv/etc/config-per-user}}"

# =============================================================================
# Server identity
# =============================================================================

header "Server identity"

ask "Server name (shown in menu and used as CA name in .p12): " ; SERVER_NAME="$REPLY"
[[ -z "$SERVER_NAME" ]] && error "Server name cannot be empty."

ask "Server address (domain or IP, without https://): " ; SERVER_ADDR="$REPLY"
[[ -z "$SERVER_ADDR" ]] && error "Server address cannot be empty."

# Parse camouflage settings from ocserv.conf
camouflage_enabled=$(grep -E '^\s*camouflage\s*=\s*true' "$OCSERV_CONF")
camouflage_secret=$(grep -E '^\s*camouflage_secret\s*=' "$OCSERV_CONF" \
  | grep -oP '(?<=")\w+(?=")' | head -1)

parsed_port=$(grep -E '^\s*tcp-port\s*=' "$OCSERV_CONF" | awk -F'=' '{print $2}' | tr -d ' ' | head -1)
parsed_port="${parsed_port:-443}"

if [[ "$parsed_port" != "443" ]]; then
  PORT_SUFFIX=":$parsed_port"
else
  PORT_SUFFIX=""
fi

if [[ -n "$camouflage_enabled" && -n "$camouflage_secret" ]]; then
  SERVER_URL="https://$SERVER_ADDR$PORT_SUFFIX/?$camouflage_secret"
  info "Camouflage detected — gateway URL: $SERVER_URL"
else
  SERVER_URL="https://$SERVER_ADDR$PORT_SUFFIX/"
  info "No camouflage — gateway URL: $SERVER_URL"
fi
echo
confirm "Is this gateway URL correct?" || {
  while true; do
    ask "Enter gateway URL manually (must start with http:// or https://): " ; SERVER_URL="$REPLY"
    if [[ "$SERVER_URL" =~ ^https?:// ]]; then
      break
    else
      warn "URL must start with http:// or https://"
    fi
  done
}

ask "Docs / channel URL (optional, press Enter to skip): " ; DOCS_URL="$REPLY"

# =============================================================================
# Security
# =============================================================================

header "Security"

while true; do
  ask "Password length [20]: " ; PASSWORD_LENGTH="$REPLY"
  PASSWORD_LENGTH="${PASSWORD_LENGTH:-20}"
  if [[ "$PASSWORD_LENGTH" =~ ^[0-9]+$ ]] && (( PASSWORD_LENGTH >= 8 )); then
    break
  else
    warn "Password length must be a number >= 8."
  fi
done

# =============================================================================
# Install directory
# =============================================================================

header "Install location"

ask "Install scripts to [$REAL_HOME/bin/ocservice]: " ; INSTALL_DIR="$REPLY"
INSTALL_DIR="${INSTALL_DIR:-$REAL_HOME/bin/ocservice}"

# =============================================================================
# Confirm overwrite if config exists
# =============================================================================

CONF_FILE="$INSTALL_DIR/ocservice.conf"
if [[ -f "$CONF_FILE" ]]; then
  warn "Config already exists: $CONF_FILE"
  confirm "Overwrite?" || exit 0
fi

# =============================================================================
# Summary
# =============================================================================

header "Summary"
echo "      Install dir:      $INSTALL_DIR"
echo "      Symlink:          /usr/local/bin/ocservice"
echo "      ocserv.conf:      $OCSERV_CONF"
echo "      OCSERV_PREFIX:    $OCSERV_PREFIX"
echo "      EASYRSA_DIR:      $EASYRSA_DIR"
echo "      VPN_CLIENTS_DIR:  $VPN_CLIENTS_DIR"
echo "      AUTH_MODE:        $AUTH_MODE"
echo "      USER_FILE:        $USER_FILE"
echo "      CONFIG_PER_USER:  $CONFIG_PER_USER"
echo "      SERVER_NAME:      $SERVER_NAME"
echo "      SERVER_URL:       $SERVER_URL"
echo "      DOCS_URL:         ${DOCS_URL:-(not set)}"
echo "      PASSWORD_LENGTH:  $PASSWORD_LENGTH"
echo
confirm "Proceed with installation?" || exit 0

# =============================================================================
# Install scripts
# =============================================================================

header "Installing scripts"

mkdir -p "$INSTALL_DIR"
SCRIPT_DIR="$(dirname "$(realpath "$0")")/bin"

for script in ocservice gen-client gen-login user-center ocnames; do
  if [[ -f "$SCRIPT_DIR/$script" ]]; then
    cp "$SCRIPT_DIR/$script" "$INSTALL_DIR/$script"
    chmod +x "$INSTALL_DIR/$script"
    chown "$REAL_USER:$REAL_USER" "$INSTALL_DIR/$script"
    info "Installed: $INSTALL_DIR/$script"
  else
    warn "Script not found, skipping: $SCRIPT_DIR/$script"
  fi
done

# Copy name pool file
REPO_DIR="$(dirname "$(realpath "$0")")"
if [[ -f "$REPO_DIR/names" ]]; then
  cp "$REPO_DIR/names" "$INSTALL_DIR/names"
  chown "$REAL_USER:$REAL_USER" "$INSTALL_DIR/names"
  info "Installed: $INSTALL_DIR/names"
else
  # Create empty pool with instructions
  cat > "$INSTALL_DIR/names" << 'NAMESEOF'
# ocservice name pool — one name per line
# Lines starting with # and empty lines are ignored.
# Format: Animal-Name (e.g. Narwhal-Yaroslav)
# Add new names freely — no restart needed.
NAMESEOF
  chown "$REAL_USER:$REAL_USER" "$INSTALL_DIR/names"
  info "Created empty name pool: $INSTALL_DIR/names"
fi

# =============================================================================
# Create symlink
# =============================================================================

header "Creating symlink"

SYMLINK="/usr/local/bin/ocservice"
# Remove old symlink or file if exists
rm -f "$SYMLINK"
ln -sf "$INSTALL_DIR/ocservice" "$SYMLINK"
info "Symlink: $SYMLINK -> $INSTALL_DIR/ocservice"

# =============================================================================
# Generate ocservice.conf
# =============================================================================

header "Generating ocservice.conf"

cat > "$CONF_FILE" << EOF
# ocservice.conf — ocserv-tools configuration
# Generated by install.sh on $(date '+%Y-%m-%d %H:%M')
# Edit manually if needed.

# =============================================================================
# Paths — set manually
# =============================================================================

OCSERV_PREFIX=$OCSERV_PREFIX
EASYRSA_DIR=$EASYRSA_DIR
VPN_CLIENTS_DIR=$VPN_CLIENTS_DIR

# =============================================================================
# Authentication mode
# =============================================================================

# cert  — certificate auth only
# plain — password auth only
# both  — both methods enabled
AUTH_MODE=$AUTH_MODE

# =============================================================================
# Paths — parsed from ocserv.conf
# =============================================================================

# Required only if AUTH_MODE=plain or AUTH_MODE=both.
USER_FILE=$USER_FILE

CONFIG_PER_USER=$CONFIG_PER_USER
OCSERV_CONF=$OCSERV_CONF

# =============================================================================
# Derived paths
# =============================================================================

USER_HISTORY=\$OCSERV_PREFIX/user-history.log
OCCTL=\$OCSERV_PREFIX/bin/occtl
OCPASSWD=\$OCSERV_PREFIX/bin/ocpasswd

# =============================================================================
# Security
# =============================================================================

PASSWORD_LENGTH=$PASSWORD_LENGTH

# =============================================================================
# Server identity
# =============================================================================

SERVER_NAME=$SERVER_NAME

# =============================================================================
# Username pool
# =============================================================================

# Set to "no" to always prompt for manual entry.
NAMES_ENABLED=yes
NAMES_FILE=$INSTALL_DIR/names
NAMES_USED_FILE=$INSTALL_DIR/names_used

# =============================================================================
# Output template
# =============================================================================

SERVER_URL=$SERVER_URL
DOCS_URL=$DOCS_URL
EOF

chown "$REAL_USER:$REAL_USER" "$CONF_FILE"
info "Generated: $CONF_FILE"

# =============================================================================
# Create directories and files
# =============================================================================

header "Setting up directories and files"

# config-per-user
mkdir -p "$CONFIG_PER_USER"
chown "$REAL_USER:$REAL_USER" "$CONFIG_PER_USER"
chmod 755 "$CONFIG_PER_USER"
info "config-per-user: $CONFIG_PER_USER"

# vpn-clients
mkdir -p "$VPN_CLIENTS_DIR"
chown "$REAL_USER:$REAL_USER" "$VPN_CLIENTS_DIR"
chmod 755 "$VPN_CLIENTS_DIR"
info "vpn-clients: $VPN_CLIENTS_DIR"

# user-history.log
HISTORY_FILE="$OCSERV_PREFIX/user-history.log"
if [[ ! -f "$HISTORY_FILE" ]]; then
  touch "$HISTORY_FILE"
fi
chown "$REAL_USER:$REAL_USER" "$HISTORY_FILE"
chmod 644 "$HISTORY_FILE"
info "user-history.log: $HISTORY_FILE"

# ocpasswd (create if not exists and auth requires it)
if [[ "$AUTH_MODE" != "cert" ]]; then
  if [[ ! -f "$USER_FILE" ]]; then
    touch "$USER_FILE"
    info "Created ocpasswd: $USER_FILE"
  fi
  chown "$REAL_USER:$REAL_USER" "$USER_FILE"
  # ocpasswd needs write access to parent dir for .tmp file
  chown "$REAL_USER:$REAL_USER" "$(dirname "$USER_FILE")"
  chmod 600 "$USER_FILE"
  info "ocpasswd: $USER_FILE"
fi

# =============================================================================
# Create sudoers file
# =============================================================================

header "Configuring sudo permissions"

SUDOERS_FILE="/etc/sudoers.d/ocservice"
OCCTL_BIN="$OCSERV_PREFIX/bin/occtl"
OCPASSWD_BIN="$OCSERV_PREFIX/bin/ocpasswd"

cat > "$SUDOERS_FILE" << EOF
# ocservice — sudo permissions
# Generated by install.sh on $(date '+%Y-%m-%d %H:%M')
# Remove this file to revoke permissions: sudo rm $SUDOERS_FILE

$REAL_USER ALL=(ALL) NOPASSWD: $OCCTL_BIN
$REAL_USER ALL=(ALL) NOPASSWD: $OCPASSWD_BIN
$REAL_USER ALL=(ALL) NOPASSWD: /usr/bin/journalctl
$REAL_USER ALL=(ALL) NOPASSWD: /bin/systemctl restart ocserv
$REAL_USER ALL=(ALL) NOPASSWD: /bin/systemctl reload ocserv
$REAL_USER ALL=(ALL) NOPASSWD: /usr/bin/systemctl restart ocserv
$REAL_USER ALL=(ALL) NOPASSWD: /usr/bin/systemctl reload ocserv
EOF

chmod 440 "$SUDOERS_FILE"

# Validate sudoers syntax
if visudo -c -f "$SUDOERS_FILE" &>/dev/null; then
  info "sudoers file created and validated: $SUDOERS_FILE"
else
  warn "sudoers validation failed — removing file for safety"
  rm -f "$SUDOERS_FILE"
  warn "You will need to configure sudo permissions manually"
fi

# =============================================================================
# Done
# =============================================================================

header "Installation complete"
info "Run: ocservice"
echo
divider
echo "  To uninstall:"
echo "    rm -rf $INSTALL_DIR"
echo "    sudo rm /usr/local/bin/ocservice"
echo "    sudo rm /etc/sudoers.d/ocservice"
divider
echo

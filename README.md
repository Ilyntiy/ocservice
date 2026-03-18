# ocservice

A set of bash scripts for managing [ocserv](https://ocserv.openconnect-vpn.net/) — the OpenConnect VPN server. Designed for servers where ocserv is built from source and installed to a custom prefix, and [easy-rsa](https://github.com/OpenVPN/easy-rsa) is used for certificate management.

![Main menu](docs/screenshots/ocservice-menu.png)

## Features

- Create certificate-based VPN users (easy-rsa + .p12 export)
- Create login/password VPN users
- User Management Center — view all users, certificate expiry, ban points, online status
- Kick users and reset ban points
- Server status block in the main menu (uptime, sessions, RX/TX)
- Supports `cert`, `plain` and `both` authentication modes
- Camouflage URL auto-detected from `ocserv.conf` during install

---

## Requirements

- ocserv built from source (any recent version)
- [easy-rsa](https://github.com/OpenVPN/easy-rsa) 3.x (for certificate users)
- openssl
- `use-occtl = true` in `ocserv.conf`

---

## Quick start

```bash
git clone https://github.com/Ilyntiy/ocservice.git
cd ocservice
chmod +x install.sh
sudo ./install.sh
```

`install.sh` will:
- Parse paths from your existing `ocserv.conf`
- Ask a few questions (prefix, auth mode, server address)
- Generate `ocservice.conf` in the install directory
- Copy scripts to `~/bin/` (or your chosen location)
- Set up file permissions and create required directories
- Create `/etc/sudoers.d/ocservice` with minimal required permissions

After installation, run:

```bash
ocservice
```

If `~/bin` is not in your PATH, add to `~/.bashrc`:

```bash
export PATH="$HOME/bin:$PATH"
```

---

## Scripts

### `ocservice`
Main menu. Shows server status on every screen and provides access to all other scripts.

### `gen-client`
Creates a certificate-based VPN user. Generates an easy-rsa client certificate, exports it as a `.p12` file, and writes the result to the user history log.

Prompts:
- Username
- Certificate validity in days (default: 365)
- Max simultaneous connections (0 = unlimited)

![Creating a certificate user](docs/screenshots/gen-client.png)

### `gen-login`
Creates a login/password VPN user via `ocpasswd`. Only available when `AUTH_MODE=plain` or `AUTH_MODE=both`.

Prompts:
- Username
- Max simultaneous connections (0 = unlimited)

### `user-center`
Lists all users with their status, certificate dates, ban points and connection limit. Allows you to view connection details, edit `config-per-user`, kick, unban or delete a user.

![User Management Center](docs/screenshots/user-center.png)

![User actions](docs/screenshots/user-actions.png)

---

## Configuration

All settings live in `ocservice.conf`, placed in the same directory as the scripts.

| Variable | Description |
|---|---|
| `OCSERV_PREFIX` | ocserv installation prefix (passed to `--prefix` at build time) |
| `EASYRSA_DIR` | Path to easy-rsa directory |
| `VPN_CLIENTS_DIR` | Where generated `.p12` files are stored |
| `AUTH_MODE` | `cert`, `plain` or `both` |
| `USER_FILE` | Path to `ocpasswd` file |
| `CONFIG_PER_USER` | Path to `config-per-user` directory |
| `OCSERV_CONF` | Path to `ocserv.conf` |
| `USER_HISTORY` | Path to user action log |
| `PASSWORD_LENGTH` | Length of auto-generated passwords (default: 20) |
| `SERVER_NAME` | Display name, also used as CA name in `.p12` certificates |
| `SERVER_URL` | Gateway URL shown to new users (include camouflage path if enabled) |
| `DOCS_URL` | Optional link to docs or Telegram channel |

See `ocservice.conf.example` for a fully commented template.

---

## Notes

### restart vs reload

Some `ocserv.conf` directives only take effect after a full restart (`systemctl restart ocserv`). These include `auth`, `enable-auth`, TCP/UDP ports and server certificates.

Use **Reload configuration** (menu item 7) for runtime changes: routes, DNS, timeouts, ban settings. Use **Restart ocserv** (menu item 6) after changing authentication or network settings.

### CA password

If your easy-rsa CA was created with a password, you will be prompted to enter it each time a certificate is created or revoked. This is expected behavior — ocservice does not store or bypass the CA password.

### AUTH_MODE

`AUTH_MODE` in `ocservice.conf` must match what is actually configured in `ocserv.conf`:

| `AUTH_MODE` | `ocserv.conf` |
|---|---|
| `cert` | `auth = "certificate"` |
| `plain` | `auth = "plain[passwd=...]"` |
| `both` | `auth = "plain[passwd=...]"` + `enable-auth = "certificate"` |

Setting `AUTH_MODE` incorrectly will hide menu items or show errors when creating users.

### CRL

The certificate revocation list is read directly from `easy-rsa/pki/crl.pem`. Make sure `ocserv.conf` points to the same path:

```
crl = /home/user/easy-rsa/pki/crl.pem
```

---

## Uninstall

```bash
rm ~/bin/{ocservice,gen-client,gen-login,user-center,ocservice.conf}
sudo rm /etc/sudoers.d/ocservice
```

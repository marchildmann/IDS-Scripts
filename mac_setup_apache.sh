#!/bin/bash

# Apache HTTPS Setup Script for macOS
# This script installs and configures Apache with HTTPS support and PHP 8.4
# Created: May 20, 2025

set -euo pipefail  # Exit on error, unset var, or failed pipe stage

### 0) Sudo up-front and keep-alive, no re-prompts ###
sudo -v
while true; do
  sudo -n true
  sleep 60
  kill -0 "$$" || exit
done 2>/dev/null &

### Color codes ###
GREEN='\033[0;32m'; BLUE='\033[0;34m'; YELLOW='\033[0;33m'; RED='\033[0;31m'; NC='\033[0m'

function echo_step    { echo -e "${BLUE}==> $1${NC}"; }
function echo_success { echo -e "${GREEN}✓ $1${NC}"; }
function echo_warn    { echo -e "${YELLOW}! $1${NC}"; }
function echo_error   { echo -e "${RED}✗ $1${NC}"; exit 1; }

### 1) Ensure macOS ###
[[ "$(uname)" == "Darwin" ]] || echo_error "This script runs on macOS only."

### 2) Variables ###
PREFIX=$(brew --prefix)
HTTPD_BIN="$PREFIX/opt/httpd/bin/httpd"
HTTPD_CONF="$PREFIX/etc/httpd/httpd.conf"
SSL_CONF="$PREFIX/etc/httpd/extra/httpd-ssl.conf"
VHOSTS_CONF="$PREFIX/etc/httpd/extra/httpd-vhosts.conf"
USERS_CONF_DIR="$PREFIX/etc/httpd/users"
SSL_DIR="$PREFIX/etc/httpd/ssl"
DOC_ROOT="$HOME/Sites"
PORT=8080

### Go reverse-proxy settings (override via env vars before running if desired) ###
# Example: GO_PROXY_PORT=8081 GO_PROXY_STRIP_PREFIX=0 ./mac_setup_apache.sh
GO_PROXY_PATH="${GO_PROXY_PATH:-/api}"               # URL prefix proxied to the Go binary
GO_PROXY_PORT="${GO_PROXY_PORT:-9000}"               # Local port the Go binary listens on (127.0.0.1)
GO_PROXY_STRIP_PREFIX="${GO_PROXY_STRIP_PREFIX:-1}"  # 1 = strip prefix (/api/foo → :9000/foo); 0 = keep prefix
SUPERVISOR_USER_DIR="$HOME/.config/supervisor/conf.d"

### GoExample demo (.htaccess [P] proxy under ~/Sites/GoExample) ###
GOEXAMPLE_DIR="$HOME/Sites/GoExample"
GOEXAMPLE_PUBLIC="$GOEXAMPLE_DIR/public_html"        # web-exposed via Alias /GoExample
GOEXAMPLE_BINARY="$GOEXAMPLE_DIR/releases/goexample" # compiled binary (outside public_html)
GOEXAMPLE_PORT="${GOEXAMPLE_PORT:-9001}"             # Different from GO_PROXY_PORT so they can coexist

### Local development domains ##############################################
# Add or remove an entry here and re-run the script. Each domain gets:
#   • ~/Sites/<domain>/public_html/             (document root)
#   • /etc/hosts:  127.0.0.1 <domain>           (managed in a fenced block)
#   • HTTP + HTTPS vhosts on $PORT and 443
#   • Inclusion as a SAN in the shared SSL cert (cert auto-regenerates if list changes)
#
# We use the .test TLD (RFC 6761 reserved for testing): no mDNS/Bonjour
# interference, no risk of clashing with any real public domain.
#
# To add another, e.g.:
#   DEV_DOMAINS+=( "newproject.test" )          # at the end of this array
DEV_DOMAINS=(
  "marchildmann.com.test"
  "iotdata.systems.test"
  "columnlens.com.test"
)

### 3) Homebrew ###
echo_step "Checking Homebrew..."
if ! command -v brew &>/dev/null; then
  echo_step "Installing Homebrew..."
  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)" \
    || echo_error "Failed to install Homebrew."
  echo_success "Homebrew installed."
else
  echo_success "Homebrew present."
fi

### 4) Stop Apple's Apache ###
echo_step "Stopping built-in Apache..."
sudo apachectl stop    >/dev/null 2>&1 || true
sudo launchctl unload -w /System/Library/LaunchDaemons/org.apache.httpd.plist 2>/dev/null || true
echo_success "Built-in Apache stopped."

### 5) Install packages ###
echo_step "Installing/updating httpd, php, openssl, duckdb, go, supervisor..."
brew update
brew install httpd php@8.4 openssl@3 duckdb go supervisor || echo_error "Failed brew install."
echo_success "Packages installed."

### 6) Prepare ~/Sites ###
echo_step "Setting up ~/Sites..."
mkdir -p "$DOC_ROOT"
cat > "$DOC_ROOT/index.html" <<EOF
<html><body><h1>Apache is running!</h1></body></html>
EOF
chmod 755 "$DOC_ROOT" && chmod 644 "$DOC_ROOT/index.html"
echo_success "Document root at $DOC_ROOT."

### 6b) Per-domain document roots ###
echo_step "Scaffolding per-domain document roots…"
if [[ "${#DEV_DOMAINS[@]}" -gt 0 ]]; then
  for domain in "${DEV_DOMAINS[@]}"; do
    domain_root="$HOME/Sites/$domain/public_html"
    mkdir -p "$domain_root"
    if [[ ! -f "$domain_root/index.html" ]]; then
      cat > "$domain_root/index.html" <<EOF
<!doctype html>
<html><head><title>$domain</title></head>
<body style="font-family:-apple-system,sans-serif;max-width:40em;margin:3em auto;">
  <h1>$domain</h1>
  <p>Local dev site is live.</p>
  <p>Document root: <code>$domain_root</code></p>
</body></html>
EOF
    fi
  done
  echo_success "${#DEV_DOMAINS[@]} dev domain root(s) ready under $HOME/Sites/."
else
  echo_step "No DEV_DOMAINS configured; skipping."
fi

### 7) Per-user Apache config ###
echo_step "Creating per-user Apache config..."
sudo mkdir -p "$USERS_CONF_DIR"
APACHE_USER_CONF="$USERS_CONF_DIR/$(whoami).conf"
sudo tee "$APACHE_USER_CONF" >/dev/null <<EOF
<Directory "$DOC_ROOT">
  Options Indexes MultiViews FollowSymLinks
  AllowOverride All
  Require all granted
</Directory>
EOF
if ! grep -Fq "Include $USERS_CONF_DIR/*.conf" "$HTTPD_CONF"; then
  sudo tee -a "$HTTPD_CONF" >/dev/null <<EOF

# include per-user settings
Include $USERS_CONF_DIR/*.conf
EOF
fi
echo_success "User config created."

### 8) Backup configs (only on first run, so we keep the pristine copy) ###
echo_step "Backing up configs..."
for f in "$HTTPD_CONF" "$SSL_CONF" "$VHOSTS_CONF"; do
  if [[ -f "$f" && ! -f "$f.backup" ]]; then
    cp "$f" "$f.backup"
    echo_success "Backed up $(basename "$f")"
  else
    echo_warn "Skipping $(basename "$f") (backup already exists or source missing)"
  fi
done

### 9) Listen & ServerName (idempotent) ###
echo_step "Configuring Listen & ServerName…"

# remove any old references to our ports, to avoid duplicates
sudo sed -i '' -e '/^Listen 8080/d' -e '/^Listen 443/d' "$HTTPD_CONF"

# append fresh Listen lines
sudo tee -a "$HTTPD_CONF" >/dev/null <<EOF
Listen $PORT
Listen 443
EOF
echo_success "Added Listen $PORT and Listen 443"

# ensure exactly one ServerName directive
if grep -q "^ServerName " "$HTTPD_CONF"; then
  # replace it
  sudo sed -i '' "s|^ServerName .*|ServerName localhost|" "$HTTPD_CONF"
  echo_success "Replaced existing ServerName → localhost"
else
  sudo tee -a "$HTTPD_CONF" >/dev/null <<EOF
ServerName localhost
EOF
  echo_success "Added ServerName localhost"
fi

### 10) Enable modules & includes ###
echo_step "Enabling SSL, socache, rewrite, proxy, proxy_http, vhosts…"
sudo sed -i '' \
  -e "s|#LoadModule ssl_module|LoadModule ssl_module|" \
  -e "s|#LoadModule socache_shmcb_module|LoadModule socache_shmcb_module|" \
  -e "s|#LoadModule rewrite_module|LoadModule rewrite_module|" \
  -e "s|#LoadModule proxy_module|LoadModule proxy_module|" \
  -e "s|#LoadModule proxy_http_module|LoadModule proxy_http_module|" \
  -e "s|#Include $PREFIX/etc/httpd/extra/httpd-ssl.conf|Include $PREFIX/etc/httpd/extra/httpd-ssl.conf|" \
  -e "s|#Include $PREFIX/etc/httpd/extra/httpd-vhosts.conf|Include $PREFIX/etc/httpd/extra/httpd-vhosts.conf|" \
  "$HTTPD_CONF"
echo_success "Modules & includes enabled."

### 11) DocumentRoot in main conf ###
echo_step "Updating DocumentRoot…"
sudo sed -i '' \
  -e "s|^DocumentRoot \"[^\"]*\"|DocumentRoot \"$DOC_ROOT\"|" \
  -e "s|<Directory \"[^\"]*\"|<Directory \"$DOC_ROOT\"|" \
  "$HTTPD_CONF"
echo_success "DocumentRoot updated."

### 12) PHP module ###
echo_step "Configuring PHP module…"
PHP_PREFIX=$(brew --prefix php@8.4)
PHP_MOD="$PHP_PREFIX/lib/httpd/modules/libphp.so"
if [[ -f "$PHP_MOD" ]]; then
  if grep -q "LoadModule php_module" "$HTTPD_CONF"; then
    sudo sed -i '' "s|LoadModule php_module.*|LoadModule php_module $PHP_MOD|" "$HTTPD_CONF"
  else
    sudo tee -a "$HTTPD_CONF" >/dev/null <<EOF
LoadModule php_module $PHP_MOD
EOF
  fi
  sudo sed -i '' 's|DirectoryIndex index.html|DirectoryIndex index.php index.html|' "$HTTPD_CONF"
  if ! grep -q "PHP configuration" "$HTTPD_CONF"; then
    sudo tee -a "$HTTPD_CONF" >/dev/null <<'EOF'

# PHP configuration
<FilesMatch \.php$>
    SetHandler application/x-httpd-php
</FilesMatch>
EOF
  fi
  echo_success "PHP module configured."
else
  echo_error "PHP module not found: $PHP_MOD"
fi

### 13) Generate SSL cert (regen on missing / expiring / changed SAN list) ###
echo_step "Checking SSL certificate…"
mkdir -p "$SSL_DIR"
CRT="$SSL_DIR/localhost.crt"
KEY="$SSL_DIR/localhost.key"
DOMAIN_FILE="$SSL_DIR/.domains-fingerprint"

# Build SAN list: localhost defaults plus every entry in DEV_DOMAINS.
SAN_LIST="DNS:localhost,DNS:*.localhost,IP:127.0.0.1"
for domain in ${DEV_DOMAINS[@]+"${DEV_DOMAINS[@]}"}; do
  SAN_LIST="${SAN_LIST},DNS:${domain}"
done
DOMAIN_FINGERPRINT=$(printf '%s' "$SAN_LIST" | shasum -a 256 | awk '{print $1}')

NEED_REGEN=0
if [[ ! -f "$CRT" || ! -f "$KEY" ]]; then
  NEED_REGEN=1                                             # missing
elif ! openssl x509 -in "$CRT" -noout -checkend 2592000 >/dev/null 2>&1; then
  NEED_REGEN=1                                             # expiring within 30 days
elif [[ ! -f "$DOMAIN_FILE" || "$(cat "$DOMAIN_FILE" 2>/dev/null)" != "$DOMAIN_FINGERPRINT" ]]; then
  NEED_REGEN=1                                             # SAN list changed since last run
fi

if [[ "$NEED_REGEN" -eq 1 ]]; then
  echo_step "Generating SSL cert with SANs: $SAN_LIST"
  openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
    -keyout "$KEY" \
    -out    "$CRT" \
    -subj   "/CN=localhost" \
    -addext "subjectAltName=$SAN_LIST" \
    -addext "basicConstraints=critical,CA:FALSE"
  chmod 600 "$KEY"
  chmod 644 "$CRT"
  echo "$DOMAIN_FINGERPRINT" > "$DOMAIN_FILE"
  NEW_CERT=1
  echo_success "SSL cert created."
else
  NEW_CERT=0
  echo_success "Existing SSL cert is valid and covers all configured domains; reusing."
fi

### 14) Trust cert in Keychain (only when we just generated a new one) ###
if [[ "$NEW_CERT" -eq 1 ]]; then
  echo_step "Trusting cert in System keychain…"
  # remove any prior copy so we don't accumulate duplicates
  sudo security delete-certificate -c localhost /Library/Keychains/System.keychain 2>/dev/null || true
  sudo security add-trusted-cert \
    -d -r trustRoot \
    -k /Library/Keychains/System.keychain \
    "$CRT" \
    || echo_error "Failed to trust cert"
  echo_success "Cert trusted in System keychain."
else
  echo_step "Skipping keychain trust (cert unchanged)."
fi

### 14b) /etc/hosts entries for dev domains (idempotent, fenced block) ###
echo_step "Updating /etc/hosts…"
HOSTS_BEGIN="# BEGIN mac_setup_apache.sh dev domains"
HOSTS_END="# END mac_setup_apache.sh dev domains"

# Drop any prior managed block, even if DEV_DOMAINS is now empty.
sudo sed -i '' "/${HOSTS_BEGIN}/,/${HOSTS_END}/d" /etc/hosts

if [[ "${#DEV_DOMAINS[@]}" -gt 0 ]]; then
  {
    echo ""
    echo "$HOSTS_BEGIN"
    echo "# Managed by mac_setup_apache.sh — edit DEV_DOMAINS in the script and re-run."
    for domain in "${DEV_DOMAINS[@]}"; do
      printf '127.0.0.1 %s\n' "$domain"
    done
    echo "$HOSTS_END"
  } | sudo tee -a /etc/hosts >/dev/null
  echo_success "/etc/hosts now lists ${#DEV_DOMAINS[@]} dev domain(s)."
else
  echo_step "No DEV_DOMAINS configured; /etc/hosts left clean."
fi

# Flush the resolver cache so the new entries take effect immediately
sudo dscacheutil -flushcache 2>/dev/null || true
sudo killall -HUP mDNSResponder 2>/dev/null || true

### 15) Disable stock vhost (idempotent: skip lines that are already commented) ###
echo_step "Commenting default SSL vhost…"
sudo sed -i '' \
  -e '/<VirtualHost _default_:8443>/,/<\/VirtualHost>/s|^\([^#]\)|#\1|' \
  "$SSL_CONF"
echo_success "Default vhost disabled."

### 16) Custom vhosts ###
echo_step "Writing custom vhosts…"

# Compose reverse-proxy block for the Go service (empty if path is unset / "/").
PROXY_BLOCK=""
if [[ -n "$GO_PROXY_PATH" && "$GO_PROXY_PATH" != "/" ]]; then
  if [[ "$GO_PROXY_STRIP_PREFIX" -eq 1 ]]; then
    PROXY_BLOCK="
    # Reverse-proxy ${GO_PROXY_PATH} → 127.0.0.1:${GO_PROXY_PORT} (prefix stripped)
    ProxyRequests Off
    ProxyPreserveHost On
    RedirectMatch ^${GO_PROXY_PATH}\$ ${GO_PROXY_PATH}/
    ProxyPass        ${GO_PROXY_PATH}/ http://127.0.0.1:${GO_PROXY_PORT}/
    ProxyPassReverse ${GO_PROXY_PATH}/ http://127.0.0.1:${GO_PROXY_PORT}/"
  else
    PROXY_BLOCK="
    # Reverse-proxy ${GO_PROXY_PATH} → 127.0.0.1:${GO_PROXY_PORT} (prefix preserved)
    ProxyRequests Off
    ProxyPreserveHost On
    ProxyPass        ${GO_PROXY_PATH} http://127.0.0.1:${GO_PROXY_PORT}${GO_PROXY_PATH}
    ProxyPassReverse ${GO_PROXY_PATH} http://127.0.0.1:${GO_PROXY_PORT}${GO_PROXY_PATH}"
  fi
fi

# GoExample alias: /GoExample URL → public_html/ on disk so releases/ stays unreachable
GOEXAMPLE_BLOCK="
    # GoExample demo: only public_html is web-exposed; .htaccess inside proxies to 127.0.0.1:${GOEXAMPLE_PORT}
    Alias /GoExample \"${GOEXAMPLE_PUBLIC}\"
    <Directory \"${GOEXAMPLE_PUBLIC}\">
        Options -Indexes FollowSymLinks
        AllowOverride All
        Require all granted
    </Directory>"

sudo tee "$VHOSTS_CONF" >/dev/null <<EOF
# HTTP vhost
<VirtualHost *:${PORT}>
    ServerName localhost
    DocumentRoot "$DOC_ROOT"
    ErrorLog "$PREFIX/var/log/httpd/error_log"
    CustomLog "$PREFIX/var/log/httpd/access_log" common
${PROXY_BLOCK}
${GOEXAMPLE_BLOCK}

    <Directory "$DOC_ROOT">
        Options Indexes FollowSymLinks
        AllowOverride All
        Require all granted
    </Directory>
</VirtualHost>

# HTTPS vhost
<VirtualHost *:443>
    ServerName localhost
    DocumentRoot "$DOC_ROOT"
    ErrorLog "$PREFIX/var/log/httpd/error_log"
    CustomLog "$PREFIX/var/log/httpd/access_log" common

    SSLEngine on
    SSLCertificateFile "$SSL_DIR/localhost.crt"
    SSLCertificateKeyFile "$SSL_DIR/localhost.key"
${PROXY_BLOCK}
${GOEXAMPLE_BLOCK}

    <Directory "$DOC_ROOT">
        Options Indexes FollowSymLinks
        AllowOverride All
        Require all granted
    </Directory>
</VirtualHost>
EOF
echo_success "Custom vhosts written (Go proxy: ${GO_PROXY_PATH:-disabled} → :${GO_PROXY_PORT}; GoExample → :${GOEXAMPLE_PORT})."

# Append per-domain vhosts (each gets HTTP + HTTPS sharing the SAN cert)
if [[ "${#DEV_DOMAINS[@]}" -gt 0 ]]; then
  for domain in "${DEV_DOMAINS[@]}"; do
    domain_root="$HOME/Sites/$domain/public_html"
    sudo tee -a "$VHOSTS_CONF" >/dev/null <<EOF

# ===== ${domain} =====
<VirtualHost *:${PORT}>
    ServerName ${domain}
    DocumentRoot "${domain_root}"
    ErrorLog "$PREFIX/var/log/httpd/${domain}-error_log"
    CustomLog "$PREFIX/var/log/httpd/${domain}-access_log" common

    <Directory "${domain_root}">
        Options -Indexes FollowSymLinks
        AllowOverride All
        Require all granted
    </Directory>
</VirtualHost>

<VirtualHost *:443>
    ServerName ${domain}
    DocumentRoot "${domain_root}"
    ErrorLog "$PREFIX/var/log/httpd/${domain}-error_log"
    CustomLog "$PREFIX/var/log/httpd/${domain}-access_log" common

    SSLEngine on
    SSLCertificateFile "$SSL_DIR/localhost.crt"
    SSLCertificateKeyFile "$SSL_DIR/localhost.key"

    <Directory "${domain_root}">
        Options -Indexes FollowSymLinks
        AllowOverride All
        Require all granted
    </Directory>
</VirtualHost>
EOF
  done
  echo_success "Appended ${#DEV_DOMAINS[@]} per-domain vhost block(s)."
fi

### 17) Validate ###
echo_step "Testing Apache config…"
sudo "$HTTPD_BIN" -t || echo_error "Apache config test failed."
echo_success "Apache config valid."

### 17b) Configure supervisord (user-level program configs, no root needed) ###
echo_step "Configuring supervisord…"
SUPERVISOR_CONF="$PREFIX/etc/supervisord.conf"
mkdir -p "$SUPERVISOR_USER_DIR"

if [[ ! -f "$SUPERVISOR_CONF" ]]; then
  echo_warn "Expected $SUPERVISOR_CONF after 'brew install supervisor' — skipping include patch."
elif grep -Fq "$SUPERVISOR_USER_DIR" "$SUPERVISOR_CONF"; then
  echo_success "Supervisor [include] already references $SUPERVISOR_USER_DIR."
elif grep -q "^\[include\]" "$SUPERVISOR_CONF"; then
  echo_warn "$SUPERVISOR_CONF already has an [include] section. Add 'files = $SUPERVISOR_USER_DIR/*.conf' to it manually."
else
  cat >> "$SUPERVISOR_CONF" <<EOF

# Per-user program configs (added by mac_setup_apache.sh)
[include]
files = $SUPERVISOR_USER_DIR/*.conf
EOF
  echo_success "Added [include] section pointing to $SUPERVISOR_USER_DIR."
fi

# Drop a commented-out template so the user has a working starting point.
SUPERVISOR_TEMPLATE="$SUPERVISOR_USER_DIR/_example-go-api.conf.disabled"
if [[ ! -f "$SUPERVISOR_TEMPLATE" ]]; then
  cat > "$SUPERVISOR_TEMPLATE" <<EOF
; Example: keep a Go binary running on 127.0.0.1:${GO_PROXY_PORT}.
; Rename to *.conf and run: supervisorctl reread && supervisorctl update
;
; [program:go-api]
; command=$HOME/go-services/api/api
; directory=$HOME/go-services/api
; autostart=true
; autorestart=true
; stopasgroup=true
; killasgroup=true
; environment=PORT="${GO_PROXY_PORT}",GO_ENV="dev"
; stdout_logfile=$HOME/go-services/api/stdout.log
; stderr_logfile=$HOME/go-services/api/stderr.log
EOF
  echo_success "Wrote example program template: $SUPERVISOR_TEMPLATE"
fi

# (Re)start supervisor under brew services so it survives reboots/login.
brew services restart supervisor >/dev/null 2>&1 \
  && echo_success "supervisord running via 'brew services'." \
  || echo_warn "Could not start supervisor via brew services; run 'brew services start supervisor' manually."

### 18) Test pages ###
echo_step "Creating phpinfo…"
cat > "$DOC_ROOT/phpinfo.php" <<'EOF'
<?php
phpinfo();
EOF

echo_step "Creating mod_rewrite test files..."
mkdir -p "${DOC_ROOT}/rewrite-test"
cat > "${DOC_ROOT}/rewrite-test/success.html" <<'EOF'
<html><body><h1>Rewrite Test Successful!</h1></body></html>
EOF

# Fine-tuned .htaccess for directory root + /test
cat > "${DOC_ROOT}/rewrite-test/.htaccess" <<'EOF'
Options -Indexes
DirectoryIndex success.html

RewriteEngine On
RewriteRule ^$           success.html [L]
RewriteRule ^test$       success.html [L]
EOF

chmod 644 "${DOC_ROOT}/rewrite-test/success.html" \
         "${DOC_ROOT}/rewrite-test/.htaccess"
echo_success "Rewrite test files created."

### 18b) GoExample app: ~/Sites/GoExample with .htaccess [P] proxy ###
echo_step "Scaffolding GoExample app at $GOEXAMPLE_DIR…"
mkdir -p "$GOEXAMPLE_PUBLIC" "$GOEXAMPLE_DIR/releases"

# Source — only seed if absent, so re-runs don't clobber user edits
if [[ ! -f "$GOEXAMPLE_DIR/main.go" ]]; then
  cat > "$GOEXAMPLE_DIR/main.go" <<'EOF'
// Tiny demo HTTP server proxied by Apache via ~/Sites/GoExample/public_html/.htaccess
package main

import (
	"encoding/json"
	"log"
	"net/http"
	"os"
	"time"
)

func main() {
	addr := "127.0.0.1:" + envOr("PORT", "9001")

	mux := http.NewServeMux()
	mux.HandleFunc("/health", func(w http.ResponseWriter, r *http.Request) {
		_, _ = w.Write([]byte("ok\n"))
	})
	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(map[string]any{
			"service": "GoExample",
			"path":    r.URL.Path,
			"method":  r.Method,
			"time":    time.Now().UTC().Format(time.RFC3339),
		})
	})

	log.Printf("GoExample listening on %s", addr)
	log.Fatal(http.ListenAndServe(addr, mux))
}

func envOr(k, def string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return def
}
EOF
  echo_success "Wrote $GOEXAMPLE_DIR/main.go"
fi

# go.mod
if [[ ! -f "$GOEXAMPLE_DIR/go.mod" ]]; then
  ( cd "$GOEXAMPLE_DIR" && go mod init goexample >/dev/null 2>&1 ) \
    || echo_warn "go mod init failed (re-runnable with: cd $GOEXAMPLE_DIR && go mod init goexample)"
fi

# Build into releases/
if command -v go >/dev/null 2>&1; then
  echo_step "Building goexample binary…"
  if ( cd "$GOEXAMPLE_DIR" && go build -o "$GOEXAMPLE_BINARY" . ); then
    echo_success "Built $GOEXAMPLE_BINARY"
  else
    echo_warn "go build failed — fix sources in $GOEXAMPLE_DIR and rebuild manually."
  fi
else
  echo_warn "go not on PATH; skipping build."
fi

# .htaccess in public_html — overwritten on every run since this is our config
cat > "$GOEXAMPLE_PUBLIC/.htaccess" <<EOF
# Proxy everything under /GoExample/ to the Go binary on 127.0.0.1:${GOEXAMPLE_PORT}.
# Requires mod_proxy, mod_proxy_http, mod_rewrite (all enabled by mac_setup_apache.sh).
Options -Indexes
RewriteEngine On
RewriteBase /GoExample/
RewriteRule ^(.*)\$ http://127.0.0.1:${GOEXAMPLE_PORT}/\$1 [P,L]
EOF
chmod 644 "$GOEXAMPLE_PUBLIC/.htaccess"
echo_success ".htaccess written: $GOEXAMPLE_PUBLIC/.htaccess"

# Supervisor program config — real .conf so supervisord auto-starts it on login
GOEXAMPLE_SUPERVISOR_CONF="$SUPERVISOR_USER_DIR/goexample.conf"
cat > "$GOEXAMPLE_SUPERVISOR_CONF" <<EOF
[program:goexample]
command=$GOEXAMPLE_BINARY
directory=$GOEXAMPLE_DIR
autostart=true
autorestart=true
stopasgroup=true
killasgroup=true
environment=PORT="${GOEXAMPLE_PORT}"
stdout_logfile=$GOEXAMPLE_DIR/stdout.log
stderr_logfile=$GOEXAMPLE_DIR/stderr.log
EOF
echo_success "Supervisor program written: $GOEXAMPLE_SUPERVISOR_CONF"

# Pick up the new program (or restart it if the binary was rebuilt)
if [[ -x "$GOEXAMPLE_BINARY" ]] && command -v "$PREFIX/bin/supervisorctl" >/dev/null 2>&1; then
  # Give brew-services-restart a moment to bring supervisord up
  for _ in 1 2 3 4 5; do
    "$PREFIX/bin/supervisorctl" status >/dev/null 2>&1 && break
    sleep 1
  done
  "$PREFIX/bin/supervisorctl" reread >/dev/null 2>&1 || true
  "$PREFIX/bin/supervisorctl" update  >/dev/null 2>&1 || true
  "$PREFIX/bin/supervisorctl" restart goexample >/dev/null 2>&1 || true
  echo_success "supervisord picked up goexample (restart applied if already running)."
else
  echo_warn "Skipping supervisorctl reload (binary missing or supervisorctl unavailable)."
fi


### 19) Run as current user ###
echo_step "Setting Apache run user/group…"
sudo sed -i '' "s|^User .*|User $(whoami)|" "$HTTPD_CONF"
sudo sed -i '' "s|^Group .*|Group staff|"     "$HTTPD_CONF"
echo_success "Apache will run as $(whoami):staff."

### 20) Start Apache ###
echo_step "Restarting httpd…"
brew services restart httpd
sleep 3

### 21) Verify ###
echo_step "Verifying HTTP…"
curl -s "http://localhost:${PORT}" >/dev/null && echo_success "HTTP OK" || echo_error "HTTP failed"

echo_step "Verifying HTTPS…"
curl -sk "https://localhost" >/dev/null && echo_success "HTTPS OK" || echo_warn "HTTPS failed; check trust/logs"

echo_step "Verifying DuckDB…"
DUCKDB_VERSION=$(duckdb -c "SELECT version();" -noheader 2>/dev/null | tr -d ' ' || true)
if [[ -n "$DUCKDB_VERSION" ]]; then
  echo_success "DuckDB OK ($DUCKDB_VERSION)"
else
  echo_warn "DuckDB CLI did not respond as expected."
fi

echo_step "Verifying Go…"
if command -v go >/dev/null 2>&1; then
  echo_success "Go OK ($(go version | awk '{print $3}'))"
else
  echo_warn "Go not on PATH."
fi

echo_step "Verifying supervisord…"
if "$PREFIX/bin/supervisorctl" version >/dev/null 2>&1; then
  echo_success "supervisorctl OK ($("$PREFIX/bin/supervisorctl" version))"
else
  echo_warn "supervisorctl did not respond — supervisord may still be starting."
fi

echo_step "Verifying GoExample (https://localhost/GoExample/health)…"
sleep 2  # give the freshly-(re)started Go binary a moment to bind
if curl -sk --max-time 5 "https://localhost/GoExample/health" | grep -q "ok"; then
  echo_success "GoExample OK"
else
  echo_warn "GoExample not responding. Check: supervisorctl status goexample ; tail $GOEXAMPLE_DIR/stderr.log"
fi

if [[ "${#DEV_DOMAINS[@]}" -gt 0 ]]; then
  echo_step "Verifying dev domains…"
  for domain in "${DEV_DOMAINS[@]}"; do
    if curl -sk --max-time 5 -o /dev/null -w '%{http_code}' "https://${domain}/" | grep -q '^2'; then
      echo_success "${domain} OK"
    else
      echo_warn "${domain} not responding — check /etc/hosts and 'sudo $HTTPD_BIN -t'."
    fi
  done
fi

if [[ "$GO_PROXY_STRIP_PREFIX" -eq 1 ]]; then
  PROXY_NOTE="prefix stripped"
else
  PROXY_NOTE="prefix preserved"
fi

### Done ###
DEV_DOMAIN_LINES=""
for domain in ${DEV_DOMAINS[@]+"${DEV_DOMAINS[@]}"}; do
  DEV_DOMAIN_LINES+=$'\n'"  • https://${domain}/   →  ~/Sites/${domain}/public_html/"
done

echo_success "Setup complete!
  • HTTP        http://localhost:${PORT}
  • HTTPS       https://localhost
  • Go API      https://localhost${GO_PROXY_PATH}/      →  127.0.0.1:${GO_PROXY_PORT}  (${PROXY_NOTE})
  • GoExample   https://localhost/GoExample/            →  127.0.0.1:${GOEXAMPLE_PORT}  (.htaccess [P] proxy)
  • DuckDB      $(command -v duckdb)
  • Go          $(command -v go)${DEV_DOMAIN_LINES}
DocumentRoot: $DOC_ROOT
GoExample:    $GOEXAMPLE_DIR  (binary: $GOEXAMPLE_BINARY)"
echo -e "${BLUE}GoExample lifecycle:${NC}
  Edit:    \$EDITOR $GOEXAMPLE_DIR/main.go
  Rebuild: ( cd $GOEXAMPLE_DIR && go build -o $GOEXAMPLE_BINARY . )
  Restart: supervisorctl restart goexample
  Logs:    tail -f $GOEXAMPLE_DIR/stderr.log
${BLUE}To add another dev domain:${NC} edit DEV_DOMAINS at the top of mac_setup_apache.sh
and re-run the script — docroot, /etc/hosts, vhost, and SSL SAN all update automatically."

exit 0

#!/bin/bash

# Apache HTTPS Setup Script for macOS
# This script installs and configures Apache with HTTPS support and PHP 8.4
# Created: May 20, 2025

set -e  # Exit on first error

### 0) Sudo up-front and keep-alive, no re-prompts ###
sudo -v
while true; do
  sudo -n true
  sleep 60
  kill -0 "$$" || exit
done 2>/dev/null &

### Color codes ###
GREEN='\033[0;32m'; BLUE='\033[0;34m'; RED='\033[0;31m'; NC='\033[0m'

function echo_step  { echo -e "${BLUE}==> $1${NC}"; }
function echo_success { echo -e "${GREEN}✓ $1${NC}"; }
function echo_error  { echo -e "${RED}✗ $1${NC}"; exit 1; }

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
echo_step "Installing/updating httpd, php, openssl..."
brew update
brew install httpd php@8.4 openssl@3 || echo_error "Failed brew install."
echo_success "Packages installed."

### 6) Prepare ~/Sites ###
echo_step "Setting up ~/Sites..."
mkdir -p "$DOC_ROOT"
cat > "$DOC_ROOT/index.html" <<EOF
<html><body><h1>Apache is running!</h1></body></html>
EOF
chmod 755 "$DOC_ROOT" && chmod 644 "$DOC_ROOT/index.html"
echo_success "Document root at $DOC_ROOT."

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
if ! grep -q "Include $USERS_CONF_DIR/*.conf" "$HTTPD_CONF"; then
  sudo tee -a "$HTTPD_CONF" >/dev/null <<EOF

# include per-user settings
Include $USERS_CONF_DIR/*.conf
EOF
fi
echo_success "User config created."

### 8) Backup configs ###
echo_step "Backing up configs..."
cp "$HTTPD_CONF"{,.backup}
cp "$SSL_CONF"{,.backup}
cp "$VHOSTS_CONF"{,.backup}
echo_success "Backups done."

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
echo_step "Enabling SSL, socache, rewrite, vhosts…"
sudo sed -i '' \
  -e "s|#LoadModule ssl_module|LoadModule ssl_module|" \
  -e "s|#LoadModule socache_shmcb_module|LoadModule socache_shmcb_module|" \
  -e "s|#LoadModule rewrite_module|LoadModule rewrite_module|" \
  -e "s|#Include $PREFIX/etc/httpd/extra/httpd-ssl.conf|Include $PREFIX/etc/httpd/extra/httpd-ssl.conf|" \
  -e "s|#Include $PREFIX/etc/httpd/extra/httpd-vhosts.conf|Include $PREFIX/etc/httpd/extra/httpd-vhosts.conf|" \
  "$HTTPD_CONF"
echo_success "Modules & includes enabled."

### 11) DocumentRoot in main conf ###
echo_step "Updating DocumentRoot…"
sudo sed -i '' \
  -e "s|^DocumentRoot \".*\"|DocumentRoot \"$DOC_ROOT\"|" \
  -e "s|<Directory \".*\"|<Directory \"$DOC_ROOT\"|" \
  "$HTTPD_CONF"
echo_success "DocumentRoot updated."

### 12) PHP module ###
echo_step "Configuring PHP module…"
PHP_MOD="$PREFIX/opt/php/lib/httpd/modules/libphp.so"
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

### 13) Generate SSL certs ###
echo_step "Generating SSL certificates…"
mkdir -p "$SSL_DIR"
openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
  -keyout "$SSL_DIR/localhost.key" \
  -out    "$SSL_DIR/localhost.crt" \
  -subj   "/CN=localhost" \
  -addext "subjectAltName=DNS:localhost,DNS:*.localhost,IP:127.0.0.1" \
  -addext "basicConstraints=critical,CA:FALSE"
chmod 600 "$SSL_DIR/localhost.key"
chmod 644 "$SSL_DIR/localhost.crt"
echo_success "SSL certs created."

### 14) Trust cert in Keychain ###
echo_step "Trusting cert in System keychain…"
sudo security add-trusted-cert \
  -d -r trustRoot \
  -k /Library/Keychains/System.keychain \
  "$SSL_DIR/localhost.crt" \
  || echo_error "Failed to trust cert"
echo_success "Cert trusted in System keychain."

### 15) Disable stock vhost ###
echo_step "Commenting default SSL vhost…"
sudo sed -i '' \
  -e '/<VirtualHost _default_:8443>/,/<\/VirtualHost>/s|^|#|' \
  "$SSL_CONF"
echo_success "Default vhost disabled."

### 16) Custom vhosts ###
echo_step "Writing custom vhosts…"
sudo tee "$VHOSTS_CONF" >/dev/null <<EOF
# HTTP vhost
<VirtualHost *:${PORT}>
    ServerName localhost
    DocumentRoot "$DOC_ROOT"
    ErrorLog "$PREFIX/var/log/httpd/error_log"
    CustomLog "$PREFIX/var/log/httpd/access_log" common

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

    <Directory "$DOC_ROOT">
        Options Indexes FollowSymLinks
        AllowOverride All
        Require all granted
    </Directory>
</VirtualHost>
EOF
echo_success "Custom vhosts written."

### 17) Validate ###
echo_step "Testing Apache config…"
sudo "$HTTPD_BIN" -t || echo_error "Apache config test failed."
echo_success "Apache config valid."

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
curl -sk "https://localhost" >/dev/null && echo_success "HTTPS OK" || echo_step "HTTPS failed; check trust/logs"

### Done ###
echo_success "Setup complete!
  • HTTP  http://localhost:${PORT}
  • HTTPS https://localhost
DocumentRoot: $DOC_ROOT"
echo -e "${BLUE}Tip: add custom domains in /etc/hosts if needed.${NC}"

exit 0

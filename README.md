# IDS-Scripts

A growing collection of useful development scripts for macOS. Each script automates a common setup or maintenance task, so you can spend less time configuring your environment and more time coding.

---

## Table of Contents

- [Overview](#overview)  
- [Scripts](#scripts)  
  - [mac_setup_apache.sh](#mac_setup_apachesh)  
- [Usage](#usage)  
- [Contributing](#contributing)  
- [License](#license)  

---

## Overview

This repository collects standalone shell scripts that simplify and automate routine developer workflows:

- **Web server** setups (Apache, Nginx, PHP, SSL)  
- **Database** provisioning  
- **Environment** configuration  
- **Utility** tasks (backups, logs rotation, cleanup)  

You can pick and choose the scripts you need, customize them, and re-run as your environment evolves. All scripts aim to be:

- **Idempotent**: Safe to run multiple times  
- **Portable**: Use `$(brew --prefix)` or similar to detect install paths  
- **Secure**: Minimal `sudo` prompts, correct permissions  
- **Self-documented**: Inline comments and helper messages  

---

## Scripts

### mac_setup_apache.sh

Automates Apache + HTTPS + PHP 8.4 + DuckDB + Go reverse-proxy setup on macOS via Homebrew.

**Features**  
- Stops and disables Apple’s built-in Apache  
- Installs/updates Homebrew packages: `httpd`, `php@8.4`, `openssl@3`, `duckdb`, `go`, `supervisor`  
- Creates `~/Sites` as your document root  
- Generates a self-signed SSL cert (with proper BasicConstraints) and **trusts** it in the macOS System keychain — re-uses an existing cert if it has more than 30 days of validity left, so re-running the script doesn't churn the keychain  
- Configures Apache to listen on ports **8080** (HTTP) and **443** (HTTPS)  
- Uses an **idempotent** Listen/ServerName block — safe to re-run without duplicates  
- Backs up the original `httpd.conf`, `httpd-ssl.conf`, and `httpd-vhosts.conf` exactly **once** (subsequent runs preserve the pristine `.backup` files)  
- Sets up a per-user Apache include in `$(brew --prefix)/etc/httpd/users/$(whoami).conf`  
- Enables PHP 8.4 via `libphp.so` (resolved via `brew --prefix php@8.4`), `mod_rewrite`, `mod_proxy`, and `mod_proxy_http`  
- Writes custom VirtualHost definitions for HTTP & HTTPS  
- Reverse-proxies a configurable URL prefix (default `/api`) to a local Go binary on `127.0.0.1:9000`, mirroring a production `acme.com/api → supervisord-managed Go` topology. Override at run time:  
  ```bash
  GO_PROXY_PATH=/api  GO_PROXY_PORT=9000  GO_PROXY_STRIP_PREFIX=1  ./mac_setup_apache.sh
  ```  
- Sets up Homebrew **supervisord** with a user-level include directory at `~/.config/supervisor/conf.d/`, drops a commented `_example-go-api.conf.disabled` template there, and starts `supervisord` via `brew services` so it survives reboots — all without root  
- Provisions any number of **local dev domains** under the `.test` TLD — RFC 6761 reserves `.test` for exactly this purpose, so there's no Bonjour/mDNS interference and zero risk of clashing with a real public domain. Defaults: `marchildmann.com.test`, `iotdata.systems.test`, `columnlens.com.test` (mirroring the production `<realdomain>.<tld>` shape, with `.test` appended — handy when copy-pasting paths/configs between local and prod). Each is wired end-to-end:  
  - `~/Sites/<domain>/public_html/` document root with a starter `index.html`  
  - `/etc/hosts` entry inside a fenced `# BEGIN/END mac_setup_apache.sh dev domains` block, so re-runs replace cleanly  
  - HTTP + HTTPS vhosts on `:8080` / `:443`  
  - The domain is added as a SAN to the shared SSL cert; a fingerprint file (`$SSL_DIR/.domains-fingerprint`) tracks the SAN list, so the cert auto-regenerates and re-trusts only when the list actually changes  
  - The macOS resolver cache is flushed so the new entries take effect immediately  

  **To add another dev domain**, edit the `DEV_DOMAINS=( … )` array at the top of the script and re-run:  
  ```bash
  DEV_DOMAINS=(
    "marchildmann.com.test"
    "iotdata.systems.test"
    "columnlens.com.test"
    "newproject.com.test"   # ← just add a line
  )
  ./mac_setup_apache.sh
  ```  
  Removing a line works the same way — the next run drops it from `/etc/hosts`, regenerates the cert without it, and the orphaned vhost is cleaned up because the vhost file is rewritten from scratch.  

- Scaffolds a working **GoExample** app under `~/Sites/GoExample/` that mirrors a typical "release directory" production layout:  
  ```
  ~/Sites/GoExample/
  ├── main.go                  # source (not web-exposed)
  ├── go.mod
  ├── releases/goexample       # compiled binary (not web-exposed)
  └── public_html/.htaccess    # mod_rewrite [P] → 127.0.0.1:9001
  ```  
  The vhost adds `Alias /GoExample → public_html/` so only `public_html/` is reachable; the source and binary are physically present but URL-unreachable. A real `~/.config/supervisor/conf.d/goexample.conf` keeps the binary running. Browse to **`https://localhost/GoExample/`** after install.  
- Verifies HTTP, HTTPS, and the DuckDB CLI at the end  
- Creates test pages:  
  - `index.html` → “Apache is running!”  
  - `phpinfo.php` → PHP info page  
  - `rewrite-test/.htaccess` → mod_rewrite test  
- Runs Apache as **your** user (no `_www` permission headaches)  
- Prompts for `sudo` **once** up-front, then uses a keep-alive loop  
- Strict shell mode (`set -euo pipefail`) to catch unset vars and broken pipes  

> ⚠️ **Dev-only.** The generated vhosts enable `Options Indexes` and `AllowOverride All` under `~/Sites`, which exposes directory listings and lets any `.htaccess` change server behavior. This is intentional for a local dev box — do **not** copy these settings onto a publicly reachable server.  

---

## Usage

1. **Clone the repo**  
   ```bash
   git clone https://github.com/your-username/IDS-Scripts.git
   cd IDS-Scripts
   ```

2. **Make the script executable**  
   ```bash
   chmod +x mac_setup_apache.sh
   ```

3. **Run it**  
   ```bash
   ./mac_setup_apache.sh
   ```

   - You will be prompted for your password once.  
   - When it completes, visit:  
     - HTTP:  `http://localhost:8080`  
     - HTTPS: `https://localhost`  
   - DuckDB is now on your `$PATH`:  
     ```bash
     duckdb -c "SELECT version();"
     ```  
   - To run a Go binary behind Apache:  
     ```bash
     # 1. Build your service (must listen on 127.0.0.1:$GO_PROXY_PORT, default 9000)
     mkdir -p ~/go-services/api && cd ~/go-services/api
     go mod init api && go build -o api .

     # 2. Copy & edit the supervisor template
     cp ~/.config/supervisor/conf.d/_example-go-api.conf.disabled \
        ~/.config/supervisor/conf.d/go-api.conf
     # edit go-api.conf to point `command=` at ~/go-services/api/api

     # 3. Pick it up
     supervisorctl reread && supervisorctl update

     # 4. Test through Apache
     curl -k https://localhost/api/<your-route>
     ```  

---

## Contributing

1. **Fork** this repository  
2. **Add** your script under a clear name and directory  
3. **Document** usage at the top of the script and update this `README.md`  
4. **Submit** a pull request  

Please aim for idempotent, well-commented, and portable code.

---

## License

```text
MIT License

Copyright (c) 2025 Marc Hildmann

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the “Software”), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell  
copies of the Software, and to permit persons to whom the Software is  
furnished to do so, subject to the following conditions:  

The above copyright notice and this permission notice shall be included in  
all copies or substantial portions of the Software.  

THE SOFTWARE IS PROVIDED “AS IS”, WITHOUT WARRANTY OF ANY KIND, EXPRESS OR  
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,  
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE  
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER  
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,  
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN  
THE SOFTWARE.  
```

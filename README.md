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

Automates Apache + HTTPS + PHP 8.4 setup on macOS via Homebrew.

**Features**  
- Stops and disables Apple’s built-in Apache  
- Installs/updates Homebrew packages: `httpd`, `php@8.4`, `openssl@3`  
- Creates `~/Sites` as your document root  
- Generates a self-signed SSL cert (with proper BasicConstraints) and **trusts** it in the macOS System keychain  
- Configures Apache to listen on ports **8080** (HTTP) and **443** (HTTPS)  
- Uses an **idempotent** Listen/ServerName block—safe to re-run without duplicates  
- Sets up a per-user Apache include in `$(brew --prefix)/etc/httpd/users/$(whoami).conf`  
- Enables PHP 8.4 via `libphp.so` and `mod_rewrite`  
- Writes custom VirtualHost definitions for HTTP & HTTPS  
- Creates test pages:  
  - `index.html` → “Apache is running!”  
  - `phpinfo.php` → PHP info page  
  - `rewrite-test/.htaccess` → mod_rewrite test  
- Runs Apache as **your** user (no `_www` permission headaches)  
- Prompts for `sudo` **once** up-front, then uses a keep-alive loop  

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

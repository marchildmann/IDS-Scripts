# IDS-Scripts

A growing collection of useful development scripts for macOS. Each script automates a common setup or maintenance task, so you can spend less time configuring your environment and more time coding.

---

## Table of Contents

- [Overview](#overview)  
- [Scripts](#scripts)  
  - [mac_setup_apache.sh](#mac_setup_apachesh)  
  - [mac_setup_llm.sh](#mac_setup_llmsh)  
- [Usage](#usage)  
- [Daily workflow — mac_setup_apache.sh](#daily-workflow--mac_setup_apachesh)  
- [Daily workflow — mac_setup_llm.sh](#daily-workflow--mac_setup_llmsh)  
- [Contributing](#contributing)  
- [License](#license)  

---

## Overview

This repository collects standalone shell scripts that simplify and automate routine developer workflows:

- **Web server** setups (Apache, Nginx, PHP, SSL)  
- **Database** provisioning  
- **Local LLM** coding environments (Ollama + VS Code)  
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
- **Re-runs never overwrite user content.** Every file the script seeds under `~/Sites/` or `~/.config/supervisor/conf.d/` is written through a `write_if_absent` helper — if the file already exists, the script skips it and prints a yellow `! Preserving existing …` line. The compiled GoExample binary is also preserved if `releases/goexample` is already executable (so a hand-built binary with custom `-ldflags` survives). Machine-managed configs (`httpd.conf`, `httpd-vhosts.conf`, the fenced `/etc/hosts` block, `supervisord.conf`'s `[include]` patch, the SSL cert) **are** still kept in sync — they're driven by the variables at the top of the script. To force-regenerate any preserved file, just `rm <path>` and re-run.  

> ⚠️ **Dev-only.** The generated vhosts enable `Options Indexes` and `AllowOverride All` under `~/Sites`, which exposes directory listings and lets any `.htaccess` change server behavior. This is intentional for a local dev box — do **not** copy these settings onto a publicly reachable server.  

---

### mac_setup_llm.sh

Sets up a local LLM coding environment for use inside VS Code. Intentionally kept **separate** from Claude Code, which stays on Anthropic's hosted models for hard agentic work — this script is for privacy-sensitive snippets, offline coding, and high-volume autocomplete that doesn't need a frontier-model brain.

**Stack**  
```
VS Code  ──┐   Cmd+L chat / Cmd+I inline edit
           │
   Continue.continue extension
           │
           ▼   HTTP, http://localhost:11434
       Ollama daemon  (brew services start ollama)
         ├── qwen2.5-coder:7b    4.7 GB    code, autocomplete
         ├── gemma4:e4b          9.6 GB    chat, docs, multimodal (text + image, 128K ctx)
         └── nomic-embed-text    274 MB    @codebase embeddings
```

**Features**  
- Installs/updates Homebrew packages: `ollama`  
- Starts the Ollama daemon via `brew services` so it auto-runs on login (HTTP API on `http://localhost:11434`)  
- Pulls each model in the `LLM_MODELS=( … )` array; skips ones already present (with `:latest` tag normalization so untagged entries don't false-miss)  
- Installs the **Continue.continue** VS Code extension via `code --install-extension`  
- Writes `~/.continue/config.json` with:  
  - Both chat models in the dropdown above the input  
  - **`contextLength`** tuned for 16 GB unified memory: **32 K** for Qwen 2.5 Coder 7B, **16 K** for Gemma 4 e4b — Ollama otherwise caps `num_ctx` at 4 K regardless of what the model supports, which trips "File exceeds model's context length" on anything bigger than ~10 KB  
  - `maxTokens: 4096` so long outputs don't get clipped  
  - `tabAutocompleteModel` pinned to Qwen at 4 K context (autocomplete prompts are tiny; a bigger KV cache just slows the per-keystroke roundtrip)  
  - `embeddingsProvider` on `nomic-embed-text` so `@codebase` retrieval works  
  - Anonymous telemetry disabled  
- End-to-end verification: `curl /api/generate` against `$PRIMARY_MODEL` with a "reply ok" prompt (90 s timeout to allow the first cold-start)  
- Strict shell mode (`set -euo pipefail`) and the same `write_if_absent` helper as the Apache script — re-runs **never** clobber `~/.continue/config.json`  
- Override-able env vars at the top:  
  - `OLLAMA_HOST` (default `http://localhost:11434`)  
  - `PRIMARY_MODEL` (default `qwen2.5-coder:7b`) — the model used for the verification ping  

**Why these models, on 16 GB hardware**  

| Model | Use | Disk | Resident at configured context |
|---|---|---:|---:|
| `qwen2.5-coder:7b` | Continue's chat / autocomplete (best 7B coder) | 4.7 GB | ~8 GB at 32 K context |
| `gemma4:e4b` | Chat / docs / multimodal (text + image), configurable thinking modes | 9.6 GB | ~12 GB at 16 K context |
| `nomic-embed-text` | Embeddings for Continue's `@codebase` context provider | 274 MB | ~0.5 GB |

Only one model is loaded at a time (Ollama unloads after ~5 min idle), so the 8 GB and 12 GB figures don't add. Switching between Qwen and Gemma in the Continue dropdown triggers a brief reload (~1–2 s) the first time you swap.

**To add another model**, edit the `LLM_MODELS=( … )` array at the top of the script and re-run, or just:  
```bash
ollama pull qwen2.5-coder:32b      # if you have 32 GB+ unified RAM
```

**Where this fits next to Claude Code**  

|  | Claude Code | Local stack |
|---|---|---|
| **Use for…** | hard agentic tasks, multi-file refactors, planning, "fix this failing test suite" | inline edits, autocomplete, "explain this", privacy-sensitive snippets, offline work |
| **Model** | Anthropic Sonnet / Opus | Qwen 2.5 Coder 7B, Gemma 4 e4b |
| **Network** | required | local-only |
| **Cost** | per-token | electricity |

The two run side by side: `Cmd+L` in VS Code gets you Continue with a local model; `claude` in a terminal gets you the hosted stack. They never step on each other.

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

3. **Run whichever script(s) you need**  

   **Web server stack:**  
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

   **Local LLM stack:**  
   ```bash
   ./mac_setup_llm.sh
   ```

   - First run pulls ~15 GB of model weights and takes a few minutes; subsequent runs are seconds.  
   - Before the first run, make sure VS Code's `code` command is on your `$PATH`: open VS Code → `Cmd+Shift+P` → **"Shell Command: Install 'code' command in PATH"**. Without it the script can't auto-install the Continue extension and will print a clear warning instead.  
   - After install, open any project and start using it:  
     ```bash
     code .                           # open VS Code in this directory
     # Cmd+L                          # opens the Continue chat panel
     # Pick a model from the dropdown above the input box
     # Cmd+I on selected code         # inline edit
     # type @codebase what does this project do?
     ```
   - CLI smoke test without VS Code:  
     ```bash
     ollama run qwen2.5-coder:7b "Refactor this function: ..."
     ollama run gemma4:e4b       "Explain this stack trace: ..."
     ollama ps                        # see what's currently loaded in RAM
     ```  

---

## Daily workflow — mac_setup_apache.sh

The script is designed to be re-run as your environment evolves — every time you change a top-of-script variable, just run `./mac_setup_apache.sh` again. The six most common scenarios:

### 1. Edit your site content

Edit anything under `~/Sites/<domain>/public_html/` (or `~/Sites/index.html`, `phpinfo.php`, `rewrite-test/`, `GoExample/main.go`, etc.). The next `./mac_setup_apache.sh` run will leave your edits alone — you'll see a yellow `! Preserving existing …` line for each file it would otherwise have written.

### 2. Restore a default file you've changed

If you've edited a seed file and want the original template back:

```bash
rm ~/Sites/marchildmann.com.test/public_html/index.html
./mac_setup_apache.sh
```

Only that one file is regenerated; everything else stays put.

### 3. Add a new dev domain

Open `mac_setup_apache.sh`, find the `DEV_DOMAINS=( … )` array near the top, add a line, save, and re-run:

```bash
DEV_DOMAINS=(
  "marchildmann.com.test"
  "iotdata.systems.test"
  "columnlens.com.test"
  "newproject.com.test"   # ← just add a line
)
./mac_setup_apache.sh
```

The script will:
- create `~/Sites/newproject.com.test/public_html/` with a starter `index.html`,
- add `127.0.0.1 newproject.com.test` inside the fenced `/etc/hosts` block,
- regenerate the SSL cert with `newproject.com.test` added to its SANs (and re-trust it in the System keychain),
- append HTTP + HTTPS vhost stanzas for the new domain to `httpd-vhosts.conf`,
- flush the macOS resolver cache,
- restart Apache and verify `https://newproject.com.test/` responds.

Existing domains' content is untouched.

### 4. Remove a dev domain

Delete the line from `DEV_DOMAINS` and re-run. The script will:
- drop the `/etc/hosts` entry,
- regenerate the SSL cert without that SAN,
- regenerate `httpd-vhosts.conf` without the orphaned vhost block.

The on-disk `~/Sites/<old-domain>/` directory is **not** deleted — your content survives even after un-listing. Remove it manually with `rm -rf` if you want.

### 5. Rebuild the GoExample binary

The binary is preserved on re-run once it exists. To rebuild after editing `main.go`:

```bash
cd ~/Sites/GoExample && go build -o releases/goexample .
supervisorctl restart goexample
```

Or, to let the script do it on the next run, delete the binary first:

```bash
rm ~/Sites/GoExample/releases/goexample
./mac_setup_apache.sh
```

### 6. Change a port or proxy path

Top-of-script variables can be overridden per-run via env vars without editing the script:

```bash
GO_PROXY_PORT=9100  GOEXAMPLE_PORT=9101  ./mac_setup_apache.sh
```

The vhosts and supervisor config are regenerated when needed; existing content under `~/Sites/` is preserved (so if you've manually edited `~/Sites/GoExample/public_html/.htaccess` to hard-code the old port, you'll need to `rm` it to pick up the new one).

---

## Daily workflow — mac_setup_llm.sh

Like the Apache script, `mac_setup_llm.sh` is built to be re-run. The most common scenarios:

### 1. Add another model

Edit `LLM_MODELS=( … )` at the top of the script and re-run, or just pull directly:

```bash
ollama pull deepseek-coder-v2:16b      # ~9 GB, strong on refactors
# or edit LLM_MODELS+=("deepseek-coder-v2:16b") and re-run
```

To make the new model show up in the Continue dropdown, add it to the `models` array in `~/.continue/config.json`. Continue auto-detects the file change within a second or two; if not, `Cmd+Shift+P → Continue: Reload Config` forces it.

### 2. Switch which model handles autocomplete vs. chat

Edit `~/.continue/config.json` — the `tabAutocompleteModel` block drives Tab-key completions, the `models` array drives the chat dropdown. Keep autocomplete pinned to a fast 7B model; chat can sit on anything that fits in RAM.

### 3. Bump the context window

Ollama defaults `num_ctx` to 4 K regardless of what the model supports. The script ships with `contextLength: 32768` for Qwen chat and `contextLength: 16384` for Gemma chat, tuned for 16 GB unified memory. On 32 GB+ hardware, bump both (try `65536` or `131072`) in `~/.continue/config.json` and watch RAM with `ollama ps` — each doubling of context roughly doubles KV-cache size.

To start fresh from the script's defaults: `rm ~/.continue/config.json && ./mac_setup_llm.sh`.

### 4. Restart the runtime

```bash
brew services restart ollama          # restart the daemon
ollama ps                             # what's currently loaded
brew services info ollama             # status / last start time
```

Continue auto-reconnects when Ollama comes back up — no need to restart VS Code.

### 5. Force a fresh config

Your `~/.continue/config.json` is preserved across script re-runs by the `write_if_absent` helper. To get the script's default back:

```bash
rm ~/.continue/config.json
./mac_setup_llm.sh
```

### 6. Run against a remote Ollama (e.g. a beefier machine on your LAN)

```bash
OLLAMA_HOST=http://192.168.1.42:11434  ./mac_setup_llm.sh
```

The verification curl and `LLM_MODELS` pull will target that host. You'll still want to edit `~/.continue/config.json`'s `apiBase` fields to match, since those are baked at config-write time.

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

#!/bin/bash

# Local LLM Coding Environment for macOS
# ---------------------------------------
# Sets up Ollama + the Continue VS Code extension and pulls coding-focused
# models for use inside VS Code. Intentionally separate from Claude Code,
# which stays on Anthropic's hosted models for hard agentic tasks — this
# script is for privacy-sensitive snippets, offline work, and high-volume
# completions where a local 7B model is plenty.
#
# Re-run safely at any time. Existing config files under ~/.continue/ are
# preserved (delete them and re-run to regenerate).

set -euo pipefail

### Color codes ###
GREEN='\033[0;32m'; BLUE='\033[0;34m'; YELLOW='\033[0;33m'; RED='\033[0;31m'; NC='\033[0m'

function echo_step    { echo -e "${BLUE}==> $1${NC}"; }
function echo_success { echo -e "${GREEN}✓ $1${NC}"; }
function echo_warn    { echo -e "${YELLOW}! $1${NC}"; }
function echo_error   { echo -e "${RED}✗ $1${NC}"; exit 1; }

# write_if_absent <path>
#   Reads stdin and writes to <path> only if <path> doesn't already exist.
function write_if_absent {
  local path="$1"
  if [[ -e "$path" ]]; then
    cat > /dev/null
    echo_warn "Preserving existing $path (delete it and re-run to regenerate)"
  else
    cat > "$path"
    echo_success "Wrote $path"
  fi
}

### 1) Ensure macOS ###
[[ "$(uname)" == "Darwin" ]] || echo_error "This script runs on macOS only."

### Variables ###
OLLAMA_HOST="${OLLAMA_HOST:-http://localhost:11434}"
PRIMARY_MODEL="${PRIMARY_MODEL:-qwen2.5-coder:7b}"   # used for the verification ping
CONTINUE_CONFIG_DIR="$HOME/.continue"
CONTINUE_CONFIG="$CONTINUE_CONFIG_DIR/config.json"

# Models the script ensures are present locally. Edit and re-run to add more
# (or just `ollama pull <name>:<tag>` directly). Format: name:tag
#
#   qwen2.5-coder:7b   ~4.7 GB  Continue's chat / autocomplete (best 7B coder)
#   gemma4:e4b         ~9.6 GB  Multimodal (text + image), 128K ctx, configurable
#                               thinking modes. ~4B "effective" params via PLE
#                               selective activation; runs ~30 tok/s on M4 16GB.
#                               Great for chat / docs / explaining errors / reading
#                               screenshots — leave Qwen for raw code completion.
#   nomic-embed-text   ~270 MB  embeddings for Continue's @codebase context
#
# Other handy models you might add:
#   qwen2.5-coder:32b  ~20 GB   near-frontier quality, needs 32 GB+ unified RAM
#   gemma4:e2b         ~5.6 GB  Smaller Gemma 4 if you're tight on RAM
#   llama3.1:8b        ~4.7 GB  general-purpose chat / docs / explanations
LLM_MODELS=(
  "qwen2.5-coder:7b"
  "gemma4:e4b"
  "nomic-embed-text"
)

### 2) Homebrew ###
echo_step "Checking Homebrew…"
if ! command -v brew &>/dev/null; then
  echo_error "Homebrew not found. Install it first: https://brew.sh"
fi
echo_success "Homebrew present."

### 3) Install Ollama ###
echo_step "Installing/updating Ollama…"
if brew list ollama &>/dev/null; then
  echo_success "Ollama already installed."
else
  brew install ollama || echo_error "Failed to install Ollama."
  echo_success "Ollama installed."
fi

### 4) Start the Ollama service ###
echo_step "Ensuring Ollama API is reachable at ${OLLAMA_HOST}…"
if ! curl -fsS --max-time 2 "$OLLAMA_HOST/api/tags" >/dev/null 2>&1; then
  brew services start ollama >/dev/null 2>&1 || brew services restart ollama >/dev/null 2>&1 || true
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    if curl -fsS --max-time 2 "$OLLAMA_HOST/api/tags" >/dev/null 2>&1; then
      break
    fi
    sleep 1
  done
fi
if curl -fsS --max-time 2 "$OLLAMA_HOST/api/tags" >/dev/null 2>&1; then
  OLLAMA_VERSION=$(ollama --version 2>/dev/null | grep -i 'version' | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' || true)
  echo_success "Ollama API reachable${OLLAMA_VERSION:+ (v$OLLAMA_VERSION)}."
else
  echo_warn "Ollama API not responding. Try: brew services info ollama  (or run 'ollama serve' manually)"
fi

### 5) Pull models (skip ones already pulled) ###
echo_step "Ensuring models are pulled (first-time downloads can take several minutes)…"
INSTALLED_MODELS=$(ollama list 2>/dev/null | awk 'NR>1 {print $1}' || true)
for model in "${LLM_MODELS[@]}"; do
  # ollama list always shows an explicit tag; normalize untagged entries to :latest
  expected="$model"
  [[ "$model" == *:* ]] || expected="${model}:latest"
  if printf '%s\n' "$INSTALLED_MODELS" | grep -Fxq "$expected"; then
    echo_success "$model already pulled"
  else
    echo_step "Pulling ${model}…"
    if ollama pull "$model"; then
      echo_success "$model pulled"
    else
      echo_warn "Failed to pull $model — check the model name and your network."
    fi
  fi
done

### 6) Install the Continue VS Code extension ###
echo_step "Configuring VS Code…"
if ! command -v code &>/dev/null; then
  echo_warn "VS Code 'code' command not on PATH. Open VS Code → Cmd+Shift+P → 'Shell Command: Install code command in PATH', then re-run."
else
  if code --list-extensions 2>/dev/null | grep -Fxq "Continue.continue"; then
    echo_success "Continue extension already installed."
  else
    code --install-extension Continue.continue >/dev/null
    echo_success "Continue extension installed."
  fi
fi

### 7) Continue config (preserved if it already exists) ###
mkdir -p "$CONTINUE_CONFIG_DIR"
write_if_absent "$CONTINUE_CONFIG" <<'EOF'
{
  "models": [
    {
      "title": "Qwen 2.5 Coder 7B (local) — code",
      "provider": "ollama",
      "model": "qwen2.5-coder:7b",
      "apiBase": "http://localhost:11434"
    },
    {
      "title": "Gemma 4 e4b (local) — chat / docs / multimodal",
      "provider": "ollama",
      "model": "gemma4:e4b",
      "apiBase": "http://localhost:11434"
    }
  ],
  "tabAutocompleteModel": {
    "title": "Qwen 2.5 Coder 7B (autocomplete)",
    "provider": "ollama",
    "model": "qwen2.5-coder:7b",
    "apiBase": "http://localhost:11434"
  },
  "embeddingsProvider": {
    "provider": "ollama",
    "model": "nomic-embed-text",
    "apiBase": "http://localhost:11434"
  },
  "contextProviders": [
    { "name": "code"     },
    { "name": "docs"     },
    { "name": "diff"     },
    { "name": "terminal" },
    { "name": "open"     },
    { "name": "codebase" },
    { "name": "folder"   }
  ],
  "slashCommands": [
    { "name": "edit",    "description": "Edit selected code" },
    { "name": "comment", "description": "Add comments to code" },
    { "name": "share",   "description": "Export the chat" }
  ],
  "allowAnonymousTelemetry": false
}
EOF

### 8) Verify end-to-end with a tiny prompt ###
echo_step "Verifying end-to-end (first call may take ~10-30 s while the model warms up)…"
VERIFY_BODY="{\"model\":\"$PRIMARY_MODEL\",\"prompt\":\"Reply with the single word ok.\",\"stream\":false}"
RESPONSE=$(curl -sS --max-time 90 "$OLLAMA_HOST/api/generate" \
            -H 'Content-Type: application/json' \
            -d "$VERIFY_BODY" 2>/dev/null \
          | grep -o '"response":"[^"]*"' | head -1 || true)
if [[ -n "$RESPONSE" ]]; then
  echo_success "Model responded: $RESPONSE"
else
  echo_warn "Model didn't respond. Try manually: ollama run $PRIMARY_MODEL 'hello'"
fi

### Done ###
INSTALLED_LIST=$(ollama list 2>/dev/null | awk 'NR>1 {printf "    - %s (%s)\n", $1, $3$4}' || true)
echo_success "Local LLM coding environment ready!
  • Ollama API     $OLLAMA_HOST
  • Models pulled:
${INSTALLED_LIST:-    (none — check 'ollama list')}
  • VS Code        Continue.continue extension (Cmd+L = chat panel, Cmd+I = inline edit)
  • Config         $CONTINUE_CONFIG"
echo -e "${BLUE}Next steps:${NC}
  1. Open a project:           code .
  2. Open the Continue panel:  Cmd+L
  3. Pick a model:             dropdown above the chat input
                                  - Qwen 2.5 Coder 7B → code generation, refactors, autocomplete
                                  - Gemma 4 e4b       → chat / docs / explaining errors / multimodal
  4. Try inline edit:          select code, Cmd+I, describe the change
  5. Try @codebase context:    Cmd+L, then type '@codebase' followed by a question
${BLUE}Daily workflow:${NC}
  • Add another model:         edit LLM_MODELS at the top and re-run, or 'ollama pull <name>:<tag>'
  • Switch model in Continue:  edit ~/.continue/config.json (or Cmd+Shift+P → 'Continue: Add Model')
  • Stop / start the runtime:  brew services {stop,start,restart} ollama
  • Check what's loaded:       ollama ps
${BLUE}Stays separate from Claude Code — keep using 'claude' for hard agentic tasks.${NC}"

exit 0

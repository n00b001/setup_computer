#!/usr/bin/env bash
# setup.sh — one-shot terminal environment bootstrap
#
# Platforms: macOS, Linux, Windows (WSL). For native Windows run setup.ps1
#            from PowerShell instead — this script exits with that hint if it
#            detects Git Bash/MSYS/Cygwin.
#
# Installs : Homebrew (macOS and Linux/WSL); CLI: starship bat fzf ripgrep eza
#            jq gh git git-delta zoxide btop node tmux uv awscli + 2 zsh plugins
#            (autosuggestions, syntax-highlighting) + fzf-tab; uv-managed
#            Python, Claude Code plugins, MCP servers,
#            codegraph, claude-auto-retry
#            macOS only: Ghostty, 1Password (+CLI), Rectangle, JetBrains
#            Toolbox, Ice, OrbStack, Stats, Claude Code cask,
#            JetBrainsMono Nerd Font cask
#            Linux: JetBrainsMono Nerd Font (nerd-fonts release tarball),
#            Claude Code native installer
#            WSL: Claude Code native installer; GUI/font/1Password pieces are
#            skipped — run setup.ps1 on the Windows side for those
# Writes   : ~/.zshrc  ~/.config/starship.toml  ~/.vimrc  ~/.tmux.conf
#            macOS/Linux: ~/.config/ghostty/config
#            macOS: /etc/pam.d/sudo_local, ~/.ssh/config (1Password agent),
#                   ~/.claude-auto-retry/bin/{pgrep,ps} shims, reconcile
#                   LaunchAgent
#            Linux: ~/.ssh/config (1Password agent, only if 1Password
#                   desktop is present), claude-auto-retry systemd user timer
#            ~/.gitconfig (delta pager everywhere; SSH commit signing via
#            1Password wherever op-ssh-sign is found)
#
# Anything that cannot work on the current platform is skipped with a log
# line and listed in the summary at the end.
#
# Unattended: asks for your sudo password once, up front, then runs with no
# further prompts. Homebrew 6 ask-mode is disabled (HOMEBREW_NO_ASK=1), its
# installer gets NONINTERACTIVE=1, apt runs with DEBIAN_FRONTEND=noninteractive,
# chsh goes through sudo, claude plugin/mcp commands read stdin from /dev/null,
# codegraph uses --yes.
# A failed install no longer aborts the run: it is listed under "Failed
# installs" in the summary and every config file is still written.
# Existing files are backed up as <file>.bak.<timestamp> before being replaced.
# Re-running is safe.

set -Eeuo pipefail

# ── unattended mode ──────────────────────────────────────────────────────────
# Homebrew 6 turned on "ask mode": brew install stops at a "Do you want to
# proceed?" prompt when run from a terminal. HOMEBREW_NO_ASK=1 answers yes to
# all of them; NONINTERACTIVE=1 keeps the Homebrew *installer* from pausing on
# "Press RETURN"; DEBIAN_FRONTEND silences apt's config-file prompts.
export HOMEBREW_NO_ASK=1
export NONINTERACTIVE=1
export HOMEBREW_NO_ENV_HINTS=1
export DEBIAN_FRONTEND=noninteractive

# if something still dies (set -e), say where instead of exiting silently
trap 'echo "✗ setup.sh: failed at line $LINENO: $BASH_COMMAND" >&2' ERR

# ── platform detection ───────────────────────────────────────────────────────
case "$(uname -s)" in
  Darwin) PLATFORM=macos ;;
  Linux)
    if grep -qi microsoft /proc/version 2>/dev/null; then
      PLATFORM=wsl
    else
      PLATFORM=linux
    fi ;;
  MINGW*|MSYS*|CYGWIN*)
    echo "Native Windows detected. Run the PowerShell script instead:"
    echo "  powershell -ExecutionPolicy Bypass -File setup.ps1"
    exit 1 ;;
  *)
    echo "Unsupported platform: $(uname -s)"; exit 1 ;;
esac
echo "Platform: $PLATFORM"

# One sudo prompt up front, then a background refresher keeps the credential
# cache warm so no later step (apt, /etc/shells, chsh, cask installers) blocks
# the unattended run waiting for a password.
if command -v sudo >/dev/null 2>&1 && sudo -v; then
  ( while kill -0 "$$" 2>/dev/null; do sudo -n true 2>/dev/null; sleep 60; done ) &
  SUDO_KEEPALIVE=$!
  trap 'kill "$SUDO_KEEPALIVE" 2>/dev/null || true' EXIT
else
  echo "warn: could not cache sudo credentials; steps needing root may fail"
fi

timestamp="$(date +%Y%m%d-%H%M%S)"

backup() {
  if [[ -e "$1" ]]; then
    if cp -p "$1" "$1.bak.$timestamp"; then
      echo "    backed up $1 -> $1.bak.$timestamp"
    else
      echo "    warn: could not back up $1; continuing"
    fi
  fi
}

SKIPPED=()
skip() {  # skip <what> <why>
  echo "    skip [$PLATFORM]: $1 — $2"
  SKIPPED+=("$1 — $2")
}

FAILED=()
fail() {  # fail <what> — log a non-fatal failure and keep going
  echo "    warn: $1 failed; continuing"
  FAILED+=("$1")
}

# ─────────────────────────────────────────────────────────────────────────────
echo "== 1/13 Homebrew =="
if ! command -v brew >/dev/null 2>&1; then
  if [[ "$PLATFORM" != macos ]]; then
    # Homebrew-on-Linux prerequisites (per its docs), plus zsh for step 4
    if command -v apt-get >/dev/null 2>&1; then
      sudo apt-get update || fail "apt-get update"
      sudo apt-get install -y build-essential procps curl file git zsh \
        || fail "apt prerequisites (build-essential procps curl file git zsh)"
    elif command -v dnf >/dev/null 2>&1; then
      sudo dnf group install -y development-tools 2>/dev/null \
        || sudo dnf groupinstall -y 'Development Tools' \
        || fail "dnf Development Tools"
      sudo dnf install -y procps-ng curl file git zsh || fail "dnf prerequisites"
    elif command -v pacman >/dev/null 2>&1; then
      sudo pacman -Sy --noconfirm --needed base-devel procps-ng curl file git zsh \
        || fail "pacman prerequisites"
    else
      echo "    warn: unknown package manager; ensure gcc, curl, file, git and zsh are installed"
    fi
  fi
  NONINTERACTIVE=1 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)" \
    || echo "    warn: Homebrew installer failed"
fi
for _brew in /opt/homebrew/bin/brew /usr/local/bin/brew \
             /home/linuxbrew/.linuxbrew/bin/brew "$HOME/.linuxbrew/bin/brew"; do
  if [[ -x "$_brew" ]]; then
    eval "$("$_brew" shellenv)"
    break
  fi
done
if ! command -v brew >/dev/null 2>&1; then
  echo "✗ Homebrew is not installed or not on PATH; cannot continue" >&2
  exit 1
fi
BREW_PREFIX="${HOMEBREW_PREFIX:-$(brew --prefix)}"
if ! grep -q 'brew shellenv' ~/.zprofile 2>/dev/null; then
  printf 'eval "$(%s/bin/brew shellenv)"\n' "$BREW_PREFIX" >> ~/.zprofile
fi

# ─────────────────────────────────────────────────────────────────────────────
echo "== 2/13 Formulas =="
formulas=(starship bat fzf ripgrep eza
          zsh-autosuggestions zsh-syntax-highlighting fzf-tab
          jq gh git git-delta zoxide btop node tmux uv awscli)
for f in "${formulas[@]}"; do
  brew list "$f" >/dev/null 2>&1 && continue
  brew install "$f" </dev/null || fail "brew install $f"
done

# default interactive shell: zsh (macOS already ships with it as default)
if [[ "$PLATFORM" != macos ]]; then
  if ! command -v zsh >/dev/null 2>&1; then
    brew install zsh </dev/null || fail "brew install zsh"
  fi
  ZSH_PATH="$(command -v zsh || true)"
  if [[ -z "$ZSH_PATH" ]]; then
    skip "default shell -> zsh" "zsh is not installed"
  elif [[ "${SHELL:-}" != *zsh* ]]; then
    if ! grep -qx "$ZSH_PATH" /etc/shells 2>/dev/null; then
      echo "$ZSH_PATH" | sudo tee -a /etc/shells >/dev/null \
        || fail "adding $ZSH_PATH to /etc/shells"
    fi
    # chsh via sudo: run directly it stops at a password prompt on Linux
    sudo chsh -s "$ZSH_PATH" "${USER:-$(id -un)}" \
      && echo "    default shell set to $ZSH_PATH (takes effect on next login)" \
      || echo "    warn: chsh failed; run: chsh -s $ZSH_PATH"
  fi
fi

# ─────────────────────────────────────────────────────────────────────────────
echo "== 3/13 Apps =="
if [[ "$PLATFORM" == macos ]]; then
  casks=(ghostty 1password 1password-cli font-jetbrains-mono-nerd-font
         rectangle jetbrains-toolbox jordanbaird-ice orbstack stats claude-code)
  for c in "${casks[@]}"; do
    brew list --cask "$c" >/dev/null 2>&1 && continue
    brew install --cask "$c" </dev/null || fail "brew install --cask $c"
  done
else
  # Claude Code: official native installer (no cask off macOS)
  if ! command -v claude >/dev/null 2>&1; then
    curl -fsSL https://claude.ai/install.sh | bash \
      || echo "    warn: Claude Code installer failed"
    export PATH="$HOME/.local/bin:$PATH"
    hash -r
  fi

  # JetBrainsMono Nerd Font
  if [[ "$PLATFORM" == linux ]]; then
    FONT_DIR="$HOME/.local/share/fonts/JetBrainsMonoNerdFont"
    if [[ ! -d "$FONT_DIR" ]]; then
      font_tmp="$(mktemp -d)"
      if curl -fsSL -o "$font_tmp/JetBrainsMono.tar.xz" \
           https://github.com/ryanoasis/nerd-fonts/releases/latest/download/JetBrainsMono.tar.xz; then
        mkdir -p "$FONT_DIR"
        if tar -xf "$font_tmp/JetBrainsMono.tar.xz" -C "$FONT_DIR"; then
          { command -v fc-cache >/dev/null 2>&1 && fc-cache -f "$FONT_DIR" >/dev/null; } || true
          echo "    installed JetBrainsMono Nerd Font to $FONT_DIR"
        else
          rm -rf "$FONT_DIR"
          fail "JetBrainsMono Nerd Font extract"
        fi
      else
        fail "JetBrainsMono Nerd Font download"
      fi
      rm -rf "$font_tmp"
    fi
  else
    skip "JetBrainsMono Nerd Font" "fonts live on the Windows side; run setup.ps1 in PowerShell"
  fi

  # GUI apps
  if [[ "$PLATFORM" == wsl ]]; then
    skip "Ghostty" "WSL uses Windows Terminal; run setup.ps1 on the Windows side"
    skip "1Password (+CLI)" "install on the Windows side via setup.ps1"
  else
    command -v ghostty >/dev/null 2>&1 \
      || skip "Ghostty" "no universal Linux package; see https://ghostty.org/download (config is still written)"
    [[ -d /opt/1Password ]] \
      || skip "1Password (+CLI)" "install the Linux desktop app from https://1password.com/downloads/linux"
  fi
  skip "Rectangle" "macOS-only window manager"
  skip "JetBrains Toolbox" "install manually from jetbrains.com/toolbox-app (Linux tarball / Windows installer)"
  skip "Ice" "macOS-only menu bar manager"
  skip "OrbStack" "macOS-only; use Docker Engine or Docker Desktop instead"
  skip "Stats" "macOS-only menu bar monitor (btop is installed)"
fi

# ─────────────────────────────────────────────────────────────────────────────
echo "== 4/13 ~/.zshrc =="
backup ~/.zshrc
cat > ~/.zshrc << 'ZSHRC'
# ── Homebrew on PATH (Linux terminals start non-login shells; harmless on macOS) ──
for _brew in /opt/homebrew/bin/brew /usr/local/bin/brew \
             /home/linuxbrew/.linuxbrew/bin/brew "$HOME/.linuxbrew/bin/brew"; do
  if [[ -x "$_brew" ]]; then
    eval "$("$_brew" shellenv)"
    break
  fi
done
unset _brew

# ── completion: fix insecure directories, then init ──
autoload -Uz compinit compaudit

function fix_compinit_insecure_dirs() {
  local insecure_dirs=$(compaudit 2>/dev/null)
  if [[ -n "$insecure_dirs" ]]; then
    echo "Fixing insecure completion directories..."
    for dir in ${(f)insecure_dirs}; do
      chmod 755 "$dir"
      chmod 755 "$(dirname "$dir")"
    done
  fi
}
fix_compinit_insecure_dirs

# full compinit if the dump is missing or older than a day, cached -C otherwise
if [[ ! -e ~/.zcompdump || -n "$(find ~/.zcompdump -mtime +0 2>/dev/null)" ]]; then
  compinit
else
  compinit -C
fi

zstyle ':completion:*' matcher-list '' 'm:{a-zA-Z}={A-Za-z}'
zstyle ':completion:*' menu no
zstyle ':completion:*:descriptions' format '[%d]'
zstyle ':completion:*' list-colors ${(s.:.)LS_COLORS}

# ── fzf-tab: after compinit, before widget-wrapping plugins ──
# every completion menu (vim <tab>, cd <tab>, git <tab>, ...) becomes an fzf search
if [[ -r "$(brew --prefix)/share/fzf-tab/fzf-tab.zsh" ]]; then
  source "$(brew --prefix)/share/fzf-tab/fzf-tab.zsh"
  zstyle ':fzf-tab:complete:cd:*' fzf-preview 'eza -1 --color=always $realpath'
  zstyle ':fzf-tab:complete:(vim|nvim|vi|nano|bat|cat|less|code):*' fzf-preview \
    '[[ -f $realpath ]] && bat --color=always --style=numbers --line-range=:200 $realpath || eza -1 --color=always $realpath 2>/dev/null'
  zstyle ':fzf-tab:*' switch-group '<' '>'
fi

# ── prompt ──
command -v starship >/dev/null 2>&1 && eval "$(starship init zsh)"

# ── fzf: ctrl-r history, ctrl-t files, alt-c cd ──
if command -v fzf >/dev/null 2>&1; then
  source <(fzf --zsh)
  export FZF_DEFAULT_COMMAND='rg --files --hidden --glob "!.git"'
  export FZF_CTRL_T_COMMAND="$FZF_DEFAULT_COMMAND"
fi

# ── suggestions and highlighting ──
ZSH_AUTOSUGGEST_STRATEGY=(history completion)
[[ -r "$(brew --prefix)/share/zsh-autosuggestions/zsh-autosuggestions.zsh" ]] && \
  source "$(brew --prefix)/share/zsh-autosuggestions/zsh-autosuggestions.zsh"
[[ -r "$(brew --prefix)/share/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh" ]] && \
  source "$(brew --prefix)/share/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh"

# ── up-arrow: pop up an fzf list of history entries that start with what you
#    have already typed (newest first). Enter fills the line (does not run it),
#    Esc cancels and keeps what you were typing. With an empty line, up shows
#    the whole history. Falls back to a plain history step when fzf is missing
#    or the line spans multiple rows. Down keeps normal forward-history motion. ──
fzf-history-prefix-up() {
  if [[ $BUFFER == *$'\n'* ]] || ! command -v fzf >/dev/null 2>&1; then
    zle up-line-or-history
    return
  fi
  local prefix=$LBUFFER selected
  # fc -rln 1: whole history, newest first, no line numbers.
  # awk (prefix via ENVIRON so it is a literal string, not a regex/escape):
  # keep lines that start with the prefix, drop duplicates, preserve order.
  selected=$(
    fc -rln 1 | prefix="$prefix" awk \
      'BEGIN{p=ENVIRON["prefix"]} (p=="" || index($0,p)==1) && !seen[$0]++' \
    | fzf --height=40% --layout=reverse --border --no-sort --tiebreak=index \
          --query='' --prompt="history ▸ ${prefix} " \
          --header='↑/↓ move · enter accept · esc cancel'
  )
  if [[ -n $selected ]]; then
    BUFFER=$selected
    CURSOR=${#BUFFER}
  fi
  zle reset-prompt
}
zle -N fzf-history-prefix-up
bindkey '^[[A' fzf-history-prefix-up
bindkey '^[OA' fzf-history-prefix-up
bindkey '^[[B' down-line-or-history
bindkey '^[OB' down-line-or-history

# ── word movement and deletion ──
bindkey -e
bindkey '^[[1;5D' backward-word
bindkey '^[[1;5C' forward-word
bindkey '^[b'     backward-word
bindkey '^[f'     forward-word
bindkey '^H'      backward-kill-word
bindkey '^[^?'    backward-kill-word
bindkey '^[[3;5~' kill-word
bindkey '^[[3;3~' kill-word
bindkey '^U'      backward-kill-line

# ── history ──
# HISTFILE must be set explicitly: zsh does not default it. macOS's /etc/zshrc
# sets it before this file runs, but Linux has no such default — without it
# SAVEHIST has nowhere to write, history never persists, and up-arrow
# prefix-search finds nothing in a new terminal.
HISTFILE="$HOME/.zsh_history"
HISTSIZE=100000
SAVEHIST=100000
setopt SHARE_HISTORY HIST_IGNORE_ALL_DUPS HIST_FIND_NO_DUPS

# ── uv: astral toolchain ──
export PATH="$HOME/.local/bin:$PATH"
command -v uv  >/dev/null 2>&1 && eval "$(uv generate-shell-completion zsh)"
command -v uvx >/dev/null 2>&1 && eval "$(uvx --generate-shell-completion zsh)"

# ── CUDA toolkit on PATH when installed (so nvcc + cuBLAS tools are found) ──
# Guarded on the dir, so this is a no-op on macOS / non-CUDA machines.
if [[ -d /usr/local/cuda/bin ]]; then
  export PATH="/usr/local/cuda/bin:$PATH"
  export LD_LIBRARY_PATH="/usr/local/cuda/lib64:${LD_LIBRARY_PATH:-}"
fi

# ── replacements ──
if command -v eza >/dev/null 2>&1; then
  # --sort=modified: oldest at the top, newest at the bottom. It also drops
  # eza's default "directories first" grouping, so files and dirs interleave
  # purely by mtime. Note eza's -t is "which timestamp" (not ls's sort-by-time)
  # and -r reverses, so append -r for newest-first; the old ls '-tr' errors.
  alias ls='eza --icons --sort=modified'
  alias ll='eza -la --icons --git --sort=modified'
  alias lt='eza --tree --level=2 --icons'
fi
# cat -> bat: syntax highlighting, but no pager so it still behaves like cat
# (Debian/Ubuntu's apt package installs the binary as batcat)
if command -v bat >/dev/null 2>&1; then
  alias cat='bat --paging=never'
elif command -v batcat >/dev/null 2>&1; then
  alias cat='batcat --paging=never'
fi
export BAT_THEME="TwoDark"
command -v zoxide >/dev/null 2>&1 && eval "$(zoxide init zsh)"    # z <fragment> jumps to frecent directories

# ── keep Homebrew completion permissions sane after brew operations ──
function brew_with_fixed_permissions() {
  command brew "$@"
  if [[ "$1" == "update" || "$1" == "upgrade" || "$1" == "install" || "$1" == "link" ]]; then
    chmod 755 "$(brew --prefix)"/share/zsh/site-functions/_* 2>/dev/null
  fi
}
alias brew=brew_with_fixed_permissions
ZSHRC
echo "    wrote ~/.zshrc"

# ─────────────────────────────────────────────────────────────────────────────
echo "== 5/13 Ghostty config =="
if [[ "$PLATFORM" == wsl ]]; then
  skip "Ghostty config" "WSL uses Windows Terminal"
else
  mkdir -p ~/.config/ghostty
  backup ~/.config/ghostty/config
  cat > ~/.config/ghostty/config << 'GHOSTTY'
font-family = JetBrainsMono Nerd Font
font-size = 13
theme = Catppuccin Mocha
# auto light/dark alternative:
# theme = dark:Catppuccin Mocha,light:Catppuccin Latte
cursor-style = block
window-padding-x = 8
window-padding-y = 8
GHOSTTY
  if [[ "$PLATFORM" == macos ]]; then
    cat >> ~/.config/ghostty/config << 'GHOSTTY_MAC'
macos-titlebar-style = tabs

# cmd+backspace deletes to line start (pairs with bindkey '^U' in .zshrc)
keybind = super+backspace=text:\x15
GHOSTTY_MAC
  fi
  echo "    wrote ~/.config/ghostty/config"
fi

# ─────────────────────────────────────────────────────────────────────────────
echo "== 6/13 Starship preset =="
mkdir -p ~/.config
backup ~/.config/starship.toml
starship preset catppuccin-powerline -o ~/.config/starship.toml --force \
  && echo "    wrote ~/.config/starship.toml" \
  || fail "starship preset catppuccin-powerline"

# ─────────────────────────────────────────────────────────────────────────────
echo "== 7/13 ~/.vimrc =="
backup ~/.vimrc
cat > ~/.vimrc << 'VIMRC'
" restore vim's shipped defaults (syntax on, ruler, wildmenu),
" which vim skips as soon as a ~/.vimrc exists
unlet! skip_defaults_vim
if !empty($VIMRUNTIME) && filereadable($VIMRUNTIME . '/defaults.vim')
  source $VIMRUNTIME/defaults.vim
endif

syntax on
filetype plugin indent on
set backspace=indent,eol,start
set ttimeout ttimeoutlen=30

" ctrl+arrows: word jumps
noremap  <C-Left>  b
noremap  <C-Right> w
inoremap <C-Left>  <C-o>b
inoremap <C-Right> <C-o>w

" opt+arrows: Ghostty sends esc b / esc f
noremap  <Esc>b b
noremap  <Esc>f w
inoremap <Esc>b <C-o>b
inoremap <Esc>f <C-o>w

" ctrl+backspace arrives as ^H: delete previous word
inoremap <C-h> <C-w>
cnoremap <C-h> <C-w>
VIMRC
echo "    wrote ~/.vimrc"

# ─────────────────────────────────────────────────────────────────────────────
echo "== 8/13 Sudo auth + 1Password SSH agent =="
if [[ "$PLATFORM" == macos ]]; then
  if [[ -f /etc/pam.d/sudo_local ]] && grep -q '^auth.*pam_tid' /etc/pam.d/sudo_local; then
    echo "    Touch ID for sudo already enabled"
  elif [[ -f /etc/pam.d/sudo_local.template ]]; then
    echo "    enabling Touch ID for sudo"
    sudo sh -c 'sed "s/^#auth/auth/" /etc/pam.d/sudo_local.template > /etc/pam.d/sudo_local' \
      || fail "Touch ID for sudo"
  else
    echo "    /etc/pam.d/sudo_local.template not found; skipping Touch ID setup"
  fi
else
  skip "Touch ID for sudo" "macOS-only"
fi

mkdir -p ~/.ssh && chmod 700 ~/.ssh
case "$PLATFORM" in
  macos) OP_AGENT_SOCK='"~/Library/Group Containers/2BUA8C4S2C.com.1password/t/agent.sock"' ;;
  linux) OP_AGENT_SOCK='~/.1password/agent.sock' ;;
  wsl)   OP_AGENT_SOCK='' ;;
esac
if [[ "$PLATFORM" == wsl ]]; then
  skip "1Password SSH agent" "needs npiperelay/wsl2-ssh-agent to bridge to the Windows agent; set up manually if wanted"
elif [[ "$PLATFORM" == linux && ! -d /opt/1Password ]]; then
  skip "1Password SSH agent" "1Password desktop not installed; re-run after installing it"
elif ! grep -q '1password\|1Password' ~/.ssh/config 2>/dev/null; then
  cat >> ~/.ssh/config << SSH

Host *
  IdentityAgent $OP_AGENT_SOCK
SSH
  chmod 600 ~/.ssh/config
  echo "    added 1Password IdentityAgent to ~/.ssh/config"
else
  echo "    1Password IdentityAgent already in ~/.ssh/config"
fi

# ─────────────────────────────────────────────────────────────────────────────
echo "== 9/13 Git: commit signing via 1Password + delta pager =="
if ! command -v git >/dev/null 2>&1; then
  skip "git config (delta pager + signing)" "git not installed"
else
git config --global core.pager delta \
  && git config --global interactive.diffFilter "delta --color-only" \
  && git config --global delta.navigate true \
  || fail "git config (delta pager)"

OP_SIGN=""
case "$PLATFORM" in
  macos) OP_SIGN="/Applications/1Password.app/Contents/MacOS/op-ssh-sign" ;;
  linux) OP_SIGN="/opt/1Password/op-ssh-sign" ;;
  wsl)
    for f in /mnt/c/Users/*/AppData/Local/1Password/app/*/op-ssh-sign.exe; do
      [[ -e "$f" ]] && OP_SIGN="$f" && break
    done ;;
esac
if [[ -n "$OP_SIGN" && -e "$OP_SIGN" ]]; then
  git config --global gpg.format ssh \
    && git config --global gpg.ssh.program "$OP_SIGN" \
    && git config --global user.signingkey "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIA+kyRFBfXb0h7c2SS6Ue/PubsqRlUKSlXr/uBcEsLnN" \
    && git config --global commit.gpgsign true \
    && echo "    signing + delta configured; signing works once 1Password holds this key and the agent is on" \
    || fail "git config (1Password signing)"
else
  skip "git commit signing via 1Password" "op-ssh-sign not found (install 1Password desktop, then re-run); delta pager still configured"
fi
fi  # git guard

# ─────────────────────────────────────────────────────────────────────────────
echo "== 10/13 uv: default Python =="
uv python install || echo "    warn: uv python install failed"

# ─────────────────────────────────────────────────────────────────────────────
echo "== 11/13 Claude Code plugins =="
if command -v claude >/dev/null 2>&1; then
  # </dev/null: without a tty these commands skip their [y/n] prompt and proceed
  run_claude() { "$@" </dev/null || echo "    warn: '$*' failed. Run 'claude' once to authenticate, then re-run this script."; }
  add_marketplace() { claude plugin marketplace add "$1" </dev/null >/dev/null 2>&1 || true; }

  add_marketplace https://github.com/Yeachan-Heo/oh-my-claudecode
  run_claude claude plugin install oh-my-claudecode

  add_marketplace martinemde/starship-claude
  run_claude claude plugin install starship-claude@starship-claude

  add_marketplace astral-sh/claude-code-plugins
  run_claude claude plugin install astral@astral-sh

  add_marketplace mksglu/context-mode
  run_claude claude plugin install context-mode@context-mode

  add_marketplace Digital-Process-Tools/claude-marketplace
  run_claude claude plugin install remember@dpt-plugins

  # ponytail: pushes the agent toward the smallest solution that works
  # (needs node on PATH for its lifecycle hooks — installed above)
  add_marketplace DietrichGebert/ponytail
  run_claude claude plugin install ponytail@ponytail

  # ty LSP plugin installs from a local clone, per its README
  TY_DIR="$HOME/.claude-tools/ty-lsp-claude-code"
  if [[ ! -d "$TY_DIR" ]]; then
    git clone --depth 1 https://github.com/ilepn/ty-lsp-claude-code "$TY_DIR" \
      || fail "git clone ty-lsp-claude-code"
  fi
  if [[ -d "$TY_DIR" ]]; then
    (cd "$TY_DIR" && run_claude claude plugin install .)
  fi

  # codegraph CLI, then wire it to Claude Code non-interactively
  if ! command -v codegraph >/dev/null 2>&1; then
    curl -fsSL https://raw.githubusercontent.com/colbymchenry/codegraph/main/install.sh | sh \
      || echo "    warn: codegraph installer failed"
    hash -r
  fi
  CG_BIN="$(command -v codegraph || true)"
  [[ -z "$CG_BIN" && -x "$HOME/.local/bin/codegraph" ]] && CG_BIN="$HOME/.local/bin/codegraph"
  if [[ -n "$CG_BIN" ]]; then
    "$CG_BIN" install --target=claude --yes </dev/null \
      || echo "    warn: codegraph install --target=claude failed; run it manually in a new terminal"
  else
    echo "    warn: codegraph not on PATH yet; run 'codegraph install --target=claude --yes' in a new terminal"
  fi
else
  echo "    warn: claude not on PATH yet; open a new terminal and re-run this script"
fi

# ─────────────────────────────────────────────────────────────────────────────
echo "== 12/13 Claude Code MCP servers =="
if command -v claude >/dev/null 2>&1; then
  # -y keeps npx non-interactive; MCP servers launch without a tty
  claude mcp get playwright >/dev/null 2>&1 || \
    claude mcp add --scope user playwright -- npx -y @playwright/mcp@latest </dev/null \
    || echo "    warn: adding playwright MCP failed"
  claude mcp get puppeteer >/dev/null 2>&1 || \
    claude mcp add --scope user puppeteer -- npx -y puppeteer-mcp-server </dev/null \
    || echo "    warn: adding puppeteer MCP failed"
fi

# ─────────────────────────────────────────────────────────────────────────────
echo "== 13/13 Usage-limit auto-resume: claude-auto-retry =="
if ! command -v npm >/dev/null 2>&1; then
  skip "claude-auto-retry" "npm not on PATH (node install failed?)"
else
# Install from GitHub, not the npm registry: the published tarball lags the repo
# and is missing reconcile, the systemd/ templates and bin/tmux-status.sh.
npm install -g "github:cheapestinference/claude-auto-retry" >/dev/null 2>&1 \
  || npm install -g "github:cheapestinference/claude-auto-retry" \
  || fail "npm install claude-auto-retry"
claude-auto-retry install </dev/null || echo "    warn: claude-auto-retry install failed"
# StopFailure hook: event-driven overload detection (no terminal scraping)
claude-auto-retry install-hook </dev/null || echo "    warn: claude-auto-retry install-hook failed"

CAR_ROOT="$(npm root -g 2>/dev/null || true)"
CAR_PKG="${CAR_ROOT:+$CAR_ROOT/claude-auto-retry}"
if [[ -z "$CAR_PKG" || ! -d "$CAR_PKG" ]]; then
  skip "claude-auto-retry tmux indicator + reconcile timer" "package not installed (npm install failed?)"
else

if [[ "$PLATFORM" == macos ]]; then
  CAR_BIN_DIR="$HOME/.claude-auto-retry/bin"
  mkdir -p "$CAR_BIN_DIR" "$HOME/.claude-auto-retry/logs"

  # GNU→BSD shims: reconcile probes monitors with `pgrep -af` (GNU "print full args";
  # macOS pgrep spells that -fl) and matches claude processes by ps comm == "claude"
  # (Linux short name; macOS comm is the executable path, truncated to 16 chars).
  # Shimming in a private dir keeps the fixes across package updates and off the
  # global PATH — only the LaunchAgent and the zsh wrapper function below use it.
  cat > "$CAR_BIN_DIR/pgrep" << 'PGREP_SHIM'
#!/bin/sh
# pgrep shim for claude-auto-retry on macOS: GNU `pgrep -af` -> BSD `pgrep -fl`.
if [ "$1" = "-af" ]; then
  shift
  exec /usr/bin/pgrep -fl "$@"
fi
exec /usr/bin/pgrep "$@"
PGREP_SHIM
  cat > "$CAR_BIN_DIR/ps" << 'PS_SHIM'
#!/bin/sh
# ps shim for claude-auto-retry on macOS: rewrite the comm column to the basename
# of the first args token (macOS comm is a 16-char-truncated path, never "claude").
if [ $# -eq 2 ] && [ "$1" = "-eo" ] && [ "$2" = "pid=,ppid=,stat=,comm=,args=" ]; then
  /bin/ps -eo pid=,ppid=,stat=,comm=,args= | awk '{
    src = ($5 != "") ? $5 : $4
    n = split(src, a, "/"); $4 = a[n]; print
  }'
  exit $?
fi
exec /bin/ps "$@"
PS_SHIM
  chmod +x "$CAR_BIN_DIR/pgrep" "$CAR_BIN_DIR/ps"

  # zsh wrapper so manual reconcile/exclude-self runs also use the shims
  if ! grep -q 'claude-auto-retry macOS shims' ~/.zshrc 2>/dev/null; then
    cat >> ~/.zshrc << 'CAR_FN'

# >>> claude-auto-retry macOS shims >>>
# reconcile/exclude-self expect GNU-style pgrep/ps; ~/.claude-auto-retry/bin holds
# macOS translation shims (used by the reconcile LaunchAgent too)
claude-auto-retry() { PATH="$HOME/.claude-auto-retry/bin:$PATH" command claude-auto-retry "$@"; }
# <<< claude-auto-retry macOS shims <<<
CAR_FN
  fi
fi

# tmux status bar indicator: 🟢AR monitoring / ⏳AR waiting on reset / 🟠AR backoff /
# 🔴AR gave up. Absolute path required — #() runs in the tmux server's environment.
touch ~/.tmux.conf
if ! grep -qF "$CAR_PKG/bin/tmux-status.sh" ~/.tmux.conf; then
  backup ~/.tmux.conf
  if grep -q 'claude-auto-retry/bin/tmux-status.sh' ~/.tmux.conf; then
    # repair a stale install path (different npm root, old node version)
    if [[ "$PLATFORM" == macos ]]; then
      sed -i '' "s|[^\"' ]*claude-auto-retry/bin/tmux-status\.sh|$CAR_PKG/bin/tmux-status.sh|g" ~/.tmux.conf
    else
      sed -i "s|[^\"' ]*claude-auto-retry/bin/tmux-status\.sh|$CAR_PKG/bin/tmux-status.sh|g" ~/.tmux.conf
    fi
  else
    cat >> ~/.tmux.conf << TMUXCONF
set -g status-interval 5
set -g status-right "#($CAR_PKG/bin/tmux-status.sh '#{pane_id}' '#{socket_path}') | %Y-%m-%d %H:%M"
TMUXCONF
  fi
fi
tmux source-file ~/.tmux.conf 2>/dev/null || true
echo "    tmux status bar indicator configured"

# Self-healing monitor coverage: reconcile every 5 min re-arms a monitor for any
# live claude pane that lost one (or was started outside the wrapper).
if [[ "$PLATFORM" == macos ]]; then
  # upstream's `install-timer` is systemd-only; this LaunchAgent is the macOS equivalent
  CAR_PLIST="$HOME/Library/LaunchAgents/com.cheapestinference.claude-auto-retry.reconcile.plist"
  mkdir -p "$HOME/Library/LaunchAgents"
  backup "$CAR_PLIST"
  cat > "$CAR_PLIST" << PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>com.cheapestinference.claude-auto-retry.reconcile</string>
	<key>ProgramArguments</key>
	<array>
		<string>$BREW_PREFIX/bin/node</string>
		<string>$CAR_PKG/bin/cli.js</string>
		<string>reconcile</string>
	</array>
	<key>EnvironmentVariables</key>
	<dict>
		<key>PATH</key>
		<string>$CAR_BIN_DIR:$BREW_PREFIX/bin:/usr/local/bin:/usr/bin:/bin</string>
	</dict>
	<key>StartInterval</key>
	<integer>300</integer>
	<key>RunAtLoad</key>
	<true/>
	<key>StandardOutPath</key>
	<string>$HOME/.claude-auto-retry/logs/reconcile-timer.log</string>
	<key>StandardErrorPath</key>
	<string>$HOME/.claude-auto-retry/logs/reconcile-timer.log</string>
	<key>ProcessType</key>
	<string>Background</string>
</dict>
</plist>
PLIST
  launchctl bootout "gui/$(id -u)/com.cheapestinference.claude-auto-retry.reconcile" 2>/dev/null || true
  launchctl bootstrap "gui/$(id -u)" "$CAR_PLIST" \
    && echo "    reconcile LaunchAgent loaded (every 5 min)" \
    || echo "    warn: launchctl bootstrap failed; run: launchctl bootstrap gui/\$(id -u) $CAR_PLIST"
else
  # Linux/WSL: upstream ships a systemd user timer
  if command -v systemctl >/dev/null 2>&1 && systemctl --user show-environment >/dev/null 2>&1; then
    claude-auto-retry install-timer </dev/null \
      && echo "    reconcile systemd user timer installed (every 5 min)" \
      || echo "    warn: claude-auto-retry install-timer failed"
  elif [[ "$PLATFORM" == wsl ]]; then
    skip "claude-auto-retry reconcile timer" "systemd not running in WSL; add 'systemd=true' under [boot] in /etc/wsl.conf, run 'wsl --shutdown' from Windows, then re-run this script"
  else
    skip "claude-auto-retry reconcile timer" "no systemd user session available"
  fi
fi
fi  # claude-auto-retry package present
fi  # npm guard

# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "── done ─────────────────────────────────────────────────────────────"

if [[ ${#SKIPPED[@]} -gt 0 ]]; then
  echo ""
  echo "Skipped on $PLATFORM:"
  printf '  - %s\n' ${SKIPPED[@]+"${SKIPPED[@]}"}
fi

if [[ ${#FAILED[@]} -gt 0 ]]; then
  echo ""
  echo "Failed installs (configs were still written; fix and re-run to retry):"
  printf '  - %s\n' ${FAILED[@]+"${FAILED[@]}"}
fi

echo ""
echo "Manual steps remaining:"
echo ""
if [[ "$PLATFORM" == macos ]]; then
  cat << 'DONE_MAC'
1. Open Ghostty. It is now the configured terminal.

2. Run 'claude' once to authenticate (browser prompt). If any plugin or
   MCP lines above printed a warn, re-run this script afterwards.

3. 1Password app: sign in, then
     Settings > Security  > Unlock with Touch ID
     Settings > Developer > Use the SSH agent
     Settings > Developer > Integrate with 1Password CLI

4. ctrl+left/right word jumps need freeing from Mission Control:
     System Settings > Keyboard > Keyboard Shortcuts > Mission Control
     untick "Move left a space" and "Move right a space"

5. Launch Rectangle, Ice, Stats once each: grant permissions, enable
   "start at login". Open JetBrains Toolbox and sign in to install IDEs.
DONE_MAC
elif [[ "$PLATFORM" == wsl ]]; then
  cat << 'DONE_WSL'
1. Open a new WSL terminal (zsh is now the default shell).

2. Run 'claude' once to authenticate (browser prompt). If any plugin or
   MCP lines above printed a warn, re-run this script afterwards.

3. On the Windows side, run setup.ps1 from PowerShell to install the
   Nerd Font, Windows Terminal tooling, 1Password and PowerToys:
     powershell -ExecutionPolicy Bypass -File setup.ps1

4. Set Windows Terminal's font to "JetBrainsMono Nerd Font"
   (Settings > your WSL profile > Appearance) so icons render.
DONE_WSL
else
  cat << 'DONE_LINUX'
1. Open a new terminal (zsh is now the default shell; log out/in if the
   shell change has not taken effect).

2. Run 'claude' once to authenticate (browser prompt). If any plugin or
   MCP lines above printed a warn, re-run this script afterwards.

3. If you installed 1Password desktop: sign in, then
     Settings > Security  > Unlock with system authentication
     Settings > Developer > Use the SSH agent
     Settings > Developer > Integrate with 1Password CLI
   and re-run this script to wire the SSH agent + commit signing.

4. Set your terminal's font to "JetBrainsMono Nerd Font" so icons render.
DONE_LINUX
fi

cat << 'DONE'

Notes:
   codegraph is wired to Claude Code globally; per repo, run
     codegraph init
   once inside the project to build that project's graph.
   claude-auto-retry wraps 'claude' in tmux, watches for the usage-limit
   message, sleeps until the stated reset time, then sends "continue".
   The tmux status bar shows per-pane state (🟢AR monitoring, ⏳AR waiting,
   🟠AR backoff, 🔴AR gave up); a background timer runs 'reconcile' every
   5 min to re-arm any monitor that died. Check it with:
     claude-auto-retry status

Verify:
   cd <TAB>                     fzf directory menu
   vim <TAB>                    fzf file picker with bat preview (zsh only)
   type a command then press ↑  fzf list of matching history, newest first
   cat ~/.zshrc                 bat: syntax-highlighted output
   vim ~/.zshrc                 syntax highlighting present
   uv python list               uv-managed CPython installed
   claude doctor                install and config health
   claude mcp list              playwright + puppeteer listed
   git config --global --get user.signingkey   your key (if signing set up)
DONE

if [[ "$PLATFORM" == macos ]]; then
  cat << 'DONE'
   sudo -k && sudo true         fingerprint prompt
   ssh -T git@github.com        1Password authorisation prompt
   launchctl print gui/$(id -u)/com.cheapestinference.claude-auto-retry.reconcile
DONE
fi

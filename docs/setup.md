# The terminal bootstrap — `setup.sh` & `setup.ps1`

This is the deep dive for the two bootstrap scripts. For the 60-second version, see the [README](../README.md).

The two scripts share one goal — turn a bare machine into a fully-equipped terminal workstation in a single unattended run — and split strictly along the OS family line:

| | `setup.sh` | `setup.ps1` |
|:--|:--|:--|
| Runs on | macOS · Linux · WSL | native Windows |
| Shell written | `zsh` | PowerShell |
| Installer | Homebrew (+ apt/dnf/pacman prereqs) | `winget` |
| Stages | 13 | 10 |

> **Why two scripts?** `zsh`, `tmux`, Homebrew casks, and the POSIX-only `codegraph`/`claude-auto-retry` installers have no native Windows equivalent. Rather than `if WINDOWS` littering one giant script, each platform gets a script that does everything it *can* do and explicitly defers the rest.

---

## Running it

```bash
# macOS / Linux / WSL
bash setup.sh

# native Windows (PowerShell)
powershell -ExecutionPolicy Bypass -File setup.ps1
```

That's it. The scripts handle the rest.

### The unattended contract

Both scripts are designed to run start-to-finish with **zero mid-run prompts**:

- **POSIX** — asks for your sudo password **once**, up front, then a background loop refreshes the credential cache every 60 s so later root steps (apt, `/etc/shells`, `chsh`, cask installers) never block.
- **Homebrew 6 ask-mode** — disabled with `HOMEBREW_NO_ASK=1`; the installer gets `NONINTERACTIVE=1`.
- **apt** — runs with `DEBIAN_FRONTEND=noninteractive`.
- **Claude Code** — `plugin`/`mcp` commands read stdin from `/dev/null` (POSIX) or an empty pipe (Windows), which makes the `[y/n]` prompt non-tty and skip.
- **codegraph / winget** — `--yes` / `--silent --accept-*-agreements`.

---

## Stage-by-stage

### `setup.sh` (POSIX) — 13 stages

| # | Stage | What happens |
|:--:|:--|:--|
| 1 | **Homebrew** | Installs Homebrew if missing (with apt/dnf/pacman build prerequisites on Linux), puts it on PATH, adds `shellenv` to `~/.zprofile`. |
| 2 | **Formulas** | `starship bat fzf ripgrep eza jq gh git git-delta zoxide btop node tmux uv awscli` + `zsh-autosuggestions`, `zsh-syntax-highlighting`, `fzf-tab`. Sets `zsh` as the default shell on Linux/WSL (macOS already ships it). |
| 3 | **Apps** | macOS casks (Ghostty, 1Password + CLI, Nerd Font, Rectangle, JetBrains Toolbox, Ice, OrbStack, Stats, Claude Code). Linux: native Claude installer, Nerd Font from the upstream tarball, Ghostty/1Password if present. WSL: defers fonts/GUI to `setup.ps1`. |
| 4 | **`~/.zshrc`** | The heart of the shell — see [below](#the-zshrc). |
| 5 | **Ghostty config** | JetBrainsMono Nerd Font, Catppuccin Mocha, block cursor, padding; macOS adds `cmd+backspace`. |
| 6 | **Starship** | Applies the `catppuccin-powerline` preset to `~/.config/starship.toml`. |
| 7 | **`~/.vimrc`** | Restores vim's shipped defaults (skipped once a vimrc exists) plus word-jump keybinds that match the terminal. |
| 8 | **Sudo + 1Password SSH agent** | Touch ID for sudo (macOS `pam.d/sudo_local`). Writes the 1Password `IdentityAgent` to `~/.ssh/config` (macOS/Linux only — WSL needs a manual relay). |
| 9 | **Git** | `delta` pager everywhere; SSH commit signing via 1Password's `op-ssh-sign` wherever it's found. |
| 10 | **uv** | Installs a default managed CPython. |
| 11 | **Claude plugins** | Installs `oh-my-claudecode`, `starship-claude`, `astral`, `context-mode`, `remember`, `ponytail`, the `ty` LSP (from a local clone), plus the `codegraph` CLI wired to Claude. |
| 12 | **Claude MCP** | Registers `playwright` and `puppeteer` MCP servers (user scope, via `npx -y`). |
| 13 | **`claude-auto-retry`** | The auto-resume layer — see [below](#claude-auto-retry). |

### `setup.ps1` (Windows) — 10 stages

| # | Stage | What happens |
|:--:|:--|:--|
| 1 | **CLI tools** | `winget`: git, starship, bat, fzf, ripgrep, eza, jq, gh, delta, zoxide, btop4win, node, uv, awscli. (Skips tmux/zsh — no native build.) |
| 2 | **Apps** | `winget`: 1Password + CLI, JetBrains Toolbox, PowerToys, JetBrainsMono Nerd Font. |
| 3 | **Claude Code** | Native installer from `claude.ai/install.ps1`. |
| 4 | **PowerShell profile** | PSFzf + PSReadLine (prefix-history, prediction), Starship, fzf bindings, `eza`/`bat`/`zoxide` wrappers. |
| 5 | **Starship** | `catppuccin-powerline` preset. |
| 6 | **Git** | `delta` pager + SSH signing via 1Password's `op-ssh-sign.exe`. |
| 7 | **uv** | Default managed CPython. |
| 8 | **Claude plugins** | Same set as POSIX (minus `codegraph`, whose installer is POSIX-only). |
| 9 | **Claude MCP** | `playwright` + `puppeteer`. |
| 10 | **auto-retry** | Skipped — tmux-based; use WSL for auto-resume. |

---

## The `~/.zshrc`

The generated zshrc is where most of the daily-experience magic lives. In order:

1. **Homebrew on PATH** — re-runs `shellenv` so non-login Linux terminals find brew; harmless on macOS.
2. **Fast, prompt-free completion** — `compinit -C` when the dump is fresh (skips the security audit entirely → fast, no prompt), `compinit -i` on a rebuild (silently ignores any insecure file). This fixes the case where a root-owned symlink target (e.g. Homebrew's Ghostty completion) would otherwise pop a blocking `[y/n]` on **every** new tab.
3. **fzf-tab** — sourced after compinit, before the widget plugins, so every completion menu becomes an fzf search with live `eza`/`bat` previews.
4. **Prompt** — `starship init zsh`.
5. **fzf** — `Ctrl+R` history, `Ctrl+T` files, `Alt+C` cd; `rg --files --hidden` as the default command.
6. **Autosuggestions + syntax-highlighting** — history+completion suggestion strategy.
7. **Prefix up-arrow history** — a custom widget: type a command, press `↑`, get an fzf list of history entries that *start with* what you typed (newest first, deduped). Enter fills the line; Esc cancels and keeps your text. Falls back to plain history motion when fzf is missing or the line spans rows.
8. **Word movement / deletion** — emacs mode (`bindkey -e`) plus explicit `Ctrl+←/→`, `Alt+B/F`, `Ctrl+Backspace`, `Ctrl+Delete`, `Ctrl+U` binds.
9. **History** — `HISTFILE` set explicitly (Linux has no default, so without it history never persists), 100k entries, shared, no dups.
10. **uv / CUDA on PATH** — uv shell completion; `/usr/local/cuda/bin` added when present (no-op on non-CUDA machines).
11. **Replacements** — `ls`/`ll`/`lt` → `eza` (icons, mtime sort); `cat` → `bat` (or `batcat` on Debian); `z` → zoxide.
12. **`brew` wrapper** — re-fixes completion permissions after `brew update/upgrade/install/link`.

---

## `claude-auto-retry`

`claude-auto-retry` keeps Claude Code running through usage-limit resets: it wraps `claude` inside a `tmux` pane, watches for the limit message, sleeps until the stated reset time, then sends `continue`. Stage 13 wires up the full self-healing stack:

- **tmux status-bar indicator** — per-pane state via `tmux-status.sh`: 🟢 `AR monitoring` · ⏳ `AR waiting` on reset · 🟠 `AR backoff` · 🔴 `AR gave up`.
- **Self-healing timer** — every 5 min, a background job re-arms a monitor for any live Claude pane that lost one:
  - **macOS** — a `LaunchAgent` (`com.cheapestinference.claude-auto-retry.reconcile`), hand-written because upstream's timer is systemd-only.
  - **Linux/WSL** — upstream's systemd user timer (`install-timer`), with a clear hint if systemd isn't running under WSL.
- **macOS GNU→BSD shims** — `reconcile` expects GNU `pgrep -af` / a Linux `ps comm`. The script drops private `pgrep`/`ps` shims into `~/.claude-auto-retry/bin/` (off the global PATH), and adds a `claude-auto-retry()` zsh wrapper so manual runs use them too. Keeps the fixes across package updates.

> `claude-auto-retry` is **POSIX-only** (it depends on tmux). On native Windows, `setup.ps1` skips it and points you to WSL.

---

## After the run

Both scripts close with two blocks:

- **Manual steps remaining** — open a *new* terminal (so PATH/shell changes land), run `claude` once to authenticate, enable 1Password's SSH agent + CLI integration, set the terminal font to JetBrainsMono Nerd Font, and (macOS) free `Ctrl+←/→` from Mission Control.
- **Verify** — a checklist of one-liners confirming fzf completion, the history widget, bat, uv Python, `claude doctor`, `claude mcp list`, and your signing key.

### Re-running

Safe at any time. Each tool is checked before install; each config is backed up to `<file>.bak.<timestamp>` then rewritten; the Claude plugin/MCP/auto-retry steps are guarded so they add only what's missing. A failure during the first run is collected and retried on the next — the end-of-run summary tells you exactly what still needs attention.

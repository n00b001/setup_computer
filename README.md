<div align="center">

# setup_computer

**One-shot developer-environment bootstrap for macOS, Linux, WSL, and native Windows.**

A single command turns a fresh machine into a fully-equipped terminal workstation: a fast zsh/PowerShell shell, a beautiful prompt, fuzzy everything, signed Git commits, a managed Python, Claude Code with its plugin + MCP ecosystem, and an optional GPU-accelerated build of `llama.cpp` / `whisper.cpp`.

</div>

<br>

| | |
|:--|:--|
| **Platforms** | ![macOS](https://img.shields.io/badge/macOS-Apple_Silicon_/_Intel-000?logo=apple&logoColor=fff) ![Linux](https://img.shields.io/badge/Linux-apt_/_dnf_/_pacman-FCC624?logo=linux&logoColor=000) ![WSL](https://img.shields.io/badge/WSL-2-4E9A06?logo=linux&logoColor=fff) ![Windows](https://img.shields.io/badge/Windows-10_/_11-0078D4?logo=windows11&logoColor=fff) |
| **Shells** | ![zsh](https://img.shields.io/badge/shell-zsh-4E9A06) ![PowerShell](https://img.shields.io/badge/shell-PowerShell-5391FE?logo=powershell&logoColor=fff) |
| **Approach** | ![unattended](https://img.shields.io/badge/run-unattended-2EA44F) ![idempotent](https://img.shields.io/badge/re--run-safe-2EA44F) ![resilient](https://img.shields.io/badge/failures-non--fatal-2EA44F) |

---

## ✨ What you get

A curated, opinionated terminal stack — installed, configured, and wired together:

- **Shell & prompt** — [zsh](https://www.zsh.org) (POSIX) or PowerShell, with [Starship](https://starship.rs)'s `catppuccin-powerline` preset and a [JetBrainsMono Nerd Font](https://github.com/ryanoasis/nerd-fonts) so every icon renders.
- **Fuzzy everything** — [fzf](https://github.com/junegunn/fzf) + [fzf-tab](https://github.com/Aloxaf/fzf-tab): every completion menu, history search (`Ctrl+R`), and file picker (`Ctrl+T`) becomes an instant fuzzy search.
- **Modern coreutils** — [eza](https://github.com/eza-community/eza) for `ls`, [bat](https://github.com/sharkdp/bat) for `cat`, [ripgrep](https://github.com/BurntSushi/ripgrep) for `grep`, [zoxide](https://github.com/ajeetdsouza/zoxide) for `cd`, [git-delta](https://github.com/dandavison/delta) for diffs, [btop](https://github.com/aristocratos/btop) for monitoring.
- **Signed Git commits** — SSH commit signing routed through the [1Password](https://1password.com) SSH agent (Touch ID / Windows Hello), plus [delta](https://github.com/dandavison/delta) as the pager.
- **Managed Python** — [uv](https://docs.astral.sh/uv) installs and pins a default CPython.
- **Claude Code, fully loaded** — [Claude Code](https://docs.claude.com/en/docs/claude-code) plus plugins ([oh-my-claudecode](https://github.com/Yeachan-Heo/oh-my-claudecode), [starship-claude](https://github.com/martinemde/starship-claude), [astral](https://github.com/astral-sh/claude-code-plugins), [context-mode](https://github.com/mksglu/context-mode), [remember](https://github.com/Digital-Process-Tools/claude-marketplace), [ponytail](https://github.com/DietrichGebert/ponytail), [ty](https://github.com/ilepn/ty-lsp-claude-code) LSP), [codegraph](https://github.com/colbymchenry/codegraph), and MCP servers ([playwright](https://github.com/microsoft/playwright-mcp), [puppeteer](https://github.com/merajmehrabi/puppeteer-mcp-server)).
- **Usage-limit auto-resume** — [claude-auto-retry](https://github.com/cheapestinference/claude-auto-retry) wraps `claude` in [tmux](https://github.com/tmux/tmux), watches for the usage-limit message, sleeps until reset, then resumes — with a tmux status-bar indicator and a self-healing background timer. *(POSIX only.)*
- **GPU [llama.cpp](https://github.com/ggml-org/llama.cpp) / [whisper.cpp](https://github.com/ggml-org/whisper.cpp)** — the optional [`cpp-builder`](docs/cpp-builder.md) clones, builds with the right acceleration backend, and installs in one command.

---

## 📸 Screenshots

| [fzf](https://github.com/junegunn/fzf) — fuzzy history search & file picker | [bat](https://github.com/sharkdp/bat) — syntax-highlighted `cat` |
|:--:|:--:|
| ![fzf preview](https://raw.githubusercontent.com/junegunn/i/master/fzf-preview.png) | ![bat syntax highlighting](https://i.imgur.com/rGsdnDe.png) |

| [git-delta](https://github.com/dandavison/delta) — rich diffs | [eza](https://github.com/eza-community/eza) — modern `ls` | [btop](https://github.com/aristocratos/btop) — resource monitor |
|:--:|:--:|:--:|
| ![delta diff](https://user-images.githubusercontent.com/52205/147996902-9829bd3f-cd33-466e-833e-49a6f3ebd623.png) | ![eza listing](https://raw.githubusercontent.com/eza-community/eza/main/docs/images/screenshots.png) | ![btop monitor](https://raw.githubusercontent.com/aristocratos/btop/main/Img/normal.png) |

---

## 🚀 Quick start

Pick the script for your platform. Each one asks for elevated permission **once**, then runs unattended to completion.

### macOS · Linux · WSL

```bash
bash setup.sh
```

> **WSL note:** run `setup.sh` inside WSL for the Linux/CLI side, then run `setup.ps1` from PowerShell on the Windows side for fonts, 1Password, and PowerToys. The script prints this reminder at the end.

### Native Windows (PowerShell)

```powershell
powershell -ExecutionPolicy Bypass -File setup.ps1
```

> Requires [winget](https://github.com/microsoft/winget-cli) (built into Windows 10/11 as *App Installer*).

### Build `llama.cpp` / `whisper.cpp` (optional, any POSIX machine)

```bash
bash cpp-builder/build_project.sh            # llama.cpp, latest, auto GPU accel
bash cpp-builder/build_project.sh whisper    # whisper.cpp
```

---

## 🧩 The three components

| Component | Script | What it does |
|:--|:--|:--|
| **Terminal bootstrap (POSIX)** | [`setup.sh`](setup.sh) | 13-stage install + config for macOS / Linux / WSL. The flagship script. |
| **Terminal bootstrap (Windows)** | [`setup.ps1`](setup.ps1) | 10-stage install + config for native Windows via winget. |
| **C++ builder** | [`cpp-builder/build_project.sh`](cpp-builder/build_project.sh) | One-shot, GPU-accelerated build of [llama.cpp](https://github.com/ggml-org/llama.cpp) / [whisper.cpp](https://github.com/ggml-org/whisper.cpp). |

📖 **Deep dives:** [`docs/setup.md`](docs/setup.md) (the bootstrap, stage by stage) · [`docs/cpp-builder.md`](docs/cpp-builder.md) (the builder, acceleration matrix)

---

## 🛠 What gets installed

### Command-line tools (all platforms)

[starship](https://starship.rs) · [bat](https://github.com/sharkdp/bat) · [fzf](https://github.com/junegunn/fzf) · [ripgrep](https://github.com/BurntSushi/ripgrep) · [eza](https://github.com/eza-community/eza) · [jq](https://github.com/jqlang/jq) · [gh](https://cli.github.com) · [git](https://git-scm.com) · [git-delta](https://github.com/dandavison/delta) · [zoxide](https://github.com/ajeetdsouza/zoxide) · [btop](https://github.com/aristocratos/btop) · [node](https://nodejs.org) · [tmux](https://github.com/tmux/tmux)<sup>POSIX</sup> · [uv](https://docs.astral.sh/uv) · [awscli](https://aws.amazon.com/cli/) · [zsh](https://www.zsh.org)<sup>POSIX</sup> + [autosuggestions](https://github.com/zsh-users/zsh-autosuggestions) / [syntax-highlighting](https://github.com/zsh-users/zsh-syntax-highlighting) / [fzf-tab](https://github.com/Aloxaf/fzf-tab)

### Desktop apps (platform-specific)

| macOS (casks) | Linux | WSL | Windows ([winget](https://github.com/microsoft/winget-cli)) |
|:--|:--|:--|:--|
| [Ghostty](https://ghostty.org) | [JetBrainsMono Nerd Font](https://github.com/ryanoasis/nerd-fonts) (tarball) | *fonts on Windows side* | [JetBrainsMono Nerd Font](https://github.com/ryanoasis/nerd-fonts) |
| [1Password](https://1password.com) + [CLI](https://developer.1password.com/docs/cli) | 1Password + CLI *(if desktop present)* | *1Password on Windows side* | 1Password + CLI |
| [Rectangle](https://rectangleapp.com) | Ghostty *(if available)* | [Windows Terminal](https://github.com/microsoft/terminal) | [PowerToys](https://github.com/microsoft/PowerToys) (FancyZones) |
| [JetBrains Toolbox](https://www.jetbrains.com/toolbox-app/) | | | JetBrains Toolbox |
| [Ice](https://github.com/jordanbaird/Ice) · [OrbStack](https://orbstack.dev) · [Stats](https://github.com/exelban/stats) | | | |
| [Claude Code](https://docs.claude.com/en/docs/claude-code) (cask) | Claude Code (native installer) | Claude Code (native installer) | Claude Code (native installer) |

Anything that can't work on the current platform is **skipped with a reason** and listed in the end-of-run summary — nothing fails silently.

---

## ⌨️ Keybindings (zsh)

| Keys | Action |
|:--|:--|
| `Tab` | fzf completion menu (files, dirs, git refs, …) with live preview |
| `Ctrl+R` | fzf history search |
| `Ctrl+T` | fzf file picker · `Alt+C` fzf `cd` |
| `↑` | fzf list of history entries **starting with what you typed** (newest first) |
| `Ctrl+←` / `Ctrl+→` · `Alt+B` / `Alt+F` | jump backward / forward a word |
| `Ctrl+Backspace` / `Ctrl+Delete` | delete word backward / forward |
| `Ctrl+U` | delete to start of line |
| `z <frag>` | jump to a frequently-used directory (zoxide) |
| `ls` / `ll` / `lt` | `eza` (icons, mtime sort, tree) |
| `cat` | `bat` (syntax-highlighted, no pager) |

PowerShell gets the equivalents: Starship prompt, `PSReadLine` prefix-history + prediction, and `PSFzf` for `Ctrl+R` / `Ctrl+T`.

---

## 📄 Config files written

| File | Contents |
|:--|:--|
| `~/.zshrc` | PATH, fast prompt-free `compinit`, fzf-tab, plugins, prompt, history, aliases |
| `~/.config/starship.toml` | `catppuccin-powerline` preset |
| `~/.config/ghostty/config` | JetBrainsMono Nerd Font, [Catppuccin](https://catppuccin.com) Mocha, padding |
| `~/.vimrc` | restored defaults + word-jump keybinds matching the terminal |
| `~/.gitconfig` | `delta` pager + SSH commit signing via 1Password |
| `~/.ssh/config` | 1Password `IdentityAgent` (where the desktop app exists) |
| `/etc/pam.d/sudo_local` | Touch ID for sudo *(macOS)* |

Every existing file is backed up to `<file>.bak.<timestamp>` before being replaced, so **re-running is always safe**.

---

## 🧭 Design principles

These scripts are built around four guarantees that hold across every platform:

1. **Unattended.** One elevated-credential prompt up front (POSIX keeps the sudo cache warm in the background; Windows uses [winget](https://github.com/microsoft/winget-cli) `--silent`). No mid-run questions — [Homebrew](https://brew.sh)'s ask-mode, apt's config prompts, and the Claude `[y/n]` prompts are all answered or piped away.
2. **Idempotent.** Each tool is checked before install; each config file is backed up then written. Run it ten times, get the same result.
3. **Resilient.** A failed install never aborts the run. It's logged, collected, and printed under **"Failed installs"** at the end — and every config file is still written.
4. **Platform-aware.** One script per family detects macOS / Linux / WSL / Windows, skips what can't work with a stated reason, and tells you the manual step or the sibling script that covers it.

---

## ✅ After it finishes

The script prints a tailored **manual-steps** checklist (open the new terminal, authenticate `claude`, enable 1Password's SSH agent, set the font) and a **verify** block. The highlights:

```bash
cd <Tab>                                     # fzf directory menu
vim <Tab>                                    # fzf file picker with bat preview
uv python list                               # uv-managed CPython installed
claude doctor                                # install + config health
claude mcp list                              # playwright + puppeteer listed
git config --global --get user.signingkey    # your signing key
claude-auto-retry status                     # auto-resume monitor state
```

---

## 📁 Repository layout

```
.
├── setup.sh                     # macOS / Linux / WSL bootstrap (13 stages)
├── setup.ps1                    # native Windows bootstrap (10 stages)
├── cpp-builder/
│   └── build_project.sh         # GPU-accelerated llama.cpp / whisper.cpp builder
├── docs/
│   ├── setup.md                 # bootstrap deep dive
│   └── cpp-builder.md           # builder deep dive
└── .gitignore
```

---

## 🔁 Updating

Re-run the same script any time — it pulls latest versions of each tool, refreshes configs, and reconciles the Claude plugin/MCP/auto-retry setup. For the C++ projects, `build_project.sh` fetches and rebuilds the latest revision by default (`--no-update` to build the current checkout as-is).

---

## 📄 License

Personal dotfiles-style setup scripts. Use, fork, and adapt freely.

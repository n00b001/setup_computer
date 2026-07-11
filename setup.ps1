# setup.ps1 — one-shot terminal environment bootstrap for native Windows
#
# Run from PowerShell (winget required — built in on Windows 10/11):
#   powershell -ExecutionPolicy Bypass -File setup.ps1
#
# Installs : winget: starship bat fzf ripgrep eza jq gh git-delta zoxide
#            btop4win nodejs-lts uv awscli git 1password (+CLI)
#            jetbrains-toolbox powertoys jetbrains-mono-nerd-font;
#            Claude Code (native installer), PSFzf + PSReadLine profile,
#            uv-managed Python, Claude Code plugins, MCP servers
# Writes   : $PROFILE.CurrentUserAllHosts (PowerShell profile)
#            ~\.config\starship.toml
#            ~\.gitconfig (SSH commit signing via 1Password, delta pager)
#
# Not available on native Windows (skipped, with a log line and an end-of-run
# summary): zsh + plugins, tmux, claude-auto-retry (tmux-based), Ghostty
# (use Windows Terminal), Rectangle (PowerToys FancyZones instead), Ice,
# Stats (btop4win instead), OrbStack (Docker Desktop instead), Touch ID
# sudo (Windows Hello), codegraph (POSIX installer only).
#
# Existing files are backed up as <file>.bak.<timestamp> before being
# replaced. Re-running is safe.

$ErrorActionPreference = 'Continue'
$timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$script:Skipped = @()

function Skip-Tool([string]$What, [string]$Why) {
    Write-Host "    skip [windows]: $What — $Why"
    $script:Skipped += "$What — $Why"
}

function Backup-File([string]$Path) {
    if (Test-Path $Path) {
        Copy-Item $Path "$Path.bak.$timestamp"
        Write-Host "    backed up $Path -> $Path.bak.$timestamp"
    }
}

function Update-PathFromRegistry {
    $env:Path = [Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' +
                [Environment]::GetEnvironmentVariable('Path', 'User')
}

function Install-WingetPackage([string]$Id) {
    winget list --id $Id -e --accept-source-agreements 2>$null | Out-Null
    if ($LASTEXITCODE -eq 0) {
        Write-Host "    $Id already installed"
        return
    }
    Write-Host "    installing $Id"
    winget install --id $Id -e --silent --accept-source-agreements --accept-package-agreements
    if ($LASTEXITCODE -ne 0) { Write-Host "    warn: winget install $Id failed" }
}

if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
    Write-Error 'winget not found. Install "App Installer" from the Microsoft Store, then re-run.'
    exit 1
}

# ─────────────────────────────────────────────────────────────────────────────
Write-Host '== 1/10 CLI tools (winget) =='
$packages = @(
    'Git.Git', 'Starship.Starship', 'sharkdp.bat', 'junegunn.fzf',
    'BurntSushi.ripgrep.MSVC', 'eza-community.eza', 'jqlang.jq',
    'GitHub.cli', 'dandavison.delta', 'ajeetdsouza.zoxide',
    'aristocratos.btop4win', 'OpenJS.NodeJS.LTS', 'astral-sh.uv',
    'Amazon.AWSCLI'
)
foreach ($p in $packages) { Install-WingetPackage $p }
Skip-Tool 'tmux' 'no native Windows build; use WSL (setup.sh) for tmux workflows'
Skip-Tool 'zsh + zsh plugins + fzf-tab' 'no zsh on native Windows; PowerShell profile below covers prompt/history/fzf'

# ─────────────────────────────────────────────────────────────────────────────
Write-Host '== 2/10 Apps (winget) =='
$apps = @(
    'AgileBits.1Password', 'AgileBits.1Password.CLI',
    'JetBrains.Toolbox', 'Microsoft.PowerToys',
    'DEVCOM.JetBrainsMonoNerdFont'
)
foreach ($a in $apps) { Install-WingetPackage $a }
Skip-Tool 'Ghostty' 'no Windows build; use Windows Terminal (set font to JetBrainsMono Nerd Font)'
Skip-Tool 'Rectangle' 'macOS-only; PowerToys FancyZones installed instead'
Skip-Tool 'Ice' 'macOS-only menu bar manager'
Skip-Tool 'OrbStack' 'macOS-only; install Docker Desktop if containers are needed'
Skip-Tool 'Stats' 'macOS-only; btop4win installed instead'
Update-PathFromRegistry

# ─────────────────────────────────────────────────────────────────────────────
Write-Host '== 3/10 Claude Code =='
if (-not (Get-Command claude -ErrorAction SilentlyContinue)) {
    try {
        Invoke-RestMethod -Uri 'https://claude.ai/install.ps1' | Invoke-Expression
    } catch {
        Write-Host "    warn: Claude Code installer failed: $_"
    }
    Update-PathFromRegistry
    # the installer puts claude in ~\.local\bin
    if (Test-Path "$env:USERPROFILE\.local\bin\claude.exe") {
        $env:Path = "$env:USERPROFILE\.local\bin;$env:Path"
    }
}

# ─────────────────────────────────────────────────────────────────────────────
Write-Host '== 4/10 PowerShell profile =='
try {
    Install-Module PSFzf -Scope CurrentUser -Force -ErrorAction Stop
} catch {
    Write-Host '    warn: PSFzf module install failed; ctrl+r/ctrl+t fzf bindings unavailable'
}
$profilePath = $PROFILE.CurrentUserAllHosts
New-Item -ItemType Directory -Force -Path (Split-Path $profilePath) | Out-Null
Backup-File $profilePath
@'
# ── prompt ──
Invoke-Expression (&starship init powershell)

# ── history: up/down cycle entries starting with the typed text ──
Set-PSReadLineOption -HistorySearchCursorMovesToEnd
Set-PSReadLineKeyHandler -Key UpArrow -Function HistorySearchBackward
Set-PSReadLineKeyHandler -Key DownArrow -Function HistorySearchForward
Set-PSReadLineOption -PredictionSource History

# ── fzf: ctrl+r history, ctrl+t files ──
if (Get-Module -ListAvailable -Name PSFzf) {
    Import-Module PSFzf
    Set-PsFzfOption -PSReadlineChordProvider 'Ctrl+t' -PSReadlineChordReverseHistory 'Ctrl+r'
}
$env:FZF_DEFAULT_COMMAND = 'rg --files --hidden --glob "!.git"'
$env:FZF_CTRL_T_COMMAND = $env:FZF_DEFAULT_COMMAND

# ── replacements ──
Remove-Item Alias:ls -Force -ErrorAction SilentlyContinue
function ls { eza --icons @args }
function ll { eza -la --icons --git @args }
function lt { eza --tree --level=2 --icons @args }
Set-Alias -Name cat -Value bat -Option AllScope -Force
$env:BAT_THEME = 'TwoDark'

# ── zoxide: z <fragment> jumps to frecent directories ──
Invoke-Expression (& { (zoxide init powershell | Out-String) })
'@ | Set-Content -Path $profilePath -Encoding UTF8
Write-Host "    wrote $profilePath"

# ─────────────────────────────────────────────────────────────────────────────
Write-Host '== 5/10 Starship preset =='
New-Item -ItemType Directory -Force -Path "$env:USERPROFILE\.config" | Out-Null
Backup-File "$env:USERPROFILE\.config\starship.toml"
if (Get-Command starship -ErrorAction SilentlyContinue) {
    starship preset catppuccin-powerline -o "$env:USERPROFILE\.config\starship.toml" --force
    Write-Host '    wrote ~\.config\starship.toml'
} else {
    Write-Host '    warn: starship not on PATH yet; open a new terminal and re-run this script'
}

# ─────────────────────────────────────────────────────────────────────────────
Write-Host '== 6/10 Git: commit signing via 1Password + delta pager =='
if (Get-Command git -ErrorAction SilentlyContinue) {
    git config --global core.pager delta
    git config --global interactive.diffFilter 'delta --color-only'
    git config --global delta.navigate true

    $opSign = "$env:LOCALAPPDATA\1Password\app\8\op-ssh-sign.exe"
    if (Test-Path $opSign) {
        git config --global gpg.format ssh
        git config --global gpg.ssh.program ($opSign -replace '\\', '/')
        git config --global user.signingkey 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIA+kyRFBfXb0h7c2SS6Ue/PubsqRlUKSlXr/uBcEsLnN'
        git config --global commit.gpgsign true
        Write-Host '    signing + delta configured; signing works once 1Password holds this key and the agent is on'
    } else {
        Skip-Tool 'git commit signing via 1Password' 'op-ssh-sign.exe not found (launch 1Password once, then re-run); delta pager still configured'
    }
} else {
    Write-Host '    warn: git not on PATH yet; open a new terminal and re-run this script'
}
# 1Password's Windows SSH agent takes over the standard OpenSSH agent named
# pipe (\\.\pipe\openssh-ssh-agent) — no ~/.ssh/config change needed.
Skip-Tool 'Touch ID for sudo' 'macOS-only; Windows Hello covers UAC prompts natively'

# ─────────────────────────────────────────────────────────────────────────────
Write-Host '== 7/10 uv: default Python =='
if (Get-Command uv -ErrorAction SilentlyContinue) {
    uv python install
    if ($LASTEXITCODE -ne 0) { Write-Host '    warn: uv python install failed' }
} else {
    Write-Host '    warn: uv not on PATH yet; open a new terminal and re-run this script'
}

# ─────────────────────────────────────────────────────────────────────────────
Write-Host '== 8/10 Claude Code plugins =='
if (Get-Command claude -ErrorAction SilentlyContinue) {
    # piping empty input makes stdin a non-tty so the [y/n] prompt is skipped
    function Invoke-Claude {
        param([string[]]$ClaudeArgs)
        '' | & claude @ClaudeArgs
        if ($LASTEXITCODE -ne 0) {
            Write-Host "    warn: 'claude $($ClaudeArgs -join ' ')' failed. Run 'claude' once to authenticate, then re-run this script."
        }
    }
    function Add-Marketplace([string]$Repo) {
        '' | & claude plugin marketplace add $Repo 2>$null | Out-Null
    }

    Add-Marketplace 'https://github.com/Yeachan-Heo/oh-my-claudecode'
    Invoke-Claude @('plugin', 'install', 'oh-my-claudecode')

    Add-Marketplace 'martinemde/starship-claude'
    Invoke-Claude @('plugin', 'install', 'starship-claude@starship-claude')

    Add-Marketplace 'astral-sh/claude-code-plugins'
    Invoke-Claude @('plugin', 'install', 'astral@astral-sh')

    Add-Marketplace 'mksglu/context-mode'
    Invoke-Claude @('plugin', 'install', 'context-mode@context-mode')

    Add-Marketplace 'Digital-Process-Tools/claude-marketplace'
    Invoke-Claude @('plugin', 'install', 'remember@dpt-plugins')

    # ty LSP plugin installs from a local clone, per its README
    $tyDir = "$env:USERPROFILE\.claude-tools\ty-lsp-claude-code"
    if (-not (Test-Path $tyDir)) {
        git clone --depth 1 https://github.com/ilepn/ty-lsp-claude-code $tyDir
    }
    Push-Location $tyDir
    Invoke-Claude @('plugin', 'install', '.')
    Pop-Location

    Skip-Tool 'codegraph' 'installer is POSIX-shell only; use WSL, or install manually if a Windows build appears'
} else {
    Write-Host "    warn: claude not on PATH yet; open a new terminal and re-run this script"
}

# ─────────────────────────────────────────────────────────────────────────────
Write-Host '== 9/10 Claude Code MCP servers =='
if (Get-Command claude -ErrorAction SilentlyContinue) {
    # -y keeps npx non-interactive; MCP servers launch without a tty
    claude mcp get playwright 2>$null | Out-Null
    if ($LASTEXITCODE -ne 0) {
        '' | & claude mcp add --scope user playwright -- npx -y '@playwright/mcp@latest'
        if ($LASTEXITCODE -ne 0) { Write-Host '    warn: adding playwright MCP failed' }
    }
    claude mcp get puppeteer 2>$null | Out-Null
    if ($LASTEXITCODE -ne 0) {
        '' | & claude mcp add --scope user puppeteer -- npx -y puppeteer-mcp-server
        if ($LASTEXITCODE -ne 0) { Write-Host '    warn: adding puppeteer MCP failed' }
    }
}

# ─────────────────────────────────────────────────────────────────────────────
Write-Host '== 10/10 Usage-limit auto-resume: claude-auto-retry =='
Skip-Tool 'claude-auto-retry' 'requires tmux (monitor panes + status bar); use WSL via setup.sh for auto-resume'

# ─────────────────────────────────────────────────────────────────────────────
Write-Host ''
Write-Host '── done ─────────────────────────────────────────────────────────────'

if ($script:Skipped.Count -gt 0) {
    Write-Host ''
    Write-Host 'Skipped on windows:'
    $script:Skipped | ForEach-Object { Write-Host "  - $_" }
}

Write-Host @'

Manual steps remaining:

1. Open a NEW Windows Terminal so PATH changes take effect, and set its
   font to "JetBrainsMono Nerd Font" (Settings > profile > Appearance)
   so prompt icons render.

2. Run 'claude' once to authenticate (browser prompt). If any plugin or
   MCP lines above printed a warn, re-run this script afterwards.

3. 1Password app: sign in, then
     Settings > Security  > Unlock with Windows Hello
     Settings > Developer > Use the SSH agent
     Settings > Developer > Integrate with 1Password CLI
   Re-run this script afterwards if commit signing was skipped above.

4. PowerToys: enable FancyZones (Rectangle equivalent) and set up zones.
   Open JetBrains Toolbox and sign in to install IDEs.

Verify:
   uv python list               uv-managed CPython installed
   claude doctor                install and config health
   claude mcp list              playwright + puppeteer listed
   git config --global --get user.signingkey   your key (if signing set up)
   ssh -T git@github.com        1Password authorisation prompt
'@

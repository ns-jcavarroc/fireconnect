#Requires -Version 5.1
<#
.SYNOPSIS
  Windows / PowerShell installer for FireConnect.

.DESCRIPTION
  PowerShell port of install.sh. Ensures Node.js is available, clones a durable
  copy of the FireConnect repo (a streamed `irm | iex` run has no local source),
  reads your Fireworks API key, routes Claude Code through Fireworks, and
  installs a `fireconnect` launcher onto your user PATH.

  Piped usage:
    Set-ExecutionPolicy -Scope Process Bypass
    irm https://raw.githubusercontent.com/fw-ai/fireconnect/main/install.ps1 | iex

  Saved usage:
    powershell -ExecutionPolicy Bypass -File .\install.ps1

  Environment overrides:
    $env:FIREWORKS_API_KEY     - skip the interactive prompt
    $env:FIREWORKS_BASE_URL    - override the Fireworks API base URL
    $env:FIRECONNECT_SOURCE    - override the git clone source
#>
$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'   # quiet git/curl progress in PS 5.1

$BaseUrl       = if ($env:FIREWORKS_BASE_URL) { $env:FIREWORKS_BASE_URL } else { 'https://api.fireworks.ai/inference' }
$DefaultSource = 'https://github.com/fw-ai/fireconnect.git'
$Source        = if ($env:FIRECONNECT_SOURCE) { $env:FIRECONNECT_SOURCE } else { $DefaultSource }

# The CLI reads process.env.HOME directly, which is unset on Windows (Windows
# uses USERPROFILE). $HOME in PowerShell is already USERPROFILE; export it as
# HOME so node child processes can resolve settings (~/.claude, ~/.fireconnect).
# Respect an existing HOME (e.g. a Git Bash environment) if present.
if (-not $env:HOME) { $env:HOME = $HOME }

# When streamed via `irm | iex`, $PSScriptRoot is empty and there is no local
# CLI to point at; bootstrap from a git clone instead.
if ($PSScriptRoot) {
  $Cli = Join-Path $PSScriptRoot 'packages/setup-cli/bin/fireconnect.mjs'
} else {
  $Cli = ''
}

function Test-Command {
  param([string]$Name)
  return [bool](Get-Command $Name -ErrorAction SilentlyContinue)
}

function Invoke-NativeCommand {
  <#
    Run a native command (node/git/...) and abort on a non-zero exit code.
    PowerShell's $ErrorActionPreference does not apply to native exit codes,
    so we check $LASTEXITCODE explicitly for PS 5.1 compatibility.

    Passing exe + args explicitly (rather than a scriptblock) avoids relying on
    PowerShell scriptblock variable capture, which is unreliable across
    function boundaries.
  #>
  param(
    [Parameter(Mandatory)][string]$Exe,
    [string[]]$Arguments = @(),
    [string]$FailureMessage,
    [switch]$SuppressOutput
  )
  if ($SuppressOutput) {
    # Mirror bash's `>/dev/null`: suppress stdout only, let stderr show.
    # Avoid `2>&1 | Out-Null`, which can turn native stderr into a terminating
    # error under $ErrorActionPreference='Stop'.
    & $Exe @Arguments | Out-Null
  } else {
    & $Exe @Arguments
  }
  if ($LASTEXITCODE -ne 0) {
    if ($FailureMessage) { Write-Error $FailureMessage }
    exit 1
  }
}

function Ensure-NodeRuntime {
  if (Test-Command 'node') { return }

  Write-Host 'Node.js is required for setup.'
  Write-Host 'The installer uses Node to update settings; it does not install or update npm packages.'

  if (Test-Command 'winget') {
    $answer = Read-Host 'Install Node.js with winget now? [y/N]'
    if ($answer -notmatch '^[Yy]') {
      Write-Error 'Install Node.js from https://nodejs.org or with winget, then rerun this installer.'
      exit 1
    }
    Write-Host 'Installing Node.js with winget...'
    Invoke-NativeCommand -Exe 'winget' `
      -Arguments 'install','--id','OpenJS.NodeJS','-e','--accept-source-agreements','--accept-package-agreements' `
      -FailureMessage 'winget failed to install Node.js.'
    # winget places node on the user PATH for future shells; refresh this session too.
    $env:PATH = [Environment]::GetEnvironmentVariable('PATH', 'User') + ';' + $env:PATH
  } else {
    Write-Error 'Could not automatically install Node.js (winget not found). Install Node.js from https://nodejs.org, then rerun this installer.'
    exit 1
  }

  if (-not (Test-Command 'node')) {
    Write-Error 'Missing required command: node. Open a new terminal so PATH updates take effect, then rerun this installer.'
    exit 1
  }
}

# The CLI launcher needs a durable copy of the repo; a streamed `irm | iex`
# checkout in $env:TEMP does not survive reboots, so keep one under
# $HOME\.fireconnect\cli.
function Ensure-DurableSource {
  if ($Cli -and (Test-Path -LiteralPath $Cli)) { return }

  $installDir = Join-Path $HOME '.fireconnect/cli'
  Write-Host 'Downloading FireConnect...'

  if (-not (Test-Command 'git')) {
    Write-Error 'Missing required command: git. Install Git from https://git-scm.com, then rerun this installer.'
    exit 1
  }
  if (Test-Path -LiteralPath $installDir) { Remove-Item -Recurse -Force -LiteralPath $installDir }
  $null = New-Item -ItemType Directory -Force -Path (Split-Path $installDir)

  Invoke-NativeCommand -Exe 'git' -Arguments 'clone','--quiet','--depth','1',$Source,$installDir `
    -FailureMessage 'git clone failed.'
  # $script: scope is required: a bare `$Cli =` here would create a function-local
  # copy and leave Main reading the (still-empty) script-scope value.
  $script:Cli = Join-Path $installDir 'packages/setup-cli/bin/fireconnect.mjs'

  if (-not (Test-Path -LiteralPath $Cli)) {
    Write-Error 'FireConnect CLI not found after download.'
    exit 1
  }
}

function Read-ApiKey {
  if ($env:FIREWORKS_API_KEY) { return $env:FIREWORKS_API_KEY }

  Write-Host 'Create a Fireworks API key here:'
  Write-Host 'https://app.fireworks.ai/settings/users/api-keys'
  Write-Host '(Fire Pass users: paste your fpk_... key directly.)'
  Write-Host ''

  # Read-Host -AsSecureString masks input and works in both PS 5.1 and 7+.
  $secure = Read-Host 'Fireworks API key' -AsSecureString
  $plain  = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
              [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure))

  $plain = $plain -replace "`r", ''
  if ($plain -notmatch '\S') {
    Write-Error 'Fireworks API key is required. Set $env:FIREWORKS_API_KEY and rerun the installer.'
    exit 1
  }
  return $plain
}

function Add-BinDirToPath {
  param([string]$BinDir)

  $userPath = [Environment]::GetEnvironmentVariable('PATH', 'User')
  $entries  = if ($userPath) { $userPath -split ';' } else { @() }

  if ($entries -notcontains $BinDir) {
    $newPath = (($entries + $BinDir | Where-Object { $_ }) -join ';')
    [Environment]::SetEnvironmentVariable('PATH', $newPath, 'User')
    Write-Host "Updated user PATH to include $BinDir."
  }
}

function Install-CliLauncher {
  param([string]$CliPath)

  $binDir       = Join-Path $HOME '.local/bin'
  $launcherPath = Join-Path $binDir 'fireconnect.cmd'

  $null = New-Item -ItemType Directory -Force -Path $binDir

  # A .cmd shim works from both PowerShell and cmd.exe; it just forwards %*
  # to node. No execution-policy concerns, unlike a .ps1 shim.
  # Set HOME=USERPROFILE (if unset) so the CLI can resolve settings in a fresh
  # shell where HOME is otherwise empty on Windows.
  $shim = "@echo off`r`nif `"%HOME%`"==`"`" set `"HOME=%USERPROFILE%`"`r`nnode `"$CliPath`" %*`r`n"
  Set-Content -LiteralPath $launcherPath -Value $shim -Encoding ascii

  Add-BinDirToPath -BinDir $binDir
}

function Main {
  Ensure-NodeRuntime
  Ensure-DurableSource

  $apiKey = Read-ApiKey

  Invoke-NativeCommand -Exe 'node' `
    -Arguments $Cli,'claude','on','--api-key',$apiKey,'--base-url',$BaseUrl `
    -FailureMessage 'Failed to route Claude Code through Fireworks.' `
    -SuppressOutput

  Install-CliLauncher -CliPath $Cli

  Write-Host ''
  Write-Host 'FireConnect is installed and Claude Code is routed through Fireworks.'
  Write-Host ''
  Invoke-NativeCommand -Exe 'node' -Arguments $Cli,'help' -FailureMessage 'Failed to print CLI help.'
  Write-Host ''
  Write-Host 'Restart Claude Code (and open a new terminal so PATH updates apply), then test with: hi'
}

Main

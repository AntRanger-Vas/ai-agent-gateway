<#
.SYNOPSIS
  Start Claude Code on this laptop with its model calls going through the
  AI Agent Gateway lab running in your GitHub Codespace.

.DESCRIPTION
  1. First run only: asks for the 'claude-code-laptop' gateway key (printed by
     lab/03-laptop-key.sh in the Codespace) and stores it encrypted for your
     Windows account (DPAPI) in %USERPROFILE%\.gateway-lab\laptop-key.
  2. Opens a private tunnel from 127.0.0.1:8082 on this laptop to the gateway's
     LLM plane in the Codespace (gh codespace ports forward). Nothing is
     exposed to the internet; GitHub authenticates the tunnel as you.
  3. Starts Claude Code with ANTHROPIC_BASE_URL and ANTHROPIC_CUSTOM_HEADERS
     set for this window only. Your claude.ai login stays the credential
     Anthropic sees. When Claude Code exits, the tunnel closes; other
     terminals and your settings are untouched.

  Needs: GitHub CLI (winget install --id GitHub.cli), signed in with the
  codespace scope (gh auth refresh -h github.com -s codespace), and Claude
  Code (irm https://claude.ai/install.ps1 | iex). The Codespace must be
  running with the lab started (bash .devcontainer/lab-up.sh).

.PARAMETER ResetKey
  Forget the stored key and ask again (after lab/03-laptop-key.sh --rotate).

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File claude-via-gateway.ps1
.EXAMPLE
  powershell -ExecutionPolicy Bypass -File claude-via-gateway.ps1 -ResetKey
.EXAMPLE
  powershell -ExecutionPolicy Bypass -File claude-via-gateway.ps1 --continue
  Arguments the script doesn't recognise are passed on to Claude Code.
#>
# PositionalBinding off: anything you don't name goes to Claude Code, never
# into -Repo or -LocalPort by position.
[CmdletBinding(PositionalBinding = $false)]
param(
  [switch]$ResetKey,
  [string]$Repo = 'AntRanger-Vas/ai-agent-gateway',
  [int]$LocalPort = 8082,
  [Parameter(ValueFromRemainingArguments = $true)]
  [string[]]$ClaudeArgs
)
$ErrorActionPreference = 'Stop'

function Fail([string]$Message) {
  Write-Host "ERROR: $Message" -ForegroundColor Red
  exit 1
}

# Prerequisites.
if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
  Fail "GitHub CLI not found. Install it:  winget install --id GitHub.cli   then open a new window and run:  gh auth login"
}
if (-not (Get-Command claude -ErrorAction SilentlyContinue)) {
  Fail "Claude Code not found. Install it:  irm https://claude.ai/install.ps1 | iex   then open a new window."
}

# 1. The gateway key, encrypted for this Windows account.
$dir = Join-Path $env:USERPROFILE '.gateway-lab'
$keyFile = Join-Path $dir 'laptop-key'
if ($ResetKey -and (Test-Path $keyFile)) { Remove-Item $keyFile -Force }
if (-not (Test-Path $keyFile)) {
  New-Item -ItemType Directory -Force -Path $dir | Out-Null
  $entered = Read-Host -AsSecureString "Paste the 'claude-code-laptop' key (gk_...) printed by lab/03-laptop-key.sh"
  $entered | ConvertFrom-SecureString | Set-Content -Path $keyFile
  Write-Host "Saved, encrypted for your Windows account: $keyFile"
}
$secure = Get-Content -Path $keyFile | ConvertTo-SecureString
$bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
try { $gatewayKey = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) }
finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
if ($gatewayKey -notmatch '^gk_') {
  Remove-Item $keyFile -Force
  Fail "That doesn't look like a gateway key (it should start with gk_). Run the script again to re-enter it."
}

# 2. The running Codespace, and a tunnel to its LLM plane.
# stdout only: under Windows PowerShell 5.1, redirecting a native command's
# stderr (2>&1) with ErrorActionPreference=Stop turns any warning into a
# terminating error. gh's own messages still reach the console.
$listing = & gh codespace list --json name,state,repository
if ($LASTEXITCODE -ne 0) {
  Fail "gh couldn't list your Codespaces (see its message above). If it mentions a missing scope, run:  gh auth refresh -h github.com -s codespace"
}
# Assign first, then pipe: 5.1's ConvertFrom-Json emits a JSON array as one
# object, and piping the variable enumerates it on every version.
$codespaces = ($listing -join "`n") | ConvertFrom-Json
$codespace = $codespaces |
  Where-Object { $_.repository -eq $Repo -and $_.state -eq 'Available' } |
  Select-Object -First 1
if (-not $codespace) {
  Fail "No running Codespace for $Repo. Open it from https://github.com/codespaces, run  bash .devcontainer/lab-up.sh  there, then try again."
}

$base = "http://127.0.0.1:$LocalPort"
$log = Join-Path $dir 'tunnel.log'
Write-Host "Opening a tunnel to $($codespace.name) (gateway LLM plane) on $base ..."
$tunnel = Start-Process -FilePath 'gh' -PassThru -NoNewWindow `
  -ArgumentList @('codespace', 'ports', 'forward', "8082:$LocalPort", '-c', $codespace.name) `
  -RedirectStandardOutput "$log.out" -RedirectStandardError $log

$ready = $false
for ($i = 0; $i -lt 30 -and -not $ready; $i++) {
  Start-Sleep -Seconds 1
  try {
    $r = Invoke-WebRequest -UseBasicParsing -Uri "$base/health" -TimeoutSec 2
    $ready = ($r.StatusCode -eq 200)
  } catch { }
  if (-not $ready -and $tunnel.HasExited) { break }
}
if (-not $ready) {
  if (-not $tunnel.HasExited) { Stop-Process -Id $tunnel.Id -Force -ErrorAction SilentlyContinue }
  $why = ''
  if (Test-Path $log) { $why = (Get-Content $log -Tail 5) -join "`n       " }
  Fail "The gateway didn't answer on $base/health. Is the lab running in the Codespace (bash .devcontainer/lab-up.sh)?`n       Tunnel output: $why"
}
Write-Host "Gateway reachable. Starting Claude Code through it (type /status to check, /exit to finish)." -ForegroundColor Green

# 3. Claude Code, routed through the gateway for this window only.
$env:ANTHROPIC_BASE_URL = $base
$env:ANTHROPIC_CUSTOM_HEADERS = "X-Gateway-Key: $gatewayKey"
try {
  & claude @ClaudeArgs
} finally {
  Remove-Item Env:ANTHROPIC_BASE_URL, Env:ANTHROPIC_CUSTOM_HEADERS -ErrorAction SilentlyContinue
  if (-not $tunnel.HasExited) { Stop-Process -Id $tunnel.Id -Force -ErrorAction SilentlyContinue }
  Write-Host "Tunnel closed. This window is back to normal."
}

<#
.SYNOPSIS
  Start Claude Code on this laptop with its model calls AND its tool calls
  going through the AI Agent Gateway lab running in your GitHub Codespace.

.DESCRIPTION
  1. First run only: asks for the 'claude-code-laptop' gateway key (printed by
     lab/03-laptop-key.sh in the Codespace) and stores it encrypted for your
     Windows account (DPAPI) in %USERPROFILE%\.gateway-lab\laptop-key.
  2. Opens a private tunnel from this laptop to the gateway in the Codespace
     (gh codespace ports forward): 127.0.0.1:8082 to the LLM plane and
     127.0.0.1:8080 to the MCP (tool) plane. Nothing is exposed to the
     internet; GitHub authenticates the tunnel as you.
  3. Starts Claude Code for this window only with:
       - ANTHROPIC_BASE_URL / ANTHROPIC_CUSTOM_HEADERS: model calls go through
         the gateway; your claude.ai login stays the credential Anthropic sees;
       - --mcp-config: the gateway as an extra tool server named "gateway".
         The config file holds a ${GATEWAY_LAPTOP_KEY} placeholder, never the
         key; Claude Code fills it in from this process's environment. If the
         key is bound to a profile (lab/03-laptop-key.sh --profile), only that
         profile's tools are visible or callable.
     When Claude Code exits, the tunnel closes; other terminals, your other
     tool servers and your Claude Code settings are untouched.

  Needs: GitHub CLI (winget install --id GitHub.cli), signed in with the
  codespace scope (gh auth refresh -h github.com -s codespace), and Claude
  Code (irm https://claude.ai/install.ps1 | iex). The Codespace must be
  running with the lab started (bash .devcontainer/lab-up.sh).

OPTIONS (matched exactly; everything else is passed to Claude Code)
  -ResetKey   Forget the stored key and ask again (after lab/03-laptop-key.sh --rotate).
  -NoTools    Route only model calls; don't add the gateway as a tool server.
  -Repo X     The fork whose Codespace to use (default AntRanger-Vas/ai-agent-gateway).

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File claude-via-gateway.ps1
.EXAMPLE
  powershell -ExecutionPolicy Bypass -File claude-via-gateway.ps1 -ResetKey
.EXAMPLE
  powershell -ExecutionPolicy Bypass -File claude-via-gateway.ps1 -c
  Continues your last Claude Code conversation (any Claude Code flag works: -c, -r, -p "..." and so on).
#>
# No param() block on purpose. PowerShell's parameter binding matches flags by
# prefix and adds its own common parameters, so Claude Code's short flags were
# swallowed or rejected (-p is ambiguous with -PipelineVariable, -r with
# -ResetKey/-Repo, -c had no value). The launcher's three options are matched
# exactly here; every other argument goes to Claude Code untouched.
$ResetKey = $false
$NoTools = $false
$Repo = 'AntRanger-Vas/ai-agent-gateway'
$LocalPort = 8082
$McpLocalPort = 8080
$ClaudeArgs = @()
for ($i = 0; $i -lt $args.Count; $i++) {
  $a = [string]$args[$i]
  if ($a -ieq '-ResetKey') { $ResetKey = $true }
  elseif ($a -ieq '-NoTools') { $NoTools = $true }
  elseif ($a -ieq '-Repo' -and ($i + 1) -lt $args.Count) { $i++; $Repo = [string]$args[$i] }
  else { $ClaudeArgs += $a }
}
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
$mcpBase = "http://127.0.0.1:$McpLocalPort"
$forward = @("8082:$LocalPort")
$checks = @("$base/health")
if (-not $NoTools) {
  $forward += "8080:$McpLocalPort"
  $checks += "$mcpBase/health"
}
$log = Join-Path $dir 'tunnel.log'
Write-Host "Opening a tunnel to $($codespace.name) (gateway: $($forward -join ', ')) ..."
$tunnel = Start-Process -FilePath 'gh' -PassThru -NoNewWindow `
  -ArgumentList (@('codespace', 'ports', 'forward') + $forward + @('-c', $codespace.name)) `
  -RedirectStandardOutput "$log.out" -RedirectStandardError $log

# Wait until every forwarded plane answers its /health.
$pending = @($checks)
for ($i = 0; $i -lt 30 -and $pending.Count -gt 0; $i++) {
  Start-Sleep -Seconds 1
  $still = @()
  foreach ($url in $pending) {
    $ok = $false
    try { $ok = ((Invoke-WebRequest -UseBasicParsing -Uri $url -TimeoutSec 2).StatusCode -eq 200) } catch { }
    if (-not $ok) { $still += $url }
  }
  $pending = $still
  if ($pending.Count -gt 0 -and $tunnel.HasExited) { break }
}
if ($pending.Count -gt 0) {
  if (-not $tunnel.HasExited) { Stop-Process -Id $tunnel.Id -Force -ErrorAction SilentlyContinue }
  $why = ''
  if (Test-Path $log) { $why = (Get-Content $log -Tail 5) -join "`n       " }
  Fail "The gateway didn't answer on $($pending -join ', '). Is the lab running in the Codespace (bash .devcontainer/lab-up.sh)?`n       Tunnel output: $why"
}

# 3. Claude Code, routed through the gateway for this window only.
$env:ANTHROPIC_BASE_URL = $base
$env:ANTHROPIC_CUSTOM_HEADERS = "X-Gateway-Key: $gatewayKey"
$launchArgs = @()
if (-not $NoTools) {
  # The file holds a placeholder, never the key: Claude Code expands
  # ${GATEWAY_LAPTOP_KEY} from this process's environment when it connects.
  # ASCII, so Windows PowerShell 5.1 writes no byte-order mark.
  $mcpFile = Join-Path $dir 'mcp.json'
  $mcpJson = '{"mcpServers":{"gateway":{"type":"http","url":"' + $mcpBase + '/mcp",' +
             '"headers":{"Authorization":"Bearer ${GATEWAY_LAPTOP_KEY}"}}}}'
  Set-Content -Path $mcpFile -Value $mcpJson -Encoding Ascii
  $env:GATEWAY_LAPTOP_KEY = $gatewayKey
  $launchArgs += @('--mcp-config', $mcpFile)
  Write-Host "Gateway reachable. Model calls and the 'gateway' tool server go through it. /status and /mcp to check, /exit to finish." -ForegroundColor Green
} else {
  Write-Host "Gateway reachable. Model calls go through it. /status to check, /exit to finish." -ForegroundColor Green
}
if ($ClaudeArgs) { $launchArgs += $ClaudeArgs }
try {
  & claude @launchArgs
} finally {
  Remove-Item Env:ANTHROPIC_BASE_URL, Env:ANTHROPIC_CUSTOM_HEADERS, Env:GATEWAY_LAPTOP_KEY -ErrorAction SilentlyContinue
  if (-not $tunnel.HasExited) { Stop-Process -Id $tunnel.Id -Force -ErrorAction SilentlyContinue }
  Write-Host "Tunnel closed. This window is back to normal."
}

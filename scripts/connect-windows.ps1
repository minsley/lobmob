# lobmob connect — Windows (PowerShell)
# Installs WireGuard, configures tunnel to lobboss, connects, opens web UI.
# Can run standalone or via: lobmob connect
#
# Run as Administrator:
#   powershell -ExecutionPolicy Bypass -File scripts\connect-windows.ps1
#
# If running from WSL, use the Linux script instead.

$ErrorActionPreference = "Stop"

# --- Config discovery ---
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$LobmobDir = if ($env:LOBMOB_DIR) { $env:LOBMOB_DIR } else { Split-Path -Parent $ScriptDir }
$InfraDir = Join-Path $LobmobDir "infra"
$SshKey = if ($env:LOBMOB_SSH_KEY) { $env:LOBMOB_SSH_KEY } else { Join-Path $HOME ".ssh\lobmob_ed25519" }
$WgDir = "C:\Program Files\WireGuard\Data\Configurations"
$WgConf = Join-Path $WgDir "lobmob.conf.dpapi"
$WgConfPlain = Join-Path $env:TEMP "lobmob.conf"
$ClientIP = "10.0.0.100"
$WebUrl = ""  # resolved after lobboss IP is known

function Log($msg)  { Write-Host "[lobmob] $msg" -ForegroundColor Green }
function Warn($msg) { Write-Host "[lobmob] $msg" -ForegroundColor Yellow }
function Err($msg)  { Write-Host "[lobmob] $msg" -ForegroundColor Red }

function Get-LobbossIP {
    if ((Test-Path $InfraDir) -and (Get-Command terraform -ErrorAction SilentlyContinue)) {
        try {
            $ip = terraform -chdir="$InfraDir" output -raw lobboss_ip 2>$null
            if ($ip) { return $ip }
        } catch {}
    }
    $ipFile = Join-Path $LobmobDir ".lobboss_ip"
    if (Test-Path $ipFile) { return (Get-Content $ipFile -Raw).Trim() }
    return $null
}

# --- Check admin ---
$isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Err "This script must be run as Administrator (WireGuard requires elevated privileges)"
    Err "Right-click PowerShell -> 'Run as administrator', then re-run this script"
    exit 1
}

# --- Step 1: Install WireGuard ---
Log "Step 1 - WireGuard"
$wgExe = "C:\Program Files\WireGuard\wireguard.exe"
if (Test-Path $wgExe) {
    Write-Host "  [ok] WireGuard installed" -ForegroundColor Green
} else {
    if (Get-Command winget -ErrorAction SilentlyContinue) {
        Log "  Installing WireGuard via winget..."
        winget install --id WireGuard.WireGuard --accept-package-agreements --accept-source-agreements
    } elseif (Get-Command choco -ErrorAction SilentlyContinue) {
        Log "  Installing WireGuard via Chocolatey..."
        choco install wireguard -y
    } else {
        Err "No package manager found (winget or chocolatey)"
        Err "Download WireGuard from: https://www.wireguard.com/install/"
        exit 1
    }
    if (-not (Test-Path $wgExe)) {
        Err "WireGuard installation failed. Install manually and re-run."
        exit 1
    }
}

# wg.exe should be in PATH after install, but add it just in case
$wgToolsDir = "C:\Program Files\WireGuard"
if ($env:PATH -notlike "*$wgToolsDir*") {
    $env:PATH = "$wgToolsDir;$env:PATH"
}

# --- Step 2: Configure tunnel ---
Log "Step 2 - Tunnel config"
# Check if tunnel service already exists
$tunnelExists = & "C:\Program Files\WireGuard\wireguard.exe" /dumplog 2>&1 | Select-String "lobmob" -Quiet
# Simpler check: see if the dpapi config exists
if (Test-Path $WgConf) {
    Write-Host "  [ok] Tunnel config exists" -ForegroundColor Green
} else {
    Log "  Generating WireGuard keypair..."
    $privkey = & wg genkey
    $pubkey = $privkey | & wg pubkey

    $lobbossIP = Get-LobbossIP
    if (-not $lobbossIP) {
        $lobbossIP = Read-Host "  Lobboss public IP"
    }

    Log "  Registering peer on lobboss..."
    if (-not (Test-Path $SshKey)) {
        Err "SSH key not found at $SshKey"
        Err "Run 'lobmob bootstrap' first, or set LOBMOB_SSH_KEY env var"
        exit 1
    }

    $registerScript = @"
wg set wg0 peer "$pubkey" allowed-ips "$ClientIP/32"
if ! grep -q "$pubkey" /etc/wireguard/wg0.conf 2>/dev/null; then
  cat >> /etc/wireguard/wg0.conf <<PEEREOF

[Peer]
# Operator workstation (Windows)
PublicKey = $pubkey
AllowedIPs = $ClientIP/32
PEEREOF
fi
wg show wg0 public-key
"@
    $lobbossWgPubkey = ($registerScript | & ssh -i $SshKey -o StrictHostKeyChecking=accept-new "root@$lobbossIP" bash).Trim()

    if (-not $lobbossWgPubkey) {
        Err "Failed to register peer on lobboss"
        exit 1
    }

    Log "  Writing tunnel config..."
    $confContent = @"
[Interface]
PrivateKey = $privkey
Address = $ClientIP/24

[Peer]
PublicKey = $lobbossWgPubkey
AllowedIPs = 10.0.0.0/24
Endpoint = ${lobbossIP}:51820
PersistentKeepalive = 25
"@
    $confContent | Out-File -FilePath $WgConfPlain -Encoding ASCII -NoNewline

    # Import via WireGuard CLI (encrypts to .dpapi)
    & "C:\Program Files\WireGuard\wireguard.exe" /installtunnelservice $WgConfPlain
    Remove-Item $WgConfPlain -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 3
    Write-Host "  [ok] Tunnel imported and started" -ForegroundColor Green
}

# --- Step 3: Connect ---
Log "Step 3 - Connect"
# Check if tunnel service is running
$svc = Get-Service -Name "WireGuardTunnel`$lobmob" -ErrorAction SilentlyContinue
if ($svc -and $svc.Status -eq "Running") {
    Write-Host "  [ok] Tunnel already running" -ForegroundColor Green
} else {
    Log "  Starting tunnel service..."
    if (-not $svc) {
        # Install tunnel service if not yet installed
        if (Test-Path $WgConf) {
            & "C:\Program Files\WireGuard\wireguard.exe" /installtunnelservice (Join-Path $WgDir "lobmob.conf.dpapi")
        }
    } else {
        Start-Service "WireGuardTunnel`$lobmob"
    }
    Start-Sleep -Seconds 3
}

# Wait for connectivity
Log "  Waiting for lobboss..."
$connected = $false
for ($i = 1; $i -le 10; $i++) {
    if (Test-Connection -ComputerName 10.0.0.1 -Count 1 -Quiet -TimeoutSeconds 2) {
        Write-Host "  [ok] Connected to lobboss (10.0.0.1)" -ForegroundColor Green
        $connected = $true
        break
    }
    Start-Sleep -Seconds 2
}
if (-not $connected) {
    Err "Could not reach lobboss at 10.0.0.1 - check WireGuard config"
    exit 1
}

# --- Step 4: Open web UI ---
Log "Step 4 - Web UI"
$lobbossIP = Get-LobbossIP
if (-not $lobbossIP) { $lobbossIP = "10.0.0.1" }
$WebUrl = "https://$lobbossIP"
try {
    [System.Net.ServicePointManager]::ServerCertificateValidationCallback = { $true }
    $health = Invoke-WebRequest -Uri "$WebUrl/health" -TimeoutSec 5 -UseBasicParsing -ErrorAction Stop
    if ($health.StatusCode -eq 200) {
        Write-Host "  [ok] Web UI reachable" -ForegroundColor Green
        Log "Opening $WebUrl ..."
        Start-Process $WebUrl
    }
} catch {
    Warn "Web UI not responding at $WebUrl (lobboss may still be starting)"
    Warn "Try: Start-Process $WebUrl"
}

Write-Host ""
Log "Connected to lobmob swarm via WireGuard"
Log "  Web UI:     $WebUrl"
Log "  SSH:        ssh -i $SshKey root@10.0.0.1"
Log "  Disconnect: wireguard /uninstalltunnelservice lobmob"

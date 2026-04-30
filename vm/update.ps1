<#
.SYNOPSIS
    Update Chicken Monitor on existing Hyper-V VM.
.NOTES
    Run as Administrator: .\update.ps1
#>

param(
    [string]$VMName = "Chicken-Monitor",
    [switch]$ResetDB
)

$ErrorActionPreference = "Stop"
$VMPath     = "C:\Hyper-V\Chicken-Monitor"
$SshKeyPath = Join-Path $VMPath "id_deploy"
$ProjectDir = Split-Path $PSScriptRoot -Parent

# Check VM exists and running
$vm = Get-VM -Name $VMName -ErrorAction SilentlyContinue
if (-not $vm) {
    Write-Host "VM '$VMName' not found. Run deploy.ps1 first." -ForegroundColor Red
    exit 1
}
if ($vm.State -ne "Running") {
    Write-Host "Starting VM..." -ForegroundColor Cyan
    Start-VM -Name $VMName
    Start-Sleep -Seconds 15
}

# Get VM IP (KVP first, then ARP fallback)
$ip = (Get-VM -Name $VMName).NetworkAdapters.IPAddresses |
    Where-Object { $_ -match '^\d+\.\d+\.\d+\.\d+$' } |
    Select-Object -First 1

if (-not $ip) {
    Write-Host "KVP empty, trying ARP..." -ForegroundColor Yellow
    $vmMac = (Get-VMNetworkAdapter -VMName $VMName | Select-Object -First 1).MacAddress
    $vmMacFormatted = ($vmMac -replace '(.{2})', '$1-').TrimEnd('-').ToLower()

    # Ping broadcast on Default Switch to populate ARP
    $hostIp = (Get-NetIPAddress -InterfaceAlias "vEthernet (Default Switch)" -AddressFamily IPv4 -ErrorAction SilentlyContinue).IPAddress
    if ($hostIp) {
        $subnet = ($hostIp -replace '\.\d+$', '')
        & ping -n 1 -w 500 "${subnet}.255" 2>$null | Out-Null
    }

    $arpLines = & arp -a 2>$null
    foreach ($line in $arpLines) {
        if ($line -match '^\s*([\d\.]+)\s+([0-9a-f-]+)') {
            if ($Matches[2] -eq $vmMacFormatted -and $Matches[1] -ne "255.255.255.255") {
                $ip = $Matches[1]
                break
            }
        }
    }
}

if (-not $ip) {
    Write-Host "Could not get VM IP. Check VM network." -ForegroundColor Red
    exit 1
}
Write-Host "VM IP: $ip" -ForegroundColor Cyan

$sshOpts = @("-o", "StrictHostKeyChecking=no", "-o", "UserKnownHostsFile=/dev/null", "-o", "LogLevel=ERROR", "-i", $SshKeyPath)
$Username = "ubuntu"

# Archive and copy project
Write-Host "Copying project..." -ForegroundColor Cyan
$archivePath = Join-Path $VMPath "project.tar.gz"
& tar -czf $archivePath --exclude=.git --exclude=deploy.ps1 -C $ProjectDir .
& scp @sshOpts "$archivePath" "${Username}@${ip}:/home/$Username/project.tar.gz"

# Extract and rebuild
Write-Host "Rebuilding containers..." -ForegroundColor Cyan
if ($ResetDB) {
    Write-Host "  Resetting database (volumes will be recreated)..." -ForegroundColor Yellow
    & ssh @sshOpts "${Username}@${ip}" "cd /home/$Username/chicken-monitor && tar -xzf /home/$Username/project.tar.gz && rm /home/$Username/project.tar.gz && sudo docker compose down -v && sudo docker compose up -d --build"
} else {
    & ssh @sshOpts "${Username}@${ip}" "cd /home/$Username/chicken-monitor && tar -xzf /home/$Username/project.tar.gz && rm /home/$Username/project.tar.gz && sudo docker compose up -d --build"
}

Write-Host ""
Write-Host "Updated! http://${ip}:8000" -ForegroundColor Green

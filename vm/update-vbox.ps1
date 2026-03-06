<#
.SYNOPSIS
    Update Chicken Monitor on existing VirtualBox VM.
.NOTES
    Run: .\update-vbox.ps1
#>

param(
    [string]$VMName = "Chicken-Monitor",
    [switch]$ResetDB
)

$ErrorActionPreference = "Stop"
$VMPath     = "C:\VirtualBox-VMs\Chicken-Monitor"
$SshKeyPath = Join-Path $VMPath "id_deploy"
$ProjectDir = Join-Path (Split-Path $PSScriptRoot -Parent) "project"
$Username   = "ubuntu"
$sshPort    = 2222
$sshTarget  = "127.0.0.1"

# Find VBoxManage
$VBoxManage = $null
$candidates = @(
    "C:\Program Files\Oracle\VirtualBox\VBoxManage.exe",
    "C:\Program Files (x86)\Oracle\VirtualBox\VBoxManage.exe"
)
foreach ($c in $candidates) {
    if (Test-Path $c) { $VBoxManage = $c; break }
}
if (-not $VBoxManage) {
    $VBoxManage = Get-Command VBoxManage -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Source
}
if (-not $VBoxManage) {
    Write-Host "VirtualBox not found." -ForegroundColor Red
    exit 1
}

# Check VM exists
$existingVMs = & $VBoxManage list vms 2>&1
if ($existingVMs -notmatch "`"$VMName`"") {
    Write-Host "VM '$VMName' not found. Run deploy-vbox.ps1 first." -ForegroundColor Red
    exit 1
}

# Check VM state, start if needed
$vmInfo = & $VBoxManage showvminfo $VMName --machinereadable 2>&1
$vmState = ($vmInfo | Select-String '^VMState="(.+)"').Matches.Groups[1].Value

if ($vmState -ne "running") {
    Write-Host "Starting VM..." -ForegroundColor Cyan
    & $VBoxManage startvm $VMName --type headless
    Start-Sleep -Seconds 15
}

# Wait for SSH
Write-Host "Checking SSH..." -ForegroundColor Cyan
$sshReady = $false
$elapsed = 0
while (-not $sshReady -and $elapsed -lt 60) {
    try {
        $tcpClient = New-Object System.Net.Sockets.TcpClient
        $tcpClient.Connect($sshTarget, $sshPort)
        $sshReady = $tcpClient.Connected
        $tcpClient.Close()
    } catch {
        Start-Sleep -Seconds 5
        $elapsed += 5
    }
}
if (-not $sshReady) {
    Write-Host "SSH not available on port $sshPort." -ForegroundColor Red
    exit 1
}

$sshOpts = @("-o", "StrictHostKeyChecking=no", "-o", "UserKnownHostsFile=/dev/null", "-o", "LogLevel=ERROR", "-i", $SshKeyPath, "-p", "$sshPort")

# Archive and copy project
Write-Host "Copying project..." -ForegroundColor Cyan
$archivePath = Join-Path $VMPath "project.tar.gz"
& tar -czf $archivePath --exclude=.git --exclude=deploy.ps1 --exclude=deploy-vbox.ps1 -C $ProjectDir .
& scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -i $SshKeyPath -P $sshPort "$archivePath" "${Username}@${sshTarget}:/home/$Username/project.tar.gz"

# Extract and rebuild
Write-Host "Rebuilding containers..." -ForegroundColor Cyan
if ($ResetDB) {
    Write-Host "  Resetting database (volumes will be recreated)..." -ForegroundColor Yellow
    & ssh @sshOpts "${Username}@${sshTarget}" "cd /home/$Username/chicken-monitor && tar -xzf /home/$Username/project.tar.gz && rm /home/$Username/project.tar.gz && sudo docker compose down -v && sudo docker compose up -d --build"
} else {
    & ssh @sshOpts "${Username}@${sshTarget}" "cd /home/$Username/chicken-monitor && tar -xzf /home/$Username/project.tar.gz && rm /home/$Username/project.tar.gz && sudo docker compose up -d --build"
}

Write-Host ""
Write-Host "Updated! http://localhost:8080" -ForegroundColor Green

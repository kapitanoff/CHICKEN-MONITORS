<#
.SYNOPSIS
    Auto-deploy Chicken Monitor in Hyper-V VM.
.NOTES
    Run as Administrator: .\deploy.ps1
#>

param(
    [string]$VMName = "Chicken-Monitor",
    [int64]$MemoryBytes = 4GB,
    [int64]$DiskSizeBytes = 30GB,
    [string]$VMPath = "C:\Hyper-V\Chicken-Monitor",
    [string]$Username = "ubuntu",
    [string]$Password
)

if (-not $Password) {
    $securePass = Read-Host "Enter VM password for user '$Username'" -AsSecureString
    $Password = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto(
        [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($securePass)
    )
    if (-not $Password) {
        Write-Host "Password cannot be empty." -ForegroundColor Red
        exit 1
    }
}

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

$CloudImageUrl = "https://cloud-images.ubuntu.com/releases/24.04/release/ubuntu-24.04-server-cloudimg-amd64.img"
$ImgPath       = Join-Path $VMPath "cloud.img"
$VhdxPath      = Join-Path $VMPath "disk.vhdx"
$CloudInitIso  = Join-Path $VMPath "cloud-init.iso"
$SshKeyPath    = Join-Path $VMPath "id_deploy"
$ProjectDir    = Join-Path (Split-Path $PSScriptRoot -Parent) "project"

function Write-Step  { param($msg) Write-Host "`n[$((Get-Date).ToString('HH:mm:ss'))] $msg" -ForegroundColor Cyan }
function Write-Ok    { param($msg) Write-Host "  OK: $msg" -ForegroundColor Green }
function Write-Warn  { param($msg) Write-Host "  WARN: $msg" -ForegroundColor Yellow }
function Write-Err   { param($msg) Write-Host "  ERROR: $msg" -ForegroundColor Red }

# === 1. Checks ===
Write-Step "Checking prerequisites..."

if (-not ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()
    ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Err "Run this script as Administrator!"
    exit 1
}
Write-Ok "Administrator"

$hyperv = Get-WindowsOptionalFeature -FeatureName Microsoft-Hyper-V-All -Online -ErrorAction SilentlyContinue
if (-not $hyperv -or $hyperv.State -ne "Enabled") {
    Write-Err "Hyper-V not enabled. Run: Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V-All"
    exit 1
}
Write-Ok "Hyper-V enabled"

$existingVM = Get-VM -Name $VMName -ErrorAction SilentlyContinue
if ($existingVM) {
    # VM already exists — just start it and show IP
    if ($existingVM.State -ne "Running") {
        Write-Step "Starting existing VM '$VMName'..."
        Start-VM -Name $VMName
    } else {
        Write-Ok "VM '$VMName' is already running"
    }

    Write-Step "Waiting for IP address..."
    $ip = $null
    $elapsed = 0
    while (-not $ip -and $elapsed -lt 120) {
        Start-Sleep -Seconds 3
        $elapsed += 3
        $ips = (Get-VM -Name $VMName).NetworkAdapters.IPAddresses
        $ip = $ips | Where-Object { $_ -match '^\d+\.\d+\.\d+\.\d+$' } | Select-Object -First 1
    }
    if (-not $ip) {
        Write-Err "Could not get IP after 120 seconds."
        exit 1
    }

    Write-Host ""
    Write-Host "===================================================" -ForegroundColor Green
    Write-Host "  Chicken Monitor ready!" -ForegroundColor Green
    Write-Host "===================================================" -ForegroundColor Green
    Write-Host ""
    Write-Host "  Open in browser: " -NoNewline; Write-Host "http://${ip}:8000" -ForegroundColor Yellow
    Write-Host "  SSH:             " -NoNewline; Write-Host "ssh -i $(Join-Path $VMPath 'id_deploy') ubuntu@${ip}" -ForegroundColor Yellow
    Write-Host ""
    exit 0
}

$maxCpu = (Get-VMHost).LogicalProcessorCount
$cpuCount = [Math]::Min(4, $maxCpu)
Write-Ok "CPU: $cpuCount (available: $maxCpu)"

$switch = Get-VMSwitch | Where-Object { $_.Name -eq "Default Switch" } | Select-Object -First 1
if (-not $switch) { $switch = Get-VMSwitch | Select-Object -First 1 }
if (-not $switch) {
    Write-Err "No virtual switch found. Create Default Switch in Hyper-V."
    exit 1
}
Write-Ok "Network: $($switch.Name)"

# === 2. Prepare directory and SSH key ===
Write-Step "Preparing..."
New-Item -ItemType Directory -Path $VMPath -Force | Out-Null

if (Test-Path $SshKeyPath) { Remove-Item $SshKeyPath, "$SshKeyPath.pub" -Force -ErrorAction SilentlyContinue }
& ssh-keygen -t ed25519 -f $SshKeyPath -N '""' -q 2>$null
$sshPubKey = (Get-Content "$SshKeyPath.pub" -Raw).Trim()
Write-Ok "SSH key generated"

# === 3. Download Ubuntu Cloud Image ===
$qemuImg = "C:\Program Files\qemu\qemu-img.exe"
if (-not (Test-Path $qemuImg)) {
    Write-Err "qemu-img not found. Install: winget install SoftwareFreedomConservancy.QEMU"
    exit 1
}
Write-Ok "qemu-img found"

if (Test-Path $VhdxPath) {
    Write-Ok "VHDX already exists, skipping download"
} else {
    Write-Step "Downloading Ubuntu 24.04 Cloud Image (~600MB)..."
    Write-Host "  URL: $CloudImageUrl"
    try {
        Invoke-WebRequest -Uri $CloudImageUrl -OutFile $ImgPath -UseBasicParsing
        Write-Ok "Downloaded: $ImgPath"
    } catch {
        Write-Err "Failed to download image: $_"
        exit 1
    }

    # Convert .img to .vhdx using qemu-img
    Write-Step "Converting IMG to VHDX..."
    & $qemuImg convert -f qcow2 -O vhdx -o subformat=dynamic $ImgPath $VhdxPath
    if ($LASTEXITCODE -ne 0) {
        Write-Err "qemu-img conversion failed"
        exit 1
    }
    Remove-Item $ImgPath -Force
    Write-Ok "Converted to VHDX"
}

Write-Step "Resizing disk to $($DiskSizeBytes / 1GB) GB..."
& fsutil sparse setflag $VhdxPath 0
& compact /u $VhdxPath | Out-Null
Resize-VHD -Path $VhdxPath -SizeBytes $DiskSizeBytes
Write-Ok "Disk resized"

# === 4. Create cloud-init data disk (FAT32 VHDX labeled "cidata") ===
Write-Step "Creating cloud-init data disk..."

$ciDataVhdx = Join-Path $VMPath "cidata.vhdx"
if (Test-Path $ciDataVhdx) { Remove-Item $ciDataVhdx -Force }

# Create small 32MB VHDX for cloud-init
New-VHD -Path $ciDataVhdx -SizeBytes 32MB -Dynamic | Out-Null
Mount-VHD -Path $ciDataVhdx

$ciDiskNumber = (Get-Disk | Where-Object { $_.Location -eq $ciDataVhdx }).Number
Initialize-Disk -Number $ciDiskNumber -PartitionStyle MBR
$ciPartition = New-Partition -DiskNumber $ciDiskNumber -UseMaximumSize -AssignDriveLetter
Format-Volume -Partition $ciPartition -FileSystem FAT -NewFileSystemLabel "cidata" -Confirm:$false | Out-Null

$ciDrive = "$($ciPartition.DriveLetter):"

$metaDataContent = "instance-id: chicken-monitor-001`nlocal-hostname: chicken-monitor"
[System.IO.File]::WriteAllText("$ciDrive\meta-data", $metaDataContent, (New-Object System.Text.UTF8Encoding($false)))

$userDataContent = @"
#cloud-config
hostname: chicken-monitor
manage_etc_hosts: true

users:
  - name: $Username
    plain_text_passwd: "$Password"
    lock_passwd: false
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/bash
    groups: [docker]
    ssh_authorized_keys:
      - $sshPubKey

ssh_pwauth: true

package_update: true

packages:
  - docker.io
  - docker-compose-v2
  - openssh-server
  - linux-cloud-tools-generic

growpart:
  mode: auto
  devices: ['/']

runcmd:
  - systemctl enable docker
  - systemctl start docker
  - systemctl enable ssh
  - systemctl start ssh
  - mkdir -p /home/$Username/chicken-monitor
  - chown -R ${Username}:${Username} /home/$Username/chicken-monitor
  - echo "CLOUD_INIT_DONE" > /home/$Username/.cloud-init-complete
  - chown ${Username}:${Username} /home/$Username/.cloud-init-complete
"@
[System.IO.File]::WriteAllText("$ciDrive\user-data", $userDataContent, (New-Object System.Text.UTF8Encoding($false)))

Dismount-VHD -Path $ciDataVhdx
Write-Ok "Cloud-init data disk created"

# === 5. Create VM ===
Write-Step "Creating Hyper-V VM '$VMName'..."

New-VM -Name $VMName `
       -MemoryStartupBytes $MemoryBytes `
       -VHDPath $VhdxPath `
       -Generation 2 `
       -SwitchName $switch.Name `
       -Path $VMPath | Out-Null

Set-VMProcessor -VMName $VMName -Count $cpuCount
Set-VMFirmware  -VMName $VMName -EnableSecureBoot Off

# Attach cloud-init data disk
Add-VMHardDiskDrive -VMName $VMName -ControllerType SCSI -Path $ciDataVhdx

Write-Ok "VM created: $cpuCount CPU, $($MemoryBytes / 1GB) GB RAM, Secure Boot Off"

# === 6. Start VM ===
Write-Step "Starting VM..."
Start-VM -Name $VMName
Write-Ok "VM started"

# === 7. Wait for IP ===
Write-Step "Waiting for IP address (up to 180s)..."

# Wait a bit for VM to fully start and get MAC assigned
Start-Sleep -Seconds 10

# Get VM MAC address via Get-VMNetworkAdapter
$vmAdapter = Get-VMNetworkAdapter -VMName $VMName | Select-Object -First 1
$vmMac = $vmAdapter.MacAddress
# Format: 001122334455 -> 00-11-22-33-44-55
$vmMacFormatted = ($vmMac -replace '(.{2})', '$1-').TrimEnd('-').ToLower()
Write-Host "  VM MAC: $vmMacFormatted"

# Get Default Switch subnet for ping broadcast
$hostIp = (Get-NetIPAddress -InterfaceAlias "vEthernet (Default Switch)" -AddressFamily IPv4 -ErrorAction SilentlyContinue).IPAddress
if ($hostIp) {
    Write-Host "  Host IP on Default Switch: $hostIp"
}

$ip = $null
$timeout = 180
$elapsed = 0
while (-not $ip -and $elapsed -lt $timeout) {
    Start-Sleep -Seconds 5
    $elapsed += 5

    # Method 1: Hyper-V KVP
    $kvpIps = (Get-VM -Name $VMName).NetworkAdapters.IPAddresses
    $ip = $kvpIps | Where-Object { $_ -match '^\d+\.\d+\.\d+\.\d+$' } | Select-Object -First 1

    # Method 2: ARP table (ping broadcast first to populate)
    if (-not $ip -and $hostIp) {
        $subnet = ($hostIp -replace '\.\d+$', '')
        & ping -n 1 -w 100 "${subnet}.255" 2>$null | Out-Null
        $arpLines = & arp -a 2>$null
        foreach ($line in $arpLines) {
            if ($line -match '^\s*([\d\.]+)\s+([0-9a-f-]+)') {
                $arpIp = $Matches[1]
                $arpMac = $Matches[2]
                if ($arpMac -eq $vmMacFormatted -and $arpIp -ne "255.255.255.255") {
                    $ip = $arpIp
                    break
                }
            }
        }
    }

    if (-not $ip) { Write-Host "  ... waiting ($elapsed sec)" -ForegroundColor Gray }
}
if (-not $ip) {
    Write-Err "VM did not get IP address in $timeout seconds."
    Write-Host "  Check VM console for IP. Then run manually:"
    Write-Host "  ssh -i $SshKeyPath ${Username}@<VM_IP>"
    exit 1
}
Write-Ok "IP: $ip"

$sshOpts = @("-o", "StrictHostKeyChecking=no", "-o", "UserKnownHostsFile=/dev/null", "-o", "LogLevel=ERROR", "-i", $SshKeyPath)

# === 8. Wait for cloud-init and SSH ===
Write-Step "Waiting for SSH (up to 300s)..."

$timeout = 300
$elapsed = 0
$sshReady = $false
while (-not $sshReady -and $elapsed -lt $timeout) {
    Start-Sleep -Seconds 10
    $elapsed += 10
    try {
        $tcpClient = New-Object System.Net.Sockets.TcpClient
        $tcpClient.Connect($ip, 22)
        $sshReady = $tcpClient.Connected
        $tcpClient.Close()
    } catch {
        Write-Host "  ... SSH not ready ($elapsed sec)" -ForegroundColor Gray
    }
}
if (-not $sshReady) {
    Write-Err "SSH not available after $timeout seconds."
    exit 1
}
Write-Ok "SSH ready"

Write-Step "Waiting for cloud-init (installing Docker)..."
$timeout = 600
$elapsed = 0
$cloudInitDone = $false
while (-not $cloudInitDone -and $elapsed -lt $timeout) {
    Start-Sleep -Seconds 15
    $elapsed += 15
    $checkResult = & ssh @sshOpts "${Username}@${ip}" "cat /home/$Username/.cloud-init-complete 2>/dev/null" 2>&1
    if ("$checkResult" -match "CLOUD_INIT_DONE") {
        $cloudInitDone = $true
    } else {
        Write-Host "  ... cloud-init running ($elapsed sec)" -ForegroundColor Gray
    }
}
if (-not $cloudInitDone) {
    Write-Warn "cloud-init did not finish in $timeout sec, trying to continue..."
}
Write-Ok "Cloud-init done"

# === 9. Copy project and start ===
Write-Step "Copying project to VM..."

$envFile = Join-Path $ProjectDir ".env"
$envExampleFile = Join-Path $ProjectDir ".env.example"
if (-not (Test-Path $envFile)) {
    if (Test-Path $envExampleFile) {
        Copy-Item $envExampleFile $envFile
        Write-Warn "Created .env from .env.example - edit MQTT settings!"
    }
}

$archivePath = Join-Path $VMPath "project.tar.gz"
$tarExcludes = @("--exclude=.git", "--exclude=deploy.ps1", "--exclude=*.zipp", "--exclude=*.vhdx")
& tar -czf $archivePath @tarExcludes -C $ProjectDir .
Write-Ok "Project archive created"

& scp @sshOpts "$archivePath" "${Username}@${ip}:/home/$Username/project.tar.gz"
Write-Ok "Files copied"

Write-Step "Starting docker compose..."
& ssh @sshOpts "${Username}@${ip}" "cd /home/$Username/chicken-monitor && tar -xzf /home/$Username/project.tar.gz && rm /home/$Username/project.tar.gz && sudo docker compose up -d --build"

Write-Host "  Waiting for containers..."
Start-Sleep -Seconds 15

$containerCheck = & ssh @sshOpts "${Username}@${ip}" "sudo docker compose -f /home/$Username/chicken-monitor/docker-compose.yml ps" 2>&1
Write-Host "`n  Containers:"
Write-Host "  $containerCheck"

# === 10. Done! ===
Write-Host ""
Write-Host "===================================================" -ForegroundColor Green
Write-Host "  Chicken Monitor deployed!" -ForegroundColor Green
Write-Host "===================================================" -ForegroundColor Green
Write-Host ""
Write-Host "  Web UI:    " -NoNewline; Write-Host "http://${ip}:8000" -ForegroundColor Yellow
Write-Host "  SSH:       " -NoNewline; Write-Host "ssh -i $SshKeyPath ${Username}@${ip}" -ForegroundColor Yellow
Write-Host "  Password:  " -NoNewline; Write-Host "$Password" -ForegroundColor Yellow
Write-Host "  VM name:   " -NoNewline; Write-Host "$VMName" -ForegroundColor Yellow
Write-Host ""
Write-Host "  Management:" -ForegroundColor Gray
Write-Host "    Stop:    Stop-VM -Name '$VMName'" -ForegroundColor Gray
Write-Host "    Start:   Start-VM -Name '$VMName'" -ForegroundColor Gray
Write-Host "    Delete:  Stop-VM '$VMName' -Force; Remove-VM '$VMName' -Force" -ForegroundColor Gray
Write-Host ""

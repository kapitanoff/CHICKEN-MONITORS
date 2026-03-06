<#
.SYNOPSIS
    Auto-deploy Chicken Monitor in VirtualBox VM.
    Works on Windows 7+ (no Hyper-V required).
.NOTES
    Run as Administrator: .\deploy-vbox.ps1
#>

param(
    [string]$VMName = "Chicken-Monitor",
    [int]$MemoryMB = 2048,
    [int]$DiskSizeMB = 30720,
    [string]$VMPath = "C:\VirtualBox-VMs\Chicken-Monitor",
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

$CloudImageUrl = "https://cloud-images.ubuntu.com/releases/22.04/release/ubuntu-22.04-server-cloudimg-amd64.img"
$ImgPath       = Join-Path $VMPath "cloud.img"
$VdiPath       = Join-Path $VMPath "disk.vdi"
$SeedIso       = Join-Path $VMPath "seed.iso"
$SshKeyPath    = Join-Path $VMPath "id_deploy"
$ProjectDir    = Join-Path (Split-Path $PSScriptRoot -Parent) "project"

function Write-Step  { param($msg) Write-Host "`n[$((Get-Date).ToString('HH:mm:ss'))] $msg" -ForegroundColor Cyan }
function Write-Ok    { param($msg) Write-Host "  OK: $msg" -ForegroundColor Green }
function Write-Warn  { param($msg) Write-Host "  WARN: $msg" -ForegroundColor Yellow }
function Write-Err   { param($msg) Write-Host "  ERROR: $msg" -ForegroundColor Red }

# === Find VBoxManage ===
$VBoxManage = $null
$candidates = @(
    "C:\Program Files\Oracle\VirtualBox\VBoxManage.exe",
    "C:\Program Files (x86)\Oracle\VirtualBox\VBoxManage.exe",
    "${env:ProgramFiles}\Oracle\VirtualBox\VBoxManage.exe"
)
foreach ($c in $candidates) {
    if (Test-Path $c) { $VBoxManage = $c; break }
}
if (-not $VBoxManage) {
    $VBoxManage = Get-Command VBoxManage -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Source
}
if (-not $VBoxManage) {
    Write-Err "VirtualBox not found. Install from https://www.virtualbox.org/wiki/Downloads"
    exit 1
}

function Invoke-VBox {
    param([string[]]$Args)
    $output = & $VBoxManage @Args 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Err "VBoxManage $($Args[0]) failed: $output"
        throw "VBoxManage failed"
    }
    return $output
}

# === 1. Check if VM already exists ===
Write-Step "Checking prerequisites..."

$existingVMs = & $VBoxManage list vms 2>&1
if ($existingVMs -match "`"$VMName`"") {
    # VM exists — check state and start if needed
    $vmInfo = & $VBoxManage showvminfo $VMName --machinereadable 2>&1
    $vmState = ($vmInfo | Select-String '^VMState="(.+)"').Matches.Groups[1].Value

    if ($vmState -ne "running") {
        Write-Step "Starting existing VM '$VMName'..."
        Invoke-VBox @("startvm", $VMName, "--type", "headless")
        Start-Sleep -Seconds 10
    } else {
        Write-Ok "VM '$VMName' is already running"
    }

    # Get IP
    Write-Step "Getting IP address..."
    $ip = $null
    $elapsed = 0
    while (-not $ip -and $elapsed -lt 120) {
        Start-Sleep -Seconds 5
        $elapsed += 5
        $propResult = & $VBoxManage guestproperty get $VMName "/VirtualBox/GuestInfo/Net/0/V4/IP" 2>&1
        if ($propResult -match 'Value:\s*(\d+\.\d+\.\d+\.\d+)') {
            $ip = $Matches[1]
        }
        # Fallback: parse DHCP leases via port forwarding — we use port forward so IP = localhost
        if (-not $ip) {
            $fwdRules = & $VBoxManage showvminfo $VMName --machinereadable 2>&1 | Select-String "Forwarding"
            if ($fwdRules -match "ssh") {
                # We have port forwarding set up, use localhost
                $ip = "127.0.0.1"
            }
        }
    }

    # Determine SSH port (could be forwarded)
    $sshPort = 22
    $fwdInfo = & $VBoxManage showvminfo $VMName --machinereadable 2>&1 | Select-String "Forwarding.*ssh"
    if ($fwdInfo -match ",(\d+),,22") {
        $sshPort = $Matches[1]
        $ip = "127.0.0.1"
    }

    Write-Host ""
    Write-Host "===================================================" -ForegroundColor Green
    Write-Host "  Chicken Monitor ready!" -ForegroundColor Green
    Write-Host "===================================================" -ForegroundColor Green
    Write-Host ""
    if ($sshPort -ne 22) {
        Write-Host "  Open in browser: " -NoNewline; Write-Host "http://localhost:8080" -ForegroundColor Yellow
        Write-Host "  SSH:             " -NoNewline; Write-Host "ssh -p $sshPort -i $(Join-Path $VMPath 'id_deploy') ubuntu@127.0.0.1" -ForegroundColor Yellow
    } else {
        Write-Host "  Open in browser: " -NoNewline; Write-Host "http://${ip}:8000" -ForegroundColor Yellow
        Write-Host "  SSH:             " -NoNewline; Write-Host "ssh -i $(Join-Path $VMPath 'id_deploy') ubuntu@${ip}" -ForegroundColor Yellow
    }
    Write-Host ""
    exit 0
}

# === 2. Prepare directory and SSH key ===
Write-Step "Preparing..."
New-Item -ItemType Directory -Path $VMPath -Force | Out-Null

if (Test-Path $SshKeyPath) { Remove-Item $SshKeyPath, "$SshKeyPath.pub" -Force -ErrorAction SilentlyContinue }
& ssh-keygen -t ed25519 -f $SshKeyPath -N '""' -q 2>$null
$sshPubKey = (Get-Content "$SshKeyPath.pub" -Raw).Trim()
Write-Ok "SSH key generated"

# === 3. Download Ubuntu Cloud Image ===
if (Test-Path $VdiPath) {
    Write-Ok "VDI already exists, skipping download"
} else {
    Write-Step "Downloading Ubuntu 22.04 Cloud Image (~700MB)..."
    Write-Host "  URL: $CloudImageUrl"
    try {
        # Use .NET WebClient for better Win7 compatibility
        $webClient = New-Object System.Net.WebClient
        $webClient.DownloadFile($CloudImageUrl, $ImgPath)
        Write-Ok "Downloaded: $ImgPath"
    } catch {
        Write-Err "Failed to download image: $_"
        exit 1
    }

    # Check for qemu-img to convert
    $qemuImg = $null
    $qemuCandidates = @(
        "C:\Program Files\qemu\qemu-img.exe",
        "C:\Program Files (x86)\qemu\qemu-img.exe"
    )
    foreach ($q in $qemuCandidates) {
        if (Test-Path $q) { $qemuImg = $q; break }
    }
    if (-not $qemuImg) {
        $qemuImg = Get-Command qemu-img -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Source
    }

    if ($qemuImg) {
        Write-Step "Converting IMG to VDI via qemu-img..."
        & $qemuImg convert -f qcow2 -O vdi $ImgPath $VdiPath
        if ($LASTEXITCODE -ne 0) {
            Write-Err "qemu-img conversion failed"
            exit 1
        }
    } else {
        Write-Step "Converting IMG to VDI via VBoxManage..."
        Invoke-VBox @("convertfromraw", $ImgPath, $VdiPath, "--format", "VDI")
    }

    Remove-Item $ImgPath -Force -ErrorAction SilentlyContinue
    Write-Ok "Converted to VDI"
}

# Resize disk
Write-Step "Resizing disk to $($DiskSizeMB / 1024) GB..."
Invoke-VBox @("modifyhd", $VdiPath, "--resize", "$DiskSizeMB")
Write-Ok "Disk resized"

# === 4. Create cloud-init ISO ===
Write-Step "Creating cloud-init ISO..."

$ciDir = Join-Path $VMPath "cloud-init-data"
New-Item -ItemType Directory -Path $ciDir -Force | Out-Null

$metaDataContent = "instance-id: chicken-monitor-001`nlocal-hostname: chicken-monitor"
[System.IO.File]::WriteAllText("$ciDir\meta-data", $metaDataContent, [System.Text.UTF8Encoding]::new($false))

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
[System.IO.File]::WriteAllText("$ciDir\user-data", $userDataContent, [System.Text.UTF8Encoding]::new($false))

# Create ISO using oscdimg (Windows ADK) or mkisofs or genisoimage
# Try multiple tools for ISO creation
$isoCreated = $false

# Method 1: oscdimg (comes with Windows ADK)
$oscdimg = Get-Command oscdimg -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Source
if (-not $oscdimg) {
    $adkPaths = @(
        "${env:ProgramFiles(x86)}\Windows Kits\10\Assessment and Deployment Kit\Deployment Tools\amd64\Oscdimg\oscdimg.exe",
        "${env:ProgramFiles(x86)}\Windows Kits\8.1\Assessment and Deployment Kit\Deployment Tools\amd64\Oscdimg\oscdimg.exe"
    )
    foreach ($p in $adkPaths) {
        if (Test-Path $p) { $oscdimg = $p; break }
    }
}

if ($oscdimg) {
    & $oscdimg -j1 -lcidata "$ciDir" $SeedIso
    if ($LASTEXITCODE -eq 0) { $isoCreated = $true }
}

# Method 2: mkisofs / genisoimage (from cdrtools)
if (-not $isoCreated) {
    $mkisofs = Get-Command mkisofs -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Source
    if (-not $mkisofs) {
        $mkisofs = Get-Command genisoimage -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Source
    }
    if ($mkisofs) {
        & $mkisofs -output $SeedIso -volid cidata -joliet -rock "$ciDir"
        if ($LASTEXITCODE -eq 0) { $isoCreated = $true }
    }
}

# Method 3: PowerShell .NET — create a minimal ISO image
if (-not $isoCreated) {
    Write-Step "No ISO tool found. Creating cloud-init ISO with built-in method..."

    # Use a simple approach: write a minimal ISO 9660 image
    # We'll use the IMAPI2 COM object (available on Windows 7+)
    try {
        $fsi = New-Object -ComObject IMAPI2FS.MsftFileSystemImage
        $fsi.FileSystemsToCreate = 2  # FsiFileSystemJoliet
        $fsi.VolumeName = "cidata"

        $metaPath = "$ciDir\meta-data"
        $userPath = "$ciDir\user-data"

        $fsiStream = New-Object -ComObject ADODB.Stream
        $fsiStream.Open()
        $fsiStream.Type = 1  # binary
        $fsiStream.LoadFromFile($metaPath)
        $fsi.Root.AddFile("meta-data", $fsiStream)
        $fsiStream.Close()

        $fsiStream2 = New-Object -ComObject ADODB.Stream
        $fsiStream2.Open()
        $fsiStream2.Type = 1
        $fsiStream2.LoadFromFile($userPath)
        $fsi.Root.AddFile("user-data", $fsiStream2)
        $fsiStream2.Close()

        $result = $fsi.CreateResultImage()
        $resultStream = $result.ImageStream

        # Write IStream to file
        $isoFileStream = [System.IO.File]::Create($SeedIso)
        $buffer = New-Object byte[] 65536
        do {
            $bytesRead = $resultStream.Read($buffer, 0, $buffer.Length)
            if ($bytesRead -gt 0) {
                $isoFileStream.Write($buffer, 0, $bytesRead)
            }
        } while ($bytesRead -gt 0)
        $isoFileStream.Close()
        $isoCreated = $true
    } catch {
        # IMAPI2 approach via IStream
        try {
            $fsi = New-Object -ComObject IMAPI2FS.MsftFileSystemImage
            $fsi.FileSystemsToCreate = 2
            $fsi.VolumeName = "cidata"

            # Add files using the Root directory
            foreach ($file in @("meta-data", "user-data")) {
                $filePath = "$ciDir\$file"
                $stream = New-Object -ComObject ADODB.Stream
                $stream.Open()
                $stream.Type = 1
                $stream.LoadFromFile($filePath)
                $fsi.Root.AddFile($file, $stream)
                $stream.Close()
            }

            $resultImage = $fsi.CreateResultImage()
            $imageStream = $resultImage.ImageStream

            # Use BinaryWriter to save
            $br = New-Object System.IO.BinaryWriter([System.IO.File]::Create($SeedIso))
            $bytes = New-Object byte[] 2048
            while ($true) {
                try {
                    $read = $imageStream.Read($bytes, $bytes.Length, [ref]$null)
                    if ($read -eq 0) { break }
                    $br.Write($bytes, 0, $read)
                } catch { break }
            }
            $br.Close()
            $isoCreated = $true
        } catch {
            Write-Warn "IMAPI2 method also failed: $_"
        }
    }
}

if (-not $isoCreated) {
    Write-Err "Cannot create cloud-init ISO. Install one of: Windows ADK (oscdimg), cdrtools (mkisofs), or genisoimage"
    Write-Host "  Download cdrtools: https://sourceforge.net/projects/cdrtoolswin/" -ForegroundColor Yellow
    exit 1
}

# Clean up temp dir
Remove-Item $ciDir -Recurse -Force -ErrorAction SilentlyContinue
Write-Ok "Cloud-init ISO created"

# === 5. Create VirtualBox VM ===
Write-Step "Creating VirtualBox VM '$VMName'..."

$cpuCount = [Math]::Min(2, [Environment]::ProcessorCount)

Invoke-VBox @("createvm", "--name", $VMName, "--ostype", "Ubuntu_64", "--register", "--basefolder", $VMPath)

# Configure VM
Invoke-VBox @("modifyvm", $VMName,
    "--memory", "$MemoryMB",
    "--cpus", "$cpuCount",
    "--nic1", "nat",
    "--boot1", "disk",
    "--boot2", "dvd",
    "--audio", "none",
    "--graphicscontroller", "vmsvga",
    "--vram", "16"
)

# Port forwarding: host 2222 -> guest 22 (SSH), host 8080 -> guest 8000 (Web)
Invoke-VBox @("modifyvm", $VMName, "--natpf1", "ssh,tcp,,2222,,22")
Invoke-VBox @("modifyvm", $VMName, "--natpf1", "web,tcp,,8080,,8000")

# Storage: SATA controller with disk and cloud-init ISO
Invoke-VBox @("storagectl", $VMName, "--name", "SATA", "--add", "sata", "--controller", "IntelAhci")
Invoke-VBox @("storageattach", $VMName, "--storagectl", "SATA", "--port", "0", "--device", "0", "--type", "hdd", "--medium", $VdiPath)
Invoke-VBox @("storageattach", $VMName, "--storagectl", "SATA", "--port", "1", "--device", "0", "--type", "dvddrive", "--medium", $SeedIso)

Write-Ok "VM created: $cpuCount CPU, $($MemoryMB) MB RAM, NAT networking"
Write-Ok "Port forwarding: localhost:2222 -> SSH, localhost:8080 -> Web"

# === 6. Start VM ===
Write-Step "Starting VM..."
Invoke-VBox @("startvm", $VMName, "--type", "headless")
Write-Ok "VM started"

# === 7. Wait for SSH ===
$sshPort = 2222
$sshTarget = "127.0.0.1"

Write-Step "Waiting for SSH on port $sshPort (up to 300s)..."
$timeout = 300
$elapsed = 0
$sshReady = $false
while (-not $sshReady -and $elapsed -lt $timeout) {
    Start-Sleep -Seconds 10
    $elapsed += 10
    try {
        $tcpClient = New-Object System.Net.Sockets.TcpClient
        $tcpClient.Connect($sshTarget, $sshPort)
        $sshReady = $tcpClient.Connected
        $tcpClient.Close()
    } catch {
        Write-Host "  ... SSH not ready ($elapsed sec)" -ForegroundColor Gray
    }
}
if (-not $sshReady) {
    Write-Err "SSH not available after $timeout seconds."
    Write-Host "  Check VM console in VirtualBox GUI." -ForegroundColor Yellow
    exit 1
}
Write-Ok "SSH ready"

$sshOpts = @("-o", "StrictHostKeyChecking=no", "-o", "UserKnownHostsFile=/dev/null", "-o", "LogLevel=ERROR", "-i", $SshKeyPath, "-p", "$sshPort")

# === 8. Wait for cloud-init ===
Write-Step "Waiting for cloud-init (installing Docker)..."
$timeout = 600
$elapsed = 0
$cloudInitDone = $false
while (-not $cloudInitDone -and $elapsed -lt $timeout) {
    Start-Sleep -Seconds 15
    $elapsed += 15
    $checkResult = & ssh @sshOpts "${Username}@${sshTarget}" "cat /home/$Username/.cloud-init-complete 2>/dev/null" 2>&1
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
$tarExcludes = @("--exclude=.git", "--exclude=deploy.ps1", "--exclude=*.zip", "--exclude=*.vhdx")
& tar -czf $archivePath @tarExcludes -C $ProjectDir .
Write-Ok "Project archive created"

& scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -i $SshKeyPath -P $sshPort "$archivePath" "${Username}@${sshTarget}:/home/$Username/project.tar.gz"
Write-Ok "Files copied"

Write-Step "Starting docker compose..."
& ssh @sshOpts "${Username}@${sshTarget}" "cd /home/$Username/chicken-monitor && tar -xzf /home/$Username/project.tar.gz && rm /home/$Username/project.tar.gz && sudo docker compose up -d --build"

Write-Host "  Waiting for containers..."
Start-Sleep -Seconds 15

$containerCheck = & ssh @sshOpts "${Username}@${sshTarget}" "sudo docker compose -f /home/$Username/chicken-monitor/docker-compose.yml ps" 2>&1
Write-Host "`n  Containers:"
Write-Host "  $containerCheck"

# === 10. Done! ===
Write-Host ""
Write-Host "===================================================" -ForegroundColor Green
Write-Host "  Chicken Monitor deployed!" -ForegroundColor Green
Write-Host "===================================================" -ForegroundColor Green
Write-Host ""
Write-Host "  Web UI:    " -NoNewline; Write-Host "http://localhost:8080" -ForegroundColor Yellow
Write-Host "  SSH:       " -NoNewline; Write-Host "ssh -p $sshPort -i $SshKeyPath ${Username}@127.0.0.1" -ForegroundColor Yellow
Write-Host "  Password:  " -NoNewline; Write-Host "$Password" -ForegroundColor Yellow
Write-Host "  VM name:   " -NoNewline; Write-Host "$VMName" -ForegroundColor Yellow
Write-Host ""
Write-Host "  Management:" -ForegroundColor Gray
Write-Host "    Stop:    & '$VBoxManage' controlvm '$VMName' acpipowerbutton" -ForegroundColor Gray
Write-Host "    Start:   & '$VBoxManage' startvm '$VMName' --type headless" -ForegroundColor Gray
Write-Host "    Delete:  & '$VBoxManage' unregistervm '$VMName' --delete" -ForegroundColor Gray
Write-Host ""

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

# Ensure Git tools (ssh, scp, tar) are in PATH (needed on Windows 7)
$gitUsrBin = "C:\Program Files\Git\usr\bin"
if ((Test-Path $gitUsrBin) -and ($env:Path -notlike "*$gitUsrBin*")) {
    $env:Path += ";$gitUsrBin"
}

# Try to enable TLS 1.2 (best-effort; on Win7 CLR 2.0 this may not work — curl.exe is used instead)
try { [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor 3072 } catch { }

$CloudImageUrl = "https://cloud-images.ubuntu.com/releases/22.04/release/ubuntu-22.04-server-cloudimg-amd64.img"
$ImgPath       = Join-Path $VMPath "cloud.img"
$VdiPath       = Join-Path $VMPath "disk.vdi"
$SeedIso       = Join-Path $VMPath "seed.iso"
$SshKeyPath    = Join-Path $VMPath "id_deploy"
$ScriptDir     = Split-Path -Parent $MyInvocation.MyCommand.Path
$ProjectDir    = Join-Path (Split-Path -Parent $ScriptDir) "project"

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
    $cmd = Get-Command VBoxManage -ErrorAction SilentlyContinue
    if ($cmd) { $VBoxManage = $cmd.Definition }
}
if (-not $VBoxManage) {
    Write-Err "VirtualBox not found. Install from https://www.virtualbox.org/wiki/Downloads"
    exit 1
}

function Invoke-VBox {
    param([string[]]$VBoxArgs)
    # Temporarily allow stderr output (VBoxManage writes progress to stderr)
    $oldEAP = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    $output = & $VBoxManage @VBoxArgs 2>&1
    $exitCode = $LASTEXITCODE
    $ErrorActionPreference = $oldEAP
    if ($exitCode -ne 0) {
        Write-Err "VBoxManage $($VBoxArgs[0]) failed: $output"
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
    $vmStateLine = $vmInfo | Select-String '^VMState="(.+)"' | Select-Object -First 1
    $vmState = "unknown"
    if ($vmStateLine) { $vmState = $vmStateLine.Matches[0].Groups[1].Value }

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
& ssh-keygen -t ed25519 -f $SshKeyPath -N "" -q 2>$null
$sshPubKey = [System.IO.File]::ReadAllText("$SshKeyPath.pub").Trim()
Write-Ok "SSH key generated"

# === 3. Download Ubuntu Cloud Image ===
if (Test-Path $VdiPath) {
    Write-Ok "VDI already exists, skipping download"
} else {
    Write-Step "Downloading Ubuntu 22.04 Cloud Image (~700MB)..."
    Write-Host "  URL: $CloudImageUrl"

    # Use Git's bundled curl.exe (supports TLS 1.2 natively, works on Windows 7)
    $gitCurl = "C:\Program Files\Git\mingw64\bin\curl.exe"
    if (-not (Test-Path $gitCurl)) {
        # Try 32-bit Git
        $gitCurl = "C:\Program Files (x86)\Git\mingw64\bin\curl.exe"
    }
    if (-not (Test-Path $gitCurl)) {
        $cmd = Get-Command curl.exe -ErrorAction SilentlyContinue
        if ($cmd) { $gitCurl = $cmd.Definition }
    }

    if (Test-Path $gitCurl) {
        Write-Host "  Using: $gitCurl" -ForegroundColor Gray
        & $gitCurl -L -o $ImgPath $CloudImageUrl --progress-bar
        if ($LASTEXITCODE -ne 0) {
            Write-Err "curl download failed (exit code $LASTEXITCODE)"
            exit 1
        }
        Write-Ok "Downloaded: $ImgPath"
    } else {
        # Fallback: try .NET WebClient (won't work on Win7 CLR 2.0 with HTTPS)
        try {
            $webClient = New-Object System.Net.WebClient
            $webClient.DownloadFile($CloudImageUrl, $ImgPath)
            Write-Ok "Downloaded: $ImgPath"
        } catch {
            Write-Err "Download failed. Install Git for Windows first (provides curl with TLS 1.2)."
            Write-Host "  Git 2.46.2: https://github.com/git-for-windows/git/releases/download/v2.46.2.windows.1/Git-2.46.2-64-bit.exe" -ForegroundColor Yellow
            exit 1
        }
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
        $cmd = Get-Command qemu-img -ErrorAction SilentlyContinue
        if ($cmd) { $qemuImg = $cmd.Definition }
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
[System.IO.File]::WriteAllText("$ciDir\meta-data", $metaDataContent, (New-Object System.Text.UTF8Encoding($false)))

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
[System.IO.File]::WriteAllText("$ciDir\user-data", $userDataContent, (New-Object System.Text.UTF8Encoding($false)))

# Create ISO using oscdimg (Windows ADK) or mkisofs or genisoimage
# Try multiple tools for ISO creation
$isoCreated = $false

# Method 1: oscdimg (comes with Windows ADK)
$oscdimgCmd = Get-Command oscdimg -ErrorAction SilentlyContinue
$oscdimg = $null
if ($oscdimgCmd) { $oscdimg = $oscdimgCmd.Definition }
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
    $mkisofs = $null
    $cmd = Get-Command mkisofs -ErrorAction SilentlyContinue
    if ($cmd) { $mkisofs = $cmd.Definition }
    if (-not $mkisofs) {
        $cmd = Get-Command genisoimage -ErrorAction SilentlyContinue
        if ($cmd) { $mkisofs = $cmd.Definition }
    }
    if ($mkisofs) {
        & $mkisofs -output $SeedIso -volid cidata -joliet -rock "$ciDir"
        if ($LASTEXITCODE -eq 0) { $isoCreated = $true }
    }
}

# Method 3: IMAPI2 COM (built into Windows 7+)
if (-not $isoCreated) {
    Write-Step "No ISO tool found. Trying IMAPI2 COM..."
    try {
        $fsi = New-Object -ComObject IMAPI2FS.MsftFileSystemImage
        $fsi.FileSystemsToCreate = 2  # FsiFileSystemJoliet
        $fsi.VolumeName = "cidata"

        foreach ($file in @("meta-data", "user-data")) {
            $filePath = "$ciDir\$file"
            $adoStream = New-Object -ComObject ADODB.Stream
            $adoStream.Open()
            $adoStream.Type = 1  # binary
            $adoStream.LoadFromFile($filePath)
            $fsi.Root.AddFile($file, $adoStream)
            $adoStream.Close()
        }

        $resultImage = $fsi.CreateResultImage()
        $iStream = $resultImage.ImageStream

        # Read COM IStream using correct parameter signatures
        $fileOut = [System.IO.File]::Create($SeedIso)
        $buffer = New-Object byte[] 2048
        while ($true) {
            [int]$bytesRead = 0
            $iStream.Read($buffer, $buffer.Length, [ref]$bytesRead)
            if ($bytesRead -le 0) { break }
            $fileOut.Write($buffer, 0, $bytesRead)
        }
        $fileOut.Close()
        $isoCreated = $true
        Write-Ok "Created via IMAPI2"
    } catch {
        Write-Warn "IMAPI2 failed: $_"
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

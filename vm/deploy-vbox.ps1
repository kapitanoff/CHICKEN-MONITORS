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

$CloudImageUrl = "https://cloud-images.ubuntu.com/releases/22.04/release/ubuntu-22.04-server-cloudimg-amd64.ova"
$OvaPath       = Join-Path $VMPath "cloud.ova"
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

# Clean up any stale media from VirtualBox registry (prevents UUID conflicts on re-runs)
$oldEAP = $ErrorActionPreference; $ErrorActionPreference = "Continue"
foreach ($ext in @("*.vmdk", "*.vdi")) {
    $staleFiles = Get-ChildItem $VMPath -Filter $ext -ErrorAction SilentlyContinue
    foreach ($f in $staleFiles) {
        & $VBoxManage closemedium disk $f.FullName 2>$null
    }
}
$ErrorActionPreference = $oldEAP

$oldEAP = $ErrorActionPreference; $ErrorActionPreference = "Continue"
$existingVMs = & $VBoxManage list vms 2>&1
$ErrorActionPreference = $oldEAP
if ($existingVMs -match "`"$VMName`"") {
    # VM exists — check state and start if needed
    $oldEAP = $ErrorActionPreference; $ErrorActionPreference = "Continue"
    $vmInfo = & $VBoxManage showvminfo $VMName --machinereadable 2>&1
    $ErrorActionPreference = $oldEAP
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
        $oldEAP = $ErrorActionPreference; $ErrorActionPreference = "Continue"
        $propResult = & $VBoxManage guestproperty get $VMName "/VirtualBox/GuestInfo/Net/0/V4/IP" 2>&1
        $ErrorActionPreference = $oldEAP
        if ($propResult -match 'Value:\s*(\d+\.\d+\.\d+\.\d+)') {
            $ip = $Matches[1]
        }
        # Fallback: parse DHCP leases via port forwarding — we use port forward so IP = localhost
        if (-not $ip) {
            $oldEAP = $ErrorActionPreference; $ErrorActionPreference = "Continue"
            $fwdRules = & $VBoxManage showvminfo $VMName --machinereadable 2>&1 | Select-String "Forwarding"
            $ErrorActionPreference = $oldEAP
            if ($fwdRules -match "ssh") {
                # We have port forwarding set up, use localhost
                $ip = "127.0.0.1"
            }
        }
    }

    # Determine SSH port (could be forwarded)
    $sshPort = 22
    $oldEAP = $ErrorActionPreference; $ErrorActionPreference = "Continue"
    $fwdInfo = & $VBoxManage showvminfo $VMName --machinereadable 2>&1 | Select-String "Forwarding.*ssh"
    $ErrorActionPreference = $oldEAP
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
$oldEAP = $ErrorActionPreference; $ErrorActionPreference = "Continue"
# PS 2.0 can't pass empty -N "" correctly; use cmd /c to bypass PowerShell argument mangling
& cmd /c "ssh-keygen -t ed25519 -f `"$SshKeyPath`" -N `"`" -q" 2>$null
if (-not (Test-Path "$SshKeyPath.pub")) {
    # Fallback: try rsa if ed25519 not supported, pipe empty lines for passphrase
    "","" | & ssh-keygen -t rsa -b 2048 -f $SshKeyPath -q 2>$null
}
$ErrorActionPreference = $oldEAP
$sshPubKey = [System.IO.File]::ReadAllText("$SshKeyPath.pub").Trim()
Write-Ok "SSH key generated"

# === 3. Download Ubuntu Cloud Image (OVA) and convert to VDI ===
if (Test-Path $VdiPath) {
    Write-Ok "VDI already exists, skipping download"
} else {
    Write-Step "Downloading Ubuntu 22.04 Cloud Image OVA (~650MB)..."
    Write-Host "  URL: $CloudImageUrl"

    # Use Git's bundled curl.exe (supports TLS 1.2 natively, works on Windows 7)
    $gitCurl = "C:\Program Files\Git\mingw64\bin\curl.exe"
    if (-not (Test-Path $gitCurl)) {
        $gitCurl = "C:\Program Files (x86)\Git\mingw64\bin\curl.exe"
    }
    if (-not (Test-Path $gitCurl)) {
        $cmd = Get-Command curl.exe -ErrorAction SilentlyContinue
        if ($cmd) { $gitCurl = $cmd.Definition }
    }

    if (Test-Path $gitCurl) {
        Write-Host "  Using: $gitCurl" -ForegroundColor Gray
        & $gitCurl -L -o $OvaPath $CloudImageUrl --progress-bar
        if ($LASTEXITCODE -ne 0) {
            Write-Err "curl download failed (exit code $LASTEXITCODE)"
            exit 1
        }
        Write-Ok "Downloaded OVA"
    } else {
        try {
            $webClient = New-Object System.Net.WebClient
            $webClient.DownloadFile($CloudImageUrl, $OvaPath)
            Write-Ok "Downloaded OVA"
        } catch {
            Write-Err "Download failed. Install Git for Windows first (provides curl with TLS 1.2)."
            Write-Host "  Git 2.46.2: https://github.com/git-for-windows/git/releases/download/v2.46.2.windows.1/Git-2.46.2-64-bit.exe" -ForegroundColor Yellow
            exit 1
        }
    }

    # OVA is a tar archive containing a VMDK disk image
    Write-Step "Extracting VMDK from OVA..."
    $vmdkFile = $null
    $oldEAP2 = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    $tarList = & tar --force-local -tf $OvaPath 2>&1
    $ErrorActionPreference = $oldEAP2
    foreach ($entry in $tarList) {
        if ("$entry" -match '\.vmdk$') { $vmdkFile = "$entry".Trim(); break }
    }
    if (-not $vmdkFile) {
        Write-Err "No VMDK found inside OVA"
        exit 1
    }
    $oldEAP3 = $ErrorActionPreference; $ErrorActionPreference = "Continue"
    & tar --force-local -xf $OvaPath -C $VMPath $vmdkFile
    $ErrorActionPreference = $oldEAP3
    $VmdkPath = Join-Path $VMPath $vmdkFile
    Write-Ok "Extracted: $vmdkFile"

    # Reset VMDK UUID to avoid conflicts with VirtualBox media registry
    $oldEAP = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    & $VBoxManage closemedium disk $VdiPath 2>$null
    & $VBoxManage closemedium disk $VmdkPath 2>$null
    & $VBoxManage internalcommands sethduuid $VmdkPath 2>$null
    $ErrorActionPreference = $oldEAP

    # Convert VMDK to VDI (VBoxManage natively supports VMDK)
    Write-Step "Converting VMDK to VDI..."
    Invoke-VBox @("clonemedium", "disk", $VmdkPath, $VdiPath, "--format", "VDI")
    Write-Ok "Converted to VDI"

    # Clean up temp files
    Remove-Item $OvaPath -Force -ErrorAction SilentlyContinue
    Remove-Item $VmdkPath -Force -ErrorAction SilentlyContinue
    # Also remove .ovf if extracted
    Get-ChildItem $VMPath -Filter "*.ovf" -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
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

# Method 3: Build ISO 9660 in pure PowerShell (no external tools needed)
if (-not $isoCreated) {
    Write-Step "Building cloud-init ISO (pure PowerShell)..."
    try {
        $metaB = [System.IO.File]::ReadAllBytes("$ciDir\meta-data")
        $userB = [System.IO.File]::ReadAllBytes("$ciDir\user-data")
        $S = 2048

        $metaN = [Math]::Max(1, [Math]::Ceiling($metaB.Length / $S))
        $userN = [Math]::Max(1, [Math]::Ceiling($userB.Length / $S))
        $rLBA = 20; $mLBA = 21; $uLBA = 21 + $metaN; $total = $uLBA + $userN
        $b = New-Object byte[] ($total * $S)

        # --- Helper: byte extraction (PS 2.0 has no -shr) ---
        function B0($v) { [byte]([uint32]$v -band 0xFF) }
        function B1($v) { [byte]([Math]::Floor([uint32]$v / 256) -band 0xFF) }
        function B2($v) { [byte]([Math]::Floor([uint32]$v / 65536) -band 0xFF) }
        function B3($v) { [byte]([Math]::Floor([uint32]$v / 16777216) -band 0xFF) }
        # Write both-endian uint32 (little then big)
        function WB32($buf,$o,[uint32]$v) {
            $buf[$o]=(B0 $v);$buf[$o+1]=(B1 $v);$buf[$o+2]=(B2 $v);$buf[$o+3]=(B3 $v)
            $buf[$o+4]=(B3 $v);$buf[$o+5]=(B2 $v);$buf[$o+6]=(B1 $v);$buf[$o+7]=(B0 $v)
        }
        function WB16($buf,$o,[uint16]$v) {
            $buf[$o]=(B0 $v);$buf[$o+1]=(B1 $v);$buf[$o+2]=(B1 $v);$buf[$o+3]=(B0 $v)
        }
        function WL32($buf,$o,[uint32]$v) {
            $buf[$o]=(B0 $v);$buf[$o+1]=(B1 $v);$buf[$o+2]=(B2 $v);$buf[$o+3]=(B3 $v)
        }
        function WM32($buf,$o,[uint32]$v) {
            $buf[$o]=(B3 $v);$buf[$o+1]=(B2 $v);$buf[$o+2]=(B1 $v);$buf[$o+3]=(B0 $v)
        }
        function WStr($buf,$o,$str,$len) {
            $sb=[System.Text.Encoding]::ASCII.GetBytes($str)
            $cl=[Math]::Min($sb.Length,$len)
            for($i=0;$i-lt $cl;$i++){$buf[$o+$i]=$sb[$i]}
            for($i=$cl;$i-lt $len;$i++){$buf[$o+$i]=0x20}
        }
        function WDirRec($buf,$o,$name,[uint32]$lba,[uint32]$sz,[byte]$fl) {
            $nb=[System.Text.Encoding]::ASCII.GetBytes($name)
            $rl=33+$nb.Length; if($rl%2-ne 0){$rl++}
            $buf[$o]=[byte]$rl; WB32 $buf ($o+2) $lba; WB32 $buf ($o+10) $sz
            $buf[$o+25]=$fl; WB16 $buf ($o+28) ([uint16]1)
            $buf[$o+32]=[byte]$nb.Length
            for($i=0;$i-lt $nb.Length;$i++){$buf[$o+33+$i]=$nb[$i]}
            return $rl
        }

        # --- PVD (sector 16) ---
        $p=16*$S; $b[$p]=1; WStr $b ($p+1) "CD001" 5; $b[$p+6]=1
        WStr $b ($p+8) " " 32; WStr $b ($p+40) "CIDATA" 32
        WB32 $b ($p+80) ([uint32]$total); WB16 $b ($p+120) ([uint16]1)
        WB16 $b ($p+124) ([uint16]1); WB16 $b ($p+128) ([uint16]$S)
        WB32 $b ($p+132) ([uint32]10)
        WL32 $b ($p+140) ([uint32]18); WM32 $b ($p+148) ([uint32]19)
        # Root dir record in PVD
        $r=$p+156; $b[$r]=34; WB32 $b ($r+2) ([uint32]$rLBA)
        WB32 $b ($r+10) ([uint32]$S); $b[$r+25]=0x02
        WB16 $b ($r+28) ([uint16]1); $b[$r+32]=1; $b[$r+33]=0
        # Identifier fields (spaces)
        foreach ($off in @(190,318,446,574)) { WStr $b ($p+$off) " " 128 }
        foreach ($off in @(702,739,776)) { WStr $b ($p+$off) " " 37 }
        $b[$p+881]=1

        # --- VDST (sector 17) ---
        $v=17*$S; $b[$v]=255; WStr $b ($v+1) "CD001" 5; $b[$v+6]=1

        # --- Path Table L (sector 18) ---
        $t=18*$S; $b[$t]=1; WL32 $b ($t+2) ([uint32]$rLBA)
        $b[$t+6]=1; $b[$t+7]=0

        # --- Path Table M (sector 19) ---
        $t=19*$S; $b[$t]=1; WM32 $b ($t+2) ([uint32]$rLBA)
        $b[$t+6]=0; $b[$t+7]=1

        # --- Root Directory (sector 20) ---
        $d=$rLBA*$S; $pos=$d
        # "." entry
        $b[$pos]=34; WB32 $b ($pos+2) ([uint32]$rLBA); WB32 $b ($pos+10) ([uint32]$S)
        $b[$pos+25]=0x02; WB16 $b ($pos+28) ([uint16]1); $b[$pos+32]=1; $b[$pos+33]=0
        $pos+=34
        # ".." entry
        $b[$pos]=34; WB32 $b ($pos+2) ([uint32]$rLBA); WB32 $b ($pos+10) ([uint32]$S)
        $b[$pos+25]=0x02; WB16 $b ($pos+28) ([uint16]1); $b[$pos+32]=1; $b[$pos+33]=1
        $pos+=34
        # File entries (Linux isofs lowercases names and strips ";1")
        $pos += (WDirRec $b $pos "META-DATA.;1" ([uint32]$mLBA) ([uint32]$metaB.Length) 0)
        $pos += (WDirRec $b $pos "USER-DATA.;1" ([uint32]$uLBA) ([uint32]$userB.Length) 0)

        # --- File data ---
        [Array]::Copy($metaB, 0, $b, $mLBA*$S, $metaB.Length)
        [Array]::Copy($userB, 0, $b, $uLBA*$S, $userB.Length)

        [System.IO.File]::WriteAllBytes($SeedIso, $b)
        $isoCreated = $true
        Write-Ok "ISO created (pure PowerShell)"
    } catch {
        Write-Warn "ISO build failed: $_"
    }
}

if (-not $isoCreated) {
    Write-Err "Cannot create cloud-init ISO."
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
    $oldEAP = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    $checkResult = & ssh @sshOpts "${Username}@${sshTarget}" "cat /home/$Username/.cloud-init-complete 2>/dev/null" 2>&1
    $ErrorActionPreference = $oldEAP
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
$oldEAP = $ErrorActionPreference; $ErrorActionPreference = "Continue"
& tar --force-local -czf $archivePath @tarExcludes -C $ProjectDir .
$ErrorActionPreference = $oldEAP
Write-Ok "Project archive created"

$oldEAP = $ErrorActionPreference; $ErrorActionPreference = "Continue"
& scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -i $SshKeyPath -P $sshPort "$archivePath" "${Username}@${sshTarget}:/home/$Username/project.tar.gz"
$ErrorActionPreference = $oldEAP
Write-Ok "Files copied"

Write-Step "Starting docker compose..."
$oldEAP = $ErrorActionPreference; $ErrorActionPreference = "Continue"
& ssh @sshOpts "${Username}@${sshTarget}" "cd /home/$Username/chicken-monitor && tar -xzf /home/$Username/project.tar.gz && rm /home/$Username/project.tar.gz && sudo docker compose up -d --build"
$ErrorActionPreference = $oldEAP

Write-Host "  Waiting for containers..."
Start-Sleep -Seconds 15

$oldEAP = $ErrorActionPreference; $ErrorActionPreference = "Continue"
$containerCheck = & ssh @sshOpts "${Username}@${sshTarget}" "sudo docker compose -f /home/$Username/chicken-monitor/docker-compose.yml ps" 2>&1
$ErrorActionPreference = $oldEAP
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

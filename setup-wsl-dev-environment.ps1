# Host provisioning:
#   .\setup-wsl-dev-environment.ps1 -Mode Host -UserName "avarghese"
# Sparse VHD is off by default; systemd is enabled by default.
# Box deployment:
#   .\setup-wsl-dev-environment.ps1 -Mode Box -Box extended_box -UserName "avarghese"

param (
    [Parameter(Mandatory=$true)]
    [ValidateSet("Host", "Box", "Update", "Remove")]
    [string]$Mode,

    [Parameter(Mandatory=$true)]
    [string]$UserName,

    [string]$Box,

    [string]$Instance,

    [switch]$Force,

    [switch]$EnableSparseVhd,

    [switch]$EnableSystemd,

    [switch]$DisableSparseVhd,

    [switch]$DisableSystemd
)

$ErrorActionPreference = "Stop"
$wslDistro = "Ubuntu"
$scriptDir = (Resolve-Path (Split-Path -Parent $MyInvocation.MyCommand.Definition)).Path

function Write-Status {
    param([Parameter(Mandatory=$true)][string]$Message)

    [Console]::Out.Write("`r")
    [Console]::Out.WriteLine($Message)
}

function Show-RetryProgress {
    param(
        [Parameter(Mandatory=$true)][string]$Activity,
        [Parameter(Mandatory=$true)][int]$Attempt,
        [Parameter(Mandatory=$true)][int]$MaxAttempts
    )

    $percent = [int][math]::Min(100, (($Attempt * 100) / $MaxAttempts))
    Write-Progress -Id 7 -Activity $Activity -Status "Waiting before retry $Attempt of $MaxAttempts..." -PercentComplete $percent
}

function Complete-RetryProgress {
    Write-Progress -Id 7 -Activity "Waiting for WSL" -Completed
}

function Get-WslPath {
    param([Parameter(Mandatory=$true)][string]$WindowsPath)

    # Forward slashes prevent WSL argument parsing from stripping Windows
    # backslash separators before wslpath receives the path.
    $wslPathInput = $WindowsPath -replace '\\', '/'
    $wslPathOutput = & wsl.exe --distribution $wslDistro -- wslpath -a $wslPathInput 2>$null
    $wslExitCode = $LASTEXITCODE
    $wslPath = if ($null -ne $wslPathOutput) { ($wslPathOutput -join "`n").Trim() } else { "" }
    if ($wslExitCode -ne 0 -or -not $wslPath) {
        throw "Could not convert Windows path to a WSL path: $WindowsPath"
    }
    return $wslPath
}

function Get-InstalledDistro {
    return wsl.exe --list --quiet 2>$null |
        ForEach-Object { ($_ -replace "`0", "").Trim() } |
        Where-Object { $_ -eq $wslDistro } |
        Select-Object -First 1
}

function Wait-ForInstalledDistro {
    $maxAttempts = 36
    for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
        if (Get-InstalledDistro) {
            Complete-RetryProgress
            return $true
        }

        if ($attempt -lt $maxAttempts) {
            Show-RetryProgress -Activity "$wslDistro is being registered by WSL" -Attempt ($attempt + 1) -MaxAttempts $maxAttempts
            Start-Sleep -Seconds 10
            Complete-RetryProgress
        }
    }

    Complete-RetryProgress
    return $false
}

function Invoke-WslScript {
    param(
        [Parameter(Mandatory=$true)][string]$Script,
        [string[]]$Arguments = @(),
        [switch]$AsRoot
    )

    $encoded = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($Script))
    $userArgs = @()
    if ($AsRoot) {
        $userArgs = @("--user", "root")
    }

    $argumentText = "echo $encoded | base64 -d | bash -s --"
    foreach ($argument in $Arguments) {
        $argumentText += " '$argument'"
    }

    & wsl.exe --distribution $wslDistro @userArgs -- bash -lc $argumentText 2>&1 |
        ForEach-Object {
            $line = $_.ToString()
            $line = $line -replace "`r", ""
            $line = $line -replace "`e\[[0-9;?]*[ -/]*[@-~]", ""
            $line = $line -replace "[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]", ""
            $line = $line.Trim()
            if ($line.Length -gt 0) {
                [Console]::Out.WriteLine("[Ubuntu] $line")
            }
        }
    $wslExitCode = $LASTEXITCODE
    if ($wslExitCode -ne 0) {
        throw "The WSL setup command failed."
    }
}

function Enable-SparseVhd {
    if (-not $EnableSparseVhd -or $DisableSparseVhd) {
        return
    }

    $maxAttempts = 36
    Write-Status "Enabling sparse VHD support for $wslDistro..."
    for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
        & wsl.exe --manage $wslDistro --set-sparse true --allow-unsafe
        if ($LASTEXITCODE -eq 0) {
            Complete-RetryProgress
            return
        }

        if ($attempt -lt $maxAttempts) {
            Show-RetryProgress -Activity "Sparse VHD conversion is still in progress" -Attempt ($attempt + 1) -MaxAttempts $maxAttempts
            Start-Sleep -Seconds 10
            Complete-RetryProgress
        }
    }

    Complete-RetryProgress
    throw "Could not enable sparse VHD support for $wslDistro after waiting for the conversion to finish. Update WSL and try again."
}

function Get-WslDistroVersion {
    $distroPattern = [regex]::Escape($wslDistro)
    $lines = wsl.exe --list --verbose 2>$null
    foreach ($line in $lines) {
        $cleanLine = ($line -replace "`0", "")
        if ($cleanLine -match "^\s*\*?\s*$distroPattern\s+\S+\s+(?<version>[12])\s*$") {
            return [int]$Matches.version
        }
    }
    return 0
}

function Set-DistroToWsl2 {
    if ((Get-WslDistroVersion) -eq 2) {
        Write-Status "$wslDistro is already running as WSL 2."
        return
    }

    $maxAttempts = 36
    for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
        & wsl.exe --set-version $wslDistro 2
        if ($LASTEXITCODE -eq 0) {
            Complete-RetryProgress
            return
        }

        if ($attempt -lt $maxAttempts) {
            Show-RetryProgress -Activity "$wslDistro is still converting to WSL 2" -Attempt ($attempt + 1) -MaxAttempts $maxAttempts
            Start-Sleep -Seconds 10
            Complete-RetryProgress
        }
    }

    Complete-RetryProgress
    throw "Could not set $wslDistro to WSL version 2 after waiting for the conversion to finish."
}

function Stop-DockerBeforeDistroTermination {
    $shutdownScript = @'
set +e
if command -v systemctl >/dev/null 2>&1; then
    systemctl stop docker.socket docker.service containerd.service >/dev/null 2>&1
else
    service docker stop >/dev/null 2>&1
fi

if pgrep -x dockerd >/dev/null 2>&1; then
    pkill -TERM -x dockerd
    for attempt in {1..10}; do
        pgrep -x dockerd >/dev/null 2>&1 || break
        sleep 1
    done
fi

if ! pgrep -x dockerd >/dev/null 2>&1; then
    rm -f /var/run/docker.pid
fi
'@

    Write-Status "Stopping Docker cleanly before restarting WSL..."
    Invoke-WslScript -Script $shutdownScript -AsRoot
}

function Install-HostDependencies {
    if ($UserName -notmatch '^[a-z_][a-z0-9_-]*$') {
        throw "UserName must be a valid Linux username because it is also used for the automated WSL user."
    }

    Write-Status "Stopping all WSL distributions before host provisioning..."
    & wsl.exe --shutdown 2>$null

    $null = wsl.exe --status 2>&1
    $installCommandRun = $false
    if ($LASTEXITCODE -ne 0) {
        Write-Status "WSL is not enabled. Installing WSL2 and Ubuntu without opening an interactive console..."
        wsl.exe --install --no-launch --distribution $wslDistro
        $installCommandRun = $true
    }

    if (-not (Get-InstalledDistro) -and -not $installCommandRun) {
        Write-Status "Ubuntu is not installed. Installing it in WSL without opening an interactive console..."
        wsl.exe --install --no-launch --distribution $wslDistro
        $installCommandRun = $true
    }

    if (-not (Get-InstalledDistro)) {
        Write-Status "$wslDistro is still completing first-run registration. Waiting before continuing..."
        if (Wait-ForInstalledDistro) {
            Write-Status "$wslDistro registration is complete. Continuing with host configuration..."
        } else {
            Write-Status "Ubuntu installation is not ready yet. Restart Windows if requested, then run Host mode again with the same UserName."
            return $false
        }
    }

    if ($installCommandRun) {
        Write-Status "Ubuntu installation is ready. Continuing with host configuration..."
    }

    Enable-SparseVhd

    Write-Status "Configuring $wslDistro as the default WSL2 distribution..."
    wsl.exe --set-default $wslDistro
    wsl.exe --set-default-version 2
    Set-DistroToWsl2

    $installScript = @'
set -e
exec 2>&1
WSL_USER="$1"
export DEBIAN_FRONTEND=noninteractive
export TERM=dumb

# Use HTTPS for every configured APT source before contacting Ubuntu or Docker repositories.
find /etc/apt -type f \( -name '*.list' -o -name '*.sources' \) -exec sed -i 's|http://|https://|g' {} +

echo "Updating package indexes..."
apt-get -o Dpkg::Use-Pty=0 -o APT::Color=0 -o APT::Progress::Fancy=0 update
echo "Installing setup prerequisites..."
apt-get -o Dpkg::Use-Pty=0 -o APT::Color=0 -o APT::Progress::Fancy=0 install -y ca-certificates curl sudo jq openssh-client

if ! (dpkg-query -W -f='${db:Status-Status}' docker-ce 2>/dev/null | grep -qx installed && \
      dpkg-query -W -f='${db:Status-Status}' docker-ce-cli 2>/dev/null | grep -qx installed); then
    echo "Adding the Docker CE repository..."
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
    chmod a+r /etc/apt/keyrings/docker.asc
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" > /etc/apt/sources.list.d/docker.list
    echo "Updating package indexes with Docker CE..."
    apt-get -o Dpkg::Use-Pty=0 -o APT::Color=0 -o APT::Progress::Fancy=0 update
    echo "Installing Docker CE and related components..."
    apt-get -o Dpkg::Use-Pty=0 -o APT::Color=0 -o APT::Progress::Fancy=0 install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
fi

echo "Configuring Linux user '$WSL_USER' and Docker permissions..."
if ! id -u "$WSL_USER" >/dev/null 2>&1; then
    useradd --create-home --shell /bin/bash "$WSL_USER"
fi
usermod -aG docker "$WSL_USER"
echo "$WSL_USER ALL=(ALL) NOPASSWD:ALL" > "/etc/sudoers.d/$WSL_USER"
chmod 0440 "/etc/sudoers.d/$WSL_USER"

cat > /etc/wsl.conf <<EOF
[boot]
__WSL_BOOT_SETTINGS__
[user]
default=$WSL_USER
EOF

echo "Cleaning stale Docker daemon state..."
if command -v systemctl >/dev/null 2>&1; then
    systemctl stop docker.service docker.socket >/dev/null 2>&1 || true
fi

if pgrep -x dockerd >/dev/null 2>&1; then
    pkill -TERM -x dockerd || true
    for attempt in {1..10}; do
        pgrep -x dockerd >/dev/null 2>&1 || break
        sleep 1
    done
fi

if pgrep -x dockerd >/dev/null 2>&1; then
    echo "A Docker daemon process is still running; refusing to remove its PID file."
    pgrep -a -x dockerd || true
    exit 1
fi

if [[ -f /var/run/docker.pid ]]; then
    echo "Removing stale /var/run/docker.pid..."
    rm -f /var/run/docker.pid
fi

echo "Starting Docker CE..."
if [[ -d /run/systemd/system ]] && command -v systemctl >/dev/null 2>&1; then
    systemctl enable containerd.service docker.service >/dev/null 2>&1 || true
    systemctl reset-failed containerd.service docker.service >/dev/null 2>&1 || true
    systemctl start containerd.service
    if ! systemctl start docker.service; then
        echo "Docker CE failed to start. Service details follow:"
        systemctl status containerd.service --no-pager -l || true
        journalctl -u containerd.service -n 40 --no-pager || true
        systemctl status docker.service --no-pager -l || true
        journalctl -u docker.service -n 80 --no-pager || true
        exit 1
    fi
else
    if ! service docker start; then
        echo "Docker CE failed to start. Service details follow:"
        service docker status || true
        exit 1
    fi
fi

if ! docker info >/dev/null 2>&1; then
    echo "Docker CE service started but docker info failed. Service details follow:"
    if command -v systemctl >/dev/null 2>&1; then
        systemctl status containerd.service --no-pager -l || true
        journalctl -u containerd.service -n 40 --no-pager || true
        systemctl status docker.service --no-pager -l || true
        journalctl -u docker.service -n 80 --no-pager || true
    fi
    exit 1
fi
'@

    if (-not $DisableSystemd) {
        $bootSettings = "systemd=true"
    } else {
        $bootSettings = 'command="service docker start"'
    }
    $installScript = $installScript.Replace('__WSL_BOOT_SETTINGS__', $bootSettings)

    Write-Status "Running Ubuntu provisioning; Ubuntu package and Docker output will appear below..."
    Invoke-WslScript -Script $installScript -Arguments @($UserName) -AsRoot
    Stop-DockerBeforeDistroTermination
    wsl.exe --terminate $wslDistro
    Write-Status "Host provisioning is complete. Docker CE will start automatically with WSL."
    return $true
}

function Configure-WindowsSsh {
    param(
        [Parameter(Mandatory=$true)][string]$HostAlias,
        [Parameter(Mandatory=$true)][int]$SshPort
    )

    $sshPath = Join-Path $env:USERPROFILE ".ssh"
    $sshConfigPath = Join-Path $sshPath "config"
    $knownHostsPath = Join-Path $sshPath "known_hosts"
    $keyPath = Join-Path $sshPath "wsl-dev-container-key"
    $pubKeyPath = Join-Path $sshPath "wsl-dev-container-key.pub"
    $sourceKeyPath = Join-Path $scriptDir "core_box\keys\wsl-dev-container-key"
    $sourcePubKeyPath = Join-Path $scriptDir "core_box\keys\wsl-dev-container-key.pub"

    if (-not (Test-Path -LiteralPath $sshPath)) {
        New-Item -ItemType Directory -Path $sshPath -Force | Out-Null
    }
    if (-not (Test-Path -LiteralPath $sourceKeyPath) -or -not (Test-Path -LiteralPath $sourcePubKeyPath)) {
        throw "The repository SSH key pair is missing from core_box\keys."
    }

    Copy-Item -LiteralPath $sourceKeyPath -Destination $keyPath -Force
    Copy-Item -LiteralPath $sourcePubKeyPath -Destination $pubKeyPath -Force

    if (-not (Test-Path -LiteralPath $sshConfigPath)) {
        New-Item -ItemType File -Path $sshConfigPath -Force | Out-Null
    }

    $hostEntryPattern = "^Host $HostAlias\s*$"
    $hostEntry = @"
Host $HostAlias
    HostName localhost
    User $UserName
    Port $SshPort
    IdentityFile `"$keyPath`"
    IdentitiesOnly yes
"@

    if (-not (Select-String -Path $sshConfigPath -Pattern $hostEntryPattern -Quiet)) {
        Add-Content -Path $sshConfigPath -Value "`n$hostEntry`n"
        Write-Status "Added Windows SSH host '$HostAlias'."
    }

    if (Get-Command ssh-keygen.exe -ErrorAction SilentlyContinue) {
        # ssh-keygen returns a nonzero status when this host is not yet in
        # known_hosts. That is expected on the first Box setup and is not an
        # installation failure.
        try {
            & ssh-keygen.exe -f $knownHostsPath -R "[localhost]:$SshPort" 2>$null | Out-Null
        } catch {
            # Ignore the benign "Host ... not found" result.
        }
    }
}

function Get-ConfiguredSshPort {
    param(
        [Parameter(Mandatory=$true)][string]$BoxName,
        [string]$InstanceName
    )

    $configPath = Join-Path $scriptDir "$BoxName\config.json"

    if ($InstanceName) {
        $configPath = Join-Path (Split-Path -Parent $configPath) "instances\$InstanceName\config.json"
    }

    if (-not (Test-Path -LiteralPath $configPath)) {
        throw "The SSH port configuration is missing: $configPath"
    }

    try {
        $configuration = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json
        $configuredPort = [int]$configuration.ssh_port
    } catch {
        throw "Could not read ssh_port from $configPath"
    }

    if ($configuredPort -lt 1 -or $configuredPort -gt 65535) {
        throw "ssh_port in $configPath must be between 1 and 65535."
    }
    return $configuredPort
}

if (-not $UserName) {
    throw "UserName is required."
}

if ($Mode -eq "Host") {
    if ($Box -or $Instance) {
        throw "Do not specify -Box or -Instance in Host mode."
    }
    Install-HostDependencies | Out-Null
    exit 0
}

if (-not $Box) {
    throw "$Mode mode requires -Box <blueprint-folder>."
}

if ($Box -notmatch '^[a-z0-9][a-z0-9_-]*$') {
    throw "Box must exactly match a lowercase blueprint folder name and contain only letters, numbers, '-' or '_'. The spelling and separator character are preserved."
}

if ($Box -eq "core_box") {
    throw "core_box is reserved for the shared foundation image. Select another blueprint folder."
}

if ($Instance -and $Instance -notmatch '^[a-z0-9][a-z0-9_.-]*$') {
    throw "Instance must start with a lowercase letter or number and contain only lowercase letters, numbers, '.', '_' or '-'."
}

if (-not (Get-InstalledDistro)) {
    throw "Ubuntu is not ready. Run Host mode first: .\setup-wsl-dev-environment.ps1 -Mode Host -UserName $UserName"
}

$scriptDirWsl = Get-WslPath $scriptDir
$bashArguments = @(
    "$scriptDirWsl/setup-wsl-dev-environment.sh",
    "--username", $UserName,
    "--box", $Box
)
if ($Instance) {
    $bashArguments += @("--instance", $Instance)
}
if ($Force) {
    $bashArguments += "--yes"
}
if ($Mode -eq "Update") {
    $bashArguments += "--update"
}
if ($Mode -eq "Remove") {
    $bashArguments += "--remove"
}

if ($Mode -eq "Update") {
    if ($Instance) {
        Write-Status "Updating box '$Box' instance '$Instance' inside $wslDistro with Docker CE..."
    } else {
        Write-Status "Updating box '$Box' inside $wslDistro with Docker CE..."
    }
} elseif ($Mode -eq "Remove") {
    if ($Instance) {
        Write-Status "Removing box '$Box' instance '$Instance' inside $wslDistro..."
    } else {
        Write-Status "Removing box '$Box' and all its instances inside $wslDistro..."
    }
} else {
    if ($Instance) {
        Write-Status "Starting box '$Box' instance '$Instance' inside $wslDistro with Docker CE..."
    } else {
        Write-Status "Starting box '$Box' inside $wslDistro with Docker CE..."
    }
}
& wsl.exe --distribution $wslDistro -- bash @bashArguments
$boxExitCode = $LASTEXITCODE
if ($boxExitCode -eq 2) {
    Write-Status "Box replacement was cancelled. Existing resources were not changed."
    exit 0
}
if ($boxExitCode -ne 0) {
    throw "Box setup was cancelled or failed in WSL."
}

if ($Mode -eq "Remove") {
    Write-Status "Removal completed for box '$Box'."
    exit 0
}

$sshPort = Get-ConfiguredSshPort -BoxName $Box -InstanceName $Instance
$hostAlias = if ($Instance) { "$Box-$Instance" } else { $Box }
Configure-WindowsSsh -HostAlias $hostAlias -SshPort $sshPort
if ($Instance) {
    Write-Status "Box '$Box' instance '$Instance' is ready. Connect with: ssh $hostAlias"
} else {
    Write-Status "Box '$Box' is ready. Connect with: ssh $hostAlias"
}

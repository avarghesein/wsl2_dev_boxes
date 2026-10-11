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

    [switch]$DisableSparseVhd
)

$ErrorActionPreference = "Stop"
$script:HostRestartDeclined = $false
$wslDistro = "Ubuntu"
$scriptDir = (Resolve-Path $PSScriptRoot).Path
$projectLeaf = [regex]::Replace((Split-Path -Leaf $scriptDir), '[^A-Za-z0-9._-]', '_')
$pathHasher = [System.Security.Cryptography.SHA256]::Create()
try {
    $pathDigest = [BitConverter]::ToString($pathHasher.ComputeHash([Text.Encoding]::UTF8.GetBytes($scriptDir))).Replace("-", "").Substring(0, 8).ToLowerInvariant()
} finally {
    $pathHasher.Dispose()
}
$projectName = "$projectLeaf-$pathDigest"

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

function Confirm-WindowsRestart {
    param([Parameter(Mandatory=$true)][string]$Reason)

    Write-Status $Reason
    $answer = Read-Host "Restart Windows now? [y/N]"
    if ($answer -notmatch '^(?i:y|yes)$') {
        $script:HostRestartDeclined = $true
        Write-Status "Restart declined. Host setup is paused; restart Windows and run Host mode again when ready."
        return $false
    }

    Write-Status "Restart confirmed. Restarting Windows now. After Windows starts, run Host mode again to continue setup."
    Restart-Computer -ErrorAction Stop
    exit 0
}

function Test-WindowsRestartRequired {
    param([string[]]$Output)

    $outputText = $Output -join "`n"
    return $outputText -match '(?i)changes will not be effective until (?:the )?system is rebooted|restart (?:is )?required|reboot (?:is )?required'
}

function Invoke-WslNative {
    param(
        [Parameter(Mandatory=$true)][string[]]$Arguments,
        [switch]$StreamOutput
    )

    $previousErrorActionPreference = $ErrorActionPreference
    $output = @()
    $exitCode = 1
    try {
        $ErrorActionPreference = "Continue"
        $output = @(& wsl.exe @Arguments 2>&1 | ForEach-Object {
            $line = $_.ToString() -replace "`0", ""
            if ($StreamOutput) {
                [Console]::Out.WriteLine($line)
            }
            $line
        })
        $exitCode = $LASTEXITCODE
    } catch {
        $output += ($_.Exception.Message -replace "`0", "")
        if ($null -ne $LASTEXITCODE) {
            $exitCode = $LASTEXITCODE
        }
    } finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }

    return [pscustomobject]@{
        ExitCode = $exitCode
        Output = [string[]]$output
    }
}

function Get-WslPath {
    param([Parameter(Mandatory=$true)][string]$WindowsPath)

    # Forward slashes prevent WSL argument parsing from stripping Windows
    # backslash separators before wslpath receives the path.
    $wslPathInput = $WindowsPath -replace '\\', '/'
    $wslResult = Invoke-WslNative -Arguments @("--distribution", $wslDistro, "--", "wslpath", "-a", $wslPathInput)
    $wslPath = ($wslResult.Output -join "`n").Trim()
    if ($wslResult.ExitCode -ne 0 -or -not $wslPath) {
        throw "Could not convert Windows path to a WSL path: $WindowsPath"
    }
    return $wslPath
}

function Get-WslHomePath {
    param([Parameter(Mandatory=$true)][string]$LinuxUser)

    $wslResult = Invoke-WslNative -Arguments @("--distribution", $wslDistro, "--user", $LinuxUser, "--", "getent", "passwd", $LinuxUser)
    $passwdEntry = $wslResult.Output
    if ($wslResult.ExitCode -ne 0 -or -not $passwdEntry) {
        throw "Could not find the Ubuntu WSL home directory for '$LinuxUser'. Run Host mode first."
    }

    $fields = ($passwdEntry -join "").Split(':')
    if ($fields.Count -lt 6 -or -not $fields[5].StartsWith('/')) {
        throw "Ubuntu returned an invalid home directory for '$LinuxUser'."
    }
    return $fields[5]
}

function Get-InstalledDistro {
    $wslResult = Invoke-WslNative -Arguments @("--list", "--quiet")
    if ($wslResult.ExitCode -ne 0) {
        return $null
    }
    return $wslResult.Output |
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
        [switch]$AsRoot,
        [string]$LinuxUser
    )

    # PowerShell scripts checked out on Windows commonly use CRLF. Bash treats
    # the carriage return as part of each command, so send LF-only script text
    # through the WSL stdin handoff.
    $normalizedScript = $Script.Replace("`r`n", "`n").Replace("`r", "`n")
    $encoded = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($normalizedScript))
    $userArgs = @()
    if ($AsRoot) {
        $userArgs = @("--user", "root")
    } elseif ($LinuxUser) {
        $userArgs = @("--user", $LinuxUser)
    }

    $argumentText = "echo $encoded | base64 -d | bash -s --"
    foreach ($argument in $Arguments) {
        $quotedArgument = "'" + $argument.Replace("'", "'\''") + "'"
        $argumentText += " $quotedArgument"
    }

    $wslArguments = @("--distribution", $wslDistro) + $userArgs + @("--", "bash", "-lc", $argumentText)
    $wslResult = Invoke-WslNative -Arguments $wslArguments
    foreach ($outputLine in $wslResult.Output) {
        $line = $outputLine -replace "`r", ""
        $line = $line -replace "`e\[[0-9;?]*[ -/]*[@-~]", ""
        $line = $line -replace "[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]", ""
        $line = $line.Trim()
        if ($line.Length -gt 0) {
            [Console]::Out.WriteLine("[Ubuntu] $line")
        }
    }
    if ($wslResult.ExitCode -ne 0) {
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
        $sparseResult = Invoke-WslNative -Arguments @("--manage", $wslDistro, "--set-sparse", "true", "--allow-unsafe")
        if ($sparseResult.ExitCode -eq 0) {
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
    $wslResult = Invoke-WslNative -Arguments @("--list", "--verbose")
    foreach ($line in $wslResult.Output) {
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
        $wslResult = Invoke-WslNative -Arguments @("--set-version", $wslDistro, "2")
        if ($wslResult.ExitCode -eq 0) {
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

function Request-WslPlatformRestart {
    Write-Status "Installing or enabling the WSL platform and Virtual Machine Platform without launching a Linux distribution..."
    $platformResult = Invoke-WslNative -Arguments @("--install", "--no-distribution")
    foreach ($outputLine in $platformResult.Output) {
        [Console]::Out.WriteLine($outputLine)
    }
    if ($platformResult.ExitCode -ne 0) {
        Write-Status "The WSL platform setup command returned exit code $($platformResult.ExitCode). Review its output above."
    }
    if (Test-WindowsRestartRequired -Output $platformResult.Output) {
        Confirm-WindowsRestart -Reason "Windows reports that the WSL platform changes require a restart."
    } else {
        Write-Status "If Windows reports that a restart is required, restart it before running Host mode again."
    }
    Write-Status "If this server is a VM, enable nested virtualization in its hypervisor. On a physical server, enable Intel VT-x or AMD-V in firmware."
}

function Install-HostDependencies {
    if ($UserName -notmatch '^[a-z_][a-z0-9_-]*$') {
        throw "UserName must be a valid Linux username because it is also used for the automated WSL user."
    }

    Write-Status "Stopping all WSL distributions before host provisioning..."
    $null = Invoke-WslNative -Arguments @("--shutdown")

    $wslStatus = Invoke-WslNative -Arguments @("--status")
    if ($wslStatus.ExitCode -ne 0) {
        Write-Status "WSL platform setup is incomplete. Preparing its required Windows features first."
        Request-WslPlatformRestart
        return $false
    }

    $installCommandRun = $false
    $installExitCode = 0
    if (-not (Get-InstalledDistro)) {
        Write-Status "Ubuntu is not installed. Installing it in WSL without opening an interactive console..."
        $installResult = Invoke-WslNative -Arguments @("--install", "--no-launch", "--distribution", $wslDistro)
        foreach ($outputLine in $installResult.Output) { [Console]::Out.WriteLine($outputLine) }
        $installExitCode = $installResult.ExitCode
        $installCommandRun = $true

        if (Test-WindowsRestartRequired -Output $installResult.Output) {
            Confirm-WindowsRestart -Reason "Windows reports that WSL platform changes require a restart."
            return $false
        }
    }

    if (-not (Get-InstalledDistro)) {
        $installFailureText = if ($installResult) { $installResult.Output -join "`n" } else { "" }
        if ($installFailureText -match '(?i)(HCS_E_HYPERV_NOT_INSTALLED|WSL2 is unable to start|Virtual Machine Platform|virtualization is not enabled)') {
            Write-Status "Ubuntu could not register because WSL 2 virtualization support is unavailable."
            Request-WslPlatformRestart
            return $false
        }
        if ($installExitCode -ne 0) {
            Write-Status "The WSL installation command failed with exit code $installExitCode."
            return $false
        }
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
    $wslResult = Invoke-WslNative -Arguments @("--set-default", $wslDistro)
    if ($wslResult.ExitCode -ne 0) {
        throw "Could not set Ubuntu as the default WSL distribution."
    }
    $wslResult = Invoke-WslNative -Arguments @("--set-default-version", "2")
    if ($wslResult.ExitCode -ne 0) {
        throw "Could not set WSL 2 as the default WSL version."
    }
    Set-DistroToWsl2

    $installScript = @'
set -e
exec 2>&1
WSL_USER="$1"
export DEBIAN_FRONTEND=noninteractive
export TERM=dumb

find /etc/apt -type f \( -name '*.list' -o -name '*.sources' \) -exec sed -i 's|http://|https://|g' {} +

echo "Checking for and removing pre-existing Docker/container engine packages and repositories..."
if command -v systemctl >/dev/null 2>&1; then
    systemctl disable --now docker.socket docker.service containerd.service >/dev/null 2>&1 || true
else
    service docker stop >/dev/null 2>&1 || true
fi
find /etc/apt/sources.list.d -maxdepth 1 -type f \( -iname '*docker*.list' -o -iname '*docker*.sources' \) -delete
rm -f /etc/apt/keyrings/docker.asc /etc/apt/keyrings/docker.gpg /usr/share/keyrings/docker-archive-keyring.gpg
for package in docker-ce docker-ce-cli docker-ce-rootless-extras docker-buildx-plugin docker-compose-plugin docker-scan-plugin containerd.io containerd docker.io docker-compose docker-compose-v2 docker-doc moby-engine moby-cli; do
    if dpkg-query -W -f='${db:Status-Status}' "$package" 2>/dev/null | grep -qx installed; then
        apt-get -o Dpkg::Use-Pty=0 -o APT::Color=0 -o APT::Progress::Fancy=0 purge -y "$package"
    fi
done
if getent group docker >/dev/null 2>&1; then
    gpasswd -d "$WSL_USER" docker >/dev/null 2>&1 || true
fi

echo "Updating package indexes..."
apt-get -o Dpkg::Use-Pty=0 -o APT::Color=0 -o APT::Progress::Fancy=0 update
echo "Installing rootless Podman and WSL prerequisites..."
apt-get -o Dpkg::Use-Pty=0 -o APT::Color=0 -o APT::Progress::Fancy=0 install -y \
    ca-certificates curl fuse-overlayfs jq openssh-client podman podman-docker rsync slirp4netns sudo uidmap

echo "Configuring Linux user '$WSL_USER'..."
if ! id -u "$WSL_USER" >/dev/null 2>&1; then
    useradd --create-home --shell /bin/bash "$WSL_USER"
fi
WSL_HOME="$(getent passwd "$WSL_USER" | cut -d: -f6)"
install -d -o "$WSL_USER" -g "$(id -gn "$WSL_USER")" "$WSL_HOME"
echo "$WSL_USER ALL=(ALL) NOPASSWD:ALL" > "/etc/sudoers.d/$WSL_USER"
chmod 0440 "/etc/sudoers.d/$WSL_USER"

add_subid_range() {
    local database="$1"
    local option="$2"
    local next_id end_id
    if grep -q "^${WSL_USER}:" "$database" 2>/dev/null; then
        return
    fi
    next_id="$(awk -F: 'BEGIN { max=99999 } { end=$2+$3-1; if (end>max) max=end } END { print max+1 }' "$database" 2>/dev/null || echo 100000)"
    end_id=$((next_id + 65535))
    usermod "$option" "$next_id-$end_id" "$WSL_USER"
}
add_subid_range /etc/subuid --add-subuids
add_subid_range /etc/subgid --add-subgids

WSL_CONF_SOURCE=/etc/wsl.conf
if [[ ! -f "$WSL_CONF_SOURCE" ]]; then
    WSL_CONF_SOURCE=/dev/null
fi
WSL_CONF_TEMP="$(mktemp /etc/wsl.conf.XXXXXX)"
awk -v default_user="$WSL_USER" '
    function finish_section() {
        if (section == "[boot]" && !boot_setting) {
            print "systemd=true"
            boot_setting=1
        }
        if (section == "[user]" && !user_setting) {
            print "default=" default_user
            user_setting=1
        }
    }
    /^[[:space:]]*\[[^]]+\][[:space:]]*$/ {
        finish_section()
        section=tolower($0)
        gsub(/[[:space:]]/, "", section)
        if (section == "[boot]") boot_section=1
        if (section == "[user]") user_section=1
        print
        next
    }
    section == "[boot]" && /^[[:space:]]*systemd[[:space:]]*=/ {
        if (!boot_setting) print "systemd=true"
        boot_setting=1
        next
    }
    section == "[user]" && /^[[:space:]]*default[[:space:]]*=/ {
        if (!user_setting) print "default=" default_user
        user_setting=1
        next
    }
    { print }
    END {
        finish_section()
        if (!boot_section) print "[boot]\nsystemd=true"
        if (!user_section) print "[user]\ndefault=" default_user
    }
' "$WSL_CONF_SOURCE" > "$WSL_CONF_TEMP"
chown root:root "$WSL_CONF_TEMP"
chmod 0644 "$WSL_CONF_TEMP"
mv -f "$WSL_CONF_TEMP" /etc/wsl.conf

echo "Rootless Podman packages installed. User services will be enabled after WSL restarts with systemd."
'@

    Write-Status "Running Ubuntu provisioning for rootless Podman..."
    Invoke-WslScript -Script $installScript -Arguments @($UserName) -AsRoot
    $wslResult = Invoke-WslNative -Arguments @("--terminate", $wslDistro)
    if ($wslResult.ExitCode -ne 0) {
        throw "Could not restart Ubuntu after enabling systemd."
    }

    $lingerScript = @'
set -e
loginctl enable-linger "$1"
'@
    Invoke-WslScript -Script $lingerScript -Arguments @($UserName) -AsRoot

    $socketScript = @'
set -e
WSL_UID="$(id -u)"
export XDG_RUNTIME_DIR="/run/user/$WSL_UID"
export DBUS_SESSION_BUS_ADDRESS="unix:path=$XDG_RUNTIME_DIR/bus"
systemctl --user enable --now podman.socket
podman info --format '{{.Host.Security.Rootless}}' | grep -qx true
'@
    Invoke-WslScript -Script $socketScript -LinuxUser $UserName
    Write-Status "Host provisioning is complete. Rootless Podman containers start through systemd when Ubuntu WSL starts."
    return $true
}

function Sync-ProjectToWsl {
    $sourceDirWsl = Get-WslPath $scriptDir
    $wslHome = Get-WslHomePath $UserName
    $wslProjectPath = "$wslHome/.local/share/wsl-dev-boxes/$projectName"
    $arguments = @($sourceDirWsl, $projectName)

    $syncScript = @'
set -euo pipefail
SOURCE_DIR="$1"
PROJECT_NAME="$2"
WSL_USER="$(id -un)"
WSL_HOME="$(getent passwd "$WSL_USER" | cut -d: -f6)"
case "$PROJECT_NAME" in
    *[!a-zA-Z0-9._-]*|'') echo "ERROR: Invalid project sync directory name." >&2; exit 1 ;;
esac
if [[ ! -d "$SOURCE_DIR" ]]; then
    echo "ERROR: Windows project checkout is not accessible through WSL: $SOURCE_DIR" >&2
    exit 1
fi
DEST="$WSL_HOME/.local/share/wsl-dev-boxes/$PROJECT_NAME"
MARKER="$DEST/.wsl-devbox-sync"
if [[ -e "$DEST" && ! -f "$MARKER" ]]; then
    echo "ERROR: Refusing to sync into an unmarked directory: $DEST" >&2
    exit 1
fi
mkdir -p "$DEST"
printf 'Managed project sync directory.\n' > "$MARKER"
rsync -a --delete --exclude='/.git/' --exclude='/.wsl-devbox-sync' "$SOURCE_DIR/" "$DEST/"

# The checkout can live on a Windows drive, where Git or an editor may leave
# shell scripts and Containerfiles with CRLF endings. Normalize those files
# before Bash executes them or Podman builds from them.
find "$DEST" -type f \( -name '*.sh' -o -name '*.bash' -o -name 'Containerfile' \) -exec sed -i 's/\r$//' {} +

printf '%s\n' "$DEST"
'@

    Invoke-WslScript -Script $syncScript -Arguments $arguments -LinuxUser $UserName
    return $wslProjectPath
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
    $pubKeyPath = "$keyPath.pub"
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

    $hostEntryPattern = "(?ms)^Host[ `t]+$([regex]::Escape($HostAlias))[ `t]*\r?\n.*?(?=^Host[ `t]|\z)"
    $hostEntry = @"
Host $HostAlias
    HostName localhost
    User $UserName
    Port $SshPort
    IdentityFile `"$keyPath`"
    IdentitiesOnly yes
"@

    $sshConfig = [System.IO.File]::ReadAllText($sshConfigPath)
    if ([regex]::IsMatch($sshConfig, $hostEntryPattern)) {
        $hostEntryReplacement = $hostEntry.Replace('$', '$$') + [Environment]::NewLine
        $sshConfig = [regex]::Replace($sshConfig, $hostEntryPattern, $hostEntryReplacement, 1)
    } else {
        $sshConfig += [Environment]::NewLine + $hostEntry + [Environment]::NewLine
    }
    [System.IO.File]::WriteAllText($sshConfigPath, $sshConfig, [System.Text.UTF8Encoding]::new($false))
    Write-Status "Updated Windows SSH host '$HostAlias'."

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
        [string]$InstanceName,
        [Parameter(Mandatory=$true)][string]$WslProjectPath
    )

    $configPath = "$WslProjectPath/$BoxName/config.json"
    if ($InstanceName) {
        $configPath = "$WslProjectPath/$BoxName/instances/$InstanceName/config.json"
    }
    $wslResult = Invoke-WslNative -Arguments @("--distribution", $wslDistro, "--user", $UserName, "--", "jq", "-r", '.ssh_port // empty', $configPath)
    $portOutput = $wslResult.Output
    if ($wslResult.ExitCode -ne 0 -or -not $portOutput) {
        throw "Could not read ssh_port from the WSL project config: $configPath"
    }
    try { $configuredPort = [int](($portOutput -join "").Trim()) } catch {
        throw "ssh_port in $configPath must be a number."
    }
    if ($configuredPort -lt 1 -or $configuredPort -gt 65535) {
        throw "ssh_port in $configPath must be between 1 and 65535."
    }
    return $configuredPort
}

if (-not $UserName) {
    throw "UserName is required."
}
if ($UserName -notmatch '^[a-z_][a-z0-9_-]*$' -or $UserName -eq "root") {
    throw "UserName must be a valid non-root Linux username because it is used for rootless Podman."
}

if ($Mode -eq "Host") {
    if ($Box -or $Instance) {
        throw "Do not specify -Box or -Instance in Host mode."
    }
    $currentIdentity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    $currentPrincipal = New-Object -TypeName System.Security.Principal.WindowsPrincipal -ArgumentList $currentIdentity
    if (-not $currentPrincipal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw "Host mode must be run from an elevated Administrator PowerShell window."
    }
    $hostSetupOutput = @(Install-HostDependencies)
    if ($script:HostRestartDeclined) {
        exit 0
    }
    if ($hostSetupOutput.Count -eq 0 -or -not [bool]$hostSetupOutput[-1]) {
        throw "Host setup did not complete. If WSL requested a Windows restart, restart Windows and run Host mode again."
    }
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

$installedDistro = Get-InstalledDistro
if (-not $installedDistro) {
    throw "Ubuntu is not ready. Run Host mode first: .\setup-wsl-dev-environment.ps1 -Mode Host -UserName $UserName"
}

$wslProjectPath = Sync-ProjectToWsl
$bashArguments = @(
    "$wslProjectPath/setup-wsl-dev-environment.sh",
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
        Write-Status "Updating box '$Box' instance '$Instance' with rootless Podman inside $wslDistro..."
    } else {
        Write-Status "Updating box '$Box' with rootless Podman inside $wslDistro..."
    }
} elseif ($Mode -eq "Remove") {
    if ($Instance) {
        Write-Status "Removing box '$Box' instance '$Instance' inside $wslDistro..."
    } else {
        Write-Status "Removing box '$Box' and all its instances inside $wslDistro..."
    }
} else {
    if ($Instance) {
        Write-Status "Creating box '$Box' instance '$Instance' with rootless Podman inside $wslDistro..."
    } else {
        Write-Status "Creating box '$Box' with rootless Podman inside $wslDistro..."
    }
}
$wslArguments = @("--distribution", $wslDistro, "--user", $UserName, "--", "bash") + $bashArguments
$boxResult = Invoke-WslNative -Arguments $wslArguments -StreamOutput
$boxExitCode = $boxResult.ExitCode
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

$sshPort = Get-ConfiguredSshPort -BoxName $Box -InstanceName $Instance -WslProjectPath $wslProjectPath
$hostAlias = if ($Instance) { "$Box-$Instance" } else { $Box }
Configure-WindowsSsh -HostAlias $hostAlias -SshPort $sshPort
if ($Instance) {
    Write-Status "Box '$Box' instance '$Instance' is ready. Connect with: ssh $hostAlias"
} else {
    Write-Status "Box '$Box' is ready. Connect with: ssh $hostAlias"
}

# az-cfg-sql.ps1

Write-Host "Installing prerequisites"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# Robust package installation with retries
$retries = 5
$wait = 10

# Install NuGet provider
$attempt = 0
while ($attempt -lt $retries) {
    try {
        Install-PackageProvider -Name NuGet -Force -ErrorAction Stop
        break
    } catch {
        $attempt++
        Write-Host "Failed to install NuGet, attempt $attempt/$retries. Error: $_"
        if ($attempt -eq $retries) { throw }
        Start-Sleep -Seconds $wait
    }
}

# Remove old SqlServer modules and install modern version
Write-Host "Updating SqlServer module..."
Get-Module -Name SqlServer -ListAvailable | Uninstall-Module -Force -ErrorAction SilentlyContinue
Install-Module -Name SqlServer -Force -AllowClobber -RequiredVersion "21.1.18256" -SkipPublisherCheck
Import-Module SqlServer -Force

# SQL IaaS Extension installation - FIXED SECTION
Write-Host "Installing SQL IaaS Extension"
try {
    $extensionUrl = "https://download.microsoft.com/download/0/2/A/02AAE597-3865-456C-AE7F-613F99F850A8/SQLIaaSExtension.exe"
    $installerPath = "C:\SQLIaaSExtension.exe"
    Invoke-WebRequest -Uri $extensionUrl -OutFile $installerPath -UseBasicParsing -ErrorAction Stop
    Start-Process $installerPath -ArgumentList "/quiet" -Wait -NoNewWindow
} catch {
    Write-Host "Using alternative installation method"
    # FIX: Use proper argument formatting
    Start-Process "msiexec.exe" -ArgumentList @("/i", "https://aka.ms/sqliaasextension", "/qn") -Wait
}

# Service management with status verification
function Ensure-ServiceRunning {
    param($serviceName)

    Set-Service -Name $serviceName -StartupType Automatic -ErrorAction SilentlyContinue
    $retries = 10
    $wait = 15

    for ($i = 0; $i -lt $retries; $i++) {
        try {
            Start-Service $serviceName -ErrorAction Stop
            if ((Get-Service $serviceName).Status -eq 'Running') {
                Write-Host "Service $serviceName is running"
                return
            }
        } catch {
            Write-Host "Service $serviceName not running, attempt $($i+1)/$retries. Error: $_"
        }
        Start-Sleep -Seconds $wait
    }
    throw "Failed to start $serviceName after $retries attempts"
}

# Start SQL services
Ensure-ServiceRunning "MSSQLSERVER"
Ensure-ServiceRunning "SQLSERVERAGENT"

# ============================================================
# OS-Level Configuration Only (No SA setup)
# ============================================================
Write-Host "Applying OS-level configurations"

# Instant File Initialization (OS-level)
try {
    Write-Host "Configuring Instant File Initialization"
    $tempCfg = "$env:TEMP\secpol.cfg"

    # Get SQL Service SID
    $service = Get-WmiObject Win32_Service -Filter "Name='MSSQLSERVER'"
    if (-not $service) {
        throw "SQL Server service not found"
    }
    $sqlSid = $service.SID

    secedit /export /cfg $tempCfg
    $content = Get-Content $tempCfg

    # Replace or add privilege line
    $privilegeLine = "SeManageVolumePrivilege = $sqlSid"
    if ($content -match "^SeManageVolumePrivilege") {
        $content = $content -replace '^SeManageVolumePrivilege.*', $privilegeLine
    } else {
        $content += $privilegeLine
    }

    $content | Set-Content $tempCfg
    secedit /configure /db "$env:windir\security\local.sdb" /cfg $tempCfg /areas USER_RIGHTS

    # Validate configuration
    secedit /export /cfg $tempCfg /areas USER_RIGHTS
    if (Select-String -Path $tempCfg -Pattern "SeManageVolumePrivilege = $sqlSid") {
        Write-Host "Instant File Initialization configured successfully"
    } else {
        Write-Host "WARNING: Failed to verify Instant File Initialization configuration"
        Write-Host "Contents of secpol.cfg:"
        Get-Content $tempCfg
    }
} catch {
    Write-Host "ERROR: Configuring IFI: $_"
    throw
} finally {
    Remove-Item $tempCfg -ErrorAction SilentlyContinue
}

Write-Host "Base SQL Server image prepared. SA configuration will be done during VM provisioning."
 
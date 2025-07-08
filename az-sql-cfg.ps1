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

# SQL IaaS Extension installation
Write-Host "Installing SQL IaaS Extension"
try {
    $extensionUrl = "https://download.microsoft.com/download/0/2/A/02AAE597-3865-456C-AE7F-613F99F850A8/SQLIaaSExtension.exe"
    $installerPath = "C:\SQLIaaSExtension.exe"
    Invoke-WebRequest -Uri $extensionUrl -OutFile $installerPath -UseBasicParsing -ErrorAction Stop
    Start-Process $installerPath -ArgumentList "/quiet" -Wait -NoNewWindow
} catch {
    Write-Host "Using alternative installation method"
    Start-Process "msiexec.exe" -ArgumentList "/i `"https://aka.ms/sqliaasextension`" /qn" -Wait
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

# SQL configuration with feature detection
function Invoke-SafeSql {
    param($query)
    try {
        Invoke-SqlCmd -Query $query -ServerInstance "." -ErrorAction Stop
    } catch {
        Write-Host "Warning: Failed to execute query: $($query -replace '\s+', ' '). Error: $_"
    }
}

function Feature-Exists {
    param($featureName)
    try {
        $result = Invoke-SqlCmd -Query "SELECT 1 FROM sys.configurations WHERE name = '$featureName'" `
            -ServerInstance "." -ErrorAction Stop
        return ($result -ne $null)
    } catch {
        return $false
    }
}

# SQL configuration commands
Write-Host "Applying SQL configuration"
Invoke-SafeSql "ALTER LOGIN sa ENABLE;"
Invoke-SafeSql "ALTER LOGIN sa WITH PASSWORD = 'Du,BOO7+awA;DZMov5dG';"
Invoke-SafeSql "EXEC xp_instance_regwrite N'HKEY_LOCAL_MACHINE', N'Software\Microsoft\MSSQLServer\MSSQLServer', N'LoginMode', REG_DWORD, 2;"
Invoke-SafeSql "EXEC sp_configure 'show advanced options', 1; RECONFIGURE;"
Invoke-SafeSql "EXEC sp_configure 'max server memory', 8192; RECONFIGURE;"
# Invoke-SafeSql "EXEC sp_configure 'backup compression default', 1; RECONFIGURE;"

# Conditional execution for advanced features
# Only configure 'optimize for ad hoc workloads' if supported
try {
    $featureCheck = Invoke-SqlCmd -Query "SELECT COUNT(*) AS ExistsFlag FROM sys.configurations WHERE name = 'optimize for ad hoc workloads'" -ServerInstance "."
    if ($featureCheck.ExistsFlag -gt 0) {
        Invoke-SafeSql "EXEC sp_configure 'optimize for ad hoc workloads', 1; RECONFIGURE;"
    } else {
        Write-Host "'optimize for ad hoc workloads' not available in this SQL version"
    }
} catch {
    Write-Host "Could not check for 'optimize for ad hoc workloads' feature: $_"
}

# TempDB configuration with size validation
Invoke-SafeSql @"
USE [master];
DECLARE @file_size INT = (SELECT size * 8 / 1024 FROM sys.master_files WHERE name = 'tempdev')
IF @file_size < 8192
    ALTER DATABASE [tempdb] MODIFY FILE (NAME = N'tempdev', SIZE = 8192MB, FILEGROWTH = 0);
"@

# Instant File Initialization
try {
    Write-Host "Configuring Instant File Initialization"
    $account = "NT SERVICE\MSSQLSERVER"
    $tempCfg = "$env:TEMP\secpol.cfg"

    secedit /export /cfg $tempCfg
    (Get-Content $tempCfg) -replace '^SeManageVolumePrivilege.*', "SeManageVolumePrivilege = $account" | Set-Content $tempCfg
    secedit /configure /db "$env:windir\security\local.sdb" /cfg $tempCfg /areas USER_RIGHTS
} catch {
    Write-Host "Error configuring IFI: $_"
} finally {
    Remove-Item $tempCfg -ErrorAction SilentlyContinue
}

Write-Host "SQL Server configuration completed."
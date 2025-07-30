# SQL Server Configuration Script
Write-Host "Starting SQL Server configuration..."

# Initialize and format data disk
Write-Host "Initializing and formatting data disk..."
$disks = Get-Disk | Where-Object { $_.PartitionStyle -eq 'raw' -or $_.OperationalStatus -eq 'Offline' }

if ($disks) {
    $disks | Initialize-Disk -PartitionStyle GPT -PassThru |
        New-Partition -AssignDriveLetter -UseMaximumSize |
        Format-Volume -FileSystem NTFS -NewFileSystemLabel "SQLData" -Confirm:$false -Force
    Write-Host "Data disk initialized and formatted successfully"
} else {
    Write-Host "WARNING: No uninitialized disks found. Data disk may already be formatted."
}

# Configure SQL services
Write-Host "Configuring SQL services..."
Set-Service -Name MSSQLSERVER -StartupType Automatic -ErrorAction Continue
Set-Service -Name SQLSERVERAGENT -StartupType Automatic -ErrorAction Continue

# Start SQL services
Write-Host "Starting SQL services..."
Start-Service MSSQLSERVER -ErrorAction Continue
Start-Service SQLSERVERAGENT -ErrorAction Continue

# Configure Instant File Initialization (IFI)
Write-Host "Configuring Instant File Initialization..."
try {
    $svc = Get-CimInstance -ClassName Win32_Service -Filter "Name='MSSQLSERVER'" -ErrorAction Stop
    $accountName = $svc.StartName
    Write-Host "SQL Service Account: $accountName"

    # Translate account to SID (without modifying the name)
    $ntAccount = New-Object System.Security.Principal.NTAccount($accountName)
    $sid = $ntAccount.Translate([System.Security.Principal.SecurityIdentifier]).Value
    Write-Host "Service Account SID: $sid"

    # Grant SeManageVolumePrivilege
    $policyTemplate = @"
[Unicode]
Unicode=yes
[Version]
signature="`$CHICAGO`$"
revision=1
[Privilege Rights]
SeManageVolumePrivilege = *$sid
"@
    $cfg = "$env:TEMP\secpol.cfg"
    $policyTemplate | Set-Content $cfg -Force
    secedit /configure /db "$env:windir\security\local.sdb" /cfg $cfg /areas USER_RIGHTS /quiet
    Remove-Item $cfg -Force
    Write-Host "Instant File Initialization configured successfully"
} catch { 
    Write-Host "WARNING: IFI configuration skipped - $_"
}

# Configure SQL firewall rule
Write-Host "Configuring Windows Firewall..."
New-NetFirewallRule -DisplayName "SQL Server" -Direction Inbound -Protocol TCP -LocalPort 1433 -Action Allow -ErrorAction Continue

# Configure default directories
Write-Host "Configuring default SQL directories..."
try {
    $directories = @("\Data", "\Logs", "\Backup")
    foreach ($dir in $directories) {
        $fullPath = "F:$dir"
        if (-not (Test-Path $fullPath)) {
            New-Item -Path $fullPath -ItemType Directory -Force | Out-Null
        }
    }

    Invoke-SqlCmd -Query "
        EXEC xp_instance_regwrite N'HKEY_LOCAL_MACHINE', N'Software\Microsoft\MSSQLServer\MSSQLServer', N'DefaultData', REG_SZ, N'F:\Data';
        EXEC xp_instance_regwrite N'HKEY_LOCAL_MACHINE', N'Software\Microsoft\MSSQLServer\MSSQLServer', N'DefaultLog', REG_SZ, N'F:\Logs';
        EXEC xp_instance_regwrite N'HKEY_LOCAL_MACHINE', N'Software\Microsoft\MSSQLServer\MSSQLServer', N'BackupDirectory', REG_SZ, N'F:\Backup';
    " -ServerInstance "localhost" -ErrorAction Continue
} catch {
    Write-Host "WARNING: Directory configuration skipped - $_"
}

Write-Host "SQL Server configuration completed successfully"
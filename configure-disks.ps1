# configure-disks.ps1

# Disk Configuration
Write-Host "Configuring disks and folders..."
$disks = Get-Disk | Where-Object PartitionStyle -eq 'RAW' | Sort-Object Number

if ($disks.Count -lt 2) {
    throw "ERROR: This configuration requires at least 2 raw disks!"
}

# Initialize Disk 1 → Assign F:
$disks[0] | Initialize-Disk -PartitionStyle GPT -PassThru | 
    New-Partition -UseMaximumSize -DriveLetter F |
    Format-Volume -FileSystem NTFS -NewFileSystemLabel "Disk$($disks[0].Number)" -Confirm:$false -Force

# Initialize Disk 2 → Assign H:
$disks[1] | Initialize-Disk -PartitionStyle GPT -PassThru | 
    New-Partition -UseMaximumSize -DriveLetter H |  # Explicitly assign H:
    Format-Volume -FileSystem NTFS -NewFileSystemLabel "Disk$($disks[1].Number)" -Confirm:$false -Force

# Wait for drives to become available
Start-Sleep -Seconds 15

# Create folder structure
$folders = @(
    "F:\Databases\UserDBs",
    "H:\tempDb"
)

foreach ($folder in $folders) {
    if (-not (Test-Path $folder)) {
        Write-Host "Creating folder: $folder"
        New-Item -Path $folder -ItemType Directory -Force
    }
}

# Configure SQL Server paths
Write-Host "Configuring SQL Server paths..."

# Function to set SQL Server registry paths
function Set-SqlPath {
    param(
        [string]$PathType,
        [string]$Path
    )

    $regPath = "HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\MSSQL16.MSSQLSERVER\MSSQLServer"
    $regName = "Default${PathType}"

    if (-not (Test-Path $regPath)) {
        New-Item -Path $regPath -Force
    }

    $current = Get-ItemProperty -Path $regPath -Name $regName -ErrorAction SilentlyContinue
    if (-not $current -or $current.$regName -ne $Path) {
        Write-Host "Setting SQL $PathType path to: $Path"
        Set-ItemProperty -Path $regPath -Name $regName -Value $Path -Type String -Force
    }
}

# Set the paths
Set-SqlPath -PathType "Data" -Path "F:\Databases\UserDBs"
Set-SqlPath -PathType "Log" -Path "F:\Databases\UserDBs"
Set-SqlPath -PathType "Temp" -Path "H:\tempDb"

# Set permissions
Write-Host "Setting permissions..."
$sqlServiceAccount = "NT SERVICE\MSSQLSERVER"

# Grant permissions to SQL Service account
foreach ($folder in $folders) {
    icacls $folder /grant "${sqlServiceAccount}:(OI)(CI)F" /T
}

# Configure SQL Server service
Write-Host "Configuring SQL Server services..."
Set-Service -Name MSSQLSERVER -StartupType Automatic
Set-Service -Name SQLSERVERAGENT -StartupType Automatic

# Restart SQL Server to apply changes
Write-Host "Restarting SQL Server..."
Restart-Service MSSQLSERVER -Force

Write-Host "Disk and folder configuration complete!"
Write-Host "Data path: F:\Databases\UserDBs"
Write-Host "TempDB path: H:\tempDb" 
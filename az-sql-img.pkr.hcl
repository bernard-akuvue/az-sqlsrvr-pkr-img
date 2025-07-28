packer {
  required_plugins {
    azure = {
      version = ">= 2.3.3"
      source  = "github.com/hashicorp/azure"
    }
  }
}

source "azure-arm" "sql_image" {
  use_azure_cli_auth        = true
  image_publisher           = "MicrosoftSQLServer"
  image_offer               = "SQL2022-WS2022"
  image_sku                 = "sqldev-gen2"
  os_type                   = "Windows"

  build_resource_group_name         = "sql-pkr-img"
  managed_image_name                = "pkr-dev-${formatdate("YYMMDDhhmm", timestamp())}"
  managed_image_resource_group_name = "sql-pkr-img"
  vm_size                           = "Standard_B4ms"

  communicator   = "winrm"
  winrm_use_ssl  = true
  winrm_insecure = true
  winrm_timeout  = "40m"
  winrm_port     = 5986

  winrm_username = "localadmin"
  winrm_password = "Du,BOO7+awA;DZMov5dG"  # Rotate after testing!

  os_disk_size_gb     = 128

  azure_tags = {
    component = "sql-server"
    build     = formatdate("YYYY-MM-DD", timestamp())
  }
}

build {
  sources = ["source.azure-arm.sql_image"]

  provisioner "powershell" {
    inline = [
      "Write-Host 'Listing all local administrators on this VM:'",
      "Get-LocalGroupMember -Group 'Administrators' | Select-Object -ExpandProperty Name"
    ]
  }

  provisioner "powershell" {
    inline = [
      "Set-Service -Name MSSQLSERVER   -StartupType Automatic",
      "Set-Service -Name SQLSERVERAGENT -StartupType Automatic"
    ]
  }

  provisioner "powershell" {
    inline = [
      "Write-Host 'Configuring IFI...'",
      "try {",
      "  $svc = Get-CimInstance -ClassName Win32_Service -Filter \"Name='MSSQLSERVER'\"",
      "  if (-not $svc) { throw 'MSSQLSERVER service not found' }",
      "  $accountName = $svc.StartName",
      "  if (-not $accountName) { throw 'Failed to get account name for MSSQLSERVER service' }",
      "  ",
      "  # Handle NT SERVICE\\ account format",
      "  if ($accountName -match '^NT SERVICE\\\\') {",
      "    $accountName = 'NT SERVICE\\' + ($accountName -split '\\\\')[-1]",
      "  }",
      "  ",
      "  # Convert account name to SID",
      "  $ntAccount = New-Object System.Security.Principal.NTAccount($accountName)",
      "  $sid = $ntAccount.Translate([System.Security.Principal.SecurityIdentifier]).Value",
      "  if (-not $sid) { throw 'Failed to convert account to SID' }",
      "  ",
      "  $cfg = \"$env:TEMP\\secpol.cfg\"",
      "  secedit /export /cfg $cfg | Out-Null",
      "  $content = Get-Content $cfg",
      "  $newContent = @()",
      "  $privilegeLineFound = $false",
      "  ",
      "  # Process each line individually",
      "  foreach ($line in $content) {",
      "    if ($line -match '^SeManageVolumePrivilege\\s*=') {",
      "      $privilegeLineFound = $true",
      "      if ($line -notmatch [regex]::Escape($sid)) {",
      "        $line = $line.Trim() + \",*$sid\"",
      "      }",
      "    }",
      "    $newContent += $line",
      "  }",
      "  ",
      "  if (-not $privilegeLineFound) {",
      "    $newContent += \"SeManageVolumePrivilege = *$sid\"",
      "  }",
      "  ",
      "  $newContent | Set-Content $cfg",
      "  secedit /configure /db \"$env:windir\\security\\local.sdb\" /cfg $cfg /areas USER_RIGHTS",
      "  Remove-Item $cfg -Force",
      "  Write-Host 'IFI configured successfully'",
      "} catch { ",
      "  Write-Error \"IFI error: $_\"",
      "  if ($cfg) { Write-Host 'Config file content:' ; Get-Content $cfg }",
      "  exit 1 ",
      "}"
    ]
  }

  provisioner "powershell" {
    inline = [
      "Write-Host 'Running Sysprep...'",
      "$sysprep = \"$env:SystemRoot\\System32\\Sysprep\\Sysprep.exe\"",
      "$arguments = '/generalize', '/oobe', '/shutdown', '/quiet', '/mode:vm'",
      "$process = Start-Process -FilePath $sysprep -ArgumentList $arguments -PassThru -NoNewWindow",
      "$process.WaitForExit(30000) | Out-Null",
      "if (-not $process.HasExited) {",
      "  Write-Error 'Sysprep failed to complete within 30 seconds'",
      "  exit 1",
      "}",
      "if ($process.ExitCode -ne 0) {",
      "  Write-Error \"Sysprep failed with exit code $($process.ExitCode)\"",
      "  exit 1",
      "}",
      "Write-Host 'Sysprep completed successfully - system will shut down'",
      "Start-Sleep -Seconds 10  # Ensure shutdown command completes"
    ]
  }
}
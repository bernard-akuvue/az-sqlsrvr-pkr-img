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
  image_version             = "16.0.250519"
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
      # Enable SQL services
      "Set-Service -Name MSSQLSERVER -StartupType Automatic",
      "Set-Service -Name SQLSERVERAGENT -StartupType Automatic",
      "Write-Host 'SQL services set to start automatically'",

      # Start SQL Server and wait for initialization
      "try {",
      "    Start-Service MSSQLSERVER -ErrorAction Stop",
      "    Write-Host 'SQL Server started. Waiting for full initialization...'",
      "    $timeout = 300; $interval = 10",
      "    $svc = Get-Service MSSQLSERVER",
      "    while ($svc.Status -ne 'Running' -and $timeout -gt 0) {",
      "        Start-Sleep -Seconds $interval",
      "        $timeout -= $interval",
      "        $svc.Refresh()",
      "    }",
      "    if ($svc.Status -ne 'Running') {",
      "        throw 'SQL Server did not start within timeout'",
      "    }",
      "    Write-Host 'SQL Server fully initialized'",
      "} catch {",
      "    Write-Error 'Failed to start SQL Server: $_'",
      "    exit 1",
      "}"
    ]
  }

  provisioner "powershell" {
    inline = [
      # Configure Instant File Initialization using security policy
      "try {",
      "    Write-Host 'Configuring Instant File Initialization via security policy'",
      "    ",
      "    # Get SQL Server service account SID",
      "    $service = Get-WmiObject Win32_Service -Filter \"Name='MSSQLSERVER'\"",
      "    if (-not $service) { throw 'SQL Server service not found' }",
      "    ",
      "    $account = New-Object System.Security.Principal.NTAccount($service.StartName)",
      "    $sid = $account.Translate([System.Security.Principal.SecurityIdentifier]).Value",
      "    Write-Host \"Resolved service account SID: $sid\"",
      "    ",
      "    $tempCfg = \"$env:TEMP\\secpol.cfg\"",
      "    secedit /export /cfg $tempCfg",
      "    ",
      "    # Safely modify privilege assignment",
      "    $content = Get-Content $tempCfg",
      "    $privilegeLine = $content | Where-Object { $_ -match '^SeManageVolumePrivilege\\s*=' }",
      "    if ($privilegeLine) {",
      "        # Append service account SID if not already present",
      "        if ($privilegeLine -notmatch [regex]::Escape($sid)) {",
      "            $newLine = $privilegeLine.Trim() + \",*$sid\"",
      "            $content = $content -replace [regex]::Escape($privilegeLine), $newLine",
      "        }",
      "    } else {",
      "        # Create new entry if privilege doesn't exist",
      "        $content += \"SeManageVolumePrivilege = *$sid\"",
      "    }",
      "    $content | Set-Content $tempCfg",
      "    ",
      "    # Apply configuration",
      "    secedit /configure /db \"$env:windir\\security\\local.sdb\" /cfg $tempCfg /areas USER_RIGHTS",
      "    Remove-Item $tempCfg -Force",
      "    Write-Host 'Instant File Initialization configured successfully'",
      "} catch {",
      "    Write-Error \"ERROR configuring IFI: $_\"",
      "    exit 1",
      "}",

      "Write-Host 'Base SQL Server image prepared. SQL IaaS Extension will be installed post-deployment.'"
    ]
  }

  provisioner "windows-restart" {
    pause_before    = "1m"
    restart_timeout = "30m"
  }

  provisioner "powershell" {
    inline = [
      "Write-Host 'Running Sysprep…'",
      "& $env:SystemRoot\\System32\\Sysprep\\Sysprep.exe /generalize /oobe /shutdown /quiet /mode:vm",

      "# Give Sysprep a moment to finish writing its success marker",
      "Start-Sleep -Seconds 10",

      "# The presence of this file means Sysprep truly succeeded",
      "$tag = \"$env:SystemRoot\\System32\\Sysprep\\Sysprep_succeeded.tag\"",
      "if (Test-Path $tag) {",
      "  Write-Host 'Sysprep succeeded (tag found)'",
      "} else {",
      "  Write-Error 'Sysprep did NOT succeed — marker file missing.'",
      "  Write-Host 'Last 50 lines of setupact.log for diagnostics:'",
      "  Get-Content \"$env:SystemRoot\\System32\\Sysprep\\Panther\\setupact.log\" | Select-Object -Last 50",
      "  exit 1",
      "}"
    ]
  }
}
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
  os_type             = "Windows"

  build_resource_group_name         = "sql-pkr-img"
  managed_image_name                = "pkr-sql2022-ws2022-${formatdate("YYMMDD-hhmm", timestamp())}"
  managed_image_resource_group_name = "sql-pkr-img"
  vm_size                           = "Standard_B4ms"  # Burstable VM to avoid quota issues

  communicator   = "winrm"
  winrm_use_ssl  = true
  winrm_insecure = true
  winrm_timeout  = "20m"  # Increased timeout for SQL config

  winrm_username = "localadmin"
  winrm_password = "Du,BOO7+awA;DZMov5dG"  # Still hardcoded - consider variables

  os_disk_size_gb    = 128
  disk_additional_size = [64]  # Additional disk for SQL

  azure_tags = {
    component = "sql-server"
    build     = formatdate("YYYY-MM-DD", timestamp())
  }
}

build {
  sources = ["source.azure-arm.sql_image"]

  provisioner "powershell" {
    inline = [
      "Restart-Service -Name WinRM"
    ]
  }  

  provisioner "powershell" {
    script = "./cfg-sql.ps1"
  }

  provisioner "windows-restart" {
    restart_timeout = "5m"  # Allow time for SQL services to restart
  }

  provisioner "powershell" {
    inline = [
      "Write-Host 'Finalizing image preparation'",
      "& $env:SystemRoot\\System32\\Sysprep\\Sysprep.exe /oobe /generalize /quiet /quit /mode:vm",
      "Start-Sleep -Seconds 300"
    ]
  }
}
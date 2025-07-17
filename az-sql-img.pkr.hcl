# az-sql-img.pkr.hcl

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
  disk_additional_size = [32, 32]

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
    script = "./az-cfg-sql.ps1"
  }  

  provisioner "powershell" {
    script = "./configure-disks.ps1"
  }

  provisioner "powershell" {
    inline = [
      "Write-Host 'Finalizing image preparation'",
      "& $env:SystemRoot\\System32\\Sysprep\\Sysprep.exe /oobe /generalize /quiet /quit /mode:vm",
      "Start-Sleep -Seconds 300"
    ]
  }
}
 
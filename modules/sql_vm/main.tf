# Configure Azure provider
terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.37.0"
    }
    azuread = {
      source  = "hashicorp/azuread"
      version = "~> 2.0"
    }
  }
}

provider "azurerm" {
  features {}
  subscription_id = "52f9cc50-7e1e-4e82-b8c3-da2757e84a48"
}

# Variables
variable "win_vm_name" {
  type = string
  default = ""
}

variable "location" {
  type    = string
  default = ""
}

variable "admin_username" {
  type    = string
  default = ""
}

variable "admin_password" {
  type      = string
  default   = ""
  sensitive = true
}

variable "sql_edition" {
  default = ""
}

variable "existing_vnet_name" {
  default = "vnet-nonprod-external-devtest"
}

variable "existing_subnet_name" {
  default = "snet-beta-web"
}

variable "existing_vnet_rg" {
  default = "" # Resource group for VNet
}

variable "sql_rg" {
  default = "" # Resource group for SQL resources
}

# Generate random password if not provided
resource "random_password" "sql_password" {
  count            = var.admin_password == "" ? 1 : 0
  length           = 20
  special          = true
  override_special = "!@#$%^&*()-_=+[]{}<>:?"
}

locals {
  admin_password = var.admin_password != "" ? var.admin_password : one(random_password.sql_password[*].result)
}

# Get existing VNet and subnet
data "azurerm_virtual_network" "main" {
  name                = var.existing_vnet_name
  resource_group_name = var.existing_vnet_rg
}

data "azurerm_subnet" "main" {
  name                 = var.existing_subnet_name
  virtual_network_name = data.azurerm_virtual_network.main.name
  resource_group_name  = var.existing_vnet_rg
}

# Create network interface without public IP
resource "azurerm_network_interface" "win" {
  name                = "nic-dev-win"
  location            = var.location
  resource_group_name = var.sql_rg

  ip_configuration {
    name                          = "internal"
    subnet_id                     = data.azurerm_subnet.main.id
    private_ip_address_allocation = "Dynamic"
  }
}

# Create WIN Server VM
resource "azurerm_windows_virtual_machine" "win" {
  name                = var.win_vm_name
  resource_group_name = var.sql_rg
  location            = var.location
  size                = "Standard_D4as_v5"
  admin_username      = var.admin_username
  admin_password      = var.admin_password
  network_interface_ids = [
    azurerm_network_interface.win.id,
  ]

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Premium_LRS"
    disk_size_gb = 127
  }

  source_image_reference {
    publisher = "MicrosoftSQLServer"
    offer     = "SQL2022-WS2022"
    sku       = var.sql_edition
    version   = "latest"
  }
}

# Configure data disk for SQL
resource "azurerm_managed_disk" "data" {
  name                 = "${var.win_vm_name}-data-disk"
  location             = var.location
  resource_group_name  = var.sql_rg
  storage_account_type = "StandardSSD_LRS"
  create_option        = "Empty"
  disk_size_gb         = 32
}

resource "azurerm_virtual_machine_data_disk_attachment" "data" {
  managed_disk_id    = azurerm_managed_disk.data.id
  virtual_machine_id = azurerm_windows_virtual_machine.win.id
  lun                = 0
  caching            = "ReadOnly"
}

# ---------------------------
# SQL IaaS Agent Extension
# ---------------------------
resource "azurerm_mssql_virtual_machine" "sql_extension" {
  virtual_machine_id = azurerm_windows_virtual_machine.win.id
  sql_license_type   = "PAYG"
  sql_connectivity_port = 1433
  sql_connectivity_type = "PRIVATE"
  sql_connectivity_update_username = "Thanos"
  sql_connectivity_update_password = "${var.admin_password}"
  depends_on = [ 
    azurerm_windows_virtual_machine.win
   ]
}

# Output important information
output "win_vm_name" {
  value = azurerm_windows_virtual_machine.win.name
}

output "win_private_ip" {
  value = azurerm_network_interface.win.private_ip_address
}

output "sql_admin_username" {
  value = var.admin_username
}

output "sql_admin_password" {
  value     = local.admin_password
  sensitive = true
}

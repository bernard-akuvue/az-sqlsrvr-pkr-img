# az-sql-vm.tf

terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.0"
    }
    azuread = {
      source  = "hashicorp/azuread"
      version = "~> 2.0"
    }
  }
}

provider "azurerm" {
  features {}
}

# Get current user details (for KV policy)
data "azurerm_client_config" "current" {}

# Existing resource group for SQL
data "azurerm_resource_group" "sql_rg" {
  name     = "sql-pkr-img"
  # location = "westus2"
}

# Use your existing VNet, Subnet, and NSG
data "azurerm_virtual_network" "vnet" {
  name                = "vnet-nonprod-external-devtest"
  resource_group_name = "nonprod-network"
}

data "azurerm_subnet" "sql_subnet" {
  name                 = "snet-beta-web"
  virtual_network_name = data.azurerm_virtual_network.vnet.name
  resource_group_name  = data.azurerm_virtual_network.vnet.resource_group_name
}

data "azurerm_network_security_group" "sql_nsg" {
  name                = "nsg-nonprod-beta-web"
  resource_group_name = data.azurerm_virtual_network.vnet.resource_group_name
}

# Find your custom SQL Server image
data "azurerm_image" "sql_image" {
  name                = "pkr-dev-2507171607"
  resource_group_name = data.azurerm_resource_group.sql_rg.name
}

# Create Key Vault for SA password (if not already existing)
resource "azurerm_key_vault" "sql_kv" {
  name                        = "kv-pkr-sql"
  location                    = data.azurerm_resource_group.sql_rg.location
  resource_group_name         = data.azurerm_resource_group.sql_rg.name
  enabled_for_disk_encryption = true
  tenant_id                   = data.azurerm_client_config.current.tenant_id
  sku_name                    = "standard"

  access_policy {
    tenant_id = data.azurerm_client_config.current.tenant_id
    object_id = data.azurerm_client_config.current.object_id

    secret_permissions = [
      "Get", "Set", "List", "Delete", "Purge"
    ]
  }
  depends_on = [
    data.azurerm_resource_group.sql_rg,
    data.azurerm_client_config.current
  ]
}

# Store a unique SA password in Key Vault
resource "azurerm_key_vault_secret" "sa_password" {
  name         = "sa-password"
  value        = var.sa_password
  key_vault_id = azurerm_key_vault.sql_kv.id
  depends_on = [
    data.azurerm_resource_group.sql_rg,
    azurerm_key_vault.sql_kv
  ]
}

# Create a NIC in the correct subnet and NSG
resource "azurerm_network_interface" "sql_nic" {
  name                = "sql-nic"
  location            = data.azurerm_resource_group.sql_rg.location
  resource_group_name = data.azurerm_resource_group.sql_rg.name

  ip_configuration {
    name                          = "internal"
    subnet_id                     = data.azurerm_subnet.sql_subnet.id
    private_ip_address_allocation = "Dynamic"
    # No public_ip_address_id
  }

  depends_on = [
    data.azurerm_virtual_network.vnet,
    data.azurerm_subnet.sql_subnet,
    data.azurerm_network_security_group.sql_nsg
  ]
}

resource "azurerm_network_interface_security_group_association" "sql_nic_nsg" {
  network_interface_id      = azurerm_network_interface.sql_nic.id
  network_security_group_id = data.azurerm_network_security_group.sql_nsg.id

  depends_on = [
    data.azurerm_virtual_network.vnet,
    data.azurerm_subnet.sql_subnet,
    data.azurerm_network_security_group.sql_nsg,
    azurerm_network_interface.sql_nic
  ]
}

# Build the SQL Server VM from your custom image
data "azurerm_key_vault_secret" "vm_admin_password" {
  name         = "sa-password"
  key_vault_id = azurerm_key_vault.sql_kv.id
}

locals {
  effective_admin_password = (
    var.vm_admin_password != null && var.vm_admin_password != "" ?
    var.vm_admin_password :
    data.azurerm_key_vault_secret.vm_admin_password.value
  )
}

resource "azurerm_windows_virtual_machine" "sql_vm" {
  name                = "sql-vm"
  resource_group_name = data.azurerm_resource_group.sql_rg.name
  location            = data.azurerm_resource_group.sql_rg.location
  size                = "Standard_D4as_v5"
  admin_username      = "localadmin"
  admin_password      = local.effective_admin_password
  network_interface_ids = [azurerm_network_interface.sql_nic.id]

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Premium_LRS"
  }

  source_image_id = data.azurerm_image.sql_image.id
  depends_on = [
    data.azurerm_resource_group.sql_rg,
    azurerm_key_vault.sql_kv,
    data.azurerm_image.sql_image,
    data.azurerm_virtual_network.vnet,
    data.azurerm_subnet.sql_subnet,
    data.azurerm_network_security_group.sql_nsg,
    azurerm_network_interface.sql_nic
  ]
}

# Managed data disks
# resource "azurerm_managed_disk" "sql_data" {
#   count                = length(var.data_disk_sizes)
#   name                 = "sqldata${count.index + 1}-${azurerm_windows_virtual_machine.sql_vm.name}"
#   location             = data.azurerm_resource_group.sql_rg.location
#   resource_group_name  = data.azurerm_resource_group.sql_rg.name
#   storage_account_type = "Premium_LRS"
#   create_option        = "Empty"
#   disk_size_gb         = var.data_disk_sizes[count.index]
#   depends_on = [
#     data.azurerm_resource_group.sql_rg,
#     azurerm_key_vault.sql_kv,
#     data.azurerm_image.sql_image,
#     data.azurerm_virtual_network.vnet,
#     data.azurerm_subnet.sql_subnet,
#     data.azurerm_network_security_group.sql_nsg,
#     azurerm_network_interface.sql_nic
#   ]
# }

# # Attach the disks to the VM
# resource "azurerm_virtual_machine_data_disk_attachment" "sql_data_attach" {
#   count               = length(var.data_disk_sizes)
#   managed_disk_id     = azurerm_managed_disk.sql_data[count.index].id
#   virtual_machine_id  = azurerm_windows_virtual_machine.sql_vm.id
#   lun                 = count.index
#   caching             = "ReadOnly"   # For SQL DBs typically "ReadOnly", for tempdb "ReadWrite"
#   depends_on = [
#     data.azurerm_resource_group.sql_rg,
#     azurerm_key_vault.sql_kv,
#     data.azurerm_image.sql_image,
#     data.azurerm_virtual_network.vnet,
#     data.azurerm_subnet.sql_subnet,
#     data.azurerm_network_security_group.sql_nsg,
#     azurerm_network_interface.sql_nic
#   ]
# }

# SQL Server IaaS Agent and SA setup at deployment
resource "azurerm_mssql_virtual_machine" "sql" {
  virtual_machine_id = azurerm_windows_virtual_machine.sql_vm.id

  sql_connectivity_update_username = "Thanos"
  sql_connectivity_update_password = local.effective_admin_password
  sql_connectivity_port            = 1433
  sql_connectivity_type            = "PRIVATE"
  sql_license_type                 = "PAYG"

  storage_configuration {
    disk_type             = "NEW"      # Required
    storage_workload_type = "GENERAL"     # Required

    data_settings {
      default_file_path = "F:\\Databases\\UserDBs"
      luns              = [0]
    }

    log_settings {
      default_file_path = "F:\\Databases\\UserDBs"
      luns              = [0]
    }

    temp_db_settings {
      default_file_path = "H:\\tempDb"
      luns              = [1]
      # Only default_file_path and luns are supported
    }
  }
  # Additional options for backups, patching, etc. can go here
  # auto_patching {
  #   day_of_week                            = "Sunday"
  #   maintenance_window_duration_in_minutes = 60
  #   maintenance_window_starting_hour       = 2
  # }
  depends_on = [
    data.azurerm_resource_group.sql_rg,
    azurerm_key_vault.sql_kv,
    data.azurerm_image.sql_image,
    data.azurerm_virtual_network.vnet,
    data.azurerm_subnet.sql_subnet,
    data.azurerm_network_security_group.sql_nsg,
    azurerm_network_interface.sql_nic
  ]
}

# Optionally: Custom Script Extension for advanced post-deploy configuration
# resource "azurerm_virtual_machine_extension" "custom_script" {
#   name                 = "custom-sql-setup"
#   virtual_machine_id   = azurerm_windows_virtual_machine.sql_vm.id
#   publisher            = "Microsoft.Compute"
#   type                 = "CustomScriptExtension"
#   type_handler_version = "1.10"
#   settings = jsonencode({
#     "commandToExecute" = "powershell -ExecutionPolicy Unrestricted -File C:\\scripts\\my-custom-config.ps1"
#   })
#   depends_on = [azurerm_mssql_virtual_machine.sql]
# }

# Variables
variable "sa_password" {
  description = "The SQL SA password (set in pipeline or tfvars)"
  type        = string
  sensitive   = true
}

variable "vm_admin_password" {
  description = "The Windows admin password (set in pipeline or tfvars)"
  type        = string
  sensitive   = true
}

variable "data_disk_sizes" {
  description = "List of data disk sizes (in GB) to attach to the VM"
  type        = list(number)
  default     = [32, 32]
}
 
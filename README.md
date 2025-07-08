
# Azure SQL Server 2022 Packer Image

This project automates the creation of a reusable Azure image with Windows Server 2022 and SQL Server 2022 Developer Edition. It uses [Packer](https://developer.hashicorp.com/packer) with the Azure ARM builder and PowerShell provisioning to fully configure and optimize SQL Server for immediate use in dev/test environments.

## 🚀 Features

  * ✅ Builds a managed Azure image using Packer and Azure CLI authentication
  * 📦 Installs SQL Server Developer Edition on Windows Server 2022
  * 🔧 Configures essential SQL settings (e.g., memory, login mode, ad hoc workloads)
  * 🛡️ Installs SQL IaaS Agent Extension (with fallback method)
  * 🧪 Verifies and starts MSSQLSERVER and SQLSERVERAGENT services
  * 📈 Optimizes TempDB and enables Instant File Initialization
  * 🔄 Finalizes with Sysprep to allow clean VM creation from image

## 📁 Project Structure

```
.
├── packer.pkr.hcl          # Packer build configuration
├── cfg-sql.ps1             # PowerShell provisioning script
└── README.md               # Documentation
```

## ⚙️ Requirements

  * **Azure CLI** (`az login` configured)
  * **Packer 1.11+** ([installation guide](https://developer.hashicorp.com/packer/install))
  * **Contributor access** to a resource group in your Azure subscription

## 🛠️ Build Instructions

1.  **Authenticate with Azure**

    ```
    az login
    ```

2.  **Initialize Packer plugins**

    ```
    packer init .
    ```

3.  **Run the build**

    ```
    packer build .
    ```

## 🔐 Security Notes

  * **Hardcoded Passwords:** Passwords are hardcoded in this example for simplicity. **Replace them with [Packer variables](https://developer.hashicorp.com/packer/language/variables) or Azure Key Vault integration for production use.**
  * **RBAC Permissions:** Validate RBAC permissions on your Azure resource group.
  * **Sysprep:** Always sysprep the image to avoid SID duplication and startup conflicts.

## 📌 Key Configuration Details

  * **Base Image:** `MicrosoftSQLServer:SQL2022-WS2022:sqldev-gen2:16.0.250519`
  * **VM Size:** `Standard_B4ms`
  * **WinRM:** Configured with SSL (insecure, demo only)
  * **SQL Tweaks Include:**
      * SA login enabled and reset
      * Mixed mode authentication
      * Max memory set to 8GB
      * Ad hoc workloads and advanced options if supported
      * Instant File Initialization via `secedit`
      * TempDB resized to 8GB minimum

## 👤 Maintainer

**Bernard Benibo Akuvue**
Senior DevOps Engin
📧 [Bernard Akuvue](mailto:bernard.akuvue@ewn.com)

## 📄 License

This project is licensed under the MIT License.
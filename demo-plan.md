# Legacy Database Discovery Demo — Plan

## Objective

Demonstrate GitHub Copilot CLI's ability to discover, investigate, and document legacy SQL Server databases on remote Windows servers — showcasing a complete "zero to one" migration preparation workflow, from credential discovery through full schema documentation.

## Architecture

```
┌─────────────────────┐                         ┌──────────────────────────────┐
│  Demo Machine       │                         │  Azure VM (Windows Server    │
│  (VS Code + Copilot)│    SSH (port 22)        │  2022 + SQL Server 2022)     │
│                     │───────────────────────▶ │                              │
│  sqlcmd             │    SQL (port 1433)      │  "Legacy" Database:          │
│  az cli             │───────────────────────▶ │   - AdventureWorks           │
│                     │                         │   - Planted credentials in:  │
│                     │                         │     · web.config             │
│                     │    Key Vault            │     · C:\Scripts\backup.bat  │
│                     │◀──────────────────────▶│     · ODBC DSN registry      │
└─────────────────────┘                         └──────────────────────────────┘
         │
         ▼
   Azure Key Vault
   (stores/retrieves credentials)
```

## Azure Resources

| Resource | Purpose |
|----------|---------|
| Resource Group | `rg-legacy-db-demo` |
| Windows VM | Windows Server 2022 + SQL Server 2022 (marketplace image) |
| VNet + Subnet | Network isolation |
| Public IP | Direct access for demo |
| NSG | Allow SSH (22) and SQL (1433) from demo machine IP |
| Azure Key Vault | Secure credential storage |

## Legacy Database Setup

Using the **AdventureWorks** sample database — a well-known Microsoft sample that simulates a manufacturing company with:
- Multiple schemas (Person, Production, Sales, HumanResources, Purchasing)
- Stored procedures, views, functions
- Complex relationships and foreign keys
- Realistic data volume

This is sufficient to demonstrate discovery capabilities without over-engineering the database itself. The point is the workflow, not the complexity.

## Planted Credentials (for Scenario 2)

| Location | Content |
|----------|---------|
| `C:\inetpub\wwwroot\web.config` | `<connectionStrings>` with SQL Server credentials |
| `C:\Scripts\nightly-backup.bat` | `sqlcmd` command with embedded `-U sa -P <password>` |
| ODBC System DSN `LegacyERP` | Registry entry pointing to SQL Server with stored credentials |
| Scheduled Task `NightlyDBBackup` | Runs the backup script daily at 2AM as SYSTEM |

## Demo Scenarios

### Scenario 1: Known Credentials (Direct Discovery)

**Story:** "The DBA gave us the server address and credentials. Let's see what's in there."

1. Retrieve SQL credentials from Azure Key Vault
2. Connect directly with `sqlcmd`
3. Copilot runs discovery queries:
   - List all databases
   - Enumerate schemas, tables, columns, data types
   - Map foreign key relationships
   - Find stored procedures, views, triggers, functions
   - Profile data (row counts, NULL percentages, distinct values)
   - Identify potential issues (varchar dates, orphaned objects, missing indexes)
4. Copilot generates comprehensive markdown documentation

### Scenario 2: Credential Discovery + Key Vault Storage

**Story:** "We have SSH access to the server but nobody knows the database password. Let's find it."

1. SSH into the Windows VM (key-based auth)
2. Copilot investigates the server:
   - Searches for config files: `findstr /s /i "connectionstring" C:\*.config C:\*.json`
   - Checks ODBC DSNs: `reg query "HKLM\SOFTWARE\ODBC\ODBC.INI" /s`
   - Looks for scripts with embedded credentials: `findstr /s /i "sqlcmd\|password\|pwd" C:\Scripts\*.*`
   - Checks IIS configurations
3. Copilot finds credentials in `web.config` and `backup.bat`
4. Copilot secures them in Azure Key Vault:
   ```
   az keyvault secret set --vault-name kv-legacy-demo --name sql-sa-password --value "<discovered-password>"
   ```
5. Proceeds with database discovery (same as Scenario 1)
6. Documents the credential locations found (for security audit)

## Deployment Steps

1. `az group create` — Create resource group
2. `az deployment group create` — Deploy Bicep template (VM, VNet, NSG, Key Vault)
3. VM Custom Script Extension automatically:
   - Enables OpenSSH Server
   - Downloads and restores AdventureWorks database
   - Plants discoverable credentials
   - Configures ODBC DSN
4. Upload SSH public key / configure admin credentials
5. Store SQL credentials in Key Vault

## Files

| File | Purpose |
|------|---------|
| `demo-plan.md` | This plan |
| `demo-script.md` | Step-by-step demo script with talking points |
| `main.bicep` | Azure infrastructure as code |
| `deploy.ps1` | One-command deployment script |
| `setup-vm.ps1` | Post-deployment VM configuration script |

## Estimated Cost

- Windows VM with SQL Server (Standard_D4s_v3): ~$15-20/day
- Key Vault: negligible
- Public IP: ~$0.15/day
- Total for a few days: **~$50-75**

## Teardown

```powershell
az group delete --name rg-legacy-db-demo --yes --no-wait
```

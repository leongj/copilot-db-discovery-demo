# Legacy Database Discovery Demo

Demonstrates how **GitHub Copilot** (CLI / Agent Mode in VS Code) can discover, investigate, and document legacy SQL Server databases on remote Windows servers — showcasing a complete "zero to one" migration preparation workflow.

## The Problem

Organizations migrating to a modern data warehouse often find that their legacy database servers are poorly documented. The original DBAs have left. Connection strings are buried in config files. Nobody knows the full schema. Before you can plan a migration, you need to answer: **what do we actually have?**

## The Demo

Copilot connects to a remote Windows Server running SQL Server 2022, discovers credentials scattered across the server, enumerates the full database schema, and produces migration-ready documentation — all from the terminal.

```
┌─────────────────────┐                         ┌──────────────────────────────┐
│  Demo Machine       │                         │  Azure VM (Windows Server    │
│  (VS Code + Copilot)│    SSH (port 22)        │  2022 + SQL Server 2022)     │
│                     │───────────────────────▶ │                              │
│  sqlcmd             │    SQL (port 1433)      │  "Legacy" Database:          │
│  az cli             │───────────────────────▶ │   - AdventureWorks2022       │
│                     │                         │   - Planted credentials in:  │
│                     │                         │     · web.config             │
│                     │    Key Vault            │     · nightly-backup.bat     │
│                     │◀──────────────────────▶│     · ODBC DSN registry      │
└─────────────────────┘                         └──────────────────────────────┘
         │
         ▼
   Azure Key Vault
   (stores/retrieves credentials)
```

### Scenario 1: Known Credentials → Direct Discovery

_"The DBA gave us the server address and credentials. Let's see what's in there."_

1. Copilot retrieves SQL credentials from Azure Key Vault
2. Connects directly with `sqlcmd`
3. Discovers schemas, tables, columns, relationships, stored procedures, views, triggers
4. Profiles data (row counts, NULL analysis, data type issues)
5. Generates comprehensive markdown documentation

### Scenario 2: Credential Discovery → Security Audit → Schema Discovery

_"We have SSH access but nobody knows the database password. Let's find it."_

1. Copilot SSHs into the Windows VM
2. Searches for credential sprawl: config files, scripts, ODBC DSNs, scheduled tasks
3. Finds plaintext passwords in `web.config`, `nightly-backup.bat`, and registry
4. Secures discovered credentials in Azure Key Vault
5. Proceeds with full database discovery (same as Scenario 1)
6. Documents credential locations as a security finding

## Prerequisites

- [VS Code](https://code.visualstudio.com/) with [GitHub Copilot](https://github.com/features/copilot) extension
- [Azure CLI](https://learn.microsoft.com/en-us/cli/azure/install-azure-cli) (`az`) — logged in with `az login`
- [SQL Server command-line tools](https://learn.microsoft.com/en-us/sql/tools/sqlcmd/sqlcmd-utility) (`sqlcmd`)
- SSH client (built into Windows 10+, macOS, Linux)

## Quick Start

### Deploy

```powershell
# Deploy to default region (eastus2)
.\deploy.ps1

# Deploy to a specific region and resource group
.\deploy.ps1 -ResourceGroup "my-demo-rg" -Location "australiaeast"
```

The deploy script will:
1. Create a resource group with `SecurityControl=Ignore` tag
2. Deploy a Windows Server 2022 VM with SQL Server 2022 (via Bicep)
3. Tag all resources to bypass Azure security policies
4. Configure the VM: enable SA auth, TCP/IP, SSH, restore AdventureWorks2022, plant credentials
5. Test connectivity (TCP 1433 + sqlcmd)
6. Store all credentials in Azure Key Vault

On completion, the script prints connection details and saves them to `demo-config.json`.

### Test

```powershell
# SQL connection (use the IP and Key Vault name from deploy output)
sqlcmd -S tcp:<VM_IP>,1433 -U sa -P <password> -Q "SELECT name FROM sys.databases"

# SSH connection
ssh azureuser@<VM_IP>
```

### Teardown

```powershell
az group delete --name rg-legacy-db-demo --yes --no-wait
```

## What's Deployed

| Resource | Details |
|----------|---------|
| Resource Group | `rg-legacy-db-demo` (configurable) |
| Windows VM | Windows Server 2022 + SQL Server 2022 Developer (`Standard_D4s_v3`) |
| Database | AdventureWorks2022 — 6 schemas, 71 tables, 120K+ rows |
| VNet + NSG | Locked down to your public IP (SSH, SQL, RDP) |
| Public IP | Static, Standard SKU |
| Azure Key Vault | Stores SA password, admin password, server address |

### Planted Credential Artifacts

These simulate a typical legacy environment where credentials are scattered across the server:

| Location | What Copilot Finds |
|----------|-------------------|
| `C:\inetpub\wwwroot\web.config` | Connection strings with SA password, comments about ex-employee "Dave Johnson" |
| `C:\Scripts\nightly-backup.bat` | Plaintext `sqlcmd` command with embedded SA credentials |
| ODBC DSN `LegacyERP` | Registry entry with server, database, username, and password |
| Scheduled Task `NightlyDBBackup` | Runs the backup script daily at 2AM as SYSTEM |

## Repository Structure

| File | Purpose |
|------|---------|
| `deploy.ps1` | One-command deployment script (accepts `-ResourceGroup` and `-Location`) |
| `setup-vm.ps1` | VM configuration script (runs on the VM via `az vm run-command`) |
| `main.bicep` | Azure infrastructure as code |
| `demo-script.md` | Step-by-step demo walkthrough with talking points |
| `demo-plan.md` | Architecture and planning details |
| `legacy-database-docs.md` | Sample output — what Copilot-generated documentation looks like |

## Estimated Cost

| Resource | Cost |
|----------|------|
| VM (Standard_D4s_v3 + SQL Dev) | ~$15–20/day |
| Public IP (Standard) | ~$0.15/day |
| Key Vault | Negligible |
| **Total for a few days** | **~$50–75** |

> 💡 **Tip:** Deallocate the VM when not in use: `az vm deallocate -g rg-legacy-db-demo -n vm-legacy-sql`

## Known Issues

- **Azure security policies** may strip NSG rules (especially SSH/port 22) after deployment. The deploy script re-applies missing rules automatically.
- **Corporate firewalls** may block outbound ports 1433 and 22. If so, you may need to present from a less restrictive network or use a VPN.
- **SQL VM Extension** does not reliably enable SA auth on the marketplace image. The setup script handles this via single-user mode recovery.

## License

[MIT](LICENSE)


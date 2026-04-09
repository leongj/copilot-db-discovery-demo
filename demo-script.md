# Legacy Database Discovery Demo — Script

## Pre-Demo Setup

### Prerequisites on your machine
- VS Code with GitHub Copilot extension (Agent mode enabled)
- Azure CLI (`az`) installed and logged in
- SQL Server command-line tools (`sqlcmd`) installed
- SSH client (built into Windows 10+)

### Deploy infrastructure
```powershell
# Deploy everything (see deploy.ps1)
.\deploy.ps1
```

### Verify access
```powershell
# Test SSH
ssh azureuser@<VM_PUBLIC_IP>

# Test SQL (scenario 1 only)
sqlcmd -S tcp:<VM_PUBLIC_IP>,1433 -U sa -P <password> -Q "SELECT @@VERSION"
```

---

## Demo Opening (30 seconds)

**Talking point:**
> "A common challenge in data warehouse migration is that nobody fully understands the legacy systems. The original DBAs have left. Documentation is outdated or missing. Before you can even plan a migration, you need to answer: what do we actually have?"
>
> "I'm going to show how GitHub Copilot can act as your discovery agent — connecting to a legacy SQL Server, investigating what's there, and producing migration-ready documentation. All from the terminal."

---

## Scenario 1: Known Credentials — Direct Discovery

### Step 1: Retrieve credentials from Key Vault

**Tell Copilot:**
> "I need to discover and document a legacy SQL Server database for migration planning. The server is at `<VM_PUBLIC_IP>` and the credentials are stored in Azure Key Vault `kv-legacy-demo`. Can you retrieve the credentials and connect to see what databases exist?"

**What Copilot does:**
```bash
# Retrieves the secret
az keyvault secret show --vault-name kv-legacy-demo --name sql-sa-password --query value -o tsv

# Connects and lists databases
sqlcmd -S tcp:<VM_PUBLIC_IP>,1433 -U sa -P <password> -Q "SELECT name, state_desc, create_date FROM sys.databases"
```

**Talking point:**
> "Copilot retrieved the credentials securely from Key Vault — no passwords in chat history or scripts — and immediately found the databases on this server."

### Step 2: Deep schema discovery

**Tell Copilot:**
> "Let's do a full discovery of the AdventureWorks database. I want to know every schema, table, column, data type, and relationship. Also find all stored procedures, views, triggers, and functions. Can you document everything in a comprehensive markdown report?"

**What Copilot does (series of sqlcmd queries):**
```sql
-- List all schemas
SELECT SCHEMA_NAME FROM INFORMATION_SCHEMA.SCHEMATA

-- List all tables with row counts
SELECT s.name AS SchemaName, t.name AS TableName,
       p.rows AS RowCount
FROM sys.tables t
JOIN sys.schemas s ON t.schema_id = s.schema_id
JOIN sys.partitions p ON t.object_id = p.object_id AND p.index_id IN (0,1)
ORDER BY s.name, t.name

-- Column details
SELECT TABLE_SCHEMA, TABLE_NAME, COLUMN_NAME, DATA_TYPE,
       CHARACTER_MAXIMUM_LENGTH, IS_NULLABLE, COLUMN_DEFAULT
FROM INFORMATION_SCHEMA.COLUMNS
ORDER BY TABLE_SCHEMA, TABLE_NAME, ORDINAL_POSITION

-- Foreign key relationships
SELECT fk.name AS FK_Name,
       tp.name AS ParentTable,
       cp.name AS ParentColumn,
       tr.name AS ReferencedTable,
       cr.name AS ReferencedColumn
FROM sys.foreign_keys fk
JOIN sys.foreign_key_columns fkc ON fk.object_id = fkc.constraint_object_id
JOIN sys.tables tp ON fkc.parent_object_id = tp.object_id
JOIN sys.columns cp ON fkc.parent_object_id = cp.object_id AND fkc.parent_column_id = cp.column_id
JOIN sys.tables tr ON fkc.referenced_object_id = tr.object_id
JOIN sys.columns cr ON fkc.referenced_object_id = cr.object_id AND fkc.referenced_column_id = cr.column_id

-- Stored procedures
SELECT SCHEMA_NAME(schema_id) AS SchemaName, name, create_date, modify_date
FROM sys.procedures

-- Views
SELECT SCHEMA_NAME(schema_id) AS SchemaName, name
FROM sys.views

-- Triggers
SELECT name, parent_id, type_desc, is_disabled
FROM sys.triggers

-- Indexes
SELECT t.name AS TableName, i.name AS IndexName, i.type_desc,
       STRING_AGG(c.name, ', ') AS Columns
FROM sys.indexes i
JOIN sys.tables t ON i.object_id = t.object_id
JOIN sys.index_columns ic ON i.object_id = ic.object_id AND i.index_id = ic.index_id
JOIN sys.columns c ON ic.object_id = c.object_id AND ic.column_id = c.column_id
WHERE i.name IS NOT NULL
GROUP BY t.name, i.name, i.type_desc
```

**Talking point:**
> "In under two minutes, Copilot has enumerated every table, column, relationship, stored procedure, view, trigger, and index in this database. A DBA doing this manually would spend half a day with SSMS. And Copilot is generating a clean markdown report as it goes."

### Step 3: Data profiling

**Tell Copilot:**
> "Can you profile the key tables? I want row counts, NULL percentages for each column, and identify any columns that look like they store dates as strings or have suspicious data patterns."

**What Copilot does:**
```sql
-- Row counts per table (already done above)

-- NULL analysis for a table
SELECT
    'ColumnName' AS [Column],
    COUNT(*) AS TotalRows,
    SUM(CASE WHEN [ColumnName] IS NULL THEN 1 ELSE 0 END) AS NullCount,
    CAST(SUM(CASE WHEN [ColumnName] IS NULL THEN 1 ELSE 0 END) * 100.0 / COUNT(*) AS DECIMAL(5,2)) AS NullPct
FROM SchemaName.TableName

-- Find varchar columns that might contain dates
SELECT TABLE_SCHEMA, TABLE_NAME, COLUMN_NAME, DATA_TYPE
FROM INFORMATION_SCHEMA.COLUMNS
WHERE DATA_TYPE IN ('varchar', 'nvarchar', 'char')
AND (COLUMN_NAME LIKE '%date%' OR COLUMN_NAME LIKE '%time%' OR COLUMN_NAME LIKE '%created%' OR COLUMN_NAME LIKE '%modified%')
```

**Talking point:**
> "This is the kind of analysis that catches migration issues early. Copilot found varchar columns that look like they store dates — that's a schema cleanup opportunity during migration."

### Step 4: Generate documentation

**Tell Copilot:**
> "Generate a complete database documentation markdown file that includes: an executive summary, schema overview, table inventory with row counts, relationship diagram (as text), stored procedure inventory, and migration recommendations."

**Copilot produces a comprehensive .md file** — this is the deliverable.

**Talking point:**
> "This document would typically take a consultant days to produce. Copilot generated it in minutes, and it's version-controllable — you can commit it to git and track changes as you refine the migration plan."

---

## Scenario 2: Credential Discovery → Key Vault

### Step 1: SSH into the server

**Tell Copilot:**
> "I need to investigate a legacy Windows server at `<VM_PUBLIC_IP>`. I have SSH access but I don't know the database credentials. Can you SSH in and search for any connection strings, passwords, or database credentials stored on this server?"

**What Copilot does:**
```powershell
# SSH into the server
ssh azureuser@<VM_PUBLIC_IP>

# Search for connection strings in config files
findstr /s /i "connectionstring" C:\inetpub\*.config C:\*.config

# Search for SQL credentials in scripts
findstr /s /i "password\|pwd\|sqlcmd" C:\Scripts\*.*

# Check ODBC DSN entries
reg query "HKLM\SOFTWARE\ODBC\ODBC.INI" /s

# Check for common credential locations
dir /s /b C:\*.config C:\*.json C:\*.xml | findstr /i "web.config appsettings"
```

**Talking point:**
> "Watch this — Copilot is doing what a security consultant would do on day one of an engagement. It's searching for credential sprawl across the server."

### Step 2: Copilot finds credentials

**Expected discoveries:**

1. **web.config** at `C:\inetpub\wwwroot\web.config`:
   ```xml
   <connectionStrings>
     <add name="LegacyInventoryDB"
          connectionString="Server=localhost;Database=AdventureWorks2022;User Id=sa;Password=Demo@Pass123!;" />
   </connectionStrings>
   ```

2. **backup.bat** at `C:\Scripts\nightly-backup.bat`:
   ```batch
   sqlcmd -S localhost -U sa -P Demo@Pass123! -Q "BACKUP DATABASE [AdventureWorks2022]..."
   ```

3. **ODBC DSN** in registry:
   ```
   HKLM\SOFTWARE\ODBC\ODBC.INI\LegacyERP
     Server = localhost
     Database = AdventureWorks2022
     Uid = sa
     Pwd = Demo@Pass123!
   ```

**Talking point:**
> "Copilot found credentials in three locations — a web.config, a backup script, and an ODBC DSN. This is incredibly common in legacy environments. And it's a security finding too — these passwords should not be stored in plaintext on the server."

### Step 3: Secure credentials in Key Vault

**Tell Copilot:**
> "Those credentials are stored insecurely. Can you add them to our Azure Key Vault so they're properly managed? Use key vault `kv-legacy-demo`."

**What Copilot does:**
```bash
az keyvault secret set --vault-name kv-legacy-demo --name sql-sa-password --value "Demo@Pass123!"
az keyvault secret set --vault-name kv-legacy-demo --name sql-sa-username --value "sa"
az keyvault secret set --vault-name kv-legacy-demo --name legacy-server-address --value "<VM_PUBLIC_IP>"
```

**Talking point:**
> "Copilot just took credentials scattered across config files and centralized them in Azure Key Vault. This is the first step of security remediation — and it happened as a natural part of the discovery workflow, not as a separate project."

### Step 4: Connect and discover

**Tell Copilot:**
> "Now use those Key Vault credentials to connect to the database and run a full discovery, just like we did before."

**(Same discovery flow as Scenario 1)**

**Talking point:**
> "And now we're in the same discovery flow — but this time we went from zero knowledge to full documentation, with security remediation along the way."

---

## Demo Closing (30 seconds)

**Talking points:**

> "What you just saw was Copilot handling the hardest, most uncertain phase of database migration — the discovery phase. The phase where you don't know what you have, where the credentials are, or what the schema looks like."
>
> "Copilot operates at the infrastructure level, from a terminal, with no pre-configuration needed. It doesn't require a data platform to be set up first — it works directly against your existing servers."
>
> "And everything Copilot produced — the documentation, the credential audit, the migration recommendations — is text that lives in your git repo. It's reviewable, version-controlled, and ready for the next phase of migration planning."

---

## Anticipated Questions

### "What about for servers that are really old?"

> "We connected over standard SQL protocol — port 1433. That's been the same since SQL Server 2000. It doesn't matter if the target server is running Windows Server 2008 or 2022 — the SQL discovery queries are identical. For OS-level investigation, we can SSH into a modern bastion host and access the legacy server from there."

### "How do you handle secrets in production?"

> "In the demo we used Azure Key Vault, but Copilot works with any secret management system — HashiCorp Vault, AWS Secrets Manager, CyberArk, or even environment variables. The point is that credentials never appear in chat history or scripts — they flow through secure channels."

### "What databases does this work with?"

> "Anything you can query from a terminal. SQL Server, PostgreSQL, MySQL, Oracle — if there's a CLI client for it, Copilot can use it. And with MCP servers, you can build structured connectors for any data source, including mainframes and proprietary systems."

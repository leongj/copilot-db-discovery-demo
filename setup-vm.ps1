$ErrorActionPreference = "Continue"
$SqlPassword = 'Demo@Pass123!'

Write-Output "=== Starting Legacy VM Setup ==="

# --- 1. Ensure sqlcmd is available ---
Write-Output "[1/8] Checking for sqlcmd..."
if (-not (Get-Command sqlcmd -ErrorAction SilentlyContinue)) {
    $found = Get-ChildItem "${env:ProgramFiles}\Microsoft SQL Server" -Recurse -Filter "sqlcmd.exe" -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($found) {
        $env:PATH += ";$($found.DirectoryName)"
        Write-Output "  Found sqlcmd at: $($found.FullName)"
    } else {
        Write-Output "  WARNING: sqlcmd not found in standard locations"
    }
}

# --- 2. Enable OpenSSH Server ---
Write-Output "[2/8] Installing OpenSSH Server..."
Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0 -ErrorAction SilentlyContinue
Set-Service -Name sshd -StartupType 'Automatic' -ErrorAction SilentlyContinue
Start-Service sshd -ErrorAction SilentlyContinue

# Set default SSH shell to PowerShell
New-ItemProperty -Path "HKLM:\SOFTWARE\OpenSSH" -Name DefaultShell `
    -Value "C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe" `
    -PropertyType String -Force -ErrorAction SilentlyContinue

# Firewall rules
New-NetFirewallRule -Name 'OpenSSH-Server' -DisplayName 'OpenSSH Server' `
    -Enabled True -Direction Inbound -Protocol TCP -Action Allow -LocalPort 22 `
    -ErrorAction SilentlyContinue
New-NetFirewallRule -Name 'SQL-Server-1433' -DisplayName 'SQL Server' `
    -Enabled True -Direction Inbound -Protocol TCP -Action Allow -LocalPort 1433 `
    -ErrorAction SilentlyContinue
Write-Output "  OpenSSH Server configured."

# --- 3. Enable SA account via single-user mode ---
Write-Output "[3/8] Enabling SA account via single-user mode recovery..."
Write-Output "  Stopping SQL Server services..."
net stop SQLSERVERAGENT /y 2>&1 | Out-Null
net stop MSSQLSERVER /y 2>&1 | Out-Null
Start-Sleep -Seconds 5

Write-Output "  Starting SQL Server in single-user mode (reserved for sqlcmd)..."
sc.exe start MSSQLSERVER /m"SQLCMD"
Start-Sleep -Seconds 10

Write-Output "  Configuring SA login and granting SYSTEM sysadmin..."
sqlcmd -S localhost -E -Q "ALTER LOGIN [sa] ENABLE; ALTER LOGIN [sa] WITH PASSWORD = N'$SqlPassword'; EXEC sp_addsrvrolemember 'NT AUTHORITY\SYSTEM', 'sysadmin'"

Write-Output "  Stopping SQL Server to switch to mixed mode..."
net stop MSSQLSERVER /y 2>&1 | Out-Null

# Set Mixed Mode auth via registry
Set-ItemProperty "HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\MSSQL16.MSSQLSERVER\MSSQLServer" -Name LoginMode -Value 2

Write-Output "  Starting SQL Server in normal mode..."
net start MSSQLSERVER
net start SQLSERVERAGENT
Write-Output "  SA account enabled with mixed mode authentication."

# --- 4. Enable TCP/IP protocol ---
Write-Output "[4/8] Enabling TCP/IP protocol for SQL Server..."
$tcpPath = "HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\MSSQL16.MSSQLSERVER\MSSQLServer\SuperSocketNetLib\Tcp"
Set-ItemProperty -Path $tcpPath -Name "Enabled" -Value 1
$ipAll = "$tcpPath\IPAll"
Set-ItemProperty -Path $ipAll -Name "TcpPort" -Value "1433"
Set-ItemProperty -Path $ipAll -Name "TcpDynamicPorts" -Value ""

Write-Output "  Restarting SQL Server to apply TCP/IP changes..."
net stop SQLSERVERAGENT /y 2>&1 | Out-Null
net stop MSSQLSERVER /y 2>&1 | Out-Null
Start-Sleep -Seconds 5
net start MSSQLSERVER
net start SQLSERVERAGENT
Write-Output "  TCP/IP enabled on port 1433."

# --- 5. Download AdventureWorks ---
Write-Output "[5/8] Downloading AdventureWorks2022..."
New-Item -ItemType Directory -Path "C:\Temp" -Force | Out-Null
$bakUrl = "https://github.com/Microsoft/sql-server-samples/releases/download/adventureworks/AdventureWorks2022.bak"
$bakPath = "C:\Temp\AdventureWorks2022.bak"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
Invoke-WebRequest -Uri $bakUrl -OutFile $bakPath -UseBasicParsing
if (Test-Path $bakPath) {
    $sizeMB = [math]::Round((Get-Item $bakPath).Length / 1MB, 1)
    Write-Output "  Downloaded: $sizeMB MB"
} else {
    Write-Output "  ERROR: Download failed!"
}

# --- 6. Restore database ---
Write-Output "[6/8] Restoring AdventureWorks2022 database..."
$sqlDataDir = (Get-ChildItem "${env:ProgramFiles}\Microsoft SQL Server\MSSQL*\MSSQL\DATA" -Directory -ErrorAction SilentlyContinue | Select-Object -First 1).FullName
if (-not $sqlDataDir) {
    $sqlDataDir = "C:\SQLData"
    New-Item -ItemType Directory -Path $sqlDataDir -Force | Out-Null
}
Write-Output "  Data directory: $sqlDataDir"

$restoreQuery = @"
RESTORE DATABASE [AdventureWorks2022]
FROM DISK = N'$bakPath'
WITH MOVE N'AdventureWorks2022' TO N'$sqlDataDir\AdventureWorks2022.mdf',
     MOVE N'AdventureWorks2022_log' TO N'$sqlDataDir\AdventureWorks2022_log.ldf',
     REPLACE
"@
sqlcmd -S localhost -U sa -P "$SqlPassword" -Q $restoreQuery
if ($LASTEXITCODE -eq 0) {
    Write-Output "  Database restored successfully."
} else {
    Write-Output "  WARNING: Restore exit code: $LASTEXITCODE (may still have succeeded)"
}

# --- 7. Plant discoverable credentials ---
Write-Output "[7/8] Planting discoverable credentials..."

# 7a. web.config
$webConfigDir = "C:\inetpub\wwwroot"
New-Item -ItemType Directory -Path $webConfigDir -Force | Out-Null
@"
<?xml version="1.0" encoding="utf-8"?>
<!--
  Legacy Inventory Management System v3.2.1
  Last deployment: 2019-06-15 by Dave Johnson
  Contact: dave.johnson@company.com (NOTE: Dave left Jan 2020)
-->
<configuration>
  <connectionStrings>
    <add name="LegacyInventoryDB"
         connectionString="Server=localhost;Database=AdventureWorks2022;User Id=sa;Password=$SqlPassword;"
         providerName="System.Data.SqlClient" />
    <add name="LegacyReportingDB"
         connectionString="Server=localhost;Database=AdventureWorks2022;User Id=sa;Password=$SqlPassword;Application Name=ReportingEngine"
         providerName="System.Data.SqlClient" />
  </connectionStrings>
  <appSettings>
    <add key="AppName" value="Legacy Inventory Management System" />
    <add key="Version" value="3.2.1" />
    <add key="LastUpdated" value="2019-06-15" />
    <add key="Maintainer" value="Dave Johnson (ext 4412) - LEFT COMPANY Jan 2020" />
  </appSettings>
</configuration>
"@ | Set-Content -Path "$webConfigDir\web.config" -Encoding UTF8
Write-Output "  Planted: C:\inetpub\wwwroot\web.config"

# 7b. Backup script
$scriptsDir = "C:\Scripts"
New-Item -ItemType Directory -Path $scriptsDir -Force | Out-Null
@"
@echo off
REM ============================================
REM Nightly database backup script
REM Created by: Dave Johnson (DBA) - 2018-03-22
REM Last modified: 2019-11-08 by Dave
REM NOTE: Dave left the company in Jan 2020
REM       Nobody has touched this since
REM ============================================

REM Backup AdventureWorks to local disk
sqlcmd -S localhost -U sa -P $SqlPassword -Q "BACKUP DATABASE [AdventureWorks2022] TO DISK = N'C:\Backups\AdventureWorks2022_%%date:~-4,4%%%%date:~-10,2%%%%date:~-7,2%%.bak' WITH FORMAT, COMPRESSION, INIT"

REM Clean up backups older than 30 days
forfiles /p "C:\Backups" /s /m *.bak /d -30 /c "cmd /c del @path" 2>nul

echo Backup completed at %%date%% %%time%%
"@ | Set-Content -Path "$scriptsDir\nightly-backup.bat" -Encoding ASCII
Write-Output "  Planted: C:\Scripts\nightly-backup.bat"

# 7c. ODBC DSN registry entry
New-Item -Path "HKLM:\SOFTWARE\ODBC\ODBC.INI\LegacyERP" -Force | Out-Null
Set-ItemProperty -Path "HKLM:\SOFTWARE\ODBC\ODBC.INI\LegacyERP" -Name "Driver" -Value "ODBC Driver 17 for SQL Server"
Set-ItemProperty -Path "HKLM:\SOFTWARE\ODBC\ODBC.INI\LegacyERP" -Name "Server" -Value "localhost"
Set-ItemProperty -Path "HKLM:\SOFTWARE\ODBC\ODBC.INI\LegacyERP" -Name "Database" -Value "AdventureWorks2022"
Set-ItemProperty -Path "HKLM:\SOFTWARE\ODBC\ODBC.INI\LegacyERP" -Name "Uid" -Value "sa"
Set-ItemProperty -Path "HKLM:\SOFTWARE\ODBC\ODBC.INI\LegacyERP" -Name "Pwd" -Value "$SqlPassword"
Set-ItemProperty -Path "HKLM:\SOFTWARE\ODBC\ODBC.INI\LegacyERP" -Name "LastUser" -Value "dave.johnson"
New-Item -Path "HKLM:\SOFTWARE\ODBC\ODBC.INI\ODBC Data Sources" -Force | Out-Null
Set-ItemProperty -Path "HKLM:\SOFTWARE\ODBC\ODBC.INI\ODBC Data Sources" -Name "LegacyERP" -Value "ODBC Driver 17 for SQL Server"
Write-Output "  Planted: ODBC DSN 'LegacyERP'"

# 7d. Create Backups directory
New-Item -ItemType Directory -Path "C:\Backups" -Force | Out-Null

# 7e. Scheduled task for nightly backup
$action = New-ScheduledTaskAction -Execute "C:\Scripts\nightly-backup.bat"
$trigger = New-ScheduledTaskTrigger -Daily -At "2:00AM"
Register-ScheduledTask -TaskName "NightlyDBBackup" -Action $action -Trigger $trigger `
    -Description "Nightly backup of AdventureWorks - Created by Dave Johnson 2018" `
    -User "SYSTEM" -Force -ErrorAction SilentlyContinue
Write-Output "  Planted: Scheduled Task 'NightlyDBBackup'"

# --- 8. Verify ---
Write-Output "[8/8] Verifying setup..."

# Check database via SA auth
$dbCheck = sqlcmd -S localhost -U sa -P "$SqlPassword" -Q "SELECT name FROM sys.databases WHERE name = 'AdventureWorks2022'" -h -1 -W 2>&1
if ($dbCheck -match "AdventureWorks2022") {
    Write-Output "  Database verification (SA auth): OK"
} else {
    Write-Output "  Database verification (SA auth): FAILED - $dbCheck"
}

# Check SSH service
$sshCheck = Get-Service sshd -ErrorAction SilentlyContinue
if ($sshCheck.Status -eq 'Running') {
    Write-Output "  SSH service: Running"
} else {
    Write-Output "  SSH service: $($sshCheck.Status)"
}

# Check TCP listening on 1433
$tcpCheck = Get-NetTCPConnection -LocalPort 1433 -ErrorAction SilentlyContinue
if ($tcpCheck) {
    Write-Output "  TCP 1433: Listening"
} else {
    Write-Output "  TCP 1433: NOT listening"
}

Write-Output ""
Write-Output "=== VM Setup Complete ==="
Write-Output "  - OpenSSH Server: Enabled (port 22)"
Write-Output "  - SQL Server: Mixed mode auth, TCP on port 1433"
Write-Output "  - SA account: Enabled"
Write-Output "  - AdventureWorks2022: Restored"
Write-Output "  - Credentials planted in:"
Write-Output "    * C:\inetpub\wwwroot\web.config"
Write-Output "    * C:\Scripts\nightly-backup.bat"
Write-Output "    * ODBC DSN: LegacyERP"
Write-Output "    * Scheduled Task: NightlyDBBackup"
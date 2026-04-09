<#
.SYNOPSIS
    Deploys the Legacy Database Discovery Demo infrastructure to Azure.

.DESCRIPTION
    Creates a Windows Server VM with SQL Server 2022, restores AdventureWorks,
    plants discoverable credentials, enables SSH, and configures Key Vault.

.PARAMETER ResourceGroup
    Name of the Azure resource group (default: rg-legacy-db-demo)

.PARAMETER Location
    Azure region for deployment (default: eastus2)

.EXAMPLE
    .\deploy.ps1
    .\deploy.ps1 -ResourceGroup "my-demo-rg" -Location "westus2"
#>
param(
    [Parameter(Mandatory=$false)]
    [string]$ResourceGroup = "rg-legacy-db-demo",

    [Parameter(Mandatory=$false)]
    [string]$Location = "eastus2"
)

$ErrorActionPreference = "Stop"

Write-Host ""
Write-Host "=========================================" -ForegroundColor Cyan
Write-Host "  Legacy DB Discovery Demo - Deployment  " -ForegroundColor Cyan
Write-Host "=========================================" -ForegroundColor Cyan
Write-Host ""

# --- Configuration ---
$vmName = "vm-legacy-sql"
$adminUsername = "azureuser"
$sqlPassword = 'Demo@Pass123!'

# Generate a random admin password (for VM RDP/SSH access)
$lower  = -join ((97..122)  | Get-Random -Count 4 | ForEach-Object { [char]$_ })
$upper  = -join ((65..90)   | Get-Random -Count 4 | ForEach-Object { [char]$_ })
$digits = -join ((48..57)   | Get-Random -Count 3 | ForEach-Object { [char]$_ })
$special = -join (('!','@','#','$','%') | Get-Random -Count 1)
$shuffled = ($lower + $upper + $digits + $special).ToCharArray() | Sort-Object { Get-Random }
$adminPassword = -join $shuffled

# Generate unique Key Vault name
$suffix = -join ((97..122) | Get-Random -Count 6 | ForEach-Object { [char]$_ })
$keyVaultName = "kv-legdemo-$suffix"

Write-Host "Configuration:" -ForegroundColor Gray
Write-Host "  VM Name:        $vmName" -ForegroundColor Gray
Write-Host "  Admin User:     $adminUsername" -ForegroundColor Gray
Write-Host "  Key Vault:      $keyVaultName" -ForegroundColor Gray
Write-Host "  Resource Group: $ResourceGroup" -ForegroundColor Gray
Write-Host "  Location:       $Location" -ForegroundColor Gray
Write-Host ""

# =============================================
# Step 1: Get Azure context
# =============================================
Write-Host "[1/8] Getting Azure context..." -ForegroundColor Yellow
$userObjectId = az ad signed-in-user show --query id -o tsv 2>$null
if (-not $userObjectId) {
    Write-Host "  ERROR: Not logged into Azure. Run 'az login' first." -ForegroundColor Red
    exit 1
}
$tenantId = az account show --query tenantId -o tsv
$subscriptionName = az account show --query name -o tsv
Write-Host "  Subscription: $subscriptionName" -ForegroundColor Gray
Write-Host "  Tenant:       $tenantId" -ForegroundColor Gray

# =============================================
# Step 2: Detect public IP
# =============================================
Write-Host "[2/8] Detecting your public IP..." -ForegroundColor Yellow
try {
    $myIp = (Invoke-RestMethod -Uri "https://api.ipify.org" -TimeoutSec 10)
} catch {
    $myIp = (Invoke-RestMethod -Uri "https://ifconfig.me/ip" -TimeoutSec 10)
}
Write-Host "  Your IP: $myIp" -ForegroundColor Gray

# =============================================
# Step 3: Register resource providers
# =============================================
Write-Host "[3/8] Registering resource providers..." -ForegroundColor Yellow
az provider register --namespace Microsoft.SqlVirtualMachine --wait 2>&1 | Out-Null
Write-Host "  Microsoft.SqlVirtualMachine: registered" -ForegroundColor Gray

# =============================================
# Step 4: Create resource group
# =============================================
Write-Host "[4/8] Creating resource group '$ResourceGroup'..." -ForegroundColor Yellow
az group create --name $ResourceGroup --location $Location --tags "SecurityControl=Ignore" --output none
Write-Host "  Resource group created." -ForegroundColor Gray

# =============================================
# Step 5: Deploy Bicep template
# =============================================
Write-Host "[5/8] Deploying infrastructure via Bicep..." -ForegroundColor Yellow
Write-Host "  This deploys: VM, VNet, NSG, Public IP, Key Vault, SQL VM Extension" -ForegroundColor Gray
Write-Host "  Estimated time: 10-15 minutes" -ForegroundColor Gray
Write-Host ""

$deploymentJson = az deployment group create `
    --resource-group $ResourceGroup `
    --template-file main.bicep `
    --parameters `
        vmName=$vmName `
        adminUsername=$adminUsername `
        adminPassword=$adminPassword `
        sqlPassword=$sqlPassword `
        keyVaultName=$keyVaultName `
        allowedSourceIp=$myIp `
        userObjectId=$userObjectId `
        tenantId=$tenantId `
    --output json

if ($LASTEXITCODE -ne 0) {
    Write-Host "  ERROR: Bicep deployment failed." -ForegroundColor Red
    exit 1
}

# Parse the public IP from deployment outputs (handle warnings in output)
try {
    $deployment = $deploymentJson | ConvertFrom-Json
    $publicIp = $deployment.properties.outputs.publicIpAddress.value
} catch {
    # Fallback: query the deployment outputs directly if JSON parsing fails
    Write-Host "  (Parsing deployment output failed, querying outputs directly...)" -ForegroundColor Gray
    $publicIp = az deployment group show -g $ResourceGroup -n main `
        --query "properties.outputs.publicIpAddress.value" -o tsv
}
Write-Host ""
Write-Host "  VM Public IP: $publicIp" -ForegroundColor Green

# Tag all resources with SecurityControl=Ignore
Write-Host "  Tagging all resources with SecurityControl=Ignore..." -ForegroundColor Gray
$resources = az resource list -g $ResourceGroup --query "[].id" -o json | ConvertFrom-Json
foreach ($id in $resources) {
    az tag update --resource-id $id --operation merge --tags "SecurityControl=Ignore" -o none 2>&1 | Out-Null
}
Write-Host "  Tagged $($resources.Count) resources." -ForegroundColor Gray

# Re-apply NSG rules (Azure policies may strip them during deployment)
Write-Host "  Re-applying NSG rules (policy may have removed some)..." -ForegroundColor Gray
$nsgName = "nsg-legacy-demo"
$existingRules = az network nsg rule list -g $ResourceGroup --nsg-name $nsgName --query "[].name" -o json | ConvertFrom-Json
foreach ($rule in @(
    @{ name = "AllowSSH"; priority = 100; port = "22" },
    @{ name = "AllowSQL"; priority = 110; port = "1433" },
    @{ name = "AllowRDP"; priority = 120; port = "3389" }
)) {
    if ($rule.name -notin $existingRules) {
        az network nsg rule create -g $ResourceGroup --nsg-name $nsgName -n $rule.name `
            --priority $rule.priority --direction Inbound --access Allow --protocol Tcp `
            --destination-port-ranges $rule.port --source-address-prefixes $myIp -o none 2>&1 | Out-Null
        Write-Host "    Re-added: $($rule.name) (port $($rule.port))" -ForegroundColor Gray
    }
}
Write-Host "  NSG rules verified." -ForegroundColor Gray

# =============================================
# Step 6: Run VM setup script
# =============================================
Write-Host "[6/8] Configuring VM (SSH, database, planted credentials)..." -ForegroundColor Yellow
Write-Host "  Running setup-vm.ps1 on the VM via run-command (base64-encoded)..." -ForegroundColor Gray
Write-Host "  Estimated time: 5-10 minutes" -ForegroundColor Gray
Write-Host ""

# Base64-encode the setup script to avoid run-command escaping issues
$scriptContent = Get-Content .\setup-vm.ps1 -Raw
$b64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($scriptContent))
$wrapper = "Invoke-Expression ([System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('$b64')))"
$wrapperFile = "$env:TEMP\setup-wrapper.ps1"
Set-Content -Path $wrapperFile -Value $wrapper -Encoding ASCII

az vm run-command create -g $ResourceGroup --vm-name $vmName --name "SetupVM" `
    --script "@$wrapperFile" --timeout-in-seconds 900 --async-execution false -o none

# Get output from the run-command
$result = az vm run-command show -g $ResourceGroup --vm-name $vmName --name "SetupVM" `
    --expand instanceView --query "instanceView" -o json | ConvertFrom-Json

if ($result.output) {
    Write-Host "  --- VM setup output ---" -ForegroundColor Gray
    $result.output -split "`n" | ForEach-Object { Write-Host "  $_" -ForegroundColor Gray }
}
if ($result.error) {
    Write-Host "  --- VM setup errors ---" -ForegroundColor Yellow
    $result.error -split "`n" | ForEach-Object { Write-Host "  $_" -ForegroundColor Yellow }
}

# Clean up temp wrapper file
Remove-Item -Path $wrapperFile -Force -ErrorAction SilentlyContinue

# =============================================
# Step 7: Test connectivity
# =============================================
Write-Host "[7/8] Testing connectivity to VM..." -ForegroundColor Yellow

# Test TCP to port 1433
$tcpTest = Test-NetConnection -ComputerName $publicIp -Port 1433 -WarningAction SilentlyContinue
if ($tcpTest.TcpTestSucceeded) {
    Write-Host "  TCP 1433: Reachable" -ForegroundColor Green
} else {
    Write-Host "  TCP 1433: NOT reachable (may need a few minutes for NSG to propagate)" -ForegroundColor Yellow
}

# Test sqlcmd connection
$sqlTest = sqlcmd -S "tcp:${publicIp},1433" -U sa -P $sqlPassword -Q "SELECT 'CONNECTION_OK'" -h -1 -W 2>&1
if ($sqlTest -match "CONNECTION_OK") {
    Write-Host "  SQL connection: OK" -ForegroundColor Green
} else {
    Write-Host "  SQL connection: Could not verify (VM may still be configuring)" -ForegroundColor Yellow
}

# =============================================
# Step 8: Store secrets in Key Vault
# =============================================
Write-Host "[8/8] Storing credentials in Key Vault '$keyVaultName'..." -ForegroundColor Yellow
az keyvault secret set --vault-name $keyVaultName --name "sql-sa-password"       --value $sqlPassword   --output none
az keyvault secret set --vault-name $keyVaultName --name "sql-sa-username"       --value "sa"           --output none
az keyvault secret set --vault-name $keyVaultName --name "vm-admin-password"     --value $adminPassword --output none
az keyvault secret set --vault-name $keyVaultName --name "legacy-server-address" --value $publicIp      --output none
Write-Host "  Secrets stored: sql-sa-password, sql-sa-username, vm-admin-password, legacy-server-address" -ForegroundColor Gray

# =============================================
# Summary
# =============================================
Write-Host ""
Write-Host "=========================================" -ForegroundColor Green
Write-Host "  Deployment Complete!                   " -ForegroundColor Green
Write-Host "=========================================" -ForegroundColor Green
Write-Host ""
Write-Host "  Resource Group:  $ResourceGroup"
Write-Host "  VM Public IP:    $publicIp"
Write-Host "  VM Admin User:   $adminUsername"
Write-Host "  VM Admin Pass:   (stored in Key Vault as 'vm-admin-password')"
Write-Host "  SQL SA Pass:     (stored in Key Vault as 'sql-sa-password')"
Write-Host "  Key Vault:       $keyVaultName"
Write-Host ""
Write-Host "--- Quick Test Commands ---" -ForegroundColor Cyan
Write-Host ""
Write-Host "  # SSH into the VM:" -ForegroundColor Gray
Write-Host "  `$pw = az keyvault secret show --vault-name $keyVaultName --name vm-admin-password --query value -o tsv"
Write-Host "  ssh ${adminUsername}@${publicIp}"
Write-Host ""
Write-Host "  # Test SQL connection:" -ForegroundColor Gray
Write-Host "  `$pw = az keyvault secret show --vault-name $keyVaultName --name sql-sa-password --query value -o tsv"
Write-Host "  sqlcmd -S tcp:${publicIp},1433 -U sa -P `$pw -Q `"SELECT name FROM sys.databases`""
Write-Host ""
Write-Host "--- Teardown ---" -ForegroundColor Red
Write-Host "  az group delete --name $ResourceGroup --yes --no-wait"
Write-Host ""

# Save deployment info for future reference
$config = @{
    ResourceGroup = $ResourceGroup
    Location      = $Location
    PublicIp      = $publicIp
    AdminUsername = $adminUsername
    KeyVaultName  = $keyVaultName
    VmName        = $vmName
    DeployedAt    = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
}
$config | ConvertTo-Json | Set-Content -Path ".\demo-config.json"
Write-Host "Deployment info saved to demo-config.json" -ForegroundColor Gray
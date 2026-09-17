# Azure environment configuration template
# Copy this file to Set-DeveloperContext.ps1 and replace the values with your own
# DO NOT commit Set-DeveloperContext.ps1 to version control

$env:AZURE_KEYVAULT_NAME = "your-keyvault-name"
$env:AZURE_KEYVAULT_SUBSCRIPTION_ID = "your-subscription-id"
$env:AZURE_STORAGE_SUBSCRIPTION_ID = "your-storage-subscription-id"
$env:AZURE_STORAGE_ACCOUNT_NAME = "your-storage-account-name"
$env:AZURE_BLOB_CONTAINER_NAME = "your-container-name"
$env:KV_CLIENT_ID_SECRET_NAME = "ClientId"
$env:KV_CLIENT_SECRET_SECRET_NAME = "ClientSecret"
$env:KV_TENANT_ID_SECRET_NAME = "TenantId"

$projectRoot = "C:\path\to\your\project"

# Set global verbose preference so module functions see -Verbose when passed to calling scripts
$global:VerbosePreference = 'Continue'

Import-Module -Name "$projectRoot/Common/GraphClient/GraphClient.psm1" -Force
Import-Module -Name "$projectRoot/Common/StorageClient/StorageClient.psm1" -Force
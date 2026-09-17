@{
    RootModule        = 'StorageClient.psm1'
    ModuleVersion     = '1.0.0'
    GUID              = '12345678-1234-1234-1234-123456789012'
    Author            = 'M365 Tenant Intelligence'
    Description       = 'PowerShell module for Azure Blob Storage operations with support for nested folders.'
    FunctionsToExport = @(
        'Write-StorageContainerFile',
        'New-StorageContainerFolder',
        'Remove-StorageContainerFolder'
    )
    CmdletsToExport   = @()
    AliasesToExport   = @()
    PrivateData       = @{
        PSData = @{
            Tags       = @('Azure', 'Storage', 'Blob')
            ProjectUri = 'https://github.com/JoelQuimper/m365-tenant-intelligence'
        }
    }
}

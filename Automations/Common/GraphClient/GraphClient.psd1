@{
	RootModule        = 'GraphClient.psm1'
	ModuleVersion     = '0.1.0'
	GUID              = 'f0ee040d-43f7-4d73-beb1-e76d2f389984'
	Author            = 'm365-tenant-intelligence'
	CompanyName       = 'm365-tenant-intelligence'
	Copyright         = '(c) m365-tenant-intelligence. All rights reserved.'
	Description       = 'Shared Microsoft Graph REST helper module for auth, requests, and paging.'
	PowerShellVersion = '7.6'

	FunctionsToExport = @(
		'Get-GraphToken',
		'Invoke-GraphRequestWithRetry',
		'Invoke-GraphPagedRequest',
		'Invoke-GraphBatchWithItemRetry',
		'Write-StorageContainerFile',
		'New-StorageContainerFolder',
		'Remove-StorageContainerFolder'
	)

	CmdletsToExport   = @()
	VariablesToExport = @()
	AliasesToExport   = @()
}

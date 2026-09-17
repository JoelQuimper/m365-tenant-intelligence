[CmdletBinding()]
param(
)

# Import required modules
$projectRoot = "C:\src\public-github\m365-tenant-intelligence"
Import-Module -Name "$projectRoot\Automations\Common\GraphClient\GraphClient.psm1" -Force
Import-Module -Name "$projectRoot\Automations\Common\StorageClient\StorageClient.psm1" -Force

# Source the Set-DeveloperContext to load environment variables
. "$projectRoot\Automations\Set-DeveloperContext.ps1"

function Get-AllUsers {
	[CmdletBinding()]
	param()

	$token = Get-GraphToken
	$headers = @{
		Authorization = "Bearer $token"
		'Content-Type' = 'application/json'
	}
	$runFolderName = "users/$((Get-Date).ToString('yyyy-MM-dd_HH-mm-ss'))"
	$storageFolder = New-StorageContainerFolder -FolderPath $runFolderName
	Write-Verbose "Created storage folder '$($storageFolder.FolderPath)' (marker: $($storageFolder.MarkerBlob))."

	# Include userType to ensure guest users are present in the dataset.
	$selectProperties = @(
		'id',
		'accountEnabled',
		'displayName',
		'givenName',
		'surname',
		'userPrincipalName',
		'mail',
		'userType',
		'createdDateTime',
		'lastPasswordChangeDateTime',
		'signInActivity',
		'licenseAssignmentStates',
		'assignedLicenses',
		'assignedPlans',
		'department',
		'jobTitle',
		'officeLocation',
		'city',
		'state',
		'country',
		'usageLocation',
		'mobilePhone',
		'businessPhones',
		'proxyAddresses',
		'onPremisesSyncEnabled',
		'onPremisesImmutableId'
	)

	$selectQuery = ($selectProperties -join ',')
	$usersUri = "https://graph.microsoft.com/v1.0/users?`$select=$selectQuery&`$top=999"
	Write-Verbose "Fetching all users from Microsoft Graph with this url: $usersUri"

	try {
		# Fetch all users using paged request
		$allUsers = @(Invoke-GraphPagedRequest -Uri $usersUri -Headers $headers)
		Write-Verbose "Retrieved $($allUsers.Count) user(s), including guests."

		# Batch configuration
		$batchSize = 2000
		[int]$totalUsersUploaded = 0

		# Process users in batches
		$userList = [System.Collections.Generic.List[object]]::new($allUsers.Count)
		foreach ($user in $allUsers) {
			$userList.Add($user)
		}

		for ($batchNumber = 1; $batchNumber -le [Math]::Ceiling($userList.Count / $batchSize); $batchNumber++) {
			$startIndex = ($batchNumber - 1) * $batchSize
			$endIndex = [Math]::Min($batchNumber * $batchSize - 1, $userList.Count - 1)
			$batchUsers = [System.Collections.Generic.List[object]]::new($batchSize)
			for ($i = $startIndex; $i -le $endIndex; $i++) {
				$batchUsers.Add($userList[$i])
			}

			Write-Verbose "Processing batch $batchNumber with $($batchUsers.Count) users..."
			[int]$uploadedCount = Write-UsersToJsonlGz -Users $batchUsers.ToArray() -BatchNumber $batchNumber -StorageFolder $storageFolder.FolderPath
			$totalUsersUploaded = $totalUsersUploaded + $uploadedCount
			Write-Verbose "Uploaded batch $batchNumber with $uploadedCount users."
		}

		Write-Verbose "Completed: Uploaded $totalUsersUploaded total users in $batchNumber batch(es)."
		return @{
			StorageFolder = $storageFolder
			TotalUsersUploaded = $totalUsersUploaded
			BatchesCreated = $batchNumber
		}
	}
	catch {
		$message = $_.Exception.Message
		$stackTrace = $_.ScriptStackTrace
		$line = $_.InvocationInfo.ScriptLineNumber
		Write-Verbose "ERROR at line $line : $stackTrace"
		Write-Verbose "Full Exception: $($_ | Format-List -Force | Out-String)"
		throw "Failed to retrieve and process users. Original error: $message"
	}
}

function Write-UsersToJsonlGz {
	[CmdletBinding()]
	param (
		[Parameter(Mandatory = $true)]
		[object[]]$Users,
		[Parameter(Mandatory = $true)]
		[int]$BatchNumber,
		[Parameter(Mandatory = $true)]
		[string]$StorageFolder
	)

	try {
		# Create JSONL content (one user per line)
		Write-Verbose "Creating JSONL lines for batch $BatchNumber..."
		$jsonlLines = foreach ($user in $Users) {
			$user | ConvertTo-Json -Compress
		}
		Write-Verbose "Created $($jsonlLines.Count) JSONL lines"

		# Join all lines
		Write-Verbose "Joining JSONL lines..."
		$jsonlText = $jsonlLines -join "`n"
		Write-Verbose "JSONL text length: $($jsonlText.Length) bytes"

		# Convert to bytes
		Write-Verbose "Converting to UTF8 bytes..."
		$jsonlBytes = [System.Text.Encoding]::UTF8.GetBytes($jsonlText)
		Write-Verbose "Bytes length: $($jsonlBytes.Length)"

		# Create temp file with a meaningful name
		$blobName = "batch_$($BatchNumber.ToString('D4')).jsonl.gz"
		$tempFilePath = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), $blobName)
		Write-Verbose "Created temp file path: $tempFilePath"

		# Create memory stream and compress with gzip
		Write-Verbose "Creating memory streams and compressing..."
		$inputStream = New-Object System.IO.MemoryStream
		$inputStream.Write($jsonlBytes, 0, $jsonlBytes.Length)
		$inputStream.Position = 0

		# Create gzip compressed stream and write to temp file
		$fileStream = [System.IO.File]::Create($tempFilePath)
		try {
			$gzipStream = New-Object System.IO.Compression.GZipStream($fileStream, [System.IO.Compression.CompressionMode]::Compress, $true)
			$inputStream.CopyTo($gzipStream)
			$gzipStream.Close()
			$gzipStream.Dispose()
		}
		finally {
			$fileStream.Dispose()
			$inputStream.Dispose()
		}

		$tempFileInfo = Get-Item -Path $tempFilePath
		Write-Verbose "Compressed file created. File size: $($tempFileInfo.Length) bytes"

		# Upload to storage
		Write-Verbose "Uploading blob: $blobName"
		$uploadResult = Write-StorageContainerFile -FilePath $tempFilePath -BlobName $blobName -TargetFolder $StorageFolder -ContentType 'application/gzip'
		Write-Verbose "Upload result: $($uploadResult.name)"

		# Clean up temp file
		Write-Verbose "Cleaning up temp file: $tempFilePath"
		Remove-Item -Path $tempFilePath -Force -ErrorAction SilentlyContinue

		Write-Verbose "Returning user count: $($Users.Count)"
		[int]$count = @($Users).Count
		return $count
	}
	catch {
		$message = $_.Exception.Message
		$line = $_.InvocationInfo.ScriptLineNumber
		$stackTrace = $_.ScriptStackTrace
		Write-Verbose "ERROR in Write-UsersToJsonlGz at line $line"
		Write-Verbose "Stack: $stackTrace"
		Write-Verbose "Message: $message"
		throw "Failed to write users batch to compressed JSONL file. Original error: $message"
	}
}

$result = Get-AllUsers

Write-Verbose "Completed user data ingestion."
Write-Verbose "Storage Folder: $($result.StorageFolder.FolderPath)"
Write-Verbose "Total Users Uploaded: $($result.TotalUsersUploaded)"
Write-Verbose "Batches Created: $($result.BatchesCreated)"



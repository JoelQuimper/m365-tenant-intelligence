function Write-StorageContainerFile {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string]$FilePath,
        [Parameter(Mandatory = $false)]
        [string]$BlobName,
        [Parameter(Mandatory = $false)]
        [string]$TargetFolder,
        [Parameter(Mandatory = $false)]
        [string]$ContentType,
        [Parameter(Mandatory = $false)]
        [bool]$Overwrite = $true
    )

    try {
        # Resolve StorageAccountName from parameter or environment variable
        $StorageAccountName = $env:AZURE_STORAGE_ACCOUNT_NAME
        if ([string]::IsNullOrWhiteSpace([string]$StorageAccountName)) { throw 'AZURE_STORAGE_ACCOUNT_NAME is required and cannot be null or empty.' }

        # Resolve ContainerName from parameter or environment variable
        $ContainerName = $env:AZURE_BLOB_CONTAINER_NAME
        if ([string]::IsNullOrWhiteSpace([string]$ContainerName)) { throw 'AZURE_BLOB_CONTAINER_NAME is required and cannot be null or empty.' }

        Write-Verbose "Write-StorageContainerFile invoked. Parameters: FilePath=$FilePath, StorageAccountName=$StorageAccountName, ContainerName=$ContainerName, BlobName=$BlobName, TargetFolder=$TargetFolder, ContentType=$ContentType, Overwrite=$Overwrite"
        
        if ([string]::IsNullOrWhiteSpace([string]$FilePath)) {
            throw 'FilePath cannot be null or empty.'
        }
        
        if (-not (Test-Path -Path $FilePath -PathType Leaf)) {
            throw "File not found: $FilePath"
        }
        
        $fileInfo = Get-Item -Path $FilePath
        Write-Verbose "File validation passed. FilePath=$FilePath, FileSize=$($fileInfo.Length) bytes"

        $resolvedBlobName = $BlobName
        if ([string]::IsNullOrWhiteSpace([string]$resolvedBlobName)) {
            $resolvedBlobName = $fileInfo.Name
            Write-Verbose "No BlobName provided. Using filename: $resolvedBlobName"
        }

        $normalizedTargetFolder = $null
        if (-not [string]::IsNullOrWhiteSpace([string]$TargetFolder)) {
            $normalizedTargetFolder = ($TargetFolder -replace '\\', '/').Trim('/')
            if (-not [string]::IsNullOrWhiteSpace([string]$normalizedTargetFolder)) {
                $resolvedBlobName = "$normalizedTargetFolder/$resolvedBlobName"
                Write-Verbose "Resolved blob name with folder prefix: $resolvedBlobName"
            }
        }

        $overwriteValue = 'false'
        if ($Overwrite) {
            $overwriteValue = 'true'
        }
        Write-Verbose "Overwrite flag: $overwriteValue"

        $arguments = @(
            'storage', 'blob', 'upload',
            '--auth-mode', 'login',
            '--account-name', $StorageAccountName,
            '--container-name', $ContainerName,
            '--name', $resolvedBlobName,
            '--file', $FilePath,
            '--overwrite', $overwriteValue,
            '--query', '{name:name,url:url,etag:etag,lastModified:properties.lastModified}',
            '--output', 'json'
        )

        if (-not [string]::IsNullOrWhiteSpace([string]$ContentType)) {
            $arguments += @('--content-type', $ContentType)
            Write-Verbose "Added content type to arguments: $ContentType"
        }

        Write-Verbose "Executing az storage blob upload command. Account=$StorageAccountName, Container=$ContainerName, BlobName=$resolvedBlobName, File=$FilePath"
        $uploadResult = az @arguments
        if ($LASTEXITCODE -ne 0) {
            Write-Verbose "Azure CLI command failed with exit code: $LASTEXITCODE. Output: $uploadResult"
            throw "Failed to upload file to blob '$resolvedBlobName' in container '$ContainerName' for account '$StorageAccountName'."
        }

        Write-Verbose "Upload successful. Parsing result: $uploadResult"
        return ($uploadResult | ConvertFrom-Json)
    }
    catch {
        Write-Verbose "Error in Write-StorageContainerFile: $($_.Exception.Message)"
        Write-Error -Message $_.Exception
        throw $_.Exception
    }
}

function New-StorageContainerFolder {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string]$FolderPath,
        [Parameter(Mandatory = $false)]
        [string]$MarkerFileName = '.keep',
        [Parameter(Mandatory = $false)]
        [bool]$Overwrite = $true
    )

    try {
        # Resolve StorageAccountName from parameter or environment variable
        $StorageAccountName = $env:AZURE_STORAGE_ACCOUNT_NAME
        if ([string]::IsNullOrWhiteSpace([string]$StorageAccountName)) { throw 'AZURE_STORAGE_ACCOUNT_NAME is required and cannot be null or empty.' }

        # Resolve ContainerName from parameter or environment variable
        $ContainerName = $env:AZURE_BLOB_CONTAINER_NAME
        if ([string]::IsNullOrWhiteSpace([string]$ContainerName)) { throw 'AZURE_BLOB_CONTAINER_NAME is required and cannot be null or empty.' }

        $normalizedFolderPath = ($FolderPath -replace '\\', '/').Trim('/')
        if ([string]::IsNullOrWhiteSpace([string]$normalizedFolderPath)) {
            throw 'FolderPath cannot be null, empty, or only slashes.'
        }

        $markerBlobName = "$normalizedFolderPath/$MarkerFileName"
        $tempFilePath = [System.IO.Path]::GetTempFileName()

        try {
            # Create a zero-byte local file that serves as a folder marker blob.
            $emptyStream = [System.IO.File]::Open($tempFilePath, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
            $emptyStream.Dispose()

            $overwriteValue = 'false'
            if ($Overwrite) {
                $overwriteValue = 'true'
            }

            $arguments = @(
                'storage', 'blob', 'upload',
                '--auth-mode', 'login',
                '--account-name', $StorageAccountName,
                '--container-name', $ContainerName,
                '--name', $markerBlobName,
                '--file', $tempFilePath,
                '--overwrite', $overwriteValue,
                '--content-type', 'application/octet-stream',
                '--query', '{name:name,url:url,etag:etag,lastModified:properties.lastModified}',
                '--output', 'json'
            )

            $uploadResult = az @arguments
            if ($LASTEXITCODE -ne 0) {
                throw "Failed to create folder marker '$markerBlobName' in container '$ContainerName' for account '$StorageAccountName'."
            }

            $parsedResult = $uploadResult | ConvertFrom-Json
            return [PSCustomObject]@{
                FolderPath = $normalizedFolderPath
                MarkerBlob = $parsedResult.name
                Url = $parsedResult.url
                ETag = $parsedResult.etag
                LastModified = $parsedResult.lastModified
            }
        }
        finally {
            if (Test-Path -Path $tempFilePath -PathType Leaf) {
                Remove-Item -Path $tempFilePath -Force -ErrorAction SilentlyContinue
            }
        }
    }
    catch {
        Write-Error -Message $_.Exception
        throw $_.Exception
    }
}

function Remove-StorageContainerFolder {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string]$FolderPath,
        [Parameter(Mandatory = $false)]
        [string]$StorageAccountName,
        [Parameter(Mandatory = $false)]
        [string]$ContainerName
    )

    try {
        Write-Verbose "Removing container folder: FolderPath='$FolderPath'"

        # Resolve StorageAccountName from parameter or environment variable
        if ([string]::IsNullOrWhiteSpace([string]$StorageAccountName)) {
            $StorageAccountName = $env:AZURE_STORAGE_ACCOUNT_NAME
            if ([string]::IsNullOrWhiteSpace([string]$StorageAccountName)) { throw 'AZURE_STORAGE_ACCOUNT_NAME is required and cannot be null or empty.' }
        }
        Write-Verbose "Using StorageAccountName='$StorageAccountName'"

        # Resolve ContainerName from parameter or environment variable
        if ([string]::IsNullOrWhiteSpace([string]$ContainerName)) {
            $ContainerName = $env:AZURE_BLOB_CONTAINER_NAME
            if ([string]::IsNullOrWhiteSpace([string]$ContainerName)) { throw 'AZURE_BLOB_CONTAINER_NAME is required and cannot be null or empty.' }
        }
        Write-Verbose "Using ContainerName='$ContainerName'"

        $normalizedFolderPath = ($FolderPath -replace '\\', '/').Trim('/')
        if ([string]::IsNullOrWhiteSpace([string]$normalizedFolderPath)) {
            throw 'FolderPath cannot be null, empty, or only slashes.'
        }
        Write-Verbose "Normalized folder path: '$normalizedFolderPath'"

        # List all blobs with the folder prefix
        Write-Verbose "Listing blobs with prefix='$normalizedFolderPath/'"
        $listArguments = @(
            'storage', 'blob', 'list',
            '--auth-mode', 'login',
            '--account-name', $StorageAccountName,
            '--container-name', $ContainerName,
            '--prefix', "$normalizedFolderPath/",
            '--query', '[].name',
            '--output', 'json'
        )

        $blobsList = az @listArguments
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to list blobs in folder '$normalizedFolderPath' in container '$ContainerName' for account '$StorageAccountName'."
        }

        $blobs = $blobsList | ConvertFrom-Json
        Write-Verbose "Found $($blobs.Count) blobs to delete"

        if ($blobs -and $blobs.Count -gt 0) {
            # Delete each blob
            $deletedCount = 0
            foreach ($blobName in $blobs) {
                Write-Verbose "Deleting blob: '$blobName'"
                $deleteArguments = @(
                    'storage', 'blob', 'delete',
                    '--auth-mode', 'login',
                    '--account-name', $StorageAccountName,
                    '--container-name', $ContainerName,
                    '--name', $blobName
                )

                az @deleteArguments | Out-Null
                if ($LASTEXITCODE -ne 0) {
                    throw "Failed to delete blob '$blobName' from container '$ContainerName' for account '$StorageAccountName'."
                }
                $deletedCount++
            }

            Write-Verbose "Successfully deleted $deletedCount blob(s)"
            return [PSCustomObject]@{
                FolderPath = $normalizedFolderPath
                DeletedBlobsCount = $deletedCount
                DeletedBlobs = $blobs
            }
        }
        else {
            Write-Verbose "No blobs found in folder '$normalizedFolderPath'"
            return [PSCustomObject]@{
                FolderPath = $normalizedFolderPath
                DeletedBlobsCount = 0
                DeletedBlobs = @()
            }
        }
    }
    catch {
        Write-Error -Message $_.Exception
        throw $_.Exception
    }
}

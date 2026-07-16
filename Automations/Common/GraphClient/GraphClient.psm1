function Get-GraphToken {
    [CmdletBinding()]
    param (
    )

    try {
        if (-not $env:AZUREPS_HOST_ENVIRONMENT) {
            Write-Information 'Running Locally (With Client Credentials flow)'

            $keyVaultName = $env:AZURE_KEYVAULT_NAME
            Write-Verbose "keyVaultName: $keyVaultName"
            if ([string]::IsNullOrWhiteSpace([string]$keyVaultName)) { throw 'AZURE_KEYVAULT_NAME is required and cannot be null or empty.' }
            
            $keyVaultSubscriptionId = $env:AZURE_KEYVAULT_SUBSCRIPTION_ID
            Write-Verbose "keyVaultSubscriptionId: $keyVaultSubscriptionId"
            if ([string]::IsNullOrWhiteSpace([string]$keyVaultSubscriptionId)) { throw 'AZURE_KEYVAULT_SUBSCRIPTION_ID is required and cannot be null or empty.' }
            
            $clientIdSecretName = $env:KV_CLIENT_ID_SECRET_NAME
            Write-Verbose "clientIdSecretName: $clientIdSecretName"
            if ([string]::IsNullOrWhiteSpace([string]$clientIdSecretName)) { throw 'KV_CLIENT_ID_SECRET_NAME is required and cannot be null or empty.' }
            
            $clientSecretSecretName = $env:KV_CLIENT_SECRET_SECRET_NAME
            Write-Verbose "clientSecretSecretName: $clientSecretSecretName"
            if ([string]::IsNullOrWhiteSpace([string]$clientSecretSecretName)) { throw 'KV_CLIENT_SECRET_SECRET_NAME is required and cannot be null or empty.' }
            
            $tenantIdSecretName = $env:KV_TENANT_ID_SECRET_NAME
            Write-Verbose "tenantIdSecretName: $tenantIdSecretName"
            if ([string]::IsNullOrWhiteSpace([string]$tenantIdSecretName)) { throw 'KV_TENANT_ID_SECRET_NAME is required and cannot be null or empty.' }

            az login --output none
            az account set --subscription $keyVaultSubscriptionId --output none
            Write-Verbose "Retrieving secrets from Key Vault '$keyVaultName' in subscription '$keyVaultSubscriptionId'...  Logged in as: $(az account show --query user.name --output tsv)"

            $clientId = az keyvault secret show --vault-name $keyVaultName --name $clientIdSecretName --query value --output tsv
            $clientSecret = az keyvault secret show --vault-name $keyVaultName --name $clientSecretSecretName --query value --output tsv
            $tenantId = az keyvault secret show --vault-name $keyVaultName --name $tenantIdSecretName --query value --output tsv
            
            if ([string]::IsNullOrWhiteSpace([string]$clientId)) { throw "Failed to retrieve ClientId secret '$clientIdSecretName' from Key Vault." }
            if ([string]::IsNullOrWhiteSpace([string]$clientSecret)) { throw "Failed to retrieve ClientSecret secret '$clientSecretSecretName' from Key Vault." }
            if ([string]::IsNullOrWhiteSpace([string]$tenantId)) { throw "Failed to retrieve TenantId secret '$tenantIdSecretName' from Key Vault." }
            
            Write-Verbose "Retrieved secrets: ClientId=$clientId, TenantId=$tenantId, ClientSecret=(masked)"
            Write-Verbose "Logging out from initial Azure session before logging in as service principal."
            az logout --output none
            az login --service-principal --username $clientId --password $clientSecret --tenant $tenantId --allow-no-subscriptions --output none
            Write-Verbose "Logged in as service principal: $(az account show --query user.name --output tsv)"
            
        } else {
            Write-Information 'Running in Azure Automation (With Managed Identity flow)'
            az login --identity --allow-no-subscriptions --output none
            Write-Verbose "Logged in as managed identity: $(az account show --query user.name --output tsv)"
        }
        # Set subscription context for storage operations
        $storageSubscriptionId = $env:AZURE_STORAGE_SUBSCRIPTION_ID
        Write-Verbose "storageSubscriptionId: $storageSubscriptionId"
        if ([string]::IsNullOrWhiteSpace([string]$storageSubscriptionId)) { throw 'AZURE_STORAGE_SUBSCRIPTION_ID is required and cannot be null or empty.' }
        az account set --subscription $storageSubscriptionId --output none

        Write-Verbose "Retrieving Microsoft Graph access token..."
        $accessToken = az account get-access-token --resource-type ms-graph --query accessToken --output tsv
        if ([string]::IsNullOrWhiteSpace([string]$accessToken)) { throw 'Failed to obtain Microsoft Graph access token.' }
        
        if ($VerbosePreference -eq 'Continue') {
            $accessToken | Set-Clipboard
            Write-Verbose "Microsoft Graph access token copied to clipboard."
        }
        return $accessToken
    }
    catch {
        Write-Error -Message $_.Exception
        throw $_.Exception
    }
}

function Invoke-GraphRequestWithRetry {
    param (
        [Parameter(Mandatory = $true)]
        [string]$Method,
        [Parameter(Mandatory = $true)]
        [string]$Uri,
        [Parameter(Mandatory = $true)]
        [hashtable]$Headers,
        [Parameter(Mandatory = $false)]
        [object]$Body,
        [Parameter(Mandatory = $false)]
        [int]$MaxRetries = 8
    )

    Write-Verbose "Invoking Graph request: Method=$Method, Uri=$Uri, MaxRetries=$MaxRetries"

    for ($attempt = 1; $attempt -le $MaxRetries; $attempt++) {
        try {
            if ($Body) {
                $BodyJson = $Body | ConvertTo-Json -Depth 10
                Write-Verbose "Doing a POST request with Body (JSON): $BodyJson"
                return Invoke-RestMethod -Method $Method -Uri $Uri -Headers $Headers -Body $BodyJson
            } else {
                Write-Verbose "Doing a GET request without a body."
                return Invoke-RestMethod -Method $Method -Uri $Uri -Headers $Headers
            }
        }
        catch {
            Write-Verbose "Graph request failed on attempt $attempt/$MaxRetries. Exception: $($_.Exception.Message)"
            Write-Verbose "Exception details: $($_ | Format-List -Force | Out-String)"
            
            # Resolve-GraphException handles everything: throws on non-retryable, sleeps and returns on retryable
            Resolve-GraphException -Exception $_ -Attempt $attempt -MaxRetries $MaxRetries
            
            # If we reach here, error was retryable and we've already slept
            continue
        }
    }
}

function Invoke-GraphPagedRequest {
    param (
        [Parameter(Mandatory = $true)]
        [string]$Uri,
        [Parameter(Mandatory = $true)]
        [hashtable]$Headers
    )

    try {
        $results = [System.Collections.Generic.List[object]]::new()
        $nextUri = $Uri

        while (-not [string]::IsNullOrWhiteSpace($nextUri)) {
            $response = Invoke-GraphRequestWithRetry -Method 'GET' -Uri $nextUri -Headers $Headers
            Write-Verbose "Received response, details: $($response | ConvertTo-Json -Depth 5)"

            foreach ($item in $response.value) {
                $results.Add($item)
            }

            $nextUri = $response.'@odata.nextLink'
            Write-Verbose "Next page link: $nextUri"
        }

        Write-Verbose "Completed paged request. Total items retrieved: $($results.Count)"
        return $results.ToArray()
    }
    catch {
        Write-Error -Message $_.Exception
        throw $_.Exception
    }
}

function Invoke-GraphBatchWithItemRetry {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Headers,

        [Parameter(Mandatory = $true)]
        [object[]]$BatchRequests,

        [Parameter(Mandatory = $false)]
        [int]$MaxRetries = 8
    )

    $pendingRequests = @($BatchRequests)
    $successResults = @()
    $skippedResults = @()
    $failedResults = @()

    for ($attempt = 1; $attempt -le $MaxRetries; $attempt++) {
        if ($pendingRequests.Count -eq 0) {
            break
        }

        $batchBody = @{ requests = $pendingRequests }
        $batchResponse = Invoke-GraphRequestWithRetry -Method 'POST' -Uri 'https://graph.microsoft.com/v1.0/$batch' -Headers $Headers -Body $batchBody
        $responses = @($batchResponse.responses)

        $retryRequests = @()
        $maxRetryAfterSeconds = 0

        # Iterate over each response in the batch to determine success, failure, or retry logic
        foreach ($response in $responses) {
            $requestId = [string]$response.id
            $status = [int]$response.status
            $bodyErrorMessage = [string]$response.body.error.message

            if ($status -eq 204 -or $status -eq 200) {
                Write-Verbose "$status - Success for request ID: $requestId"
                $successResults += $requestId
                continue
            }

            if ($status -eq 404) {
                Write-Verbose "$status - Not found for request ID: $requestId"
                $skippedResults += @{
                    id = $requestId
                    status = $status
                    reason = 'Item not found.'
                }
                continue
            }

            # Check if status is retryable
            $retryAfterSeconds = 0
            if ($null -ne $response.headers -and $null -ne $response.headers.PSObject.Properties['Retry-After']) {
                $retryAfterHeader = $response.headers.'Retry-After'
                if (-not [string]::IsNullOrWhiteSpace([string]$retryAfterHeader)) {
                    $parsed = 0
                    if ([int]::TryParse([string]$retryAfterHeader, [ref]$parsed)) {
                        $retryAfterSeconds = [Math]::Max(0, $parsed)
                    }
                }
            }
            
            $retryAction = Get-RetryAction -StatusCode $status -Attempt $attempt -MaxRetries $MaxRetries -RetryAfterSeconds $retryAfterSeconds
            
            if ($retryAction.IsRetryable) {
                Write-Verbose "$status - Retryable error for request ID: $requestId"
                $retryRequests += $pendingRequests | Where-Object { $_.id -eq $requestId }
                
                Write-Verbose "Response headers: $($response.headers | ConvertTo-Json -Depth 5)"
                Write-Warning "Retrying request $requestId (HTTP $status, Retry-After: $retryAfterSeconds)"
                if ($retryAfterSeconds -gt $maxRetryAfterSeconds) {
                    $maxRetryAfterSeconds = $retryAfterSeconds
                }
                continue
            }
            
            if ($status -ge 500) {
                # Server error that isn't retryable - treat as failed
                Write-Verbose "$status - Non-retryable server error for request ID: $requestId"
                $failedResults += @{
                    id = $requestId
                    status = $status
                    reason = "HTTP ${status}: $bodyErrorMessage"
                }
                continue
            }

            $failedResults += @{
                id = $requestId
                status = $status
                reason = "HTTP ${status}: $bodyErrorMessage"
            }
        }

        $pendingRequests = @($retryRequests)

        if ($pendingRequests.Count -gt 0) {
            # Use Get-RetryAction to calculate delay (status 429 is retryable, so pass it)
            $retryAction = Get-RetryAction -StatusCode 429 -Attempt $attempt -MaxRetries $MaxRetries -RetryAfterSeconds $maxRetryAfterSeconds
            Write-Warning "Batch had $($pendingRequests.Count) retryable item(s). Waiting $($retryAction.DelaySeconds) second(s) before retry attempt $($attempt + 1)/$MaxRetries."
            Start-Sleep -Seconds $retryAction.DelaySeconds
        } else {
            # Pace requests even on success to avoid throttling
            Start-Sleep -Milliseconds $RequestDelayMs
        }
    }

    # Mark any remaining pending requests as failed if we exhausted retries
    foreach ($request in $pendingRequests) {
        $failedResults += @{
            id = [string]$request.id
            status = 0
            reason = 'Max retry attempts exceeded.'
        }
    }

    return @{
        Success = $successResults
        Skipped = $skippedResults
        Failed = $failedResults
    }
}

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

function Get-RetryAction {
    <#
    .SYNOPSIS
        Determines if an HTTP status code is retryable and calculates the retry delay.
    .PARAMETER StatusCode
        The HTTP status code to evaluate.
    .PARAMETER Attempt
        The current attempt number (1-based).
    .PARAMETER MaxRetries
        Maximum number of retry attempts allowed.
    .PARAMETER RetryAfterSeconds
        The Retry-After header value in seconds (0 if not provided).
    .OUTPUTS
        PSCustomObject with IsRetryable (bool) and DelaySeconds (int) properties.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [int]$StatusCode,
        [Parameter(Mandatory = $true)]
        [int]$Attempt,
        [Parameter(Mandatory = $true)]
        [int]$MaxRetries,
        [Parameter(Mandatory = $false)]
        [int]$RetryAfterSeconds = 0
    )
    
    # Check if status code is retryable (429, 503, 504)
    if ($StatusCode -ne 429 -and $StatusCode -ne 503 -and $StatusCode -ne 504) {
        return @{ IsRetryable = $false; DelaySeconds = 0 }
    }
    
    # Retryable status code - check if we can retry
    if ($Attempt -lt $MaxRetries) {
        # Calculate delay with exponential backoff: 2^Attempt capped at 60 seconds, respecting Retry-After
        $backoffSeconds = [Math]::Min(60, [int][Math]::Pow(2, $Attempt))
        $delaySeconds = [Math]::Max($RetryAfterSeconds, $backoffSeconds)
        return @{ IsRetryable = $true; DelaySeconds = $delaySeconds }
    }
    
    # Retryable status code but max retries exhausted
    return @{ IsRetryable = $false; DelaySeconds = 0 }
}

function Resolve-GraphException {
    <#
    .SYNOPSIS
        Resolves Graph API request exceptions intelligently: throws on non-retryable errors, sleeps and continues on retryable errors.
    .PARAMETER Exception
        The exception object from a failed Graph request.
    .PARAMETER Attempt
        The current attempt number (1-based).
    .PARAMETER MaxRetries
        Maximum number of retry attempts allowed.
    .DESCRIPTION
        This function decides whether an error is retryable or not:
        - If NOT retryable: Collects diagnostics and throws immediately
        - If retryable: Extracts Retry-After, calculates delay with exponential backoff, sleeps, and returns (continue signal)
    #>
    param(
        [Parameter(Mandatory = $true)]
        [System.Management.Automation.ErrorRecord]$Exception,
        [Parameter(Mandatory = $true)]
        [int]$Attempt,
        [Parameter(Mandatory = $true)]
        [int]$MaxRetries
    )
    
    # Extract status code
    $statusCode = 0
    if ($null -ne $Exception.Exception.Response) {
        try {
            $statusCode = [int]$Exception.Exception.Response.StatusCode
        } catch {
            Write-Verbose "Failed to extract status code from response: $($_.Exception.Message)"
            $statusCode = 0
        }
    } else {
        Write-Verbose "No response object available. Exception type: $($Exception.Exception.GetType().FullName)"
        $statusCode = 0
    }
    
    Write-Verbose "HTTP Status Code: $statusCode"
    
    # Extract Retry-After header
    $retryAfterSeconds = 0
    try {
        if ($null -ne $Exception.Exception.Response) {
            $retryAfterHeader = $Exception.Exception.Response.Headers['Retry-After']
            Write-Verbose "Retry-After header value: $retryAfterHeader"
            if (-not [string]::IsNullOrWhiteSpace([string]$retryAfterHeader)) {
                $parsed = 0
                Write-Verbose "Attempting to parse Retry-After header value."
                if ([int]::TryParse([string]$retryAfterHeader, [ref]$parsed)) {
                    $retryAfterSeconds = [Math]::Max(1, $parsed)
                    Write-Verbose "Parsed Retry-After value: $retryAfterSeconds seconds."
                } else {
                    Write-Warning "Retry-After header is not a valid integer: '$retryAfterHeader'."
                }
            }
        }
    }
    catch {
        Write-Warning "Failed to parse Retry-After header: $($_.Exception.Message)"
    }
    
    # Use Get-RetryAction to determine retry strategy
    $retryAction = Get-RetryAction -StatusCode $statusCode -Attempt $Attempt -MaxRetries $MaxRetries -RetryAfterSeconds $retryAfterSeconds
    
    if ($retryAction.IsRetryable) {
        # Retryable - sleep and return to signal continue
        Write-Warning "Retryable Graph error (HTTP $statusCode). Retrying in $($retryAction.DelaySeconds) second(s) [attempt $Attempt/$MaxRetries]."
        Start-Sleep -Seconds $retryAction.DelaySeconds
        Write-Verbose "Sleep complete. Retrying Graph request (attempt $($Attempt + 1)/$MaxRetries)..."
        return  # Signal to continue the retry loop
    }
    
    # Non-retryable error - collect diagnostics and throw
    if ($statusCode -ne 429 -and $statusCode -ne 503 -and $statusCode -ne 504) {
        $diagnosticInfo = @{
            StatusCode = $statusCode
            StatusDescription = if ($null -ne $Exception.Exception.Response) { $Exception.Exception.Response.StatusDescription } else { 'N/A' }
            Headers = @{}
        }
        
        if ($null -ne $Exception.Exception.Response -and $null -ne $Exception.Exception.Response.Headers) {
            foreach ($header in $Exception.Exception.Response.Headers.Keys) {
                $diagnosticInfo.Headers[$header] = $Exception.Exception.Response.Headers[$header]
            }
        }
        
        try {
            if ($null -ne $Exception.Exception.Response) {
                $responseStream = $Exception.Exception.Response.GetResponseStream()
                $streamReader = New-Object System.IO.StreamReader($responseStream)
                $diagnosticInfo.ResponseBody = $streamReader.ReadToEnd()
                $streamReader.Close()
                Write-Verbose "Captured response body for diagnostic purposes: $($diagnosticInfo.ResponseBody)"
            }
        }
        catch { }
        
        Write-Error -Message "Graph API Error (non-retryable): $($diagnosticInfo | ConvertTo-Json -Depth 5)"
    }
    
    # Max retries exhausted or non-retryable
    Write-Error -Message "Graph request failed: HTTP $statusCode. Last error: $($Exception.Exception.Message)"
    throw $Exception.Exception
}






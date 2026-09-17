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
        if ($attempt -gt $MaxRetries) {
            Write-Error "Maximum retry attempts ($MaxRetries) reached for Graph request: Method=$Method, Uri=$Uri"
            throw "Maximum retry attempts ($MaxRetries) reached for Graph request: Method=$Method, Uri=$Uri"
        }

        try {
            if ($Body) {
                $BodyJson = $Body | ConvertTo-Json -Depth 10
                Write-Verbose "Doing a $Method request with Body (JSON): $BodyJson"
                $result = Invoke-RestMethod -Method $Method -Uri $Uri -Headers $Headers -Body $BodyJson
            } else {
                Write-Verbose "Doing a $Method request without a body."
                $result = Invoke-RestMethod -Method $Method -Uri $Uri -Headers $Headers
            }
            
            return $result
        }
        catch {
            $initialError = $_
            Write-Verbose "Caught exception on attempt $attempt/$MaxRetries : $($initialError.Exception.Message)"
            if ($null -eq $initialError.Exception.Response) {
                Write-Error "No response received from Graph API. Exception: $($initialError.Exception.Message)"
                throw $initialError.Exception
            }
            
            $statusCode = 0
            try {                 
                $statusCode = [int]$initialError.Exception.Response.StatusCode
                Write-Verbose "Extracted HTTP status code: $statusCode"
            }
            catch {
                Write-Error "Failed to extract status code from response: $($initialError.Exception.Message)"
                throw $initialError.Exception
            }

            if ($statusCode -ne 429){
                Write-Error "Non-retryable Graph API error (HTTP $statusCode): $($initialError.Exception.Message)"
                throw $initialError.Exception
            }
            
            $retryAfterHeader = [string]$initialError.Exception.Response.Headers['Retry-After']
            $parsed = 0
            if (-not [int]::TryParse($retryAfterHeader, [ref]$parsed) -or $parsed -le 0) {
                Write-Error "HTTP 429 received but Retry-After header is missing or invalid: '$retryAfterHeader'"
                throw $initialError.Exception
            }
            $retryAfterSeconds = $parsed
            Write-Warning "Retrying Graph request after HTTP 429 in $retryAfterSeconds second(s) [attempt $attempt/$MaxRetries]."
            Start-Sleep -Seconds $retryAfterSeconds
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
[CmdletBinding()]
param(
	[Parameter(Mandatory = $false)]
	[ValidateRange(1, 100000)]
	[int]$Count = 11000,

	[Parameter(Mandatory = $false)]
	[ValidateRange(1, 1000000)]
	[int]$StartNumber = 39020
)

$BatchSize = 20
$MaxBatchRetries = 8

function Get-DefaultTenantDomain {
	[CmdletBinding()]
	param(
		[Parameter(Mandatory = $true)]
		[hashtable]$Headers
	)

	$org = Invoke-GraphRequest -Method 'GET' -Uri 'https://graph.microsoft.com/v1.0/organization?$select=verifiedDomains' -Headers $Headers
	$verifiedDomains = @($org.value[0].verifiedDomains)

	if (-not $verifiedDomains -or $verifiedDomains.Count -eq 0) {
		throw 'No verified tenant domains were returned from Microsoft Graph.'
	}

	$defaultDomain = $verifiedDomains | Where-Object { $_.isDefault -eq $true } | Select-Object -First 1
	if ($null -ne $defaultDomain) {
		return [string]$defaultDomain.name
	}

	return [string]($verifiedDomains | Select-Object -First 1).name
}

function Get-RandomPassword {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [int]$Length = 20
    )

    $chars = 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789!@#$%^&*()_+-=[]{}|;:,.<>?'
    $password = -join ((1..$Length) | ForEach-Object { $chars[(Get-Random -Minimum 0 -Maximum $chars.Length)] })
    return $password
}

function Get-RetryAfterSeconds {
	[CmdletBinding()]
	param(
		[Parameter(Mandatory = $false)]
		[object]$ResponseHeaders
	)

	if ($null -eq $ResponseHeaders) {
		return 0
	}

	$retryAfterValue = $null

	if ($ResponseHeaders -is [System.Collections.IDictionary]) {
		if ($ResponseHeaders.Contains('Retry-After')) {
			$retryAfterValue = $ResponseHeaders['Retry-After']
		} elseif ($ResponseHeaders.Contains('retry-after')) {
			$retryAfterValue = $ResponseHeaders['retry-after']
		}
	}

	if ($null -eq $retryAfterValue) {
		return 0
	}

	$parsed = 0
	if ([int]::TryParse([string]$retryAfterValue, [ref]$parsed)) {
		return [Math]::Max(0, $parsed)
	}

	return 0
}

function Invoke-UserCreateBatchWithRetry {
	[CmdletBinding()]
	param(
		[Parameter(Mandatory = $true)]
		[hashtable]$Headers,

		[Parameter(Mandatory = $true)]
		[object[]]$BatchUsers,

		[Parameter(Mandatory = $true)]
		[ValidateRange(1, 20)]
		[int]$MaxRetries
	)

	$pendingUsers = @($BatchUsers)
	$createdUsers = @()
	$skippedUsers = @()
	$failedUsers = @()
	$attempt = 0

	while ($pendingUsers.Count -gt 0) {
		$attempt++
		if ($attempt -gt $MaxRetries) {
			foreach ($remainingUser in $pendingUsers) {
				$failedUsers += [PSCustomObject]@{
					userPrincipalName = $remainingUser.UserPrincipalName
					reason = 'Max retry attempts exceeded.'
				}
			}
			break
		}

		$requests = @()
		$idToUserMap = @{}

		for ($i = 0; $i -lt $pendingUsers.Count; $i++) {
			$requestId = [string]$i
			$user = $pendingUsers[$i]

			$idToUserMap[$requestId] = $user
			$requests += @{
				id = $requestId
				method = 'POST'
				url = '/users'
				headers = @{ 'Content-Type' = 'application/json' }
				body = $user.Body
			}
		}

		$batchBody = @{ requests = $requests }
		$batchResponse = Invoke-GraphRequest -Method 'POST' -Uri 'https://graph.microsoft.com/v1.0/$batch' -Headers $Headers -Body $batchBody
		$responses = @($batchResponse.responses)

		$retryUsers = @()
		$maxRetryAfterSeconds = 0

		foreach ($response in $responses) {
			$requestId = [string]$response.id
			if (-not $idToUserMap.ContainsKey($requestId)) {
				continue
			}

			$user = $idToUserMap[$requestId]
			$status = [int]$response.status
			$bodyErrorMessage = [string]$response.body.error.message

			if ($status -eq 201 -or $status -eq 200) {
				$createdUsers += [PSCustomObject]@{
					userPrincipalName = [string]$response.body.userPrincipalName
				}
				continue
			}

			if ($status -eq 400 -and $bodyErrorMessage -match 'already exists') {
				$skippedUsers += [PSCustomObject]@{
					userPrincipalName = $user.UserPrincipalName
					reason = 'User already exists.'
				}
				continue
			}

			if ($status -eq 409) {
				$skippedUsers += [PSCustomObject]@{
					userPrincipalName = $user.UserPrincipalName
					reason = 'User already exists.'
				}
				continue
			}

			if ($status -eq 429 -or $status -eq 503 -or $status -eq 504 -or $status -ge 500) {
				$retryUsers += $user
				$retryAfterSeconds = Get-RetryAfterSeconds -ResponseHeaders $response.headers
                Write-Warning "Retrying create for $($user.userPrincipalName) (HTTP $status, Retry-After: $retryAfterSeconds)"
				if ($retryAfterSeconds -gt $maxRetryAfterSeconds) {
					$maxRetryAfterSeconds = $retryAfterSeconds
				}
				continue
			}

			$failedUsers += [PSCustomObject]@{
				userPrincipalName = $user.UserPrincipalName
				reason = "HTTP ${status}: $bodyErrorMessage"
			}
		}

		$pendingUsers = @($retryUsers)

		if ($pendingUsers.Count -gt 0) {
			$backoffSeconds = [Math]::Min(60, [int][Math]::Pow(2, $attempt))
			$delaySeconds = [Math]::Max($maxRetryAfterSeconds, $backoffSeconds)
			Write-Warning "Batch had $($pendingUsers.Count) retryable request(s). Waiting $delaySeconds second(s) before retry attempt $($attempt + 1)/$MaxRetries."
			Start-Sleep -Seconds $delaySeconds
		}
	}

	return [PSCustomObject]@{
		Created = $createdUsers
		Skipped = $skippedUsers
		Failed = $failedUsers
	}
}

function New-TestUsers {
	[CmdletBinding()]
	param(
		[Parameter(Mandatory = $true)]
		[ValidateRange(1, 100000)]
		[int]$Count,

		[Parameter(Mandatory = $true)]
		[ValidateRange(1, 1000000)]
		[int]$StartNumber
	)

	$BatchSize = $script:BatchSize
	$MaxBatchRetries = $script:MaxBatchRetries

	$token = Get-GraphToken
	$headers = @{
		Authorization = "Bearer $token"
		'Content-Type' = 'application/json'
	}

	$tenantDomain = Get-DefaultTenantDomain -Headers $headers

	Write-Host "Using tenant domain: $tenantDomain"
	Write-Host "Creating $Count test user(s) in batches of $BatchSize"

	$createdUsers = @()
	$skippedUsers = @()
	$failedUsers = @()

	$processed = 0
	for ($offset = 0; $offset -lt $Count; $offset += $BatchSize) {
		$currentBatchCount = [Math]::Min($BatchSize, $Count - $offset)
		$batchUsers = @()

		for ($j = 0; $j -lt $currentBatchCount; $j++) {
			$n = $StartNumber + $offset + $j
			$displayName = "Test User $n"
			$mailNickname = "test.user$n"
			$userPrincipalName = "$mailNickname@$tenantDomain"

			$body = @{
				accountEnabled = $false
				displayName = $displayName
				givenName = 'Test'
				surname = "User $n"
				mailNickname = $mailNickname
				userPrincipalName = $userPrincipalName
				passwordProfile = @{
					forceChangePasswordNextSignIn = $true
					password = Get-RandomPassword -Length 40
				}
			}

			$batchUsers += [PSCustomObject]@{
				UserPrincipalName = $userPrincipalName
				Body = $body
			}
		}

		$batchResult = Invoke-UserCreateBatchWithRetry -Headers $headers -BatchUsers $batchUsers -MaxRetries $MaxBatchRetries
		$createdUsers += @($batchResult.Created)
		$skippedUsers += @($batchResult.Skipped)
		$failedUsers += @($batchResult.Failed)

		$processed += $currentBatchCount
		Write-Host "Progress: $processed/$Count processed | Created: $($createdUsers.Count) | Skipped: $($skippedUsers.Count) | Failed: $($failedUsers.Count)"
	}

	return [PSCustomObject]@{
		Created = $createdUsers
		Skipped = $skippedUsers
		Failed = $failedUsers
	}
}

$result = New-TestUsers -Count $Count -StartNumber $StartNumber
Write-Host "Done. Created $($result.Created.Count) user(s), skipped $($result.Skipped.Count), failed $($result.Failed.Count)."

if ($result.Failed.Count -gt 0) {
	Write-Warning 'Some users failed to create. First 20 failures:'
	$result.Failed | Select-Object -First 20 | ForEach-Object {
		Write-Warning " - $($_.userPrincipalName): $($_.reason)"
	}
}

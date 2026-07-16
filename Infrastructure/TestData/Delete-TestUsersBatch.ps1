[CmdletBinding()]
param()

$UserPrincipalNamePrefix = 'test.user'
$BatchSize = 15  # Reduced from 20 to reduce throttling
$MaxBatchRetries = 8
$RequestDelayMs = 100  # Milliseconds between batch requests to pace load

function Remove-TestUsersBatch {
	[CmdletBinding()]
	param()

	$token = Get-GraphToken
	$baseHeaders = @{
		Authorization = "Bearer $token"
		'Content-Type' = 'application/json'
		'User-Agent' = 'M365TenantIntelligence/1.0 (PowerShell; M365 User Cleanup - Batch)'
	}

	$usersUri = "https://graph.microsoft.com/v1.0/users?`$select=id,userPrincipalName&`$filter=startsWith(userPrincipalName,'$UserPrincipalNamePrefix')&`$top=999"
	$users = @(Invoke-GraphPagedRequest -Uri $usersUri -Headers $baseHeaders)

	if ($users.Count -eq 0) {
		Write-Host "No users found with prefix '$UserPrincipalNamePrefix'."
		return [PSCustomObject]@{
			Deleted = @()
			Skipped = @()
			Failed = @()
		}
	}

	Write-Host "Found $($users.Count) user(s) with prefix '$UserPrincipalNamePrefix'. Deleting in batches of $BatchSize..."

	$deletedUsers = @()
	$skippedUsers = @()
	$failedUsers = @()

	$processed = 0
	for ($offset = 0; $offset -lt $users.Count; $offset += $BatchSize) {
		$currentBatchCount = [Math]::Min($BatchSize, $users.Count - $offset)
		$batchUsers = @($users[$offset..($offset + $currentBatchCount - 1)])

		# Add Request-Id per batch for tracing
		$requestHeaders = $baseHeaders.Clone()
		$requestHeaders['Request-Id'] = [guid]::NewGuid().ToString()

		# Build batch requests for deletion
		$requests = @()
		$userMap = @{}  # Local mapping: requestId -> user object

		for ($i = 0; $i -lt $batchUsers.Count; $i++) {
			$requestId = [string]$i
			$user = $batchUsers[$i]
			$userMap[$requestId] = $user  # Store user object for result mapping

			$requests += @{
				id = $requestId
				method = 'DELETE'
				url = "/users/$($user.id)"
			}
		}

		# Call module WITHOUT ItemMap parameter (now domain-agnostic)
		Write-Verbose "Invoking batch with $($requests.Count) DELETE requests [Batch Request-Id: $($requestHeaders['Request-Id'])]"
		$batchResult = Invoke-GraphBatchWithItemRetry -Headers $requestHeaders -BatchRequests $requests -MaxRetries $MaxBatchRetries

		# Map returned IDs back to original user objects using local userMap
		$deletedUsers += $batchResult.Success | ForEach-Object {
			$requestId = $_
			$user = $userMap[$requestId]
			[PSCustomObject]@{
				id = $user.id
				userPrincipalName = $user.userPrincipalName
				status = 204
			}
		}

		# Process skipped items (e.g., 404 not found)
		$skippedUsers += $batchResult.Skipped | ForEach-Object {
			$requestId = $_.id
			$user = $userMap[$requestId]
			[PSCustomObject]@{
				id = $user.id
				userPrincipalName = $user.userPrincipalName
				status = $_.status
				reason = $_.reason
			}
		}

		# Process failed items
		$failedUsers += $batchResult.Failed | ForEach-Object {
			$requestId = $_.id
			$user = $userMap[$requestId]
			[PSCustomObject]@{
				id = $user.id
				userPrincipalName = $user.userPrincipalName
				status = $_.status
				reason = $_.reason
			}
		}

		$processed += $currentBatchCount
		Write-Host "Progress: $processed/$($users.Count) processed | Deleted: $($deletedUsers.Count) | Skipped: $($skippedUsers.Count) | Failed: $($failedUsers.Count)"

		# Pace requests to reduce throttling
		if ($offset + $BatchSize -lt $users.Count) {
			Start-Sleep -Milliseconds $RequestDelayMs
		}
	}

	return [PSCustomObject]@{
		Deleted = $deletedUsers
		Skipped = $skippedUsers
		Failed = $failedUsers
	}
}

$result = Remove-TestUsersBatch
Write-Host "Done. Deleted $($result.Deleted.Count) user(s), skipped $($result.Skipped.Count), failed $($result.Failed.Count)."

if ($result.Failed.Count -gt 0) {
	Write-Warning 'Some users failed to delete. First 20 failures:'
	$result.Failed | Select-Object -First 20 | ForEach-Object {
		Write-Warning " - $($_.userPrincipalName): $($_.reason)"
	}
}

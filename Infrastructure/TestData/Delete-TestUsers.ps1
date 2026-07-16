[CmdletBinding()]
param()

$UserPrincipalNamePrefix = 'test.user'
$RequestDelayMs = 100

function Remove-TestUsers {
	[CmdletBinding()]
	param()

	$token = Get-GraphToken
	$baseHeaders = @{
		Authorization = "Bearer $token"
		'Content-Type' = 'application/json'
		'User-Agent' = 'M365TenantIntelligence/1.0 (PowerShell; M365 User Cleanup)'
	}

	$usersUri = "https://graph.microsoft.com/v1.0/users?`$select=id,userPrincipalName&`$filter=startsWith(userPrincipalName,'$UserPrincipalNamePrefix')&`$top=999"
	$users = @(Invoke-GraphPagedRequestWithRetry -Uri $usersUri -Headers $baseHeaders)

	if ($users.Count -eq 0) {
		Write-Host "No users found with prefix '$UserPrincipalNamePrefix'."
		return [PSCustomObject]@{
			Deleted = @()
			Skipped = @()
			Failed = @()
		}
	}

	Write-Host "Found $($users.Count) user(s) with prefix '$UserPrincipalNamePrefix'. Deleting one-by-one..."

	$deletedUsers = @()
	$skippedUsers = @()
	$failedUsers = @()

	for ($i = 0; $i -lt $users.Count; $i++) {
		$user = $users[$i]
		$deleteUri = "https://graph.microsoft.com/v1.0/users/$($user.id)"

		try {
			$requestHeaders = $baseHeaders.Clone()
			$requestHeaders['Request-Id'] = [guid]::NewGuid().ToString()

			Write-Verbose "Deleting user: $($user.userPrincipalName) [ID: $($user.id)]"
			$response = Invoke-GraphRequest -Uri $deleteUri -Method 'DELETE' -Headers $requestHeaders

			$deletedUsers += [PSCustomObject]@{
				id = $user.id
				userPrincipalName = $user.userPrincipalName
				status = 204
			}

			Write-Host "[$($i + 1)/$($users.Count)] Deleted: $($user.userPrincipalName)"

		} catch {
			$errorMsg = $_.Exception.Message

			# Check for 404 (user not found)
			if ($errorMsg -match '404|not found') {
				$skippedUsers += [PSCustomObject]@{
					id = $user.id
					userPrincipalName = $user.userPrincipalName
					status = 404
					reason = 'User not found'
				}
				Write-Host "[$($i + 1)/$($users.Count)] Skipped (404): $($user.userPrincipalName)"
			} else {
				$failedUsers += [PSCustomObject]@{
					id = $user.id
					userPrincipalName = $user.userPrincipalName
					status = 'Error'
					reason = $errorMsg
				}
				Write-Host "[$($i + 1)/$($users.Count)] Failed: $($user.userPrincipalName) - $errorMsg"
			}
		}
	}

	return [PSCustomObject]@{
		Deleted = $deletedUsers
		Skipped = $skippedUsers
		Failed = $failedUsers
	}
}

$result = Remove-TestUsers
Write-Host "Done. Deleted $($result.Deleted.Count) user(s), skipped $($result.Skipped.Count), failed $($result.Failed.Count)."

if ($result.Failed.Count -gt 0) {
	Write-Warning 'Some users failed to delete. First 20 failures:'
	$result.Failed | Select-Object -First 20 | ForEach-Object {
		Write-Warning " - $($_.userPrincipalName): $($_.reason)"
	}
}

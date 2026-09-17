[CmdletBinding()]
param()

$UserPrincipalNamePrefix = 'test.user'

function Remove-TestUsers {
	[CmdletBinding()]
	param()

	$token = Get-GraphToken
	$headers = @{
		Authorization = "Bearer $token"
		'Content-Type' = 'application/json'
		'User-Agent' = 'M365TenantIntelligence/1.0 (PowerShell; M365 User Cleanup)'
	}

	$usersUri = "https://graph.microsoft.com/v1.0/users?`$select=id,userPrincipalName&`$filter=startsWith(userPrincipalName,'$UserPrincipalNamePrefix')&`$top=999"
	$users = @(Invoke-GraphPagedRequest -Uri $usersUri -Headers $headers)

	if ($users.Count -eq 0) {
		Write-Verbose "No users found with prefix '$UserPrincipalNamePrefix'."
		return [PSCustomObject]@{
			Deleted = @()
			Failed = @()
		}
	}

	Write-Verbose "Found $($users.Count) user(s) with prefix '$UserPrincipalNamePrefix'. Deleting one-by-one..."

	$deletedUsers = @()
	$failedUsers = @()

	for ($i = 0; $i -lt $users.Count; $i++) {
		$user = $users[$i]
		$deleteUri = "https://graph.microsoft.com/v1.0/users/$($user.id)"

		try {
			Write-Verbose "Deleting user: $($user.userPrincipalName) [ID: $($user.id)]"
			Invoke-GraphRequestWithRetry -Uri $deleteUri -Method 'DELETE' -Headers $headers

			$deletedUsers += [PSCustomObject]@{
				id = $user.id
				userPrincipalName = $user.userPrincipalName
			}

			Write-Verbose "[$($i + 1)/$($users.Count)] Deleted: $($user.userPrincipalName), trying to remove it from deleted users."

		} catch {
			$errorMsg = $_.Exception.Message
			Write-Error "Error deleting user: $($user.userPrincipalName) [ID: $($user.id)] - $errorMsg"
			Write-Verbose "Exception: $($_.Exception)"

			$failedUsers += [PSCustomObject]@{
				id = $user.id
				userPrincipalName = $user.userPrincipalName
				reason = $errorMsg
			}
		}
	}

	return [PSCustomObject]@{
		Deleted = $deletedUsers
		Failed = $failedUsers
	}
}

$result = Remove-TestUsers
Write-Verbose "Done. Deleted $($result.Deleted.Count) user(s), failed $($result.Failed.Count)."

if ($result.Failed.Count -gt 0) {
	Write-Warning 'Some users failed to delete. First 20 failures:'
	$result.Failed | Select-Object -First 20 | ForEach-Object {
		Write-Warning " - $($_.userPrincipalName): $($_.reason)"
	}
}

[CmdletBinding()]
param()

function Remove-TestUsersPermanently {
	[CmdletBinding()]
	param()

	$token = Get-GraphToken
	$headers = @{
		Authorization = "Bearer $token"
		'Content-Type' = 'application/json'
		'User-Agent' = 'M365TenantIntelligence/1.0 (PowerShell; M365 User Cleanup)'
	}

	$deletedUsersUri = "https://graph.microsoft.com/v1.0/directory/deletedItems/microsoft.graph.user"
	$deletedUsers = @(Invoke-GraphPagedRequest -Uri $deletedUsersUri -Headers $headers)

	if ($deletedUsers.Count -eq 0) {
		Write-Verbose "No deleted users found"
		return [PSCustomObject]@{
			Deleted = @()
			Failed = @()
		}
	}

	Write-Verbose "Found $($deletedUsers.Count) deleted user(s). Deleting one-by-one..."
	$succeed = @()
	$failed = @()

	for ($i = 0; $i -lt $deletedUsers.Count; $i++) {
		$user = $deletedUsers[$i]
		$permanentDeleteUri = "https://graph.microsoft.com/v1.0/directory/deletedItems/$($user.id)"

		try {
			Write-Verbose "Permanently deleting user: $($user.userPrincipalName) [ID: $($user.id)]"
			Invoke-GraphRequestWithRetry -Uri $permanentDeleteUri -Method 'DELETE' -Headers $headers

			$succeed += [PSCustomObject]@{
				id = $user.id
				userPrincipalName = $user.userPrincipalName
			}

			Write-Verbose "[$($i + 1)/$($deletedUsers.Count)] Permanently deleted: $($user.userPrincipalName)"

		} catch {
			$errorMsg = $_.Exception.Message
			Write-Error "Error permanently deleting user: $($user.userPrincipalName) [ID: $($user.id)] - $errorMsg"
			Write-Verbose "Exception: $($_.Exception)"

			$failed += [PSCustomObject]@{
				id = $user.id
				userPrincipalName = $user.userPrincipalName
				reason = $errorMsg
			}
		}
	}

	return [PSCustomObject]@{
		Deleted = $succeed
		Failed = $failed
	}
}

$result = Remove-TestUsersPermanently
Write-Verbose "Done. Deleted $($result.Deleted.Count) user(s), failed $($result.Failed.Count)."

if ($result.Failed.Count -gt 0) {
	Write-Warning 'Some users failed to delete. First 20 failures:'
	$result.Failed | Select-Object -First 20 | ForEach-Object {
		Write-Warning " - $($_.userPrincipalName): $($_.reason)"
	}
}

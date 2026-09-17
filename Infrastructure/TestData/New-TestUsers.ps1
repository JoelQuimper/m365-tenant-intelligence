[CmdletBinding()]
param(
	[Parameter(Mandatory = $false)]
	[ValidateRange(1, 100000)]
	[int]$Count = 11000,

	[Parameter(Mandatory = $false)]
	[ValidateRange(1, 1000000)]
	[int]$StartNumber = 39020
)

# Import required modules
$projectRoot = "C:\src\public-github\m365-tenant-intelligence"
Import-Module -Name "$projectRoot\Automations\Common\GraphClient\GraphClient.psm1" -Force
Import-Module -Name "$projectRoot\Automations\Common\StorageClient\StorageClient.psm1" -Force

# Source the Set-DeveloperContext to load environment variables
. "$projectRoot\Automations\Set-DeveloperContext.ps1"

$MaxRequestRetries = 8

function Get-DefaultTenantDomain {
	[CmdletBinding()]
	param(
		[Parameter(Mandatory = $true)]
		[hashtable]$Headers
	)

	$org = Invoke-GraphPagedRequest -Uri 'https://graph.microsoft.com/v1.0/organization?$select=verifiedDomains' -Headers $Headers
	$verifiedDomains = @($org[0].verifiedDomains)

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

function Invoke-UserCreateWithRetry {
	[CmdletBinding()]
	param(
		[Parameter(Mandatory = $true)]
		[hashtable]$Headers,

		[Parameter(Mandatory = $true)]
		[string]$UserPrincipalName,

		[Parameter(Mandatory = $true)]
		[hashtable]$Body,

		[Parameter(Mandatory = $true)]
		[ValidateRange(1, 20)]
		[int]$MaxRetries
	)

	try {
		$response = Invoke-GraphRequestWithRetry -Method 'POST' -Uri 'https://graph.microsoft.com/v1.0/users' -Headers $Headers -Body $Body -MaxRetries $MaxRetries
		return [PSCustomObject]@{
			Status = 'Created'
			UserPrincipalName = [string]$response.userPrincipalName
			Reason = $null
		}
	}
	catch {
		$statusCode = 0
		if ($null -ne $_.Exception.Response) {
			try {
				$statusCode = [int]$_.Exception.Response.StatusCode
			} catch {
				$statusCode = 0
			}
		}

		$message = [string]$_.Exception.Message
		if ($statusCode -eq 409 -or ($statusCode -eq 400 -and $message -match 'already exists')) {
			return [PSCustomObject]@{
				Status = 'Skipped'
				UserPrincipalName = $UserPrincipalName
				Reason = 'User already exists.'
			}
		}

		return [PSCustomObject]@{
			Status = 'Failed'
			UserPrincipalName = $UserPrincipalName
			Reason = "HTTP ${statusCode}: $message"
		}
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

	$MaxRequestRetries = $script:MaxRequestRetries

	$token = Get-GraphToken
	$headers = @{
		Authorization = "Bearer $token"
		'Content-Type' = 'application/json'
	}

	$tenantDomain = Get-DefaultTenantDomain -Headers $headers

	Write-Verbose "Using tenant domain: $tenantDomain"
	Write-Verbose "Creating $Count test user(s) using per-user Graph requests with retry"

	$createdUsers = @()
	$skippedUsers = @()
	$failedUsers = @()

	for ($i = 0; $i -lt $Count; $i++) {
		$n = $StartNumber + $i
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

		$createResult = Invoke-UserCreateWithRetry -Headers $headers -UserPrincipalName $userPrincipalName -Body $body -MaxRetries $MaxRequestRetries
		if ($createResult.Status -eq 'Created') {
			$createdUsers += [PSCustomObject]@{ userPrincipalName = $createResult.UserPrincipalName }
		} elseif ($createResult.Status -eq 'Skipped') {
			$skippedUsers += [PSCustomObject]@{ userPrincipalName = $createResult.UserPrincipalName; reason = $createResult.Reason }
		} else {
			$failedUsers += [PSCustomObject]@{ userPrincipalName = $createResult.UserPrincipalName; reason = $createResult.Reason }
		}

		$processed = $i + 1
		Write-Verbose "Progress: $processed/$Count processed | Created: $($createdUsers.Count) | Skipped: $($skippedUsers.Count) | Failed: $($failedUsers.Count)"
	}

	return [PSCustomObject]@{
		Created = $createdUsers
		Skipped = $skippedUsers
		Failed = $failedUsers
	}
}

$result = New-TestUsers -Count $Count -StartNumber $StartNumber
Write-Verbose "Done. Created $($result.Created.Count) user(s), skipped $($result.Skipped.Count), failed $($result.Failed.Count)."

if ($result.Failed.Count -gt 0) {
	Write-Warning 'Some users failed to create. First 20 failures:'
	$result.Failed | Select-Object -First 20 | ForEach-Object {
		Write-Warning " - $($_.userPrincipalName): $($_.reason)"
	}
}

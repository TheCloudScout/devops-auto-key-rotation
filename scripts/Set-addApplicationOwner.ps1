<#
.DESCRIPTION
    This script will add the Service Principal of the Application as Owner of the Application.
    It performs the following steps:
    - Login to the graph.microsoft.com
    - Validate the Application Id
    - Retrieve the current owner(s)
    - Add if applicable the application delegation for graph.microsoft.com/Application.ReadWrite.OwnedBy
    - Perform if applicable the admin consent for the application delegation graph.microsoft.com/Application.ReadWrite.OwnedBy
    - Add if applicable the service principal to the application as owner
    Required permissions:
    - Global Administrator (or the following permissions)
        - Application.ReadWrite.All
        - Directory.Read.All
        - AppRoleAssignment.ReadWrite.All

.PARAMETER TenantId <String>
    The tenant id which contains the Azure AD Application.

.PARAMETER ApplicationId <String>
    The AppId of the Application which will add itself as it's owner.
#>
[CmdletBinding()]
param (
    [Parameter (Mandatory = $true)]
    [String] $TenantId,

    [Parameter (Mandatory = $true)]
    [String] $ApplicationId
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$authority = "https://login.microsoftonline.com"
$clientId = "1950a258-227b-4e31-a9cf-717495945fc2"

$params = @{
    "Method" = "Post"
    "Uri"    = "$($authority)/$($TenantId)/oauth2/devicecode"
    "Body"   = @{
        "client_id"         = $clientId
        "ClientRedirectUri" = "urn:ietf:wg:oauth:2.0:oob"
        "Resource"          = "https://graph.microsoft.com/"
        "ValidateAuthority" = "True"
    }
}
$request = Invoke-RestMethod @params
Write-Host "Validation url: $($request.verification_url)"
Write-Host "Validation code: $($request.user_code)"
Set-Clipboard -Value $request.user_code
$params = @{
    "Method" = "Post"
    "Uri"    = "$($authority)/$($TenantId)/oauth2/token"
    "body"   = @{
        "grant_type" = "urn:ietf:params:oauth:grant-type:device_code"
        "code"       = $request.device_code
        "client_id"  = $clientId
    }
}
$timeoutTimer = [System.Diagnostics.Stopwatch]::StartNew()
do {
    Start-Sleep -Seconds 1
    $token = $null
    if ($timeoutTimer.Elapsed.TotalSeconds -ge $request.expires_in) {
        throw "Login timed out, please try again."
    }
    try {
        $token = Invoke-RestMethod @params
    } catch {
        $message = $_.ErrorDetails.Message | ConvertFrom-Json
        if ($message.error -ne "authorization_pending") {
            throw
        }
    }
} while ([System.String]::IsNullOrWhiteSpace($token) -or [System.String]::IsNullOrWhiteSpace($token.access_token))
$timeoutTimer.Stop()
$token = Invoke-RestMethod @params
$headers = @{
    "Content-Type"  = "application/json"
    "Authorization" = "$($token.token_type) $($token.access_token)"
}
# Retrieve application
Write-Host "Retrieve application with appId $($ApplicationId)"
$params = @{
    "Method"  = "Get"
    "Uri"     = "https://graph.microsoft.com/v1.0/applications?`$filter=appId eq '$($ApplicationId)'"
    "Headers" = $headers
}
$applications = Invoke-RestMethod @params -UseBasicParsing
# Validate application found
if ($applications.value.Count -ne 1) {
    Write-Error "Found $($applications.value.Count) applications with appId '$($ApplicationId)'"
}
# Retrieve application details
$params = @{
    "Method"  = "Get"
    "Uri"     = "https://graph.microsoft.com/v1.0/applications/$($applications.value[0].id)"
    "Headers" = $headers
}
$application = Invoke-RestMethod @params -UseBasicParsing
Write-Host "Found application with appId '$($application.appId)', objectId '$($application.id)' and displayName '$($application.displayName)'"
# Retrieve application owners
Write-Host "Retrieve current application owners"
$params = @{
    "Method"  = "Get"
    "Uri"     = "https://graph.microsoft.com/v1.0/applications/$($application.id)/owners"
    "Headers" = $headers
}
$applicationOwners = Invoke-RestMethod @params -UseBasicParsing
# Retrieve Service Principal
Write-Host "Retrieve associated Service Principal"
$params = @{
    "Method"  = "Get"
    "Uri"     = "https://graph.microsoft.com/v1.0/servicePrincipals?`$filter=appId eq '$($ApplicationId)'"
    "Headers" = $headers
}
$servicePrincipals = Invoke-RestMethod @params -UseBasicParsing
$servicePrincipalId = $servicePrincipals.value[0].id
# Get the Service Principal for Admin Consent
Write-Host "Retrieve details for admin consent"
$params = @{
    "Method"  = "Get"
    "Uri"     = "https://graph.microsoft.com/v1.0/servicePrincipals?`$filter=displayName eq 'Microsoft Graph'"
    "Headers" = $headers
}
$servicePrincipals = Invoke-RestMethod @params -UseBasicParsing
if ($servicePrincipals.value.Count -eq 1) {
    $graphPrincipal = $servicePrincipals.value[0]
    if ($appRole = ($graphPrincipal.appRoles | Where-Object -FilterScript { $_.value -eq "Application.ReadWrite.OwnedBy" })) {
        $updateApp = $false
        if ($resourceAccess = ($application.requiredResourceAccess | Where-Object -FilterScript { $_.resourceAppId -eq $graphPrincipal.appId })) {
            if ($null -eq ($resourceAccess.resourceAccess | Where-Object -FilterScript { $_.type -eq "Role" -and $_.id -eq $appRole.id })) {
                Write-Host "Add 'Microsoft Graph' with the delegated role 'Application.ReadWrite.OwnedBy'"
                $resourceAccessItem = [PSCustomObject]@{
                    "id"   = $appRole.id
                    "type" = "Role"
                }
                $application.requiredResourceAccess[$application.requiredResourceAccess.resourceAppId.IndexOf($graphPrincipal.appId)].resourceAccess += $resourceAccessItem
                $updateApp = $true
            }
        }
        if ($null -eq ($application.requiredResourceAccess | Where-Object -FilterScript { $_.resourceAppId -eq $graphPrincipal.appId -and $_.resourceAccess.id -eq $appRole.id })) {
            Write-Host "Add 'Microsoft Graph' and the delegated role 'Application.ReadWrite.OwnedBy'"
            $resourceAccessItem = [PSCustomObject]@{
                "resourceAppId"  = $graphPrincipal.appId
                "resourceAccess" = @(
                    [PSCustomObject]@{
                        "id"   = $appRole.id
                        "type" = "Role"
                    }
                )
            }
            $application.requiredResourceAccess += $resourceAccessItem
            $updateApp = $true
        }
        if ($updateApp) {
            Write-Host "Update the current application with the added role delegation"
            $application = $application | Select-Object -Property "id", "appId", "displayName", "identifierUris", "requiredResourceAccess"
            $params = @{
                "Method"  = "Patch"
                "Uri"     = "https://graph.microsoft.com/v1.0/applications/$($application.id)"
                "Body"    = $application | ConvertTo-Json -Compress -Depth 99
                "Headers" = $headers
            }
            $update = Invoke-WebRequest @params -UseBasicParsing
            if ($update.StatusCode -eq 204) {
                Write-Host "Added application delegation"
                Write-Host "Verify the delegation and admin consent within the portal"
                Write-Host "https://portal.azure.com/#blade/Microsoft_AAD_RegisteredApps/ApplicationMenuBlade/CallAnAPI/appId/$($application.appId)/isMSAApp/"
            }
        }
        # Retrieve delegations
        $params = @{
            "Method"  = "Get"
            "Uri"     = "https://graph.microsoft.com/v1.0/servicePrincipals/$($servicePrincipalId)/appRoleAssignments"
            "Headers" = $headers
        }
        $delegations = Invoke-RestMethod @params -UseBasicParsing
        if ($null -eq ($delegations.value | Where-Object -FilterScript { $_.principalId -eq $servicePrincipalId -and $_.resourceId -eq $graphPrincipal.id -and $_.appRoleId -eq $appRole.id })) {
            Write-Host "Add application admin consent"
            $params = @{
                "Method"  = "Post"
                "Uri"     = "https://graph.microsoft.com/v1.0/servicePrincipals/$($servicePrincipalId)/appRoleAssignments"
                "Body"    = @{
                    "principalId" = $servicePrincipalId
                    "resourceId"  = $graphPrincipal.id
                    "appRoleId"   = $appRole.id
                } | ConvertTo-Json -Compress
                "Headers" = $headers
            }
            try {
                $delegation = Invoke-RestMethod @params -UseBasicParsing
                Write-Host "Added application admin consent with id '$($delegation.id)'"
            } catch {
                Write-Host "Failed to perform the admin consent" -ForegroundColor Red
            }
        } else {
            Write-Host "Application admin consent exists"
        }
    } else {
        Write-Host "Application role 'Application.ReadWrite.OwnedBy' not found within the 'Microsoft Graph'" -ForegroundColor Yellow
    }
} else {
    Write-Host "Service Principal with displayName 'Microsoft Graph' not found" -ForegroundColor Yellow
}
# Validate if already owner
if ($null -ne ($applicationOwners.value | Where-Object -FilterScript { $_.id -eq $servicePrincipalId })) {
    Write-Host "Application already owner of itself"
    return
}
# Add Service Principal as Owner of the Application
$params = @{
    "Method"  = "Post"
    "Uri"     = "https://graph.microsoft.com/v1.0/applications/$($applications.value[0].id)/owners/`$ref"
    "Body"    = @{
        "@odata.id" = "https://graph.microsoft.com/v1.0/directoryObjects/$($servicePrincipalId)"
    } | ConvertTo-Json -Compress
    "Headers" = $headers
}
$result = Invoke-WebRequest @params -UseBasicParsing
if ($result.StatusCode -eq 204) {
    Write-Host "Owner added to the application"
} else {
    Write-Host "Failed to add owner to the application"
}

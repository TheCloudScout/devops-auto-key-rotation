# Add application owner

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
$request = Invoke-RestMethod @params
Write-Host ""
Write-Host "Please open your browser and open the folowing URL:"
Write-Host $request.verification_url
Write-Host "Paste the following code in the window $($request.user_code)"
Write-Host ""
Set-Clipboard -Value $request.user_code

$params = @{
    "Method" = "Post"
    "Uri"    = "$($authority)/$($tenantId)/oauth2/token"
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
        $message = $_.ErrorDetails.Message | Convertfrom-Json
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
# Retrieve application owners
$params = @{
    "Method"  = "Get"
    "Uri"     = "https://graph.microsoft.com/v1.0/applications/$($application.id)/owners"
    "Headers" = $headers
}
$applicationOwners = Invoke-RestMethod @params -UseBasicParsing
# Retrieve Service Principal
$params = @{
    "Method"  = "Get"
    "Uri"     = "https://graph.microsoft.com/v1.0/servicePrincipals?`$filter=appId eq '$($ApplicationId)'"
    "Headers" = $headers
}
$servicePrincipals = Invoke-RestMethod @params -UseBasicParsing
$servicePrincipalId = $servicePrincipals.value[0].id
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
    Write-Host "Ownership succesfully applied to app registration" -ForegroundColor Green }

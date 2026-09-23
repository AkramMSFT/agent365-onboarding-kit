param([string] $ManagementClientAppId)

$ErrorActionPreference = 'Stop'
$settings = Get-Content (Join-Path $PSScriptRoot 'appsettings.json') -Raw | ConvertFrom-Json
$local = Get-Content (Join-Path $PSScriptRoot '.a365-runtime.local.json') -Raw | ConvertFrom-Json
if (-not $ManagementClientAppId) { $ManagementClientAppId = $local.Agent365Local.OperatorClientAppId }
if (-not $ManagementClientAppId) { throw 'Initialize a reviewed OperatorClientAppId first.' }
$tenant = $settings.Agent365Observability.TenantId
$runtimeApp = $local.Agent365Observability.AgentId
if (-not $runtimeApp) { $runtimeApp = $settings.Agent365Observability.AgentId }
Set-Location $PSScriptRoot
$accountText = & az account show -o json
if ($LASTEXITCODE -ne 0) { throw 'Azure CLI sign-in is required.' }
$account = $accountText | ConvertFrom-Json
if ($account.user.name -ine $local.Agent365Local.UserPrincipalName -or $account.tenantId -ine $tenant) {
    throw 'Azure CLI account does not match the configured owner and tenant.'
}
$captured = [System.Collections.Generic.List[string]]::new()
& a365 develop get-token --app-id $ManagementClientAppId `
    --resource-id 00000003-0000-0000-c000-000000000000 `
    --scopes DelegatedPermissionGrant.ReadWrite.All Application.Read.All User.Read `
    --output raw --device-code 2>&1 | ForEach-Object {
    $line = "$_"
    $jwt = [regex]::Match($line, 'eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+')
    if ($jwt.Success) { $captured.Add($jwt.Value) }
    else { Write-Host $line }
}
if ($LASTEXITCODE -ne 0 -or $captured.Count -ne 1) { throw 'Management token acquisition failed.' }
$payload = $captured[0].Split('.')[1].Replace('-', '+').Replace('_', '/')
$payload = $payload.PadRight([int]([Math]::Ceiling($payload.Length / 4.0) * 4), '=')
$claims = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($payload)) | ConvertFrom-Json
if ($claims.tid -ine $tenant -or $claims.oid -ine $local.Agent365Local.UserId -or
    'DelegatedPermissionGrant.ReadWrite.All' -cnotin ($claims.scp -split ' ')) {
    throw 'Management token identity or grant-management permission does not match.'
}
$secureToken = ConvertTo-SecureString $captured[0] -AsPlainText -Force
Connect-MgGraph -AccessToken $secureToken -NoWelcome
try {
    $context = Get-MgContext
    $me = Invoke-MgGraphRequest -Method GET -Uri 'https://graph.microsoft.com/v1.0/me?$select=id,userPrincipalName'
    if (($context.TenantId -and $context.TenantId -ine $tenant) -or $me.id -ine $local.Agent365Local.UserId -or
        $me.userPrincipalName -ine $local.Agent365Local.UserPrincipalName) {
        throw 'Management sign-in does not match the configured tenant and owner.'
    }
    $graph = 'https://graph.microsoft.com/v1.0'
    $clients = Invoke-MgGraphRequest -Method GET -Uri "$graph/servicePrincipals?`$filter=appId eq '$runtimeApp'&`$select=id,appId"
    $resources = Invoke-MgGraphRequest -Method GET -Uri "$graph/servicePrincipals?`$filter=appId eq '00000003-0000-0000-c000-000000000000'&`$select=id"
    if (@($clients.value).Count -ne 1 -or @($resources.value).Count -ne 1) { throw 'Runtime or Graph service principal is ambiguous or missing.' }
    $client = $clients.value[0].id
    $resource = $resources.value[0].id
    $response = Invoke-MgGraphRequest -Method GET -Uri "$graph/servicePrincipals/$client/oauth2PermissionGrants"
    $existing = @($response.value | Where-Object { $_.resourceId -eq $resource -and $_.consentType -eq 'AllPrincipals' })
    if ($existing.Count -gt 1) { throw 'Multiple tenant-wide Graph grants found; no changes made.' }
    $scopes = @('ProtectionScopes.Compute.User', 'Content.Process.User')
    if ($existing.Count) { $scopes += $existing[0].scope -split '\s+' | Where-Object { $_ } }
    $scope = ($scopes | Sort-Object -Unique) -join ' '
    if ($existing.Count) {
        Invoke-MgGraphRequest -Method PATCH -Uri "$graph/oauth2PermissionGrants/$($existing[0].id)" `
            -ContentType 'application/json' -Body (@{ scope=$scope } | ConvertTo-Json) | Out-Null
    }
    else {
        $body = @{ clientId=$client; resourceId=$resource; consentType='AllPrincipals'; principalId=$null; scope=$scope }
        Invoke-MgGraphRequest -Method POST -Uri "$graph/oauth2PermissionGrants" `
            -ContentType 'application/json' -Body ($body | ConvertTo-Json) | Out-Null
    }
    $verified = Invoke-MgGraphRequest -Method GET -Uri "$graph/servicePrincipals/$client/oauth2PermissionGrants"
    $grant = @($verified.value | Where-Object { $_.resourceId -eq $resource -and $_.consentType -eq 'AllPrincipals' })
    if ($grant.Count -ne 1 -or 'ProtectionScopes.Compute.User' -cnotin ($grant[0].scope -split ' ') -or
        'Content.Process.User' -cnotin ($grant[0].scope -split ' ')) { throw 'Purview grant verification failed.' }
    Write-Output "Runtime OAuth client: $runtimeApp"
    Write-Output "Verified delegated Graph scopes: $($grant[0].scope)"
}
finally { Disconnect-MgGraph | Out-Null }

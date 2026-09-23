param(
    [string] $ClientAppId,
    [switch] $TelemetryOnly,
    [string[]] $Servers = @(),
    [switch] $PlanOnly
)

$ErrorActionPreference = 'Stop'
Set-Location $PSScriptRoot
$local = Get-Content '.a365-runtime.local.json' -Raw | ConvertFrom-Json
if (-not $ClientAppId) { $ClientAppId = $local.Agent365Local.OperatorClientAppId }
if (-not $ClientAppId) { throw 'Initialize a reviewed OperatorClientAppId first.' }
$settings = Get-Content 'appsettings.json' -Raw | ConvertFrom-Json
$manifest = Get-Content 'ToolingManifest.json' -Raw | ConvertFrom-Json
. (Join-Path $PSScriptRoot 'Agent365TokenPlan.ps1')
$managedServers = @(if ($local.Agent365Local.UseAgentMailboxForMail) { 'mcp_MailTools' })
$resources = @(Get-Agent365TokenTargets -McpServers $manifest.mcpServers `
    -BlueprintId $settings.Agent365Observability.AgentBlueprintId -Servers $Servers `
    -DisabledServers @($local.Agent365Local.DisabledWorkIqServers) -ManagedServers $managedServers -TelemetryOnly:$TelemetryOnly)
if ($PlanOnly) {
    $resources | ConvertTo-Json -Depth 4
    return
}
$accountText = & az account show --output json
if ($LASTEXITCODE -ne 0) { throw 'Sign in to Azure CLI before refreshing Agent 365 tokens.' }
$account = $accountText | ConvertFrom-Json
if ($account.user.name -ine $local.Agent365Local.UserPrincipalName -or
    $account.tenantId -ine $settings.Agent365Observability.TenantId) {
    throw "Azure CLI must use $($local.Agent365Local.UserPrincipalName) in the configured tenant."
}
$tokens = @{}
$tokenPath = Join-Path $PSScriptRoot '.a365-tokens.local.json'
if (Test-Path -LiteralPath $tokenPath) {
    $tokens = Get-Content -LiteralPath $tokenPath -Raw | ConvertFrom-Json -AsHashtable
}

foreach ($resource in $resources) {
    Write-Host "Authorizing $($resource.Name) as $($local.Agent365Local.UserPrincipalName)"
    $captured = [System.Collections.Generic.List[string]]::new()
    $arguments = @('develop', 'get-token', '--app-id', $ClientAppId, '--resource-id', $resource.Audience,
        '--scopes') + @($resource.Scopes) + @('--output', 'raw', '--device-code')
    & a365 @arguments 2>&1 | ForEach-Object {
        $line = "$_"
        $jwt = [regex]::Match($line, 'eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+')
        if ($jwt.Success) { $captured.Add($jwt.Value) }
        else { Write-Host $line }
    }
    if ($LASTEXITCODE -ne 0 -or $captured.Count -ne 1) {
        throw "Could not acquire exactly one token for $($resource.Name). Previously saved tokens were retained."
    }
    $token = $captured[0]
    $payload = $token.Split('.')[1].Replace('-', '+').Replace('_', '/')
    $payload = $payload.PadRight([int]([Math]::Ceiling($payload.Length / 4.0) * 4), '=')
    $claims = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($payload)) | ConvertFrom-Json
    $upn = @($claims.preferred_username, $claims.upn, $claims.unique_name) |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -First 1
    $audience = ($claims.aud -replace '^api://', '').TrimEnd('/')
    if ($claims.tid -ine $account.tenantId -or
        $claims.oid -ine $local.Agent365Local.UserId -or
        ($upn -and $upn -ine $local.Agent365Local.UserPrincipalName) -or
        $audience -ine $resource.Audience -or
        @($resource.Scopes | Where-Object { $_ -cnotin ($claims.scp -split ' ') }).Count -gt 0 -or
        [long]$claims.exp -le [DateTimeOffset]::UtcNow.AddMinutes(2).ToUnixTimeSeconds()) {
        throw "Token identity, audience, scope or expiry did not match $($resource.Name); it was not saved."
    }
    $tokens[$resource.Audience] = $token
    $tempPath = "$tokenPath.tmp"
    try {
        [IO.File]::WriteAllText($tempPath, ($tokens | ConvertTo-Json), [Text.UTF8Encoding]::new($false))
        Move-Item -LiteralPath $tempPath -Destination $tokenPath -Force
    }
    finally {
        if (Test-Path -LiteralPath $tempPath) { Remove-Item -LiteralPath $tempPath }
    }
    Write-Host "Saved $($resource.Name) token locally; expiry $([DateTimeOffset]::FromUnixTimeSeconds($claims.exp).ToString('o'))."
}
Write-Host 'Tokens saved. Run: dotnet run -- --a365-check'

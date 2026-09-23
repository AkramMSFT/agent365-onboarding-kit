param(
    [Parameter(Mandatory)][string] $ExpectedUser,
    [string] $AgentIdentityId,
    [string] $OperatorClientAppId,
    [string] $AgentMailboxUserId
)
$ErrorActionPreference = 'Stop'
Set-Location $PSScriptRoot
if (Test-Path '.a365-runtime.local.json') { throw 'Local runtime config already exists. Review it rather than overwriting local identity choices.' }
function Read-AzJson {
    param([string[]] $Arguments)
    $result = & az @Arguments
    if ($LASTEXITCODE -ne 0) { throw "Azure read failed: $($Arguments[0])" }
    return ($result | ConvertFrom-Json)
}
$account = Read-AzJson @('account','show','-o','json')
$me = Read-AzJson @('ad','signed-in-user','show','-o','json')
if ($me.userPrincipalName -ine $ExpectedUser -or $account.user.name -ine $ExpectedUser) { throw 'Azure CLI is signed into a different account.' }
$generated = Get-Content 'a365.generated.config.json' -Raw | ConvertFrom-Json
$registration = Get-Content 'a365.config.json' -Raw | ConvertFrom-Json
if ($registration.tenantId -and $registration.tenantId -ne $account.tenantId) { throw 'Azure CLI tenant differs from the registered project tenant.' }
$blueprint = $generated.agentBlueprintId
$parsed = [guid]::Empty
if (-not [guid]::TryParse($blueprint, [ref]$parsed)) { throw 'Run Agent 365 registration first; no valid blueprint ID was generated.' }
if (-not $AgentIdentityId) { $AgentIdentityId = $generated.agenticAppId }
if (-not $AgentIdentityId -or $AgentIdentityId -eq $blueprint) {
    throw 'Supply -AgentIdentityId with the verified child agent appId. Do not substitute the blueprint ID after CLI restamping.'
}
$identity = Read-AzJson @('rest','--method','get','--url',"https://graph.microsoft.com/beta/servicePrincipals/$AgentIdentityId",'-o','json')
if ($identity.agentIdentityBlueprintId -ne $blueprint -or $identity.servicePrincipalType -ne 'ServiceIdentity') {
    throw 'The selected identity is not a child of this blueprint.'
}
if (-not $OperatorClientAppId) {
    $apps = @(Read-AzJson @('ad','app','list','--display-name','Agent 365 CLI','-o','json'))
    if ($apps.Count -ne 1) { throw 'Specify -OperatorClientAppId for the reviewed tenant-owned public client; no unique Agent 365 CLI app was found.' }
    $OperatorClientAppId = $apps[0].appId
}
$operatorApp = Read-AzJson @('ad','app','show','--id',$OperatorClientAppId,'-o','json')
if (-not $operatorApp.isFallbackPublicClient) { throw 'The operator client must be a reviewed public client supporting device-code authentication.' }
$local = @{
    Agent365Local = @{
        UserId=$me.id; UserPrincipalName=$me.userPrincipalName; OperatorClientAppId=$OperatorClientAppId
        DisabledWorkIqServers=@(); UseAgentMailboxForMail=$false
    }
    Agent365Observability = @{ AgentId=$identity.appId; AgentName=$identity.displayName }
    Connections = @{ ServiceConnection = @{ Settings = @{ AgentId=$identity.appId } } }
}
if ($AgentMailboxUserId) {
    $mailUser = Read-AzJson @('rest','--method','get','--url',"https://graph.microsoft.com/beta/users/$AgentMailboxUserId",'-o','json')
    if (-not $mailUser.identityParentId -or -not $mailUser.userPrincipalName -or -not $mailUser.mail) { throw 'Agent user linkage or mailbox address is missing.' }
    $mailIdentity = Read-AzJson @('rest','--method','get','--url',"https://graph.microsoft.com/beta/servicePrincipals/$($mailUser.identityParentId)",'-o','json')
    if ($mailIdentity.agentIdentityBlueprintId -ne $blueprint) { throw 'Agent mailbox belongs to a different blueprint.' }
    $local.Agent365Local.UseAgentMailboxForMail = $true
    $local.Agent365Local.AgentMailbox = @{
        AgentIdentityId=$mailIdentity.appId; UserId=$mailUser.id; UserPrincipalName=$mailUser.userPrincipalName
    }
}
[IO.File]::WriteAllText((Join-Path $PSScriptRoot '.a365-runtime.local.json'),
    ($local | ConvertTo-Json -Depth 8), [Text.UTF8Encoding]::new($false))
Write-Output "Created local identity configuration for $ExpectedUser. No generated identity file or .env was modified."

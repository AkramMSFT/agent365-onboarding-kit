param(
    [Parameter(Mandatory)][string] $Sender,
    [Parameter(Mandatory)][string] $Recipient,
    [Parameter(Mandatory)][string] $MessageId,
    [Parameter(Mandatory)][DateTimeOffset] $SentAt
)
$ErrorActionPreference = 'Stop'
$local = Get-Content (Join-Path $PSScriptRoot '.a365-runtime.local.json') -Raw | ConvertFrom-Json
$settings = Get-Content (Join-Path $PSScriptRoot 'appsettings.json') -Raw | ConvertFrom-Json
$start = $SentAt.AddMinutes(-10).UtcDateTime
$end = [DateTime]::UtcNow
if ($end -gt $start.AddDays(1)) { $end = $start.AddDays(1) }
if ($end -le $start) { throw 'The sent time is in the future.' }
Import-Module ExchangeOnlineManagement
Connect-ExchangeOnline -Device -ShowBanner:$false
try {
    if (-not @(Get-ConnectionInformation | Where-Object {
        $_.UserPrincipalName -ieq $local.Agent365Local.UserPrincipalName -and $_.TenantID -eq $settings.Agent365Observability.TenantId
    }).Count) { throw 'Exchange sign-in does not match the configured operator and tenant.' }
    $traces = @(Get-MessageTraceV2 -SenderAddress $Sender -RecipientAddress $Recipient -MessageId $MessageId `
        -StartDate $start -EndDate $end -ResultSize 10)
    if (-not $traces.Count) { Write-Output 'No exact trace found yet; this does not prove delivery.'; return }
    $traces | Format-List Received,SenderAddress,RecipientAddress,Subject,Status,MessageTraceId,MessageId
    foreach ($trace in $traces) {
        Get-MessageTraceDetailV2 -MessageTraceId $trace.MessageTraceId -RecipientAddress $Recipient `
            -StartDate $start -EndDate $end | Format-List Date,Event,Action,Detail
    }
}
finally { Disconnect-ExchangeOnline -Confirm:$false }

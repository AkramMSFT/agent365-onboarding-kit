$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Agent365TokenPlan.ps1')
$servers = @(
    [pscustomobject]@{ mcpServerName='mcp_A'; audience='shared'; scope='Scope.A' },
    [pscustomobject]@{ mcpServerName='mcp_B'; audience='shared'; scope='Scope.B' },
    [pscustomobject]@{ mcpServerName='mcp_C'; audience='separate'; scope='Scope.C' }
)
$all = @(Get-Agent365TokenTargets -McpServers $servers -BlueprintId 'blueprint')
if ($all.Count -ne 3) { throw 'Expected two audiences plus the blueprint assertion.' }
$shared = $all | Where-Object Audience -eq 'shared'
if (($shared.Scopes -join ',') -ne 'Scope.A,Scope.B') { throw 'Shared scopes must be combined.' }
$selected = @(Get-Agent365TokenTargets -McpServers $servers -BlueprintId 'blueprint' -Servers mcp_A)
if ($selected.Count -ne 1 -or ($selected[0].Scopes -join ',') -ne 'Scope.A,Scope.B') {
    throw 'Refreshing one server must preserve enabled peers sharing its audience.'
}
$disabled = @(Get-Agent365TokenTargets -McpServers $servers -BlueprintId 'blueprint' -DisabledServers mcp_B -Servers mcp_A)
if ($disabled.Count -ne 1 -or ($disabled[0].Scopes -join ',') -ne 'Scope.A') { throw 'Disabled server scopes must be excluded.' }
$telemetry = @(Get-Agent365TokenTargets -McpServers $servers -BlueprintId 'blueprint' -TelemetryOnly)
if ($telemetry.Count -ne 1 -or $telemetry[0].Audience -ne 'blueprint') { throw 'Telemetry-only mode requested Work IQ.' }
$managed = @(Get-Agent365TokenTargets -McpServers $servers -BlueprintId 'blueprint' -ManagedServers mcp_A)
if (($managed.Name -join ',') -match 'mcp_A' -or (($managed | Where-Object Audience -eq 'shared').Scopes -join ',') -ne 'Scope.B') {
    throw 'An agent-user managed server would receive a human device-code token.'
}
foreach ($arguments in @(
    @{ Servers=@('missing') },
    @{ Servers=@('mcp_A'); TelemetryOnly=$true },
    @{ Servers=@('mcp_B'); DisabledServers=@('mcp_B') },
    @{ Servers=@('mcp_A'); ManagedServers=@('mcp_A') }
)) {
    $failed = $false
    try { Get-Agent365TokenTargets -McpServers $servers -BlueprintId 'blueprint' @arguments | Out-Null }
    catch { $failed = $true }
    if (-not $failed) { throw 'Invalid token selection was accepted.' }
}
Write-Output 'Token-plan checks passed: audience grouping, scope union, selective refresh, explicit exclusions, and invalid selections.'

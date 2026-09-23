function Get-Agent365TokenTargets {
    param(
        [object[]] $McpServers,
        [string] $BlueprintId,
        [string[]] $Servers = @(),
        [string[]] $DisabledServers = @(),
        [string[]] $ManagedServers = @(),
        [switch] $TelemetryOnly
    )
    if ($TelemetryOnly -and $Servers.Count) { throw 'Use -TelemetryOnly or -Servers, not both.' }
    $unknown = @($Servers | Where-Object { $_ -cnotin @($McpServers.mcpServerName) })
    if ($unknown.Count) { throw "Servers not in ToolingManifest.json: $($unknown -join ', ')" }
    $disabledSelection = @($Servers | Where-Object { $_ -cin $DisabledServers })
    if ($disabledSelection.Count) { throw "Servers explicitly disabled locally: $($disabledSelection -join ', ')" }
    $managedSelection = @($Servers | Where-Object { $_ -cin $ManagedServers })
    if ($managedSelection.Count) { throw "These servers acquire agent-user tokens automatically, not device-code user tokens: $($managedSelection -join ', ')" }
    if (-not $TelemetryOnly) {
        $McpServers | Where-Object { $_.mcpServerName -cnotin $DisabledServers -and $_.mcpServerName -cnotin $ManagedServers } |
            Group-Object -Property audience | ForEach-Object {
            $group = $_
            if (-not $Servers.Count -or @($group.Group.mcpServerName | Where-Object { $_ -cin $Servers }).Count) {
                [pscustomobject]@{
                    Name = $group.Group.mcpServerName -join ', '
                    Audience = $group.Name
                    Scopes = @($group.Group.scope | ForEach-Object { $_ -split '\s+' } | Where-Object { $_ } | Sort-Object -Unique)
                }
            }
        }
    }
    if ($TelemetryOnly -or -not $Servers.Count) {
        [pscustomobject]@{
            Name = 'Agent delegation for telemetry'
            Audience = $BlueprintId
            Scopes = @('access_agent_as_user')
        }
    }
}

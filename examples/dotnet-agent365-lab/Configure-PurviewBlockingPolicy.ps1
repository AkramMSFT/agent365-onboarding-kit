[CmdletBinding(SupportsShouldProcess)]
param([Parameter(Mandatory)][string] $PolicyName, [switch] $Create)
$ErrorActionPreference = 'Stop'
$local = Get-Content (Join-Path $PSScriptRoot '.a365-runtime.local.json') -Raw | ConvertFrom-Json
$settings = Get-Content (Join-Path $PSScriptRoot 'appsettings.json') -Raw | ConvertFrom-Json
$upn = $local.Agent365Local.UserPrincipalName
$tenant = $settings.Agent365Observability.TenantId
$matches = @(Select-String -LiteralPath (Join-Path $PSScriptRoot '.env') -Pattern '^PURVIEW_APP_LOCATION_ID=')
if ($matches.Count -ne 1) { throw 'Confirm one protected app location in .env first.' }
$appId = $matches[0].Line.Split('=', 2)[1].Trim()
$parsed = [guid]::Empty
if (-not [guid]::TryParse($appId, [ref]$parsed)) { throw 'The policy location must be a confirmed Entra application appId.' }
$ruleName = "$PolicyName-Block-Credit-Cards"
Import-Module ExchangeOnlineManagement
Connect-ExchangeOnline -ConnectionUri 'https://ps.compliance.protection.outlook.com/PowerShell-LiveId' -Device -ShowBanner:$false
try {
    if (-not @(Get-ConnectionInformation | Where-Object { $_.UserPrincipalName -ieq $upn -and $_.TenantID -eq $tenant }).Count) {
        throw 'Compliance sign-in does not match the configured operator and tenant.'
    }
    $policies = @(Get-DlpCompliancePolicy -ErrorAction Stop | Where-Object Name -eq $PolicyName)
    $rules = @(Get-DlpComplianceRule -ErrorAction Stop | Where-Object Name -eq $ruleName)
    if ($policies.Count -or $rules.Count) {
        $policies | Format-List Name,Mode,DistributionStatus,EnforcementPlanes,Locations
        $rules | Format-List Name,Policy,Disabled,ContentContainsSensitiveInformation,RestrictAccess
        if ($Create) { throw 'Existing policy/rule names were not overwritten. Inspect their scope and live behavior.' }
        return
    }
    if (-not $Create) { Write-Output 'No matching policy/rule exists. Use -Create only after confirming billing, roles and this app-scoped rule.'; return }
    if (-not $PSCmdlet.ShouldProcess($appId, "Enable credit-card UploadText blocking policy $PolicyName")) { return }
    $locations = ConvertTo-Json -Depth 6 -Compress -InputObject @(@{
        Workload='Applications'; Location=$appId; LocationDisplayName=$PolicyName; LocationSource='Entra'; LocationType='Individual'
        Inclusions=@(@{Type='Tenant';Identity='All'})
    })
    New-DlpCompliancePolicy -Name $PolicyName -Mode Enable -Locations $locations -EnforcementPlanes @('Application') | Out-Null
    New-DlpComplianceRule -Name $ruleName -Policy $PolicyName `
        -ContentContainsSensitiveInformation @{Name='Credit Card Number'} `
        -RestrictAccess @(@{setting='UploadText';value='Block'}) | Out-Null
    Get-DlpCompliancePolicy -Identity $PolicyName | Format-List Name,Mode,DistributionStatus,EnforcementPlanes,Locations
    Get-DlpComplianceRule -Identity $ruleName | Format-List Name,Policy,Disabled,ContentContainsSensitiveInformation,RestrictAccess
}
finally { Disconnect-ExchangeOnline -Confirm:$false }

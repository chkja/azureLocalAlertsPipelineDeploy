<#
.SYNOPSIS
    Deploys the Azure Local alerting stack (Action Group + tier-appropriate metric/log alerts)
    to a single subscription/resource group, using the Bicep templates in ../bicep.

.DESCRIPTION
    Wraps `az deployment sub create` with:
      - up-front parameter validation (fails fast instead of a deep ARM error), notably that
        Advanced/Premium tiers must supply a Log Analytics workspace resource ID
      - JSON-encoding of email/webhook receiver arrays so they can be passed from a pipeline
        as simple comma separated strings
      - a -WhatIf switch that runs `az deployment sub what-if` for pipeline validation stages

.PARAMETER SubscriptionId
    Target subscription ID. The script runs `az account set` before deploying.

.PARAMETER ServiceTier
    One of Basic, Advanced, Premium. Selects which parameter file under bicep/parameters is
    used as the base, and is also passed through to override serviceTier explicitly.

.PARAMETER ResourceGroupName
    Resource group that contains (or will contain) the alerting resources.

.PARAMETER Location
    Azure region, e.g. westeurope.

.PARAMETER ClusterResourceId
    ARM resource ID of the Microsoft.AzureStackHCI/clusters resource.

.PARAMETER LogAnalyticsWorkspaceResourceId
    ARM resource ID of the Log Analytics workspace. Required for Advanced/Premium.

.PARAMETER ActionGroupName
    Name of the Action Group resource.

.PARAMETER ActionGroupShortName
    Short name (max 12 chars) for the Action Group.

.PARAMETER EmailReceiversJson
    JSON array string: [{"name":"...", "emailAddress":"...", "useCommonAlertSchema":true}, ...]

.PARAMETER WebhookReceiversJson
    JSON array string: [{"name":"...", "serviceUri":"...", "useCommonAlertSchema":true}, ...]

.PARAMETER CreateResourceGroup
    Switch. Create the resource group as part of this deployment.

.PARAMETER WhatIf
    Switch. Run `az deployment sub what-if` instead of applying the deployment.

.EXAMPLE
    pwsh -File ./Deploy-AzureLocalAlerts.ps1 `
      -SubscriptionId "00000000-0000-0000-0000-000000000000" `
      -ServiceTier "Advanced" `
      -ResourceGroupName "rg-azurelocal-customera-prod" `
      -Location "westeurope" `
      -ClusterResourceId "/subscriptions/.../providers/Microsoft.AzureStackHCI/clusters/azlclustercustomera" `
      -LogAnalyticsWorkspaceResourceId "/subscriptions/.../providers/Microsoft.OperationalInsights/workspaces/law-azurelocal-customera" `
      -ActionGroupName "ag-azurelocal-customera-prod" `
      -ActionGroupShortName "azlalerts" `
      -EmailReceiversJson '[{"name":"ops","emailAddress":"ops@example.com"}]' `
      -WebhookReceiversJson '[{"name":"itsm","serviceUri":"https://example.com/webhook"}]'
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory = $true)]
    [string]$SubscriptionId,

    [Parameter(Mandatory = $true)]
    [ValidateSet('Basic', 'Advanced', 'Premium')]
    [string]$ServiceTier,

    [Parameter(Mandatory = $true)]
    [string]$ResourceGroupName,

    [Parameter(Mandatory = $true)]
    [string]$Location,

    [Parameter(Mandatory = $true)]
    [string]$ClusterResourceId,

    [Parameter(Mandatory = $false)]
    [string]$LogAnalyticsWorkspaceResourceId = '',

    [Parameter(Mandatory = $true)]
    [string]$ActionGroupName,

    [Parameter(Mandatory = $true)]
    [ValidateLength(1, 12)]
    [string]$ActionGroupShortName,

    [Parameter(Mandatory = $false)]
    [string]$EmailReceiversJson = '[]',

    [Parameter(Mandatory = $false)]
    [string]$WebhookReceiversJson = '[]',

    [Parameter(Mandatory = $false)]
    [int]$CpuThresholdPercent = 85,

    [Parameter(Mandatory = $false)]
    [int]$MemoryThresholdPercent = 85,

    [Parameter(Mandatory = $false)]
    [int]$HeartbeatMissingMinutes = 10,

    [Parameter(Mandatory = $false)]
    [switch]$CreateResourceGroup,

    [Parameter(Mandatory = $false)]
    [switch]$WhatIf
)

$ErrorActionPreference = 'Stop'

function Assert-JsonArray {
    param([string]$Value, [string]$ParamName)
    try {
        $parsed = $Value | ConvertFrom-Json
    }
    catch {
        throw "Parameter '$ParamName' is not valid JSON: $Value"
    }
    if ($null -ne $parsed -and $parsed -isnot [System.Collections.IEnumerable]) {
        throw "Parameter '$ParamName' must be a JSON array, e.g. []"
    }
}

Write-Host "==> Validating parameters for tier '$ServiceTier'..." -ForegroundColor Cyan

if ($ServiceTier -in @('Advanced', 'Premium') -and [string]::IsNullOrWhiteSpace($LogAnalyticsWorkspaceResourceId)) {
    throw "ServiceTier '$ServiceTier' requires -LogAnalyticsWorkspaceResourceId (Advanced/Premium alerts include log-based alert rules)."
}

Assert-JsonArray -Value $EmailReceiversJson -ParamName 'EmailReceiversJson'
Assert-JsonArray -Value $WebhookReceiversJson -ParamName 'WebhookReceiversJson'

$emailReceivers = @($EmailReceiversJson | ConvertFrom-Json)
$webhookReceivers = @($WebhookReceiversJson | ConvertFrom-Json)

if ($emailReceivers.Count -eq 0 -and $webhookReceivers.Count -eq 0) {
    Write-Warning "No email or webhook receivers supplied. Alerts will fire with nobody notified."
}

Write-Host "==> Setting subscription context to $SubscriptionId..." -ForegroundColor Cyan
az account set --subscription $SubscriptionId
if ($LASTEXITCODE -ne 0) { throw "Failed to set subscription context." }

$repoRoot = Split-Path -Parent $PSScriptRoot
$templateFile = Join-Path $repoRoot 'bicep/main.bicep'

# Bicep params must be passed as a single JSON-escaped string for array-typed CLI parameters.
$emailReceiversCompact = ($emailReceivers | ConvertTo-Json -Compress -AsArray)
$webhookReceiversCompact = ($webhookReceivers | ConvertTo-Json -Compress -AsArray)

$deploymentName = "azurelocal-alerts-$ServiceTier-$(Get-Date -Format 'yyyyMMddHHmmss')"

$azArgs = @(
    'deployment', 'sub',
    ($WhatIf ? 'what-if' : 'create'),
    '--name', $deploymentName,
    '--location', $Location,
    '--template-file', $templateFile,
    '--parameters',
    "serviceTier=$ServiceTier",
    "resourceGroupName=$ResourceGroupName",
    "location=$Location",
    "createResourceGroup=$($CreateResourceGroup.IsPresent.ToString().ToLower())",
    "clusterResourceId=$ClusterResourceId",
    "logAnalyticsWorkspaceResourceId=$LogAnalyticsWorkspaceResourceId",
    "actionGroupName=$ActionGroupName",
    "actionGroupShortName=$ActionGroupShortName",
    "emailReceivers=$emailReceiversCompact",
    "webhookReceivers=$webhookReceiversCompact",
    "cpuThresholdPercent=$CpuThresholdPercent",
    "memoryThresholdPercent=$MemoryThresholdPercent",
    "heartbeatMissingMinutes=$HeartbeatMissingMinutes"
)

Write-Host "==> Running: az $($azArgs -join ' ')" -ForegroundColor Cyan

if ($PSCmdlet.ShouldProcess($ResourceGroupName, "Deploy Azure Local alerts ($ServiceTier)")) {
    az @azArgs
    if ($LASTEXITCODE -ne 0) { throw "az deployment failed with exit code $LASTEXITCODE." }
}

Write-Host "==> Done." -ForegroundColor Green

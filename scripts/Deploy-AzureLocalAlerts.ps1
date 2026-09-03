<#
.SYNOPSIS
    Deploys the Azure Local alerting stack (resource group + Action Group + tier-appropriate
    metric/log alerts) using an Azure Deployment Stack, so every resource is tracked and
    protected from out-of-band deletion.

.DESCRIPTION
    Wraps `az stack sub create` / `az stack sub validate` with:
      - up-front parameter validation (fails fast instead of a deep ARM error), notably that
        Advanced/Premium tiers must supply a Log Analytics workspace resource ID
      - JSON-encoding of email/webhook receiver arrays so they can be passed from a pipeline
        as simple JSON strings
      - a -WhatIf switch that runs `az stack sub validate` instead of applying the deployment

    Deployment stacks (Microsoft.Resources/deploymentStacks) track every resource created by
    bicep/main.bicep - including the resource group itself - as a single managed unit:
      - `-DenySettingsMode denyDelete` (default) blocks delete operations against any resource
        the stack manages, so alert rules/action groups can't be deleted from the portal by
        mistake (or by a user working around the pipeline), preventing configuration drift.
      - `-ActionOnUnmanage deleteResources` (default) removes resources that fall out of the
        template on the next deployment (e.g. downgrading from Advanced to Basic removes the
        log alerts and the stack cleans them up automatically) WITHOUT ever deleting the
        resource group itself - the customer's Azure Local cluster and other resources in that
        RG are never touched, even if the stack itself is later deleted.

.PARAMETER SubscriptionId
    Target subscription ID. The script runs `az account set` before deploying.

.PARAMETER ServiceTier
    One of Basic, Advanced, Premium.

.PARAMETER ResourceGroupName
    Resource group that will contain the alerting resources. Created automatically by
    bicep/main.bicep if it does not already exist.

.PARAMETER Location
    Azure region, e.g. westeurope. Used both for the resource group and the deployment stack.

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

.PARAMETER IncludeServiceHealth
    Premium tier only (ignored otherwise). Also deploys a subscription-wide Azure Service Health
    activity log alert alongside the Resource Health one. Default $true.

.PARAMETER SuppressionWindowsJson
    JSON array string of maintenance-window suppression rule definitions, applied at every
    service tier. Each entry: {"name":"...", "effectiveFrom":"2026-01-01T00:00:00",
    "effectiveUntil":"2027-01-01T00:00:00", "timeZone":"UTC", "recurrenceType":"Weekly",
    "startTime":"22:00:00", "endTime":"02:00:00", "daysOfWeek":["Saturday"]}. See
    bicep/modules/suppressionRules.bicep for the full shape (recurrenceType None/Daily/Weekly/Monthly).

.PARAMETER EnableOffHoursSuppression
    Basic/Advanced only (ignored for Premium, which commits to 24/7 response). Deploys a standing
    weekly suppression schedule (bicep/modules/offHoursSuppression.bicep) that silences
    action-group notifications outside ServiceHoursStart/ServiceHoursEnd, Monday-Friday. Alert
    rules still evaluate around the clock - only notifications are suppressed. Default $true.

.PARAMETER ServiceHoursStart
    Daily start of the committed service/working-hours window, "HH:mm:ss", Monday-Friday. Only
    used when EnableOffHoursSuppression is set and ServiceTier is not Premium. Default '07:00:00'.

.PARAMETER ServiceHoursEnd
    Daily end of the committed service/working-hours window, "HH:mm:ss". Default '17:00:00'.

.PARAMETER ServiceHoursTimeZone
    Windows time zone name the service-hours window is evaluated in. Default 'Romance Standard Time'.

.PARAMETER DeploymentStackName
    Name of the deployment stack resource. Defaults to "stack-azurelocal-alerts-<ResourceGroupName>".
    Re-running with the same name updates the existing stack; a different name creates a new one.

.PARAMETER DenySettingsMode
    One of denyDelete, denyWriteAndDelete, none. Default denyDelete.

.PARAMETER ActionOnUnmanage
    One of deleteResources, deleteAll, detachAll. Default deleteResources (never deletes resource
    groups - see DESCRIPTION). Only use deleteAll if you fully understand it will delete the
    resource group - and everything in it - once the stack is removed or the RG falls out of the
    template.

.PARAMETER WhatIf
    Switch. Run `az stack sub validate` instead of applying the deployment.

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
    [long]$StorageFreeBytesThreshold = 214748364800,

    [Parameter(Mandatory = $false)]
    [long]$MemoryAvailableBytesThreshold = 1073741824,

    [Parameter(Mandatory = $false)]
    [string]$VolumeLatencyReadThresholdSeconds = '0.5',

    [Parameter(Mandatory = $false)]
    [string]$VolumeLatencyWriteThresholdSeconds = '0.5',

    [Parameter(Mandatory = $false)]
    [long]$NetworkInThresholdBytesPerSecond = 500000000000,

    [Parameter(Mandatory = $false)]
    [long]$NetworkOutThresholdBytesPerSecond = 200000000000,

    [Parameter(Mandatory = $false)]
    [bool]$IncludeServiceHealth = $true,

    [Parameter(Mandatory = $false)]
    [string]$SuppressionWindowsJson = '[]',

    [Parameter(Mandatory = $false)]
    [bool]$EnableOffHoursSuppression = $true,

    [Parameter(Mandatory = $false)]
    [string]$ServiceHoursStart = '07:00:00',

    [Parameter(Mandatory = $false)]
    [string]$ServiceHoursEnd = '17:00:00',

    [Parameter(Mandatory = $false)]
    [string]$ServiceHoursTimeZone = 'Romance Standard Time',

    [Parameter(Mandatory = $false)]
    [int]$HeartbeatMissingMinutes = 10,

    [Parameter(Mandatory = $false)]
    [string]$DeploymentStackName = '',

    [Parameter(Mandatory = $false)]
    [ValidateSet('denyDelete', 'denyWriteAndDelete', 'none')]
    [string]$DenySettingsMode = 'denyDelete',

    [Parameter(Mandatory = $false)]
    [ValidateSet('deleteResources', 'deleteAll', 'detachAll')]
    [string]$ActionOnUnmanage = 'deleteResources',

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

function Assert-SuppressionWindows {
    <#
        Validates -SuppressionWindowsJson up front (fails fast with a clear message instead of a
        deep ARM/discriminated-union error), then returns the parsed array. Mirrors the shape
        documented in bicep/modules/suppressionRules.bicep.
    #>
    param([string]$Json)

    Assert-JsonArray -Value $Json -ParamName 'SuppressionWindowsJson'
    $windows = @($Json | ConvertFrom-Json)

    foreach ($w in $windows) {
        foreach ($required in @('name', 'effectiveFrom', 'effectiveUntil', 'recurrenceType')) {
            if (-not ($w.PSObject.Properties.Name -contains $required) -or [string]::IsNullOrWhiteSpace($w.$required)) {
                throw "SuppressionWindowsJson entry is missing required property '$required': $($w | ConvertTo-Json -Compress)"
            }
        }
        if ($w.recurrenceType -notin @('None', 'Daily', 'Weekly', 'Monthly')) {
            throw "SuppressionWindowsJson entry '$($w.name)' has invalid recurrenceType '$($w.recurrenceType)' - must be None, Daily, Weekly, or Monthly."
        }
        if ($w.recurrenceType -ne 'None') {
            foreach ($required in @('startTime', 'endTime')) {
                if (-not ($w.PSObject.Properties.Name -contains $required) -or [string]::IsNullOrWhiteSpace($w.$required)) {
                    throw "SuppressionWindowsJson entry '$($w.name)' with recurrenceType '$($w.recurrenceType)' requires '$required' (format 'HH:mm:ss')."
                }
            }
        }
        if ($w.recurrenceType -eq 'Weekly' -and (-not ($w.PSObject.Properties.Name -contains 'daysOfWeek') -or @($w.daysOfWeek).Count -eq 0)) {
            throw "SuppressionWindowsJson entry '$($w.name)' with recurrenceType 'Weekly' requires a non-empty 'daysOfWeek' array."
        }
        if ($w.recurrenceType -eq 'Monthly' -and (-not ($w.PSObject.Properties.Name -contains 'daysOfMonth') -or @($w.daysOfMonth).Count -eq 0)) {
            throw "SuppressionWindowsJson entry '$($w.name)' with recurrenceType 'Monthly' requires a non-empty 'daysOfMonth' array."
        }
    }

    return $windows
}

function Test-LogAnalyticsWorkspaceExists {
    <#
        Confirms the Log Analytics workspace referenced by -LogAnalyticsWorkspaceResourceId
        actually exists (and is reachable with the current credentials) before deploying any
        log-based alert rules against it. A scheduledQueryRules resource deploys successfully
        even if its target workspace ID is wrong or doesn't exist - it just silently never
        retrieves data, so this check turns that into a fast, clear failure instead of a
        "why are my alerts never firing" support ticket later.
    #>
    param([string]$WorkspaceResourceId)

    Write-Host "==> Verifying Log Analytics workspace exists: $WorkspaceResourceId" -ForegroundColor Cyan

    if ($WorkspaceResourceId -notmatch '(?i)^/subscriptions/[^/]+/resourceGroups/[^/]+/providers/Microsoft\.OperationalInsights/workspaces/[^/]+$') {
        throw "LogAnalyticsWorkspaceResourceId '$WorkspaceResourceId' is not a valid Log Analytics workspace resource ID (expected .../providers/Microsoft.OperationalInsights/workspaces/<name>)."
    }

    $workspaceJson = az resource show --ids $WorkspaceResourceId -o json 2>$null
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($workspaceJson)) {
        throw "Log Analytics workspace '$WorkspaceResourceId' was not found (or is not accessible with the current credentials). Advanced/Premium log-based alert rules would deploy successfully but never retrieve data against a missing workspace - fix -LogAnalyticsWorkspaceResourceId before retrying."
    }

    $workspace = $workspaceJson | ConvertFrom-Json
    if ($workspace.properties.provisioningState -ne 'Succeeded') {
        Write-Warning "Log Analytics workspace '$WorkspaceResourceId' exists but provisioningState is '$($workspace.properties.provisioningState)' (expected 'Succeeded')."
    }

    Write-Host "==> Log Analytics workspace confirmed (provisioningState: $($workspace.properties.provisioningState))." -ForegroundColor Green
}

Write-Host "==> Validating parameters for tier '$ServiceTier'..." -ForegroundColor Cyan

if ($ServiceTier -in @('Advanced', 'Premium') -and [string]::IsNullOrWhiteSpace($LogAnalyticsWorkspaceResourceId)) {
    throw "ServiceTier '$ServiceTier' requires -LogAnalyticsWorkspaceResourceId (Advanced/Premium alerts include log-based alert rules)."
}

if ($ActionOnUnmanage -eq 'deleteAll') {
    Write-Warning "ActionOnUnmanage 'deleteAll' will delete the resource group '$ResourceGroupName' (and everything in it, including the Azure Local cluster resource) if the stack is later deleted or the RG falls out of the template. 'deleteResources' is strongly recommended instead."
}

Assert-JsonArray -Value $EmailReceiversJson -ParamName 'EmailReceiversJson'
Assert-JsonArray -Value $WebhookReceiversJson -ParamName 'WebhookReceiversJson'

$emailReceivers = @($EmailReceiversJson | ConvertFrom-Json)
$webhookReceivers = @($WebhookReceiversJson | ConvertFrom-Json)
$suppressionWindows = Assert-SuppressionWindows -Json $SuppressionWindowsJson

if ($emailReceivers.Count -eq 0 -and $webhookReceivers.Count -eq 0) {
    Write-Warning "No email or webhook receivers supplied. Alerts will fire with nobody notified."
}

Write-Host "==> Setting subscription context to $SubscriptionId..." -ForegroundColor Cyan
az account set --subscription $SubscriptionId
if ($LASTEXITCODE -ne 0) { throw "Failed to set subscription context." }

if ($ServiceTier -in @('Advanced', 'Premium')) {
    Test-LogAnalyticsWorkspaceExists -WorkspaceResourceId $LogAnalyticsWorkspaceResourceId
}

# `az stack` is a core Azure CLI command since 2.61; fall back to the extension on older CLIs.
az stack sub --help *> $null
if ($LASTEXITCODE -ne 0) {
    Write-Host "==> 'az stack' not available as a core command, installing the deployment-stacks extension..." -ForegroundColor Cyan
    az extension add --name deployment-stacks --upgrade --only-show-errors
    if ($LASTEXITCODE -ne 0) { throw "Failed to install the 'deployment-stacks' Azure CLI extension." }
}

$repoRoot = Split-Path -Parent $PSScriptRoot
$templateFile = Join-Path $repoRoot 'bicep/main.bicep'

# Bicep params must be passed as a single JSON-escaped string for array-typed CLI parameters.
$emailReceiversCompact = ($emailReceivers | ConvertTo-Json -Compress -AsArray)
$webhookReceiversCompact = ($webhookReceivers | ConvertTo-Json -Compress -AsArray)
$suppressionWindowsCompact = ($suppressionWindows | ConvertTo-Json -Compress -AsArray)
$includeServiceHealthValue = $IncludeServiceHealth.ToString().ToLowerInvariant()
$enableOffHoursSuppressionValue = $EnableOffHoursSuppression.ToString().ToLowerInvariant()

if ([string]::IsNullOrWhiteSpace($DeploymentStackName)) {
    $DeploymentStackName = "stack-azurelocal-alerts-$ResourceGroupName"
}

$templateParameters = @(
    "serviceTier=$ServiceTier",
    "resourceGroupName=$ResourceGroupName",
    "location=$Location",
    "clusterResourceId=$ClusterResourceId",
    "logAnalyticsWorkspaceResourceId=$LogAnalyticsWorkspaceResourceId",
    "actionGroupName=$ActionGroupName",
    "actionGroupShortName=$ActionGroupShortName",
    "emailReceivers=$emailReceiversCompact",
    "webhookReceivers=$webhookReceiversCompact",
    "cpuThresholdPercent=$CpuThresholdPercent",
    "memoryThresholdPercent=$MemoryThresholdPercent",
    "storageFreeBytesThreshold=$StorageFreeBytesThreshold",
    "memoryAvailableBytesThreshold=$MemoryAvailableBytesThreshold",
    "volumeLatencyReadThresholdSeconds=$VolumeLatencyReadThresholdSeconds",
    "volumeLatencyWriteThresholdSeconds=$VolumeLatencyWriteThresholdSeconds",
    "networkInThresholdBytesPerSecond=$NetworkInThresholdBytesPerSecond",
    "networkOutThresholdBytesPerSecond=$NetworkOutThresholdBytesPerSecond",
    "includeServiceHealth=$includeServiceHealthValue",
    "suppressionWindows=$suppressionWindowsCompact",
    "enableOffHoursSuppression=$enableOffHoursSuppressionValue",
    "serviceHoursStart=$ServiceHoursStart",
    "serviceHoursEnd=$ServiceHoursEnd",
    "serviceHoursTimeZone=$ServiceHoursTimeZone",
    "heartbeatMissingMinutes=$HeartbeatMissingMinutes"
) -join ' '

$stackAction = if ($WhatIf) { 'validate' } else { 'create' }

$azArgs = @(
    'stack', 'sub', $stackAction,
    '--name', $DeploymentStackName,
    '--location', $Location,
    '--template-file', $templateFile,
    '--parameters', $templateParameters,
    '--deny-settings-mode', $DenySettingsMode,
    '--action-on-unmanage', $ActionOnUnmanage,
    '--description', "Azure Local alerts ($ServiceTier) for $ClusterResourceId",
    '--yes'
)

Write-Host "==> Running: az $($azArgs -join ' ')" -ForegroundColor Cyan

if ($PSCmdlet.ShouldProcess($ResourceGroupName, "Deploy Azure Local alerts ($ServiceTier) as deployment stack '$DeploymentStackName'")) {
    az @azArgs
    if ($LASTEXITCODE -ne 0) { throw "az stack sub $stackAction failed with exit code $LASTEXITCODE." }
}

Write-Host "==> Done." -ForegroundColor Green

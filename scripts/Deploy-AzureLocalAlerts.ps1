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

.PARAMETER BicepParamFile
    Path to a .bicepparam file (using bicep/main.bicep) carrying every template parameter for
    one customer/cluster - the recommended way to configure a deployment. Mutually exclusive
    with the individual -ServiceTier/-ResourceGroupName/-EmailReceiversJson/etc. parameters
    below (ParameterSetName 'ByValue'): using -BicepParamFile selects ParameterSetName
    'ByBicepParamFile' instead. The script compiles the file with `az bicep build-params` to
    read back the handful of values (ServiceTier, ResourceGroupName, Location,
    ClusterResourceId, LogAnalyticsWorkspaceResourceId) it needs for its own pre-flight checks
    (Log Analytics workspace existence, DCR event-log auto-extension) and deployment-stack
    naming/description - it does not re-validate every parameter the way -EmailReceiversJson
    etc. are validated in ByValue mode; malformed values instead surface as a Bicep/ARM error
    from `az stack sub create`/`validate`. The original .bicepparam file (not the compiled JSON)
    is passed straight through to `az stack sub create/validate --parameters`.

.PARAMETER ServiceTier
    One of Basic, Advanced, Premium. (ByValue parameter set only - see -BicepParamFile.)

.PARAMETER ResourceGroupName
    Resource group that will contain the alerting resources. Created automatically by
    bicep/main.bicep if it does not already exist. (ByValue parameter set only.)

.PARAMETER Location
    Azure region, e.g. westeurope. Used both for the resource group and the deployment stack.
    (ByValue parameter set only.)

.PARAMETER ClusterResourceId
    ARM resource ID of the Microsoft.AzureStackHCI/clusters resource. (ByValue parameter set only.)

.PARAMETER LogAnalyticsWorkspaceResourceId
    ARM resource ID of the Log Analytics workspace. Required for Advanced/Premium. (ByValue
    parameter set only.)

.PARAMETER ActionGroupName
    Name of the Action Group resource. (ByValue parameter set only.)

.PARAMETER ActionGroupShortName
    Short name (max 12 chars) for the Action Group. (ByValue parameter set only.)

.PARAMETER EmailReceiversJson
    JSON array string: [{"name":"...", "emailAddress":"...", "useCommonAlertSchema":true}, ...]
    (ByValue parameter set only.)

.PARAMETER WebhookReceiversJson
    JSON array string: [{"name":"...", "serviceUri":"...", "useCommonAlertSchema":true}, ...]
    (ByValue parameter set only.)

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
    action-group notifications outside ActiveMonitoringHoursStart/ActiveMonitoringHoursEnd, Monday-Friday. Alert
    rules still evaluate around the clock - only notifications are suppressed. Default $true.

.PARAMETER ActiveMonitoringHoursStart
    Daily start of the committed service/working-hours window, "HH:mm:ss", Monday-Friday. Only
    used when EnableOffHoursSuppression is set and ServiceTier is not Premium. Default '07:00:00'.

.PARAMETER ActiveMonitoringHoursEnd
    Daily end of the committed service/working-hours window, "HH:mm:ss". Default '17:00:00'.

.PARAMETER ActiveMonitoringHoursTimeZone
    Windows time zone name the active-monitoring-hours window is evaluated in. Default 'Romance Standard Time'.

.PARAMETER LogAlertsMuteActionsDuration
    Optional throttle for the Advanced/Premium log-based alerts (heartbeat, volume health, and the
    Premium error-rate alert): ISO 8601 duration (e.g. "PT1H", "PT30M") for which repeat
    notifications are suppressed after firing, while the condition remains true. When set, this
    switches from the default "one Fired notification, then silent until Resolved" (stateful)
    behavior to periodic re-notification every LogAlertsMuteActionsDuration for as long as the
    issue persists. NOT supported by Azure Monitor metric alerts (no ARM equivalent exists for
    Microsoft.Insights/metricAlerts) - those remain purely stateful regardless of this setting.
    Default '' (disabled).

.PARAMETER DcrResourceId
    ARM resource ID of the Data Collection Rule (Microsoft.Insights/dataCollectionRules) that
    collects Windows Event Logs for this cluster's nodes. Advanced/Premium only. When supplied
    (or auto-discovered - see DESCRIPTION), the script extends the DCR's "System" and
    "Microsoft-Windows-FailoverClustering/Operational" / Hyper-V event log collection so the new
    cluster-quorum, critical-service-down, and Hyper-V-availability log alerts actually receive
    data. This update runs OUTSIDE the deployment stack (a direct `az rest` PUT merge against the
    live resource) - the DCR is a shared prerequisite resource typically owned/created by the
    customer's onboarding/Arc setup, not something this stack should track or could safely
    delete. If not supplied, the script attempts to auto-discover it from a
    Microsoft.HybridCompute/machines resource in ClusterResourceId's resource group - this
    auto-discovery is a HARD requirement (Advanced/Premium, not -WhatIf, not -SkipDcrUpdate):
    if no DCR can be identified, the deployment STOPS with a clear error instead of proceeding,
    since alert rules deployed without a confirmed DCR update cannot be trusted to ever receive
    data. Use -SkipDcrUpdate to intentionally bypass DCR handling (e.g. a quick test deployment
    where you'll extend the DCR separately).

.PARAMETER SkipDcrUpdate
    Switch. Skip DCR discovery/extension entirely, even for Advanced/Premium.

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
    # Recommended: one .bicepparam file per customer/cluster (see pipeline/environments/*.bicepparam).
    pwsh -File ./Deploy-AzureLocalAlerts.ps1 `
      -SubscriptionId "00000000-0000-0000-0000-000000000000" `
      -BicepParamFile "./pipeline/environments/example-customerb-advanced.bicepparam"

.EXAMPLE
    # ByValue parameter set: every template parameter passed explicitly (no .bicepparam file).
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
[CmdletBinding(DefaultParameterSetName = 'ByValue')]
param(
    [Parameter(Mandatory = $true)]
    [string]$SubscriptionId,

    [Parameter(Mandatory = $true, ParameterSetName = 'ByBicepParamFile')]
    [string]$BicepParamFile,

    [Parameter(Mandatory = $true, ParameterSetName = 'ByValue')]
    [ValidateSet('Basic', 'Advanced', 'Premium')]
    [string]$ServiceTier,

    [Parameter(Mandatory = $true, ParameterSetName = 'ByValue')]
    [string]$ResourceGroupName,

    [Parameter(Mandatory = $true, ParameterSetName = 'ByValue')]
    [string]$Location,

    [Parameter(Mandatory = $true, ParameterSetName = 'ByValue')]
    [string]$ClusterResourceId,

    [Parameter(Mandatory = $false, ParameterSetName = 'ByValue')]
    [string]$LogAnalyticsWorkspaceResourceId = '',

    [Parameter(Mandatory = $true, ParameterSetName = 'ByValue')]
    [string]$ActionGroupName,

    [Parameter(Mandatory = $true, ParameterSetName = 'ByValue')]
    [ValidateLength(1, 12)]
    [string]$ActionGroupShortName,

    [Parameter(Mandatory = $false, ParameterSetName = 'ByValue')]
    [string]$EmailReceiversJson = '[]',

    [Parameter(Mandatory = $false, ParameterSetName = 'ByValue')]
    [string]$WebhookReceiversJson = '[]',

    [Parameter(Mandatory = $false, ParameterSetName = 'ByValue')]
    [int]$CpuThresholdPercent = 85,

    [Parameter(Mandatory = $false, ParameterSetName = 'ByValue')]
    [int]$MemoryThresholdPercent = 85,

    [Parameter(Mandatory = $false, ParameterSetName = 'ByValue')]
    [long]$StorageFreeBytesThreshold = 214748364800,

    [Parameter(Mandatory = $false, ParameterSetName = 'ByValue')]
    [long]$MemoryAvailableBytesThreshold = 1073741824,

    [Parameter(Mandatory = $false, ParameterSetName = 'ByValue')]
    [string]$VolumeLatencyReadThresholdSeconds = '0.5',

    [Parameter(Mandatory = $false, ParameterSetName = 'ByValue')]
    [string]$VolumeLatencyWriteThresholdSeconds = '0.5',

    [Parameter(Mandatory = $false, ParameterSetName = 'ByValue')]
    [long]$NetworkInThresholdBytesPerSecond = 500000000000,

    [Parameter(Mandatory = $false, ParameterSetName = 'ByValue')]
    [long]$NetworkOutThresholdBytesPerSecond = 200000000000,

    [Parameter(Mandatory = $false, ParameterSetName = 'ByValue')]
    [bool]$IncludeServiceHealth = $true,

    [Parameter(Mandatory = $false, ParameterSetName = 'ByValue')]
    [string]$SuppressionWindowsJson = '[]',

    [Parameter(Mandatory = $false, ParameterSetName = 'ByValue')]
    [bool]$EnableOffHoursSuppression = $true,

    [Parameter(Mandatory = $false, ParameterSetName = 'ByValue')]
    [string]$ActiveMonitoringHoursStart = '07:00:00',

    [Parameter(Mandatory = $false, ParameterSetName = 'ByValue')]
    [string]$ActiveMonitoringHoursEnd = '17:00:00',

    [Parameter(Mandatory = $false, ParameterSetName = 'ByValue')]
    [string]$ActiveMonitoringHoursTimeZone = 'Romance Standard Time',

    [Parameter(Mandatory = $false, ParameterSetName = 'ByValue')]
    [string]$LogAlertsMuteActionsDuration = '',

    [Parameter(Mandatory = $false, ParameterSetName = 'ByValue')]
    [int]$HeartbeatMissingMinutes = 10,

    # Shared across both parameter sets: not Bicep template parameters, only used by this
    # script's own pre-flight DCR discovery/extension logic.
    [Parameter(Mandatory = $false)]
    [string]$DcrResourceId = '',

    [Parameter(Mandatory = $false)]
    [switch]$SkipDcrUpdate,

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

# All functions live in src/powershell/ (one file per function) for readability - dot-source
# every *.ps1 there so they're available for the rest of this script, regardless of definition
# order (none of them call each other at *definition* time, only when invoked below).
$functionsPath = Join-Path $PSScriptRoot 'src/powershell'
Get-ChildItem -Path $functionsPath -Filter '*.ps1' | ForEach-Object { . $_.FullName }

$usingBicepParamFile = $PSCmdlet.ParameterSetName -eq 'ByBicepParamFile'

if ($usingBicepParamFile) {
    $bicepParamValues = Resolve-BicepParamFile -Path $BicepParamFile
    # Populate the same local variables the rest of the script (LAW check, DCR discovery,
    # deployment-stack naming/description) already relies on, regardless of parameter set.
    $ServiceTier = $bicepParamValues.ServiceTier
    $ResourceGroupName = $bicepParamValues.ResourceGroupName
    $Location = $bicepParamValues.Location
    $ClusterResourceId = $bicepParamValues.ClusterResourceId
    $LogAnalyticsWorkspaceResourceId = $bicepParamValues.LogAnalyticsWorkspaceResourceId
}

Write-Host "==> Validating parameters for tier '$ServiceTier'..." -ForegroundColor Cyan

if ($ServiceTier -in @('Advanced', 'Premium') -and [string]::IsNullOrWhiteSpace($LogAnalyticsWorkspaceResourceId)) {
    throw "ServiceTier '$ServiceTier' requires a Log Analytics workspace resource ID (Advanced/Premium alerts include log-based alert rules) - set -LogAnalyticsWorkspaceResourceId, or 'logAnalyticsWorkspaceResourceId' in the .bicepparam file."
}

if ($ActionOnUnmanage -eq 'deleteAll') {
    Write-Warning "ActionOnUnmanage 'deleteAll' will delete the resource group '$ResourceGroupName' (and everything in it, including the Azure Local cluster resource) if the stack is later deleted or the RG falls out of the template. 'deleteResources' is strongly recommended instead."
}

if (-not $usingBicepParamFile) {
    # ByValue-only: the .bicepparam file itself already carries these values (in valid Bicep
    # syntax, checked by `az bicep build-params` during Resolve-BicepParamFile above), so none of
    # this re-validation applies when -BicepParamFile is used.
    Assert-JsonArray -Value $EmailReceiversJson -ParamName 'EmailReceiversJson'
    Assert-JsonArray -Value $WebhookReceiversJson -ParamName 'WebhookReceiversJson'

    $emailReceivers = @($EmailReceiversJson | ConvertFrom-Json)
    $webhookReceivers = @($WebhookReceiversJson | ConvertFrom-Json)
    $suppressionWindows = @(Assert-SuppressionWindows -Json $SuppressionWindowsJson)
    Assert-IsoDuration -Value $LogAlertsMuteActionsDuration -ParamName 'LogAlertsMuteActionsDuration'

    if ($ServiceTier -eq 'Basic' -and -not [string]::IsNullOrWhiteSpace($LogAlertsMuteActionsDuration)) {
        Write-Warning "LogAlertsMuteActionsDuration is set but ServiceTier is 'Basic' - Basic has no log-based alerts, so this setting has no effect."
    }

    if ($emailReceivers.Count -eq 0 -and $webhookReceivers.Count -eq 0) {
        Write-Warning "No email or webhook receivers supplied. Alerts will fire with nobody notified."
    }
}

Write-Host "==> Setting subscription context to $SubscriptionId..." -ForegroundColor Cyan
az account set --subscription $SubscriptionId
if ($LASTEXITCODE -ne 0) { throw "Failed to set subscription context." }

if ($ServiceTier -in @('Advanced', 'Premium')) {
    Test-LogAnalyticsWorkspaceExists -WorkspaceResourceId $LogAnalyticsWorkspaceResourceId

    if ($WhatIf) {
        Write-Host "==> -WhatIf set - not checking/extending the Data Collection Rule's event collection (no live mutation during validation)." -ForegroundColor Yellow
    }
    elseif (-not $SkipDcrUpdate) {
        $effectiveDcrResourceId = $DcrResourceId
        if ([string]::IsNullOrWhiteSpace($effectiveDcrResourceId)) {
            Write-Host "==> No -DcrResourceId supplied, attempting auto-discovery..." -ForegroundColor Cyan
            # Throws (not a warning + $null) if no DCR can be identified - a deployment that's
            # supposed to extend a DCR's event collection must be able to trust that update
            # actually happened, so this stops the deployment instead of silently shipping
            # log alerts that will never receive data. Use -SkipDcrUpdate to bypass intentionally.
            $effectiveDcrResourceId = Find-AzureLocalDcrResourceId -ClusterResourceId $ClusterResourceId
        }
        Set-AzureLocalDcrEventCollection -DcrResourceId $effectiveDcrResourceId
    }
    else {
        Write-Host "==> -SkipDcrUpdate set - not checking/extending the Data Collection Rule's event collection." -ForegroundColor Yellow
    }
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

if (-not $usingBicepParamFile) {
    # Bicep params must be passed as a single JSON-escaped string for array-typed CLI parameters.
    $emailReceiversCompact = ConvertTo-CompactJsonArray -Items $emailReceivers
    $webhookReceiversCompact = ConvertTo-CompactJsonArray -Items $webhookReceivers
    $suppressionWindowsCompact = ConvertTo-CompactJsonArray -Items $suppressionWindows
    $includeServiceHealthValue = $IncludeServiceHealth.ToString().ToLowerInvariant()
    $enableOffHoursSuppressionValue = $EnableOffHoursSuppression.ToString().ToLowerInvariant()
}

if ([string]::IsNullOrWhiteSpace($DeploymentStackName)) {
    $DeploymentStackName = "stack-azurelocal-alerts-$ResourceGroupName"
}

if ($usingBicepParamFile) {
    # The .bicepparam file (using bicep/main.bicep) carries every template parameter already -
    # pass it straight through as the single --parameters value instead of building individual
    # key=value pairs. Its `using` statement means --template-file is omitted here (passing both
    # would conflict).
    $templateParameters = @($bicepParamValues.ResolvedPath)
}
else {
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
        "activeMonitoringHoursStart=$ActiveMonitoringHoursStart",
        "activeMonitoringHoursEnd=$ActiveMonitoringHoursEnd",
        "activeMonitoringHoursTimeZone=$ActiveMonitoringHoursTimeZone",
        "logAlertsMuteActionsDuration=$LogAlertsMuteActionsDuration",
        "heartbeatMissingMinutes=$HeartbeatMissingMinutes"
    )
}

$stackAction = if ($WhatIf) { 'validate' } else { 'create' }

# `--parameters` must receive each key=value pair as its OWN argv token - the Azure CLI's
# argparse (nargs='+') expects a list of separate parameter strings, not one string containing
# all pairs joined by spaces. Splicing $templateParameters into the array (rather than
# `-join ' '`-ing it into a single element) preserves that. Getting this wrong doesn't error;
# az silently fails to parse any parameters and falls back to prompting interactively for the
# first missing required one (e.g. "Please provide string value for 'resourceGroupName'").
$azArgs = @(
    'stack', 'sub', $stackAction,
    '--name', $DeploymentStackName,
    '--location', $Location
)
if (-not $usingBicepParamFile) {
    $azArgs += @('--template-file', $templateFile)
}
$azArgs += @('--parameters') + $templateParameters + @(
    '--deny-settings-mode', $DenySettingsMode,
    '--action-on-unmanage', $ActionOnUnmanage,
    '--description', "Azure Local alerts ($ServiceTier) for $ClusterResourceId"
)
# `az stack sub validate` doesn't accept --yes (there's nothing to confirm - it's read-only);
# only `create` prompts for confirmation of the deny-settings/action-on-unmanage behavior.
if ($stackAction -eq 'create') {
    $azArgs += '--yes'
}

Write-Host "==> Running: az $($azArgs -join ' ')" -ForegroundColor Cyan

if ($PSCmdlet.ShouldProcess($ResourceGroupName, "Deploy Azure Local alerts ($ServiceTier) as deployment stack '$DeploymentStackName'")) {
    az @azArgs
    if ($LASTEXITCODE -ne 0) { throw "az stack sub $stackAction failed with exit code $LASTEXITCODE." }
}

Write-Host "==> Done." -ForegroundColor Green

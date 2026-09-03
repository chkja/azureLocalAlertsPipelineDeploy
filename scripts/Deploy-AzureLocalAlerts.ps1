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

.PARAMETER LogAlertsMuteActionsDuration
    Optional throttle for the Advanced/Premium log-based alerts (heartbeat, volume health, and the
    Premium error-rate alert): ISO 8601 duration (e.g. "PT1H", "PT30M") for which repeat
    notifications are suppressed after firing, while the condition remains true. When set, this
    switches from the default "one Fired notification, then silent until Resolved" (stateful)
    behavior to periodic re-notification every LogAlertsMuteActionsDuration for as long as the
    issue persists. NOT supported by Azure Monitor metric alerts (no ARM equivalent exists for
    Microsoft.Insights/metricAlerts) - those remain purely stateful regardless of this setting.
    Default '' (disabled).

.PARAMETER CriticalServiceNamesJson
    Advanced/Premium only. JSON array of substrings to match against Service Control Manager
    event messages for the critical-service-down watchdog alert (HciSvc / mochostagent /
    wssdcloudagent / wssdagent). Default covers short names and plausible display names - verify
    against your own nodes (`Get-Service -Name HciSvc, mochostagent, wssdcloudagent, wssdagent |
    Select-Object Name, DisplayName`) and override if needed.

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
    Microsoft.HybridCompute/machines resource in ClusterResourceId's resource group. Auto-discovery
    or the update itself failing is a non-fatal warning, not a deployment blocker - the alerts
    still deploy, they just won't receive data for those specific event log channels until the
    DCR is extended (manually, or by re-running with a valid DcrResourceId).

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
[CmdletBinding()]
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
    [string]$LogAlertsMuteActionsDuration = '',

    [Parameter(Mandatory = $false)]
    [string]$CriticalServiceNamesJson = '["HciSvc","Health Service","mochostagent","MOC HostAgent","wssdcloudagent","WSSD Cloud Agent","wssdagent","WSSD Agent"]',

    [Parameter(Mandatory = $false)]
    [string]$DcrResourceId = '',

    [Parameter(Mandatory = $false)]
    [switch]$SkipDcrUpdate,

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
    <#
        Validates that $Value is JSON-array syntax (starts with '[').
        NOTE: deliberately does NOT type-check the *parsed* result - PowerShell's
        ConvertFrom-Json collapses a JSON array containing exactly one element into a bare
        PSCustomObject (not IEnumerable), so a naive "-isnot [System.Collections.IEnumerable]"
        check incorrectly rejects perfectly valid single-item arrays like
        '[{"name":"ops","emailAddress":"ops@example.com"}]'. All call sites already wrap the
        parsed value in @(...) to re-normalize it back to an array, so only the JSON *shape*
        needs validating here.
    #>
    param([string]$Value, [string]$ParamName)
    try {
        $null = $Value | ConvertFrom-Json
    }
    catch {
        throw "Parameter '$ParamName' is not valid JSON: $Value"
    }
    if ($Value.Trim() -notmatch '^\[.*\]$') {
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

function Assert-IsoDuration {
    <#
        Validates an ISO 8601 duration string (e.g. "PT1H", "PT30M", "P1D") up front, so a
        malformed -LogAlertsMuteActionsDuration fails fast with a clear message instead of a
        deep ARM error. Empty string is allowed (means "disabled").
    #>
    param([string]$Value, [string]$ParamName)

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return
    }
    if ($Value -notmatch '^P(?!$)(\d+Y)?(\d+M)?(\d+D)?(T(?=\d)(\d+H)?(\d+M)?(\d+S)?)?$') {
        throw "$ParamName '$Value' is not a valid ISO 8601 duration (e.g. 'PT1H' for 1 hour, 'PT30M' for 30 minutes)."
    }
}

function Find-AzureLocalDcrResourceId {
    <#
        Best-effort auto-discovery of the Data Collection Rule associated with this cluster's
        nodes: lists Microsoft.HybridCompute/machines in the cluster's resource group, and
        returns the DataCollectionRuleId from the first node's DCR association. Returns $null
        (with a warning) if no Arc machines or no association is found - callers must treat this
        as non-fatal.
    #>
    param([string]$ClusterResourceId)

    if ($ClusterResourceId -notmatch '(?i)^/subscriptions/(?<sub>[^/]+)/resourceGroups/(?<rg>[^/]+)/providers/Microsoft\.AzureStackHCI/clusters/[^/]+$') {
        Write-Warning "Could not parse resource group from ClusterResourceId '$ClusterResourceId' - skipping DCR auto-discovery."
        return $null
    }
    $clusterRg = $Matches['rg']

    $machinesJson = az resource list -g $clusterRg --resource-type 'Microsoft.HybridCompute/machines' -o json 2>$null
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($machinesJson)) {
        Write-Warning "No Microsoft.HybridCompute/machines resources found in resource group '$clusterRg' - skipping DCR auto-discovery."
        return $null
    }
    $machines = @($machinesJson | ConvertFrom-Json)
    if ($machines.Count -eq 0) {
        Write-Warning "No Arc-enabled node (Microsoft.HybridCompute/machines) found in resource group '$clusterRg' - skipping DCR auto-discovery."
        return $null
    }

    foreach ($machine in $machines) {
        $associationsJson = az monitor data-collection rule association list --resource $machine.id -o json 2>$null
        if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($associationsJson)) {
            continue
        }
        $associations = @($associationsJson | ConvertFrom-Json)
        $dcrId = $associations | Where-Object { $_.dataCollectionRuleId } | Select-Object -First 1 -ExpandProperty dataCollectionRuleId
        if ($dcrId) {
            Write-Host "==> Auto-discovered DCR '$dcrId' via node '$($machine.name)'." -ForegroundColor Green
            return $dcrId
        }
    }

    Write-Warning "No Data Collection Rule association found on any node in resource group '$clusterRg' - skipping DCR auto-discovery."
    return $null
}

function Set-AzureLocalDcrEventCollection {
    <#
        Idempotently extends an existing Data Collection Rule's Windows Event Log collection
        (dataSources.windowsEventLogs) with the additional xPathQueries required by the new
        cluster-quorum, critical-service-down, and Hyper-V-availability log alerts, WITHOUT
        touching any other configuration on the DCR (performance counters, other data sources,
        destinations, data flows are preserved as-is).

        Runs as a direct `az rest` GET-merge-PUT against the live resource, deliberately outside
        the deployment stack: the DCR is a shared prerequisite resource (typically owned by the
        customer's onboarding/Arc setup, associated with every Arc node in the cluster), not
        something this stack should track or risk deleting via ActionOnUnmanage.

        Non-fatal on any failure - logs a warning and returns, since the alerts themselves still
        deploy successfully; they just won't receive data for these specific channels until the
        DCR is extended.
    #>
    param([string]$DcrResourceId)

    $apiVersion = '2023-03-11'

    if ($DcrResourceId -notmatch '(?i)^/subscriptions/[^/]+/resourceGroups/[^/]+/providers/Microsoft\.Insights/dataCollectionRules/[^/]+$') {
        Write-Warning "DcrResourceId '$DcrResourceId' is not a valid Data Collection Rule resource ID - skipping DCR event collection update."
        return
    }

    Write-Host "==> Checking Data Collection Rule event collection: $DcrResourceId" -ForegroundColor Cyan

    $requiredXPathQueries = @(
        'Microsoft-Windows-FailoverClustering/Operational!*[System[(EventID=1205 or EventID=1573)]]',
        "System!*[System[Provider[@Name='Service Control Manager'] and (EventID=7031 or EventID=7034 or EventID=7036)]]",
        'Microsoft-Windows-Hyper-V-VMMS-Admin!*[System[(EventID=10650)]]',
        'Microsoft-Windows-Hyper-V-High-Availability-Admin!*[System[(EventID=12400)]]'
    )

    $dcrJson = az rest --method get --uri "https://management.azure.com${DcrResourceId}?api-version=$apiVersion" -o json 2>$null
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($dcrJson)) {
        Write-Warning "Could not read Data Collection Rule '$DcrResourceId' (not found, or not accessible with current credentials) - skipping DCR event collection update. The new cluster-quorum/service-watchdog/Hyper-V log alerts will deploy but won't receive data until this is resolved."
        return
    }

    $dcr = $dcrJson | ConvertFrom-Json
    if (-not $dcr.properties.dataSources) {
        Write-Warning "Data Collection Rule '$DcrResourceId' has no dataSources - skipping DCR event collection update (unexpected shape for an Azure Local Insights DCR)."
        return
    }
    if (-not $dcr.properties.dataSources.windowsEventLogs -or @($dcr.properties.dataSources.windowsEventLogs).Count -eq 0) {
        Write-Warning "Data Collection Rule '$DcrResourceId' has no windowsEventLogs data source configured - skipping DCR event collection update. Add an eventLogsDataSource manually, or re-run once one exists."
        return
    }

    $eventDataSource = $dcr.properties.dataSources.windowsEventLogs[0]
    $existingQueries = @($eventDataSource.xPathQueries)
    $missingQueries = $requiredXPathQueries | Where-Object { $existingQueries -notcontains $_ }

    if ($missingQueries.Count -eq 0) {
        Write-Host "==> Data Collection Rule already collects all required event log channels - no update needed." -ForegroundColor Green
        return
    }

    Write-Host "==> Adding $($missingQueries.Count) missing xPathQuery/queries to DCR '$($dcr.name)':" -ForegroundColor Cyan
    $missingQueries | ForEach-Object { Write-Host "    + $_" -ForegroundColor Cyan }

    $eventDataSource.xPathQueries = @($existingQueries + $missingQueries)

    # PUT only the writable subset of the resource (location + properties, minus read-only
    # sub-properties) - never send etag/systemData/id/name/type, and strip properties that ARM
    # only returns (immutableId, provisioningState), otherwise the PUT is rejected or ignored.
    $putBody = [ordered]@{
        location   = $dcr.location
        properties = [ordered]@{
            dataCollectionEndpointId = $dcr.properties.dataCollectionEndpointId
            dataFlows                = $dcr.properties.dataFlows
            dataSources              = $dcr.properties.dataSources
            destinations             = $dcr.properties.destinations
        }
    }
    if ($dcr.PSObject.Properties.Name -contains 'tags' -and $dcr.tags) {
        $putBody['tags'] = $dcr.tags
    }
    if ($dcr.PSObject.Properties.Name -contains 'kind' -and $dcr.kind) {
        $putBody['kind'] = $dcr.kind
    }

    $tempFile = [System.IO.Path]::GetTempFileName()
    try {
        $putBody | ConvertTo-Json -Depth 20 | Set-Content -Path $tempFile -Encoding utf8
        az rest --method put --uri "https://management.azure.com${DcrResourceId}?api-version=$apiVersion" --body "@$tempFile" -o none
        if ($LASTEXITCODE -ne 0) {
            Write-Warning "Failed to update Data Collection Rule '$DcrResourceId' with the merged event collection - the new log alerts will deploy but won't receive data until this is resolved manually."
            return
        }
        Write-Host "==> Data Collection Rule updated successfully." -ForegroundColor Green
    }
    finally {
        Remove-Item -Path $tempFile -ErrorAction SilentlyContinue
    }
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
Assert-JsonArray -Value $CriticalServiceNamesJson -ParamName 'CriticalServiceNamesJson'

$emailReceivers = @($EmailReceiversJson | ConvertFrom-Json)
$webhookReceivers = @($WebhookReceiversJson | ConvertFrom-Json)
$criticalServiceNames = @($CriticalServiceNamesJson | ConvertFrom-Json)
$suppressionWindows = @(Assert-SuppressionWindows -Json $SuppressionWindowsJson)
Assert-IsoDuration -Value $LogAlertsMuteActionsDuration -ParamName 'LogAlertsMuteActionsDuration'

if ($ServiceTier -eq 'Basic' -and -not [string]::IsNullOrWhiteSpace($LogAlertsMuteActionsDuration)) {
    Write-Warning "LogAlertsMuteActionsDuration is set but ServiceTier is 'Basic' - Basic has no log-based alerts, so this setting has no effect."
}

if ($emailReceivers.Count -eq 0 -and $webhookReceivers.Count -eq 0) {
    Write-Warning "No email or webhook receivers supplied. Alerts will fire with nobody notified."
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
            $effectiveDcrResourceId = Find-AzureLocalDcrResourceId -ClusterResourceId $ClusterResourceId
        }
        if (-not [string]::IsNullOrWhiteSpace($effectiveDcrResourceId)) {
            Set-AzureLocalDcrEventCollection -DcrResourceId $effectiveDcrResourceId
        }
        else {
            Write-Warning "No Data Collection Rule identified (supply -DcrResourceId, or ensure the cluster's Arc nodes have a DCR association) - the new cluster-quorum/service-watchdog/Hyper-V log alerts will deploy but won't receive data until this is resolved."
        }
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

function ConvertTo-CompactJsonArray {
    <#
        Serializes $Items (already normalized to an array by the caller, e.g. via @(...)) to a
        compact single-line JSON array string, including the correct "[]" for an empty array.
        Deliberately uses -InputObject (not the pipeline) and omits -AsArray: piping an empty
        array to ConvertTo-Json never invokes its process block (zero objects to enumerate), so
        it silently returns $null instead of "[]" - and combining -InputObject with -AsArray on a
        *non-empty* array double-wraps the result (e.g. "[[{...}]]"). Passing the array directly
        via -InputObject with neither pipe nor -AsArray handles empty/one/many items correctly.
    #>
    param([array]$Items)
    return (ConvertTo-Json -InputObject $Items -Compress)
}

# Bicep params must be passed as a single JSON-escaped string for array-typed CLI parameters.
$emailReceiversCompact = ConvertTo-CompactJsonArray -Items $emailReceivers
$webhookReceiversCompact = ConvertTo-CompactJsonArray -Items $webhookReceivers
$suppressionWindowsCompact = ConvertTo-CompactJsonArray -Items $suppressionWindows
$criticalServiceNamesCompact = ConvertTo-CompactJsonArray -Items $criticalServiceNames
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
    "logAlertsMuteActionsDuration=$LogAlertsMuteActionsDuration",
    "criticalServiceNames=$criticalServiceNamesCompact",
    "heartbeatMissingMinutes=$HeartbeatMissingMinutes"
)

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
    '--location', $Location,
    '--template-file', $templateFile,
    '--parameters'
) + $templateParameters + @(
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

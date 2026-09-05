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

        Throws on any failure (invalid DcrResourceId, unreadable DCR, missing windowsEventLogs
        data source, or a failed PUT) instead of warning and continuing - a deployment that's
        supposed to extend a DCR's event collection must be able to trust that update actually
        happened; silently deploying log alerts that will never receive data is worse than
        stopping with a clear, actionable error. Callers wanting to skip DCR handling entirely
        should use -SkipDcrUpdate on Deploy-AzureLocalAlerts.ps1 instead.
    #>
    param([string]$DcrResourceId)

    $apiVersion = '2023-03-11'

    if ($DcrResourceId -notmatch '(?i)^/subscriptions/[^/]+/resourceGroups/[^/]+/providers/Microsoft\.Insights/dataCollectionRules/[^/]+$') {
        throw "DcrResourceId '$DcrResourceId' is not a valid Data Collection Rule resource ID - cannot extend its event collection. Supply a valid -DcrResourceId, or -SkipDcrUpdate to bypass DCR handling entirely."
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
        throw "Could not read Data Collection Rule '$DcrResourceId' (not found, or not accessible with current credentials) - cannot extend its event collection, so the new cluster-quorum/service-watchdog/Hyper-V log alerts cannot be trusted to receive data. Fix -DcrResourceId, or use -SkipDcrUpdate to bypass DCR handling entirely."
    }

    $dcr = $dcrJson | ConvertFrom-Json
    if (-not $dcr.properties.dataSources) {
        throw "Data Collection Rule '$DcrResourceId' has no dataSources (unexpected shape for an Azure Local Insights DCR) - cannot extend its event collection. Use -SkipDcrUpdate to bypass DCR handling entirely if this is expected."
    }
    if (-not $dcr.properties.dataSources.windowsEventLogs -or @($dcr.properties.dataSources.windowsEventLogs).Count -eq 0) {
        throw "Data Collection Rule '$DcrResourceId' has no windowsEventLogs data source configured - cannot extend its event collection. Add an eventLogsDataSource manually and re-run, or use -SkipDcrUpdate to bypass DCR handling entirely."
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
            throw "Failed to update Data Collection Rule '$DcrResourceId' with the merged event collection - the new log alerts cannot be trusted to receive data until this is resolved. Re-run once the underlying `az rest` PUT failure is fixed, or use -SkipDcrUpdate to bypass DCR handling entirely."
        }
        Write-Host "==> Data Collection Rule updated successfully." -ForegroundColor Green
    }
    finally {
        Remove-Item -Path $tempFile -ErrorAction SilentlyContinue
    }
}

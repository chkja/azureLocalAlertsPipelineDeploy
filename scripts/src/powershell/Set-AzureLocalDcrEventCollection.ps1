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

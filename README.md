# azureLocalAlertsPipelineDeploy

Pipeline-based deployment of Azure Local alert rules (Action Group + metric/log alerts), aligned
to the Basic / Advanced / Premium tiers of the Azure Local Managed Service.

See **[docs/service-tiers-and-alerts.md](docs/service-tiers-and-alerts.md)** for the full tier-to-alert
mapping, the KQL/CLI exploration commands, and how drift prevention works.

## What's in the repo

| Path | Purpose |
|---|---|
| `bicep/main.bicep` | Subscription-scope entry point (optionally creates the RG) |
| `bicep/modules/alerts.bicep` | Resource-group scope orchestrator; gates alerts by `serviceTier` |
| `bicep/modules/actionGroup.bicep` | Action Group with email + webhook receivers |
| `bicep/modules/metricAlerts.bicep` | Platform metric alerts (storage degraded, CPU, memory) |
| `bicep/modules/logAlerts.bicep` | Log Analytics scheduled query alerts (heartbeat, volume health, error-rate) |
| `bicep/parameters/*.parameters.json` | Example parameter sets per tier |
| `scripts/Deploy-AzureLocalAlerts.ps1` | Validates inputs, then runs `az deployment sub create` (or `what-if`) |
| `scripts/Get-AzureLocalAlertExploration.ps1` | Read-only exploration of metrics/tables against a live cluster |
| `pipeline/azure-pipelines.yml` | Azure DevOps CD pipeline |
| `pipeline/environments/*.yml` | Per-tenant/cluster committed config: service connection, tier, resource IDs, receivers |

## Quick start

1. **Explore your environment first** (optional but recommended):
   ```powershell
   pwsh -File scripts/Get-AzureLocalAlertExploration.ps1 `
     -ClusterResourceId "/subscriptions/.../providers/Microsoft.AzureStackHCI/clusters/<name>" `
     -LogAnalyticsWorkspaceId "<workspace-guid>"   # omit for Basic tier
   ```
2. **Deploy locally** for a quick test:
   ```powershell
   az login
   pwsh -File scripts/Deploy-AzureLocalAlerts.ps1 `
     -SubscriptionId "<sub-id>" `
     -ServiceTier "Advanced" `
     -ResourceGroupName "rg-azurelocal-customera-prod" `
     -Location "westeurope" `
     -ClusterResourceId "/subscriptions/.../Microsoft.AzureStackHCI/clusters/<name>" `
     -LogAnalyticsWorkspaceResourceId "/subscriptions/.../Microsoft.OperationalInsights/workspaces/<law>" `
     -ActionGroupName "ag-azurelocal-customera-prod" `
     -ActionGroupShortName "azlalerts" `
     -EmailReceiversJson '[{"name":"ops","emailAddress":"ops@example.com"}]' `
     -WebhookReceiversJson '[{"name":"itsm","serviceUri":"https://example.com/webhook"}]' `
     -WhatIf   # drop this switch to actually deploy
   ```
3. **Onboard via pipeline**: copy `pipeline/environments/example-customera-basic.yml`, fill in your
   values, add the file name to the `environmentFile` parameter list in
   `pipeline/azure-pipelines.yml`, and merge to `main`.

## Prerequisites

- Azure DevOps ARM service connection per tenant/subscription (name referenced by
  `serviceConnection` in each environment file).
- Azure CLI + Bicep (bundled on Microsoft-hosted `ubuntu-latest` agents).
- For Advanced/Premium: Log Analytics workspace + DCR/DCE already collecting Azure Local Insights
  data (see [Azure Local - Insights and Logging - Part 1](https://chkja.dk/blog/azure-local-insights-part1)).

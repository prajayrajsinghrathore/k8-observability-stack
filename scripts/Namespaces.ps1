# File: scripts/Namespaces.ps1
<#
.SYNOPSIS
    Namespace creation and management for the observability stack.
#>

function New-ObservabilityNamespace {
    <#
    .SYNOPSIS
        Creates the observability namespace with appropriate labels.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Config
    )
    
    $namespace = $OBSERVABILITY_NAMESPACE
    
    Write-StepStart "Creating/verifying namespace: $namespace"
    
    # Build labels based on Istio mode
    # Note: We do NOT enable istio-injection at namespace level for observability
    # because it breaks Helm hooks/jobs. Instead, we selectively inject on deployments.
    $istioLabel = ""
    if ($Config.IstioDetected) {
        if ($Config.IstioMode -eq [IstioMode]::Ambient) {
            # Ambient mode can be enabled at namespace level as it doesn't inject sidecars
            $istioLabel = "istio.io/dataplane-mode: ambient"
        }
        else {
            # For Sidecar mode, explicitly disable injection at namespace level
            # We'll enable it per-deployment where needed
            $istioLabel = "istio-injection: disabled"
        }
    }
    
    $manifestPath = Get-ManifestPath "namespace.yaml"
    $replacements = @{
        '\$\{NAMESPACE\}'    = $namespace
        '\$\{ISTIO_LABEL\}'  = $istioLabel
    }
    
    $applied = Apply-ManifestFile -FilePath $manifestPath -Replacements $replacements
    if (-not $applied) {
        throw "Failed to create namespace: $namespace"
    }
    
    # Apply resource quotas (optional, non-critical)
    Write-StepStart "Applying resource quotas..."
    $quotaPath = Get-ManifestPath "resource-quota.yaml"
    $quotaReplacements = @{
        '\$\{NAMESPACE\}' = $namespace
    }
    
    $quotaApplied = Apply-ManifestFile -FilePath $quotaPath -Replacements $quotaReplacements
    if ($quotaApplied) {
        Write-Info "Resource quota applied"
    }
    else {
        Write-Warning $WARN_RESOURCE_QUOTA_FAILED
    }
    
    # Apply limit range
    Write-StepStart "Applying limit ranges..."
    $limitPath = Get-ManifestPath "limit-range.yaml"
    $limitReplacements = @{
        '\$\{NAMESPACE\}' = $namespace
    }
    
    $limitApplied = Apply-ManifestFile -FilePath $limitPath -Replacements $limitReplacements
    if ($limitApplied) {
        Write-Info "Limit range applied"
    }
}

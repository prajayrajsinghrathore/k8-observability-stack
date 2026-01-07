# File: scripts/Jaeger.ps1
<#
.SYNOPSIS
    Jaeger distributed tracing installation for the observability stack.
#>

function Install-Jaeger {
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Config
    )
    
    if ($Config.DryRun) {
        Write-Host "  [DRY RUN] Would install Jaeger" -ForegroundColor Magenta
        return
    }
    
    Write-StepStart "Deploying Jaeger all-in-one..."
    
    # Determine sidecar injection setting based on Istio mode
    $sidecarInject = "false"
    if ($Config.IstioDetected -and $Config.IstioMode -eq [IstioMode]::Sidecar) {
        # For sidecar mode, we might want to inject, but typically tracing backends don't need it
        $sidecarInject = "false"
    }
    
    $manifestPath = Get-ManifestPath "jaeger.yaml"
    $replacements = @{
        '\$\{NAMESPACE\}'            = $OBSERVABILITY_NAMESPACE
        '\$\{JAEGER_VERSION\}'       = $DEFAULT_JAEGER_VERSION
        '\$\{ISTIO_SIDECAR_INJECT\}' = $sidecarInject
    }
    
    Write-Info "Applying Jaeger manifests..."
    $applied = Apply-ManifestFile -FilePath $manifestPath -Replacements $replacements
    
    if (-not $applied) {
        throw "Failed to apply Jaeger manifests"
    }
    
    # Apply ServiceMonitor for Prometheus scraping
    Write-StepStart "Creating Jaeger ServiceMonitor..."
    $smPath = Get-ManifestPath "jaeger-servicemonitor.yaml"
    $smReplacements = @{
        '\$\{NAMESPACE\}' = $OBSERVABILITY_NAMESPACE
    }
    Apply-ManifestFile -FilePath $smPath -Replacements $smReplacements
    
    # Wait for Jaeger to be ready
    Write-StepStart "Waiting for Jaeger deployment..."
    $ready = Wait-ForDeployment -Name "jaeger" -Namespace $OBSERVABILITY_NAMESPACE -TimeoutSeconds 180
    
    if (-not $ready) {
        Write-Warning "Jaeger deployment may not be fully ready"
    }
    
    Write-Info "Jaeger installed successfully"
}

function Get-JaegerEndpoint {
    return "http://jaeger-query.$OBSERVABILITY_NAMESPACE.svc:16686"
}

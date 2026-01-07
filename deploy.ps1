# File: deploy.ps1
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet("local", "aks")]
    [string]$Target,

    [Parameter(Mandatory = $false)]
    [string]$PrometheusVersion = "v3.9.0",

    [Parameter(Mandatory = $false)]
    [string]$GrafanaImageTag = "12.4.0-20766360996",

    [Parameter(Mandatory = $false)]
    [string]$SubscriptionId,

    [Parameter(Mandatory = $false)]
    [string]$ResourceGroup,

    [Parameter(Mandatory = $false)]
    [string]$AksClusterName,

    [Parameter(Mandatory = $false)]
    [string]$TenantId,

    [Parameter(Mandatory = $false)]
    [string]$EntraGroupObjectId,

    [Parameter(Mandatory = $false)]
    [switch]$EnableInternalLoadBalancer,

    [Parameter(Mandatory = $false)]
    [switch]$SkipImageValidation,

    [Parameter(Mandatory = $false)]
    [switch]$DryRun
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

$ScriptRoot = $PSScriptRoot
if (-not $ScriptRoot) { $ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path }

# Import modules
. "$ScriptRoot/scripts/Constants.ps1"
. "$ScriptRoot/scripts/Common.ps1"
. "$ScriptRoot/scripts/Prerequisites.ps1"
. "$ScriptRoot/scripts/Namespaces.ps1"
. "$ScriptRoot/scripts/ImageValidation.ps1"
. "$ScriptRoot/scripts/IstioDetection.ps1"
. "$ScriptRoot/scripts/Prometheus.ps1"
. "$ScriptRoot/scripts/Jaeger.ps1"
. "$ScriptRoot/scripts/Kiali.ps1"
. "$ScriptRoot/scripts/NetworkPolicies.ps1"

# Configuration object
$Config = @{
    Target                     = $Target
    PrometheusVersion          = $PrometheusVersion
    GrafanaImageTag            = $GrafanaImageTag
    SubscriptionId             = $SubscriptionId
    ResourceGroup              = $ResourceGroup
    AksClusterName             = $AksClusterName
    TenantId                   = $TenantId
    EntraGroupObjectId         = $EntraGroupObjectId
    EnableInternalLoadBalancer = $EnableInternalLoadBalancer.IsPresent
    SkipImageValidation        = $SkipImageValidation.IsPresent
    DryRun                     = $DryRun.IsPresent
    IstioDetected              = $false
    IstioMode                  = $null
    IstioHealthy               = $false
}

# Banner
Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "  Kubernetes Observability Stack Deployment" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "Target:              $($Config.Target)" -ForegroundColor Yellow
Write-Host "Namespace:           $OBSERVABILITY_NAMESPACE (fixed)" -ForegroundColor Yellow
Write-Host "Prometheus Version:  $($Config.PrometheusVersion)" -ForegroundColor Yellow
Write-Host "Grafana Image Tag:   $($Config.GrafanaImageTag)" -ForegroundColor Yellow
if ($Config.DryRun) {
    Write-Host "Mode:                DRY RUN" -ForegroundColor Magenta
}
Write-Host ""

# PHASE 1: Prerequisites
Write-SectionHeader "Phase 1: Checking Prerequisites"
try {
    Test-Prerequisites -Config $Config
    Write-Success "All prerequisites satisfied"
} catch {
    Write-Error "Prerequisites check failed: $_"
    exit 1
}

# PHASE 2: Authentication
if ($Config.Target -eq "aks") {
    Write-SectionHeader "Phase 2: AKS Authentication"
    if (-not $Config.SubscriptionId -or -not $Config.ResourceGroup -or -not $Config.AksClusterName) {
        Write-Error $ERR_AKS_PARAMS_MISSING
        exit 1
    }
    try {
        Connect-AksCluster -Config $Config
        Write-Success "Connected to AKS cluster: $($Config.AksClusterName)"
    } catch {
        Write-Error "Failed to connect to AKS: $_"
        exit 1
    }
} else {
    Write-SectionHeader "Phase 2: Local Kubernetes Validation"
    try {
        Test-LocalKubernetes
        Write-Success "Local Kubernetes is accessible"
    } catch {
        Write-Error "Local Kubernetes check failed: $_"
        exit 1
    }
}

# PHASE 3: Istio Detection (NO INSTALLATION)
Write-SectionHeader "Phase 3: Istio Detection"
$istioStatus = Get-IstioStatus
$Config.IstioDetected = $istioStatus.Installed
$Config.IstioMode = $istioStatus.Mode
$Config.IstioHealthy = $istioStatus.Healthy

if ($Config.IstioDetected) {
    Write-Success "Istio detected: $($istioStatus.Details)"
    Write-Info "Istio Version: $($istioStatus.Version)"
    Write-Info "Istio Mode: $($Config.IstioMode)"
    Write-Info "Gateway Present: $($istioStatus.HasGateway)"
    
    if (-not $Config.IstioHealthy) {
        Write-Warning $ERR_ISTIO_UNHEALTHY
    }
} else {
    Write-Info $INFO_ISTIO_NOT_FOUND
}

# PHASE 4: Image Pre-flight Validation
Write-SectionHeader "Phase 4: Image Pre-flight Validation"
if ($Config.SkipImageValidation) {
    Write-Warning "Skipping image validation (as requested)"
} else {
    try {
        $imagesToValidate = Get-RequiredImages -Config $Config
        Test-ImageAvailability -Images $imagesToValidate -Target $Config.Target
        Write-Success "All required images are accessible"
    } catch {
        Write-Error "Image validation failed: $_"
        exit 1
    }
}

# PHASE 5: Create Namespace
Write-SectionHeader "Phase 5: Creating Namespace"
if (-not $Config.DryRun) {
    try {
        New-ObservabilityNamespace -Config $Config
        Write-Success "Namespace created/verified: $OBSERVABILITY_NAMESPACE"
    } catch {
        Write-Error "Failed to create namespace: $_"
        exit 1
    }
} else {
    Write-Host "  [DRY RUN] Would create namespace: $OBSERVABILITY_NAMESPACE" -ForegroundColor Magenta
}

# PHASE 6: Install Prometheus Stack
Write-SectionHeader "Phase 6: Installing Prometheus Stack"
try {
    Install-PrometheusStack -Config $Config
    Write-Success "Prometheus stack installed"
} catch {
    Write-Error "Failed to install Prometheus stack: $_"
    exit 1
}

# PHASE 7: Install Jaeger
Write-SectionHeader "Phase 7: Installing Jaeger"
try {
    Install-Jaeger -Config $Config
    Write-Success "Jaeger installed"
} catch {
    Write-Error "Failed to install Jaeger: $_"
    exit 1
}

# PHASE 8: Install Kiali (only if Istio present)
Write-SectionHeader "Phase 8: Installing Kiali"
try {
    Install-Kiali -Config $Config
    if ($Config.IstioDetected) {
        Write-Success "Kiali installed"
    }
} catch {
    Write-Error "Failed to install Kiali: $_"
    exit 1
}

# PHASE 9: Network Policies
Write-SectionHeader "Phase 9: Applying Network Policies"
try {
    Install-NetworkPolicies -Config $Config
    Write-Success "Network policies applied"
} catch {
    Write-Warning "Network policies could not be applied: $_"
}

# PHASE 10: Wait for Deployments
Write-SectionHeader "Phase 10: Waiting for Deployments"
if (-not $Config.DryRun) {
    try {
        Wait-ForDeployments -Config $Config
        Write-Success "All deployments are ready"
    } catch {
        Write-Warning "Some deployments may not be fully ready: $_"
    }
}

# Summary
Write-Host ""
Write-Host "============================================================" -ForegroundColor Green
Write-Host "  DEPLOYMENT COMPLETE" -ForegroundColor Green
Write-Host "============================================================" -ForegroundColor Green
Write-Host ""
Write-Host "INSTALLED COMPONENTS:" -ForegroundColor Cyan
Write-Host "  - Prometheus (kube-prometheus-stack) - $($Config.PrometheusVersion)"
Write-Host "  - Grafana - $($Config.GrafanaImageTag)"
Write-Host "  - Alertmanager"
Write-Host "  - kube-state-metrics"
Write-Host "  - node-exporter"
Write-Host "  - Jaeger (all-in-one)"
if ($Config.IstioDetected) {
    Write-Host "  - Kiali (via kiali-operator)"
    Write-Host ""
    Write-Host "ISTIO INTEGRATION:" -ForegroundColor Cyan
    Write-Host "  - Mode: $($Config.IstioMode)"
    Write-Host "  - Prometheus configured to scrape Istio metrics"
}
Write-Host ""
Write-Host "AUTHENTICATION:" -ForegroundColor Cyan
if ($Config.Target -eq "local") {
    Write-Host "  - Grafana: No authentication (anonymous admin access)"
    Write-Host "  - Prometheus: No authentication"
} else {
    if ($Config.EntraGroupObjectId) {
        Write-Host "  - Grafana: Azure Entra ID (group: $($Config.EntraGroupObjectId))"
    } else {
        Write-Host "  - Grafana: No authentication (provide -EntraGroupObjectId for Entra ID)"
    }
}
Write-Host ""
Write-Host "ACCESS (via kubectl port-forward):" -ForegroundColor Cyan
Write-Host ""
Write-Host "  Prometheus:" -ForegroundColor Yellow
Write-Host "    kubectl port-forward svc/prometheus-kube-prometheus-prometheus -n $OBSERVABILITY_NAMESPACE 9090:9090"
Write-Host "    http://localhost:9090"
Write-Host ""
Write-Host "  Grafana:" -ForegroundColor Yellow
Write-Host "    kubectl port-forward svc/prometheus-grafana -n $OBSERVABILITY_NAMESPACE 3000:80"
Write-Host "    http://localhost:3000"
Write-Host ""
Write-Host "  Alertmanager:" -ForegroundColor Yellow
Write-Host "    kubectl port-forward svc/prometheus-kube-prometheus-alertmanager -n $OBSERVABILITY_NAMESPACE 9093:9093"
Write-Host "    http://localhost:9093"
Write-Host ""
Write-Host "  Jaeger:" -ForegroundColor Yellow
Write-Host "    kubectl port-forward svc/jaeger-query -n $OBSERVABILITY_NAMESPACE 16686:16686"
Write-Host "    http://localhost:16686"
if ($Config.IstioDetected) {
    Write-Host ""
    Write-Host "  Kiali:" -ForegroundColor Yellow
    Write-Host "    kubectl port-forward svc/kiali -n $OBSERVABILITY_NAMESPACE 20001:20001"
    Write-Host "    http://localhost:20001"
}
Write-Host ""
Write-Host "To uninstall: ./rollback.ps1 -Target $($Config.Target)" -ForegroundColor Cyan
Write-Host ""

exit 0

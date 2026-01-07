# File: rollback.ps1
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet("local", "aks")]
    [string]$Target,

    [Parameter(Mandatory = $false)]
    [string]$SubscriptionId,

    [Parameter(Mandatory = $false)]
    [string]$ResourceGroup,

    [Parameter(Mandatory = $false)]
    [string]$AksClusterName,

    [Parameter(Mandatory = $false)]
    [switch]$RemoveNamespace,

    [Parameter(Mandatory = $false)]
    [switch]$Force
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

$ScriptRoot = $PSScriptRoot
if (-not $ScriptRoot) { $ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path }

. "$ScriptRoot/scripts/Constants.ps1"
. "$ScriptRoot/scripts/Common.ps1"

$Namespace = $OBSERVABILITY_NAMESPACE

# Banner
Write-Host ""
Write-Host "============================================================" -ForegroundColor Red
Write-Host "  Kubernetes Observability Stack - ROLLBACK/CLEANUP" -ForegroundColor Red
Write-Host "============================================================" -ForegroundColor Red
Write-Host ""
Write-Host "Target:              $Target" -ForegroundColor Yellow
Write-Host "Namespace:           $Namespace" -ForegroundColor Yellow
Write-Host "Remove Namespace:    $($RemoveNamespace.IsPresent)" -ForegroundColor Yellow
Write-Host ""

if (-not $Force.IsPresent) {
    Write-Host "WARNING: This will remove all observability components and their data!" -ForegroundColor Red
    $confirm = Read-Host "Type 'yes' to continue"
    if ($confirm -ne "yes") {
        Write-Host "Rollback cancelled." -ForegroundColor Yellow
        exit 0
    }
}

# Prerequisites
Write-SectionHeader "Checking Prerequisites"

if (-not (Get-Command kubectl -ErrorAction SilentlyContinue)) {
    Write-Error $ERR_KUBECTL_NOT_FOUND
    exit 1
}

if (-not (Get-Command helm -ErrorAction SilentlyContinue)) {
    Write-Error $ERR_HELM_NOT_FOUND
    exit 1
}

if ($Target -eq "aks") {
    if (-not $SubscriptionId -or -not $ResourceGroup -or -not $AksClusterName) {
        Write-Error $ERR_AKS_PARAMS_MISSING
        exit 1
    }
    
    Write-Info "Connecting to AKS cluster..."
    if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
        Write-Error $ERR_AZ_CLI_NOT_FOUND
        exit 1
    }
    
    $azAccount = az account show 2>$null | ConvertFrom-Json -ErrorAction SilentlyContinue
    if (-not $azAccount) {
        az login
    }
    az account set --subscription $SubscriptionId
    az aks get-credentials --resource-group $ResourceGroup --name $AksClusterName --overwrite-existing
    Write-Success "Connected to AKS cluster"
}

Write-Success "Prerequisites verified"

# Helper function
function Invoke-SafeHelmUninstall {
    param([string]$ReleaseName, [string]$Ns)
    $existing = helm list -n $Ns -q 2>$null | Where-Object { $_ -eq $ReleaseName }
    if ($existing) {
        Write-Info "Uninstalling Helm release: $ReleaseName..."
        helm uninstall $ReleaseName -n $Ns --wait 2>$null
        Write-Success "Removed: $ReleaseName"
    } else {
        Write-Info "Skipped (not found): $ReleaseName"
    }
}

# Phase 1: Remove Kiali
Write-SectionHeader "Removing Kiali"
Invoke-SafeHelmUninstall -ReleaseName "kiali-operator" -Ns $Namespace

$kialiCR = kubectl get kiali kiali -n $Namespace 2>$null
if ($LASTEXITCODE -eq 0) {
    Write-Info "Removing Kiali CR..."
    # Remove finalizers first to prevent hanging
    $patchJson = '{"metadata":{"finalizers":null}}'
    kubectl patch kiali kiali -n $Namespace -p $patchJson --type=merge 2>$null
    Start-Sleep -Seconds 2
    kubectl delete kiali kiali -n $Namespace --ignore-not-found=true --grace-period=0 --force 2>$null
}

kubectl delete crd kialis.kiali.io --ignore-not-found=true 2>$null
Write-Success "Kiali removed"

# Phase 2: Remove Jaeger
Write-SectionHeader "Removing Jaeger"
$jaegerResources = @("deployment/jaeger", "service/jaeger-query", "service/jaeger-collector", "service/jaeger-agent", "serviceaccount/jaeger", "servicemonitor/jaeger")
foreach ($resource in $jaegerResources) {
    kubectl delete $resource -n $Namespace --ignore-not-found=true 2>$null
}
Write-Success "Jaeger removed"

# Phase 3: Remove Prometheus Stack
Write-SectionHeader "Removing Prometheus Stack"
Invoke-SafeHelmUninstall -ReleaseName "prometheus" -Ns $Namespace

$promCrds = @(
    "alertmanagerconfigs.monitoring.coreos.com",
    "alertmanagers.monitoring.coreos.com",
    "podmonitors.monitoring.coreos.com",
    "probes.monitoring.coreos.com",
    "prometheusagents.monitoring.coreos.com",
    "prometheuses.monitoring.coreos.com",
    "prometheusrules.monitoring.coreos.com",
    "scrapeconfigs.monitoring.coreos.com",
    "servicemonitors.monitoring.coreos.com",
    "thanosrulers.monitoring.coreos.com"
)

Write-Info "Removing Prometheus Operator CRDs..."
foreach ($crd in $promCrds) {
    kubectl delete crd $crd --ignore-not-found=true 2>$null
}

Write-Info "Removing PVCs..."
kubectl delete pvc -n $Namespace -l "app.kubernetes.io/name=prometheus" --ignore-not-found=true 2>$null
kubectl delete pvc -n $Namespace -l "app.kubernetes.io/name=alertmanager" --ignore-not-found=true 2>$null
kubectl delete pvc -n $Namespace -l "app.kubernetes.io/name=grafana" --ignore-not-found=true 2>$null
Write-Success "Prometheus stack removed"

# Phase 4: Remove Network Policies
Write-SectionHeader "Removing Network Policies"
kubectl delete networkpolicy -n $Namespace --all --ignore-not-found=true 2>$null
Write-Success "Network policies removed"

# Phase 5: Remove ConfigMaps and other resources
Write-SectionHeader "Removing Additional Resources"
kubectl delete configmap -n $Namespace -l "grafana_dashboard=1" --ignore-not-found=true 2>$null
kubectl delete resourcequota observability-quota -n $Namespace --ignore-not-found=true 2>$null
kubectl delete limitrange observability-limits -n $Namespace --ignore-not-found=true 2>$null
Write-Success "Additional resources removed"

# Phase 6: Remove Namespace
if ($RemoveNamespace.IsPresent) {
    Write-SectionHeader "Removing Namespace"
    Write-Info "Removing namespace: $Namespace..."
    kubectl delete namespace $Namespace --ignore-not-found=true 2>$null
    Write-Success "Namespace removed"
}

# Phase 7: Cleanup Helm Repos
Write-SectionHeader "Cleaning Up Helm Repositories"
$repos = @("prometheus-community", "kiali")
foreach ($repo in $repos) {
    $existing = helm repo list 2>$null | Select-String "^$repo\s"
    if ($existing) {
        Write-Info "Removing Helm repo: $repo..."
        helm repo remove $repo 2>$null
    }
}
Write-Success "Helm repositories cleaned"

# Summary
Write-Host ""
Write-Host "============================================================" -ForegroundColor Green
Write-Host "  ROLLBACK COMPLETE" -ForegroundColor Green
Write-Host "============================================================" -ForegroundColor Green
Write-Host ""
Write-Host "Removed components:" -ForegroundColor Cyan
Write-Host "  - Kiali (operator and CR)"
Write-Host "  - Jaeger"
Write-Host "  - Prometheus stack (Prometheus, Grafana, Alertmanager)"
Write-Host "  - kube-state-metrics"
Write-Host "  - node-exporter"
Write-Host "  - Network Policies"
if ($RemoveNamespace.IsPresent) {
    Write-Host "  - Namespace: $Namespace"
}
Write-Host ""
Write-Host "To redeploy: ./deploy.ps1 -Target $Target" -ForegroundColor Cyan
Write-Host ""

exit 0

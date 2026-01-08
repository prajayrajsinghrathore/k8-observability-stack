# File: scripts/NetworkPolicies.ps1
<#
.SYNOPSIS
    Network policies for the observability stack.
#>

function Install-NetworkPolicies {
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Config
    )
    
    if ($Config.DryRun) {
        Write-Host "  [DRY RUN] Would install network policies" -ForegroundColor Magenta
        return
    }
    
    Write-StepStart "Applying network policies..."
    
    $manifestPath = Get-ManifestPath "network-policies.yaml"
    $replacements = @{
        '\$\{NAMESPACE\}' = $OBSERVABILITY_NAMESPACE
    }
    
    $applied = Apply-ManifestFile -FilePath $manifestPath -Replacements $replacements
    
    if (-not $applied) {
        Write-Warning $WARN_NETWORK_POLICY_NOT_SUPPORTED
    }
    else {
        $policies = kubectl get networkpolicy -n $OBSERVABILITY_NAMESPACE -o name 2>$null
        if ($policies) {
            $count = ($policies | Measure-Object).Count
            Write-Info "Created $count network policies"
        }
    }
}

function Wait-ForDeployments {
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Config
    )
    
    $deployments = @(
        @{ Name = "prometheus-kube-prometheus-operator"; Timeout = 120 },
        @{ Name = "prometheus-kube-state-metrics"; Timeout = 120 },
        @{ Name = "prometheus-grafana"; Timeout = 180 },
        @{ Name = "jaeger"; Timeout = 120 }
    )
    
    # Add Kiali if Istio is present
    if ($Config.IstioDetected) {
        $deployments += @{ Name = "kiali-operator"; Timeout = 120 }
    }
    
    foreach ($deploy in $deployments) {
        $exists = kubectl get deployment $deploy.Name -n $OBSERVABILITY_NAMESPACE -o name 2>$null
        if ($LASTEXITCODE -eq 0 -and $exists) {
            Write-Info "Waiting for $($deploy.Name)..."
            Wait-ForDeployment -Name $deploy.Name -Namespace $OBSERVABILITY_NAMESPACE -TimeoutSeconds $deploy.Timeout
        }
    }
    
    # Wait for StatefulSets
    $statefulsets = @(
        @{ Name = "prometheus-prometheus-prometheus"; Timeout = 180 },
        @{ Name = "alertmanager-prometheus-alertmanager"; Timeout = 120 }
    )
    
    foreach ($ss in $statefulsets) {
        $exists = kubectl get statefulset $ss.Name -n $OBSERVABILITY_NAMESPACE -o name 2>$null
        if ($LASTEXITCODE -eq 0 -and $exists) {
            Write-Info "Waiting for $($ss.Name)..."
            Wait-ForStatefulSet -Name $ss.Name -Namespace $OBSERVABILITY_NAMESPACE -TimeoutSeconds $ss.Timeout
        }
    }
    
    # Wait for DaemonSets
    $exists = kubectl get daemonset prometheus-prometheus-node-exporter -n $OBSERVABILITY_NAMESPACE -o name 2>$null
    if ($LASTEXITCODE -eq 0 -and $exists) {
        Write-Info "Waiting for prometheus-prometheus-node-exporter..."
        Wait-ForDaemonSet -Name "prometheus-prometheus-node-exporter" -Namespace $OBSERVABILITY_NAMESPACE -TimeoutSeconds 120
    }
    
    # Wait for Kiali if Istio present
    if ($Config.IstioDetected) {
        Start-Sleep -Seconds 5
        $kialiExists = kubectl get deployment kiali -n $OBSERVABILITY_NAMESPACE -o name 2>$null
        if ($LASTEXITCODE -eq 0 -and $kialiExists) {
            Write-Info "Waiting for kiali..."
            Wait-ForDeployment -Name "kiali" -Namespace $OBSERVABILITY_NAMESPACE -TimeoutSeconds 180
        }
    }
}

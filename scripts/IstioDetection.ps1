# File: scripts/IstioDetection.ps1
<#
.SYNOPSIS
    Istio detection and mode identification for the observability stack.
    This module ONLY detects Istio presence and mode - it does NOT install Istio.
#>

# Istio mode enumeration
enum IstioMode {
    NotInstalled
    Sidecar
    Ambient
    Unknown
}

function Get-IstioStatus {
    <#
    .SYNOPSIS
        Detects if Istio is installed and determines its operational mode.
    .OUTPUTS
        Returns a hashtable with:
        - Installed: bool
        - Mode: IstioMode (NotInstalled, Sidecar, Ambient, Unknown)
        - Healthy: bool
        - Version: string or $null
        - HasGateway: bool
        - Details: string
    #>
    param()
    
    $status = @{
        Installed   = $false
        Mode        = [IstioMode]::NotInstalled
        Healthy     = $false
        Version     = $null
        HasGateway  = $false
        Details     = ""
    }
    
    Write-StepStart "Checking for Istio in namespace: $ISTIO_NAMESPACE"
    
    # Check if istio-system namespace exists
    $nsExists = Test-NamespaceExists -Namespace $ISTIO_NAMESPACE
    if (-not $nsExists) {
        Write-Info "Namespace '$ISTIO_NAMESPACE' does not exist"
        $status.Details = "Istio namespace not found"
        return $status
    }
    
    # Check for istiod deployment
    $istiod = kubectl get deployment istiod -n $ISTIO_NAMESPACE -o json 2>$null | ConvertFrom-Json -ErrorAction SilentlyContinue
    if (-not $istiod) {
        Write-Info "istiod deployment not found"
        $status.Details = "istiod deployment not found in $ISTIO_NAMESPACE"
        return $status
    }
    
    $status.Installed = $true
    Write-Info "istiod deployment found"
    
    # Get Istio version from istiod image
    try {
        $image = $istiod.spec.template.spec.containers[0].image
        if ($image -match ":(.+)$") {
            $status.Version = $Matches[1]
            Write-Info "Istio version: $($status.Version)"
        }
    }
    catch {
        Write-Warning "Could not determine Istio version"
    }
    
    # Check istiod health
    $readyReplicas = $istiod.status.readyReplicas
    $desiredReplicas = $istiod.spec.replicas
    if ($readyReplicas -ge 1 -and $readyReplicas -eq $desiredReplicas) {
        $status.Healthy = $true
        Write-Info "istiod is healthy ($readyReplicas/$desiredReplicas replicas ready)"
    }
    else {
        Write-Warning "istiod may not be healthy ($readyReplicas/$desiredReplicas replicas ready)"
    }
    
    # Check for istio-ingressgateway
    $gateway = kubectl get deployment istio-ingressgateway -n $ISTIO_NAMESPACE -o name 2>$null
    if ($LASTEXITCODE -eq 0 -and $gateway) {
        $status.HasGateway = $true
        Write-Info "Istio ingress gateway is present"
    }
    else {
        Write-Info "Istio ingress gateway is not present"
    }
    
    # Determine Istio mode: Ambient vs Sidecar
    $status.Mode = Get-IstioMode
    
    switch ($status.Mode) {
        ([IstioMode]::Ambient) {
            $status.Details = "Istio running in Ambient mode (ztunnel-based)"
            Write-Info $INFO_ISTIO_AMBIENT_MODE
        }
        ([IstioMode]::Sidecar) {
            $status.Details = "Istio running in Sidecar mode (envoy proxy injection)"
            Write-Info $INFO_ISTIO_SIDECAR_MODE
        }
        ([IstioMode]::Unknown) {
            $status.Details = "Istio installed but mode could not be determined"
            Write-Warning "Could not determine Istio mode"
        }
    }
    
    return $status
}

function Get-IstioMode {
    <#
    .SYNOPSIS
        Determines whether Istio is running in Sidecar or Ambient mode.
    #>
    
    # Check for ztunnel DaemonSet (indicates Ambient mode)
    $ztunnel = kubectl get daemonset ztunnel -n $ISTIO_NAMESPACE -o name 2>$null
    if ($LASTEXITCODE -eq 0 -and $ztunnel) {
        Write-Info "ztunnel DaemonSet found - Ambient mode detected"
        return [IstioMode]::Ambient
    }
    
    # Check for CNI DaemonSet with ambient configuration
    $cniConfig = kubectl get daemonset istio-cni-node -n $ISTIO_NAMESPACE -o json 2>$null | ConvertFrom-Json -ErrorAction SilentlyContinue
    if ($cniConfig) {
        $cniArgs = $cniConfig.spec.template.spec.containers | 
            Where-Object { $_.name -eq "install-cni" } | 
            Select-Object -ExpandProperty args -ErrorAction SilentlyContinue
        
        if ($cniArgs -match "ambient") {
            Write-Info "Istio CNI configured for Ambient mode"
            return [IstioMode]::Ambient
        }
    }
    
    # Check for waypoint proxies (Ambient mode gateway equivalent)
    $waypoints = kubectl get gateways.gateway.networking.k8s.io -A -l istio.io/waypoint-for 2>$null
    if ($LASTEXITCODE -eq 0 -and $waypoints) {
        Write-Info "Waypoint proxies found - Ambient mode detected"
        return [IstioMode]::Ambient
    }
    
    # Check for namespace labels indicating ambient mode
    $ambientNamespaces = kubectl get namespaces -l istio.io/dataplane-mode=ambient -o name 2>$null
    if ($LASTEXITCODE -eq 0 -and $ambientNamespaces) {
        Write-Info "Namespaces with ambient mode label found"
        return [IstioMode]::Ambient
    }
    
    # Check for sidecar injector webhook (indicates Sidecar mode)
    $webhook = kubectl get mutatingwebhookconfiguration istio-sidecar-injector -o name 2>$null
    if ($LASTEXITCODE -eq 0 -and $webhook) {
        Write-Info "Sidecar injector webhook found - Sidecar mode detected"
        return [IstioMode]::Sidecar
    }
    
    # Check for sidecar-injected pods
    $sidecarPods = kubectl get pods -A -o jsonpath='{.items[*].spec.containers[*].name}' 2>$null
    if ($sidecarPods -match "istio-proxy") {
        Write-Info "istio-proxy sidecars found - Sidecar mode detected"
        return [IstioMode]::Sidecar
    }
    
    # Default: If istiod exists but we can't determine mode, assume sidecar (more common)
    Write-Warning "Could not definitively determine Istio mode, defaulting to Sidecar"
    return [IstioMode]::Sidecar
}

function Test-IstioConnectivity {
    <#
    .SYNOPSIS
        Tests connectivity to Istio components.
    #>
    param()
    
    $result = @{
        IstiodReachable = $false
        GatewayReachable = $false
    }
    
    # Test istiod service
    $istiodSvc = kubectl get svc istiod -n $ISTIO_NAMESPACE -o jsonpath='{.spec.clusterIP}' 2>$null
    if ($LASTEXITCODE -eq 0 -and $istiodSvc) {
        $result.IstiodReachable = $true
    }
    
    # Test gateway service
    $gatewaySvc = kubectl get svc istio-ingressgateway -n $ISTIO_NAMESPACE -o jsonpath='{.spec.clusterIP}' 2>$null
    if ($LASTEXITCODE -eq 0 -and $gatewaySvc) {
        $result.GatewayReachable = $true
    }
    
    return $result
}

function Get-IstioMetricsEndpoint {
    <#
    .SYNOPSIS
        Returns the appropriate metrics endpoint based on Istio mode.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [IstioMode]$Mode
    )
    
    switch ($Mode) {
        ([IstioMode]::Ambient) {
            # Ambient mode uses ztunnel for metrics
            return @{
                IstiodMetrics = "http://istiod.$ISTIO_NAMESPACE.svc:15014/metrics"
                ZtunnelMetrics = "http://ztunnel.$ISTIO_NAMESPACE.svc:15020/metrics"
            }
        }
        ([IstioMode]::Sidecar) {
            # Sidecar mode uses envoy sidecars
            return @{
                IstiodMetrics = "http://istiod.$ISTIO_NAMESPACE.svc:15014/metrics"
                EnvoyStats = "/stats/prometheus"  # Available on port 15090 of each sidecar
            }
        }
        default {
            return @{
                IstiodMetrics = "http://istiod.$ISTIO_NAMESPACE.svc:15014/metrics"
            }
        }
    }
}

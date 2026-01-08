# File: scripts/Kiali.ps1
<#
.SYNOPSIS
    Kiali installation via kiali-operator Helm chart.
    Kiali requires Istio to be present - will be skipped if Istio is not detected.
#>

function Install-Kiali {
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Config
    )
    
    # Kiali requires Istio
    if (-not $Config.IstioDetected) {
        Write-Warning $WARN_KIALI_REQUIRES_ISTIO
        return
    }
    
    if ($Config.DryRun) {
        Write-Host "  [DRY RUN] Would install Kiali" -ForegroundColor Magenta
        return
    }
    
    Write-StepStart "Adding Kiali Helm repository..."
    Add-HelmRepoIfNotExists -Name "kiali" -Url "https://kiali.org/helm-charts"
    Update-HelmRepos
    
    Write-StepStart "Generating Kiali configuration..."
    $kialiValues = Get-KialiValues -Config $Config
    
    $valuesFile = Join-Path $env:TEMP "kiali-values.yaml"
    $kialiValues | Out-File -FilePath $valuesFile -Encoding utf8 -Force
    
    Write-StepStart "Installing/upgrading Kiali operator..."
    $releaseExists = Test-HelmReleaseExists -ReleaseName "kiali-operator" -Namespace $OBSERVABILITY_NAMESPACE
    
    $helmCmd = if (-not $releaseExists) { "install" } else { "upgrade" }
    Write-Info "$helmCmd Kiali operator..."
    
    helm $helmCmd kiali-operator kiali/kiali-operator `
        --namespace $OBSERVABILITY_NAMESPACE `
        --version $DEFAULT_KIALI_VERSION `
        --values $valuesFile `
        --wait `
        --timeout $DEFAULT_HELM_TIMEOUT
    
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to $helmCmd Kiali operator"
    }
    
    Remove-Item $valuesFile -Force -ErrorAction SilentlyContinue
    
    # Wait for Kiali
    Write-StepStart "Waiting for Kiali deployment..."
    
    $operatorReady = Wait-ForDeployment -Name "kiali-operator" -Namespace $OBSERVABILITY_NAMESPACE -TimeoutSeconds 120
    if (-not $operatorReady) {
        Write-Warning "Kiali operator may not be fully ready"
    }
    
    # Wait for Kiali server (created by operator)
    Start-Sleep -Seconds 10
    
    $maxWait = 180
    $waited = 0
    while ($waited -lt $maxWait) {
        $kiali = kubectl get deployment kiali -n $OBSERVABILITY_NAMESPACE -o name 2>$null
        if ($LASTEXITCODE -eq 0 -and $kiali) {
            $kialiReady = Wait-ForDeployment -Name "kiali" -Namespace $OBSERVABILITY_NAMESPACE -TimeoutSeconds ($maxWait - $waited)
            if ($kialiReady) {
                break
            }
        }
        Start-Sleep -Seconds 10
        $waited += 10
        Write-Info "Waiting for Kiali server to be created by operator... ($waited/$maxWait seconds)"
    }
    
    Write-Info "Kiali installed successfully"
}

function Get-KialiValues {
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Config
    )
    
    $namespace = $OBSERVABILITY_NAMESPACE
    
    # Determine authentication strategy
    $authStrategy = "anonymous"
    if ($Config.Target -eq "aks" -and $Config.EntraGroupObjectId) {
        # For AKS with Entra ID, we could use token auth, but anonymous is simpler for internal use
        # Kiali doesn't have native Azure AD support, so we rely on network-level security
        $authStrategy = "anonymous"
    }
    
    return @"
image:
  repo: quay.io/kiali/kiali-operator
  tag: v$DEFAULT_KIALI_VERSION
  pullPolicy: IfNotPresent

resources:
  requests:
    cpu: 10m
    memory: 64Mi
  limits:
    cpu: 500m
    memory: 512Mi

securityContext:
  runAsNonRoot: true
  allowPrivilegeEscalation: false
  readOnlyRootFilesystem: true
  capabilities:
    drop:
      - ALL
  seccompProfile:
    type: RuntimeDefault

cr:
  create: true
  name: kiali
  namespace: $namespace
  spec:
    istio_namespace: "$ISTIO_NAMESPACE"
    
    deployment:
      accessible_namespaces:
        - "**"

      pod_annotations:
        sidecar.istio.io/inject: "false"
      
      resources:
        requests:
          cpu: 50m
          memory: 64Mi
        limits:
          cpu: 500m
          memory: 512Mi
      
      security_context:
        run_as_non_root: true
        run_as_user: 1000
        fs_group: 1000
    
    auth:
      strategy: $authStrategy
    
    server:
      port: 20001
      web_root: /kiali
    
    external_services:
      prometheus:
        url: "http://prometheus-prometheus.$namespace.svc:9090"
      
      tracing:
        enabled: true
        in_cluster_url: "http://jaeger-query.$namespace.svc:16686"
        use_grpc: false
      
      grafana:
        enabled: true
        in_cluster_url: "http://prometheus-grafana.$namespace.svc:80"
      
      istio:
        root_namespace: "$ISTIO_NAMESPACE"
        component_status:
          enabled: true
          components:
            - app_label: istiod
              is_core: true
              namespace: "$ISTIO_NAMESPACE"
    
    istio_labels:
      app_label_name: "app"
      version_label_name: "version"
    
    kubernetes_config:
      burst: 200
      qps: 175
      cache_enabled: true
      cache_duration: 300
"@
}

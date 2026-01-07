# File: scripts/Istio.ps1
<#
.SYNOPSIS
    Istio installation and configuration for the observability stack.
#>

function Test-IstioInstalled {
    <#
    .SYNOPSIS
        Checks if Istio is already installed in the cluster.
    #>
    param(
        [string]$Namespace = "istio-system"
    )
    
    # Check for istiod deployment
    $istiod = kubectl get deployment istiod -n $Namespace -o name 2>$null
    return ($LASTEXITCODE -eq 0 -and $istiod)
}

function Test-IstioGateway {
    <#
    .SYNOPSIS
        Checks if Istio ingress gateway is installed and running.
    #>
    param(
        [string]$Namespace = "istio-system"
    )
    
    $gateway = kubectl get deployment istio-ingressgateway -n $Namespace -o name 2>$null
    return ($LASTEXITCODE -eq 0 -and $gateway)
}

function Install-Istio {
    <#
    .SYNOPSIS
        Installs Istio using Helm charts with minimal profile.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Config
    )
    
    # Check if Istio is already installed
    if (Test-IstioInstalled -Namespace $Config.IstioNamespace) {
        Write-Info "Istio is already installed"
        
        # Verify connectivity
        Write-StepStart "Verifying Istio connectivity..."
        $istiodReady = kubectl get deployment istiod -n $Config.IstioNamespace -o jsonpath='{.status.readyReplicas}' 2>$null
        if ($istiodReady -gt 0) {
            Write-Info "Istiod is running with $istiodReady replica(s)"
        }
        else {
            Write-Warning "Istiod may not be fully ready"
        }
        
        # Check for gateway
        if (Test-IstioGateway -Namespace $Config.IstioNamespace) {
            Write-Info "Istio ingress gateway is present"
        }
        else {
            Write-Info "Istio ingress gateway is not installed (minimal profile)"
        }
        
        return
    }
    
    if ($Config.DryRun) {
        Write-Host "  [DRY RUN] Would install Istio" -ForegroundColor Magenta
        return
    }
    
    Write-StepStart "Installing Istio via Helm..."
    
    # Add Istio Helm repository
    Add-HelmRepoIfNotExists -Name "istio" -Url "https://istio-release.storage.googleapis.com/charts"
    Update-HelmRepos
    
    # Istio version to use
    $istioVersion = "1.25.2"
    
    # Install Istio base (CRDs)
    Write-StepStart "Installing Istio base (CRDs)..."
    
    $baseExists = Test-HelmReleaseExists -ReleaseName "istio-base" -Namespace $Config.IstioNamespace
    
    if (-not $baseExists) {
        helm install istio-base istio/base `
            --namespace $Config.IstioNamespace `
            --version $istioVersion `
            --set defaultRevision=default `
            --wait `
            --timeout $Config.HelmTimeout
        
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to install Istio base"
        }
    }
    else {
        Write-Info "Istio base already installed, upgrading..."
        helm upgrade istio-base istio/base `
            --namespace $Config.IstioNamespace `
            --version $istioVersion `
            --set defaultRevision=default `
            --wait `
            --timeout $Config.HelmTimeout
    }
    
    # Install Istiod (control plane)
    Write-StepStart "Installing Istiod (control plane)..."
    
    # Minimal profile values with Docker Hub images
    $istiodValues = @"
pilot:
  image: docker.io/istio/pilot:$istioVersion
  resources:
    requests:
      cpu: 100m
      memory: 128Mi
    limits:
      cpu: 500m
      memory: 1Gi
  autoscaleEnabled: false
  replicaCount: 1
  
global:
  hub: docker.io/istio
  tag: $istioVersion
  proxy:
    image: proxyv2
    resources:
      requests:
        cpu: 50m
        memory: 64Mi
      limits:
        cpu: 200m
        memory: 256Mi
  proxy_init:
    image: proxyv2
    resources:
      requests:
        cpu: 10m
        memory: 10Mi
      limits:
        cpu: 100m
        memory: 50Mi

meshConfig:
  enablePrometheusMerge: true
  defaultConfig:
    holdApplicationUntilProxyStarts: true
    proxyMetadata:
      ISTIO_META_DNS_CAPTURE: "true"
      ISTIO_META_DNS_AUTO_ALLOCATE: "true"
  accessLogFile: /dev/stdout
"@
    
    $valuesFile = Join-Path $env:TEMP "istiod-values.yaml"
    $istiodValues | Out-File -FilePath $valuesFile -Encoding utf8 -Force
    
    $istiodExists = Test-HelmReleaseExists -ReleaseName "istiod" -Namespace $Config.IstioNamespace
    
    if (-not $istiodExists) {
        helm install istiod istio/istiod `
            --namespace $Config.IstioNamespace `
            --version $istioVersion `
            --values $valuesFile `
            --wait `
            --timeout $Config.HelmTimeout
        
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to install Istiod"
        }
    }
    else {
        Write-Info "Istiod already installed, upgrading..."
        helm upgrade istiod istio/istiod `
            --namespace $Config.IstioNamespace `
            --version $istioVersion `
            --values $valuesFile `
            --wait `
            --timeout $Config.HelmTimeout
    }
    
    # Clean up temp file
    Remove-Item $valuesFile -Force -ErrorAction SilentlyContinue
    
    # Wait for istiod to be ready
    Write-StepStart "Waiting for Istiod to be ready..."
    $ready = Wait-ForDeployment -Name "istiod" -Namespace $Config.IstioNamespace -TimeoutSeconds 300
    if (-not $ready) {
        throw "Istiod failed to become ready"
    }
    
    Write-Info "Istio installed successfully (minimal profile, no gateway)"
}

function Get-IstioStatus {
    <#
    .SYNOPSIS
        Returns the status of Istio components.
    #>
    param(
        [string]$Namespace = "istio-system"
    )
    
    $status = @{
        Installed = $false
        IstiodReady = $false
        GatewayInstalled = $false
        Version = $null
    }
    
    if (Test-IstioInstalled -Namespace $Namespace) {
        $status.Installed = $true
        
        # Get version
        $version = kubectl get deployment istiod -n $Namespace -o jsonpath='{.spec.template.spec.containers[0].image}' 2>$null
        if ($version) {
            $status.Version = ($version -split ":")[-1]
        }
        
        # Check ready status
        $ready = kubectl get deployment istiod -n $Namespace -o jsonpath='{.status.readyReplicas}' 2>$null
        $status.IstiodReady = ($ready -gt 0)
        
        # Check gateway
        $status.GatewayInstalled = Test-IstioGateway -Namespace $Namespace
    }
    
    return $status
}

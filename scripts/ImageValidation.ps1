# File: scripts/ImageValidation.ps1
<#
.SYNOPSIS
    Pre-flight image validation to detect and fail fast on image pull issues.
#>

function Get-RequiredImages {
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Config
    )
    
    $promImageTag = $Config.PrometheusVersion
    
    $images = @(
        "quay.io/prometheus/prometheus:$promImageTag",
        "quay.io/prometheus/alertmanager:v0.28.1",
        "quay.io/prometheus/node-exporter:v1.8.2",
        "quay.io/prometheus-operator/prometheus-operator:v0.81.0",
        "quay.io/prometheus-operator/prometheus-config-reloader:v0.81.0",
        "registry.k8s.io/kube-state-metrics/kube-state-metrics:v2.15.0",
        "grafana/grafana:$($Config.GrafanaImageTag)",
        "jaegertracing/all-in-one:$($DEFAULT_JAEGER_VERSION)"
    )
    
    # Add Kiali images only if Istio is present
    if ($Config.IstioDetected) {
        $images += @(
            "quay.io/kiali/kiali-operator:v$($DEFAULT_KIALI_VERSION)",
            "quay.io/kiali/kiali:v$($DEFAULT_KIALI_VERSION)"
        )
    }
    
    return $images
}

function Test-DnsResolution {
    param([string[]]$RegistryHosts)

    $failed = @()

    foreach ($registryHost in $RegistryHosts) {
        Write-Info "Testing DNS resolution for: $registryHost"

        $resolved = $false

        # Try .NET DNS resolution first
        try {
            $addresses = [System.Net.Dns]::GetHostAddresses($registryHost)
            if ($addresses.Count -gt 0) {
                Write-Info "  Resolved to: $($addresses[0].IPAddressToString)"
                $resolved = $true
            }
        }
        catch {
            Write-Warning "  .NET DNS resolution failed, trying nslookup..."
        }

        # Fallback to nslookup if .NET resolution failed
        if (-not $resolved) {
            try {
                $nslookupResult = nslookup $registryHost 2>&1
                if ($LASTEXITCODE -eq 0 -and $nslookupResult -match "Address") {
                    Write-Info "  Resolved via nslookup"
                    $resolved = $true
                }
            }
            catch {
                # Ignore nslookup errors
            }
        }

        if (-not $resolved) {
            Write-Warning "  Failed to resolve: $registryHost"
            $failed += $registryHost
        }
    }

    return $failed
}

function Test-ImageAvailability {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Images,
        
        [Parameter(Mandatory = $true)]
        [string]$Target
    )
    
    # Extract unique registry hosts
    $registryHosts = @()
    foreach ($image in $Images) {
        if ($image -match "^([^/]+)/") {
            $registryHostName = $Matches[1]
            if ($registryHostName -match "\.") {
                $registryHosts += $registryHostName
            }
        }
    }
    $registryHosts = $registryHosts | Sort-Object -Unique
    
    # Add common Docker Hub hosts
    $registryHosts += @(
        "registry-1.docker.io",
        "production.cloudflare.docker.com",
        "auth.docker.io"
    )
    $registryHosts = $registryHosts | Sort-Object -Unique
    
    Write-StepStart "Testing DNS resolution for registries..."
    $failedDns = Test-DnsResolution -RegistryHosts $registryHosts
    
    if ($failedDns.Count -gt 0) {
        $errorMsg = "DNS resolution failed for the following hosts:`n"
        $errorMsg += ($failedDns -join "`n")
        $errorMsg += "`n`n$ERR_DNS_RESOLUTION_FAILED"
        throw $errorMsg
    }
    
    Write-Success "DNS resolution successful for all registries"
    
    if ($Target -eq "local") {
        Write-StepStart "Pre-pulling critical images (this may take a few minutes)..."
        
        $criticalImages = $Images | Where-Object { 
            $_ -match "grafana/grafana:" -or 
            $_ -match "jaegertracing/all-in-one:" 
        }
        
        foreach ($image in $criticalImages) {
            Write-Info "Pre-pulling: $image"
            
            $pullResult = docker pull $image 2>&1
            
            if ($LASTEXITCODE -ne 0) {
                $errorDetail = $pullResult -join "`n"
                
                if ($errorDetail -match "no such host" -or $errorDetail -match "lookup.*failed") {
                    throw "Failed to pull image: $image`nError: DNS resolution failed`n`n$errorDetail`n`n$ERR_DNS_RESOLUTION_FAILED"
                }
                elseif ($errorDetail -match "not found" -or $errorDetail -match "manifest unknown") {
                    throw "Failed to pull image: $image`nError: Image tag not found`n`n$ERR_IMAGE_TAG_NOT_FOUND"
                }
                elseif ($errorDetail -match "unauthorized" -or $errorDetail -match "authentication") {
                    throw "Failed to pull image: $image`nError: Authentication required`n`n$ERR_IMAGE_AUTH_REQUIRED"
                }
                else {
                    throw "Failed to pull image: $image`n`n$errorDetail"
                }
            }
            
            Write-Info "  Successfully pulled: $image"
        }
    }
    else {
        Write-Info "AKS target - skipping pre-pull (images will be pulled by nodes)"
        Write-Info "Note: Ensure AKS nodes have network access to container registries"
    }
}

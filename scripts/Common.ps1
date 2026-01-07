# File: scripts/Common.ps1
<#
.SYNOPSIS
    Common helper functions for the observability stack deployment.
#>

# ============================================================
# Output Helpers
# ============================================================

function Write-SectionHeader {
    param([string]$Title)
    Write-Host ""
    Write-Host "------------------------------------------------------------" -ForegroundColor Cyan
    Write-Host "  $Title" -ForegroundColor Cyan
    Write-Host "------------------------------------------------------------" -ForegroundColor Cyan
}

function Write-Success {
    param([string]$Message)
    Write-Host "  [OK] $Message" -ForegroundColor Green
}

function Write-Info {
    param([string]$Message)
    Write-Host "  [INFO] $Message" -ForegroundColor Gray
}

function Write-Warning {
    param([string]$Message)
    Write-Host "  [WARN] $Message" -ForegroundColor Yellow
}

function Write-StepStart {
    param([string]$Message)
    Write-Host "  -> $Message" -ForegroundColor White
}

# ============================================================
# Kubernetes Helpers
# ============================================================

function Test-KubernetesConnection {
    try {
        $result = kubectl cluster-info 2>&1
        if ($LASTEXITCODE -ne 0) {
            throw "kubectl cluster-info failed: $result"
        }
        return $true
    }
    catch {
        throw "Cannot connect to Kubernetes cluster: $_"
    }
}

function Get-KubernetesVersion {
    $version = kubectl version --output=json 2>$null | ConvertFrom-Json
    return $version.serverVersion.gitVersion
}

function Test-NamespaceExists {
    param([string]$Namespace)
    $ns = kubectl get namespace $Namespace -o name 2>$null
    return ($LASTEXITCODE -eq 0)
}

function New-NamespaceIfNotExists {
    param(
        [string]$Namespace,
        [hashtable]$Labels = @{}
    )
    
    if (-not (Test-NamespaceExists -Namespace $Namespace)) {
        Write-Info "Creating namespace: $Namespace"
        kubectl create namespace $Namespace
        
        foreach ($key in $Labels.Keys) {
            kubectl label namespace $Namespace "${key}=$($Labels[$key])" --overwrite
        }
    }
    else {
        Write-Info "Namespace exists: $Namespace"
        foreach ($key in $Labels.Keys) {
            kubectl label namespace $Namespace "${key}=$($Labels[$key])" --overwrite 2>$null
        }
    }
}

function Wait-ForDeployment {
    param(
        [string]$Name,
        [string]$Namespace,
        [int]$TimeoutSeconds = 300
    )
    
    Write-Info "Waiting for deployment $Name in $Namespace..."
    kubectl rollout status deployment/$Name -n $Namespace --timeout="${TimeoutSeconds}s" 2>$null
    return ($LASTEXITCODE -eq 0)
}

function Wait-ForStatefulSet {
    param(
        [string]$Name,
        [string]$Namespace,
        [int]$TimeoutSeconds = 300
    )
    
    Write-Info "Waiting for statefulset $Name in $Namespace..."
    kubectl rollout status statefulset/$Name -n $Namespace --timeout="${TimeoutSeconds}s" 2>$null
    return ($LASTEXITCODE -eq 0)
}

function Wait-ForDaemonSet {
    param(
        [string]$Name,
        [string]$Namespace,
        [int]$TimeoutSeconds = 300
    )
    
    Write-Info "Waiting for daemonset $Name in $Namespace..."
    kubectl rollout status daemonset/$Name -n $Namespace --timeout="${TimeoutSeconds}s" 2>$null
    return ($LASTEXITCODE -eq 0)
}

function Test-HelmReleaseExists {
    param(
        [string]$ReleaseName,
        [string]$Namespace
    )
    
    $releases = helm list -n $Namespace -q 2>$null
    return ($releases -contains $ReleaseName)
}

# ============================================================
# Helm Helpers
# ============================================================

function Add-HelmRepoIfNotExists {
    param(
        [string]$Name,
        [string]$Url
    )
    
    $repos = helm repo list -o json 2>$null | ConvertFrom-Json
    $exists = $repos | Where-Object { $_.name -eq $Name }
    
    if (-not $exists) {
        Write-Info "Adding Helm repository: $Name"
        helm repo add $Name $Url
    }
    else {
        Write-Info "Helm repository exists: $Name"
    }
}

function Update-HelmRepos {
    Write-Info "Updating Helm repositories..."
    helm repo update
}

# ============================================================
# File Helpers
# ============================================================

function Get-ManifestPath {
    param([string]$FileName)
    
    $scriptRoot = $PSScriptRoot
    if (-not $scriptRoot) {
        $scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
    }
    
    return Join-Path (Split-Path -Parent $scriptRoot) "manifests" $FileName
}

function Apply-ManifestFile {
    param(
        [string]$FilePath,
        [hashtable]$Replacements = @{}
    )
    
    if (-not (Test-Path $FilePath)) {
        throw "Manifest file not found: $FilePath"
    }
    
    $content = Get-Content $FilePath -Raw
    
    foreach ($key in $Replacements.Keys) {
        $content = $content -replace $key, $Replacements[$key]
    }
    
    $content | kubectl apply -f - 2>$null
    return ($LASTEXITCODE -eq 0)
}

# ============================================================
# Wait/Retry Helpers
# ============================================================

function Invoke-WithRetry {
    param(
        [scriptblock]$ScriptBlock,
        [int]$MaxRetries = 3,
        [int]$DelaySeconds = 5,
        [string]$Operation = "operation"
    )
    
    $attempt = 0
    while ($attempt -lt $MaxRetries) {
        $attempt++
        try {
            return & $ScriptBlock
        }
        catch {
            if ($attempt -eq $MaxRetries) {
                throw "Failed after $MaxRetries attempts: $_"
            }
            Write-Warning "$Operation failed (attempt $attempt/$MaxRetries), retrying in ${DelaySeconds}s..."
            Start-Sleep -Seconds $DelaySeconds
        }
    }
}

function Wait-ForCondition {
    param(
        [scriptblock]$Condition,
        [int]$TimeoutSeconds = 300,
        [int]$PollIntervalSeconds = 5,
        [string]$Description = "condition"
    )
    
    $elapsed = 0
    while ($elapsed -lt $TimeoutSeconds) {
        if (& $Condition) {
            return $true
        }
        Start-Sleep -Seconds $PollIntervalSeconds
        $elapsed += $PollIntervalSeconds
    }
    
    throw "Timeout waiting for $Description after ${TimeoutSeconds}s"
}

# ============================================================
# Functions are available via dot-sourcing
# ============================================================

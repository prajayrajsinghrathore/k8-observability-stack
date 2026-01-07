# File: scripts/Prerequisites.ps1
<#
.SYNOPSIS
    Prerequisite checks for the observability stack deployment.
#>

function Test-Prerequisites {
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Config
    )
    
    Write-StepStart "Checking kubectl..."
    if (-not (Get-Command kubectl -ErrorAction SilentlyContinue)) {
        throw $ERR_KUBECTL_NOT_FOUND
    }
    Write-Info "kubectl found: $(kubectl version --client --short 2>$null)"
    
    Write-StepStart "Checking helm..."
    if (-not (Get-Command helm -ErrorAction SilentlyContinue)) {
        throw $ERR_HELM_NOT_FOUND
    }
    Write-Info "helm found: $(helm version --short 2>$null)"
    
    if ($Config.Target -eq "aks") {
        Write-StepStart "Checking Azure CLI..."
        if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
            throw $ERR_AZ_CLI_NOT_FOUND
        }
        Write-Info "Azure CLI found: $(az version --query '""azure-cli""' -o tsv 2>$null)"
    }
    
    if ($Config.Target -eq "local") {
        Write-StepStart "Checking Docker..."
        if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
            throw $ERR_DOCKER_NOT_FOUND
        }
        
        $dockerInfo = docker info 2>&1
        if ($LASTEXITCODE -ne 0) {
            throw $ERR_DOCKER_NOT_RUNNING
        }
        Write-Info "Docker is running"
        
        Write-StepStart "Checking Docker Desktop Kubernetes..."
        $kubeContext = kubectl config current-context 2>$null
        if ($kubeContext -ne "docker-desktop") {
            Write-Warning "Current context is '$kubeContext', not 'docker-desktop'"
            Write-Info "Attempting to switch to docker-desktop context..."
            
            $contexts = kubectl config get-contexts -o name 2>$null
            if ($contexts -contains "docker-desktop") {
                kubectl config use-context docker-desktop
            }
            else {
                throw $ERR_K8S_NOT_ENABLED
            }
        }
        Write-Info "Using context: docker-desktop"
    }
    
    Write-StepStart "Testing cluster connectivity..."
    Test-KubernetesConnection
    $k8sVersion = Get-KubernetesVersion
    Write-Info "Kubernetes version: $k8sVersion"
}

function Connect-AksCluster {
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Config
    )
    
    Write-StepStart "Checking Azure authentication..."
    $azAccount = az account show 2>$null | ConvertFrom-Json -ErrorAction SilentlyContinue
    
    if (-not $azAccount) {
        Write-Info "Not logged in to Azure. Initiating login..."
        az login
        if ($LASTEXITCODE -ne 0) {
            throw $ERR_AZURE_LOGIN_FAILED
        }
    }
    else {
        Write-Info "Logged in as: $($azAccount.user.name)"
    }
    
    Write-StepStart "Setting Azure subscription..."
    az account set --subscription $Config.SubscriptionId
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to set subscription: $($Config.SubscriptionId)"
    }
    Write-Info "Subscription: $($Config.SubscriptionId)"
    
    Write-StepStart "Getting AKS credentials..."
    az aks get-credentials `
        --resource-group $Config.ResourceGroup `
        --name $Config.AksClusterName `
        --overwrite-existing
    
    if ($LASTEXITCODE -ne 0) {
        throw $ERR_AKS_CREDENTIALS_FAILED
    }
    
    Write-StepStart "Verifying AKS connection..."
    Test-KubernetesConnection
    
    $k8sVersion = Get-KubernetesVersion
    Write-Info "AKS Kubernetes version: $k8sVersion"
}

function Test-LocalKubernetes {
    Write-StepStart "Verifying Kubernetes nodes..."
    $nodes = kubectl get nodes -o json 2>$null | ConvertFrom-Json
    if ($LASTEXITCODE -ne 0 -or -not $nodes.items) {
        throw $ERR_K8S_NODES_NOT_ACCESSIBLE
    }
    
    $nodeCount = $nodes.items.Count
    Write-Info "Found $nodeCount node(s)"
    
    foreach ($node in $nodes.items) {
        $nodeName = $node.metadata.name
        $ready = ($node.status.conditions | Where-Object { $_.type -eq "Ready" }).status
        if ($ready -ne "True") {
            throw "Node '$nodeName' is not ready"
        }
        Write-Info "Node '$nodeName' is Ready"
    }
}

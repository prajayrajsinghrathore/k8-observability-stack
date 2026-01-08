# File: scripts/Constants.ps1
<#
.SYNOPSIS
    Constants and error messages for the observability stack deployment.
#>

# ============================================================
# Fixed Configuration
# ============================================================
$script:OBSERVABILITY_NAMESPACE = "observability"
$script:ISTIO_NAMESPACE = "istio-system"
$script:KUBE_SYSTEM_NAMESPACE = "kube-system"

# ============================================================
# Default Versions
# ============================================================
$script:DEFAULT_PROMETHEUS_VERSION = "v3.9.0"
$script:DEFAULT_GRAFANA_TAG = "12.4.0-20766360996"
$script:DEFAULT_JAEGER_VERSION = "1.76.0"
$script:DEFAULT_KIALI_VERSION = "2.18.0"
$script:DEFAULT_HELM_TIMEOUT = "10m"

# ============================================================
# Error Messages - Prerequisites
# ============================================================
$script:ERR_KUBECTL_NOT_FOUND = @"
kubectl is not installed or not in PATH.

Installation instructions:
  Windows:   choco install kubernetes-cli
             OR winget install Kubernetes.kubectl
  macOS:     brew install kubectl
  Linux:     See https://kubernetes.io/docs/tasks/tools/install-kubectl-linux/
"@

$script:ERR_HELM_NOT_FOUND = @"
helm is not installed or not in PATH.

Installation instructions:
  Windows:   choco install kubernetes-helm
             OR winget install Helm.Helm
  macOS:     brew install helm
  Linux:     See https://helm.sh/docs/intro/install/
"@

$script:ERR_AZ_CLI_NOT_FOUND = @"
Azure CLI (az) is not installed or not in PATH.

Installation instructions:
  Windows:   winget install Microsoft.AzureCLI
             OR https://docs.microsoft.com/en-us/cli/azure/install-azure-cli-windows
  macOS:     brew install azure-cli
  Linux:     curl -sL https://aka.ms/InstallAzureCLIDeb | sudo bash
"@

$script:ERR_DOCKER_NOT_FOUND = @"
Docker is not installed or not in PATH.

For local Kubernetes deployment, Docker Desktop is required.
Installation: https://docs.docker.com/desktop/
"@

$script:ERR_DOCKER_NOT_RUNNING = @"
Docker is not running. Please start Docker Desktop.

If Docker Desktop is running but you see this error:
  - Check Docker Desktop settings
  - Ensure Kubernetes is enabled in Docker Desktop
  - Restart Docker Desktop
"@

$script:ERR_K8S_NOT_ENABLED = @"
Docker Desktop Kubernetes context not found.

Please enable Kubernetes in Docker Desktop:
  1. Open Docker Desktop
  2. Go to Settings > Kubernetes
  3. Check 'Enable Kubernetes'
  4. Click 'Apply & Restart'
"@

$script:ERR_K8S_NODES_NOT_ACCESSIBLE = @"
Cannot access Kubernetes nodes.

Possible issues:
  - Kubernetes is not enabled in Docker Desktop
  - Docker Desktop needs to be restarted
  - There may be a proxy/firewall issue

Try:
  1. Open Docker Desktop Settings
  2. Go to Kubernetes
  3. Click 'Reset Kubernetes Cluster'
  4. Wait for restart and try again
"@

$script:ERR_AKS_PARAMS_MISSING = @"
AKS target requires the following parameters:
  -SubscriptionId
  -ResourceGroup
  -AksClusterName

Example:
  ./deploy.ps1 -Target aks -SubscriptionId "xxx" -ResourceGroup "myRG" -AksClusterName "myAKS"
"@

# ============================================================
# Error Messages - Image Validation
# ============================================================
$script:ERR_DNS_RESOLUTION_FAILED = @"
DNS resolution failed for container registries.

This is commonly caused by:
  1. Docker Desktop DNS/proxy misconfiguration
  2. Corporate firewall/VPN blocking container registries
  3. WSL2 DNS configuration issues

TROUBLESHOOTING STEPS:

For Docker Desktop (Windows/macOS):
  1. Open Docker Desktop Settings
  2. Go to Resources > Network
  3. Try enabling 'Use kernel networking for UDP'
  4. Check DNS settings - try using 8.8.8.8 or your corporate DNS

For WSL2:
  1. Edit /etc/resolv.conf in WSL
  2. Add: nameserver 8.8.8.8
  3. Make it persistent: create /etc/wsl.conf with:
     [network]
     generateResolvConf = false

For Corporate Proxy:
  1. Configure Docker Desktop proxy settings
  2. Settings > Resources > Proxies
  3. Add your corporate proxy URL

For VPN Users:
  1. Try disconnecting from VPN temporarily
  2. Or configure Docker to use VPN's DNS servers
"@

$script:ERR_IMAGE_TAG_NOT_FOUND = @"
The specified image or tag does not exist in the registry.
Please verify the image name and tag are correct.
"@

$script:ERR_IMAGE_AUTH_REQUIRED = @"
The image requires authentication. For public images, this may indicate:
  - Rate limiting (Docker Hub has pull rate limits)
  - Temporary registry issues

Try:
  1. docker login (to increase rate limits)
  2. Wait a few minutes and retry
"@

# ============================================================
# Error Messages - Azure / AKS
# ============================================================
$script:ERR_AZURE_LOGIN_FAILED = "Azure login failed. Please check your credentials and try again."

$script:ERR_AKS_CREDENTIALS_FAILED = "Failed to get AKS credentials. Verify the cluster name, resource group, and your permissions."

$script:ERR_ENTRA_GROUP_REQUIRED = @"
Azure Entra ID authentication requires a group object ID.
Please provide -EntraGroupObjectId parameter with the Object ID of the Azure AD group
that should have access to the observability stack.

To find your group's Object ID:
  1. Go to Azure Portal > Azure Active Directory > Groups
  2. Search for your group
  3. Copy the Object ID

Example:
  ./deploy.ps1 -Target aks -SubscriptionId "xxx" -ResourceGroup "myRG" -AksClusterName "myAKS" -EntraGroupObjectId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
"@

# ============================================================
# Error Messages - Istio Detection
# ============================================================
$script:INFO_ISTIO_NOT_FOUND = @"
Istio is not installed in the cluster.
The observability stack will be deployed without service mesh integration.
Kiali will not be installed as it requires Istio.
"@

$script:INFO_ISTIO_SIDECAR_MODE = @"
Istio detected in SIDECAR mode.
Configuring observability stack for sidecar proxy integration.
"@

$script:INFO_ISTIO_AMBIENT_MODE = @"
Istio detected in AMBIENT mode.
Configuring observability stack for ztunnel/waypoint integration.
"@

$script:ERR_ISTIO_UNHEALTHY = @"
Istio is installed but appears unhealthy.
Please check Istio status before proceeding:
  kubectl get pods -n istio-system
  istioctl analyze (if available)
"@

# ============================================================
# Warning Messages
# ============================================================
$script:WARN_NETWORK_POLICY_NOT_SUPPORTED = "Network policies may not be enforced. CNI may not support NetworkPolicy."

$script:WARN_KIALI_REQUIRES_ISTIO = "Kiali installation skipped - Istio is not present in the cluster."

$script:WARN_RESOURCE_QUOTA_FAILED = "Resource quota not applied (may require cluster admin permissions)."

# ============================================================
# Info Messages
# ============================================================
$script:INFO_LOCAL_NO_AUTH = "Local deployment: Authentication disabled for Prometheus and Grafana."

$script:INFO_AKS_ENTRA_AUTH = "AKS deployment: Azure Entra ID authentication enabled for Grafana."

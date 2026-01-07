# File: README.md
# Kubernetes Observability Stack Deployment Pack

A modular, idempotent PowerShell deployment pack for Kubernetes observability.

## Components

| Component | Description | Source |
|-----------|-------------|--------|
| **Prometheus** | Metrics collection (kube-prometheus-stack) | prometheus-community Helm |
| **Grafana** | Visualization & dashboards | grafana/grafana (Docker Hub) |
| **Alertmanager** | Alert routing | quay.io/prometheus/alertmanager |
| **Jaeger** | Distributed tracing | jaegertracing/all-in-one |
| **Kiali** | Istio observability (requires Istio) | kiali-operator Helm |

**Note:** No Bitnami images. All images from official open-source registries.

## Features

- **Istio Detection Only** - Does NOT install Istio; detects existing installation
- **Sidecar & Ambient Mode Support** - Auto-detects Istio mode and configures accordingly
- **Local: No Authentication** - Anonymous admin access for development
- **AKS: Azure Entra ID** - Group-based authentication for Grafana
- **Fixed Namespace** - All components deploy to `observability` namespace

## Prerequisites

- `kubectl` - Kubernetes CLI
- `helm` - Helm 3.x
- `docker` - Docker Desktop (local only)
- `az` - Azure CLI (AKS only)

## Usage

### Local Deployment (Docker Desktop)

```powershell
# Basic deployment (no authentication)
./deploy.ps1 -Target local

# Dry run
./deploy.ps1 -Target local -DryRun
```

### AKS Deployment

```powershell
# Basic (anonymous auth - for testing)
./deploy.ps1 -Target aks -SubscriptionId "your-sub-id" -ResourceGroup "your-rg" -AksClusterName "your-cluster"

# With Azure Entra ID authentication
./deploy.ps1 -Target aks -SubscriptionId "your-sub-id" -ResourceGroup "your-rg" -AksClusterName "your-cluster" -TenantId "your-tenant-id" -EntraGroupObjectId "your-group-object-id"

# With internal load balancer
./deploy.ps1 -Target aks -SubscriptionId "your-sub-id" -ResourceGroup "your-rg" -AksClusterName "your-cluster" -EnableInternalLoadBalancer
```

## Parameters

| Parameter | Required | Default | Description |
|-----------|----------|---------|-------------|
| `-Target` | Yes | - | `local` or `aks` |
| `-PrometheusVersion` | No | `v3.9.0` | Prometheus version |
| `-GrafanaImageTag` | No | `12.4.0-20766360996` | Grafana image tag |
| `-SubscriptionId` | AKS | - | Azure subscription ID |
| `-ResourceGroup` | AKS | - | Azure resource group |
| `-AksClusterName` | AKS | - | AKS cluster name |
| `-TenantId` | AKS+Entra | - | Azure AD tenant ID |
| `-EntraGroupObjectId` | AKS+Entra | - | Azure AD group for access |
| `-EnableInternalLoadBalancer` | No | false | Use internal LB on AKS |
| `-SkipImageValidation` | No | false | Skip DNS/image validation |
| `-DryRun` | No | false | Preview without changes |

**Component Versions:**
- Jaeger: `1.76.0`
- Kiali Operator: `2.18.0`

## Istio Integration

The script **detects but does not install** Istio. It checks:

1. `istio-system` namespace exists
2. `istiod` deployment is present and healthy
3. `istio-ingressgateway` deployment (optional)

### Mode Detection

- **Sidecar Mode**: Detected via sidecar-injector webhook or istio-proxy containers
- **Ambient Mode**: Detected via ztunnel DaemonSet or ambient namespace labels

When Istio is detected:
- Prometheus is configured to scrape Istio metrics (istiod, envoy/ztunnel)
- Kiali is installed and configured
- Istio sidecar injection is **disabled** at namespace level to prevent issues with Helm hooks
- Sidecar injection can be enabled per-deployment if needed using pod annotations

When Istio is NOT detected:
- Stack works normally without service mesh integration
- Kiali is NOT installed (requires Istio)

## Authentication

### Local (Docker Desktop)
- **No authentication** - Anonymous admin access
- Suitable for development/testing

### AKS
- **Without `-EntraGroupObjectId`**: Anonymous admin access (testing only)
- **With `-EntraGroupObjectId`**: Azure Entra ID authentication
  - Users in the specified group get Admin role
  - Others get Viewer role

## Access UIs

All services use ClusterIP. Access via port-forward:

```bash
# Prometheus
kubectl port-forward svc/prometheus-kube-prometheus-prometheus -n observability 9090:9090
# http://localhost:9090

# Grafana
kubectl port-forward svc/prometheus-grafana -n observability 3000:80
# http://localhost:3000

# Alertmanager
kubectl port-forward svc/prometheus-kube-prometheus-alertmanager -n observability 9093:9093
# http://localhost:9093

# Jaeger
kubectl port-forward svc/jaeger-query -n observability 16686:16686
# http://localhost:16686

# Kiali (only if Istio present)
kubectl port-forward svc/kiali -n observability 20001:20001
# http://localhost:20001
```

## Cleanup

```powershell
# Basic cleanup (keeps namespace)
./rollback.ps1 -Target local

# Remove namespace too
./rollback.ps1 -Target local -RemoveNamespace

# Skip confirmation
./rollback.ps1 -Target local -Force

# AKS cleanup
./rollback.ps1 -Target aks -SubscriptionId "your-sub-id" -ResourceGroup "your-rg" -AksClusterName "your-cluster" -RemoveNamespace
```

## File Structure

```
k8s-observability-pack/
├── deploy.ps1              # Main entrypoint
├── rollback.ps1            # Cleanup script
├── README.md
├── scripts/
│   ├── Constants.ps1       # Error messages & constants
│   ├── Common.ps1          # Helper functions
│   ├── Prerequisites.ps1   # Prerequisite checks
│   ├── Namespaces.ps1      # Namespace management
│   ├── ImageValidation.ps1 # Image pre-flight checks
│   ├── IstioDetection.ps1  # Istio detection (no install)
│   ├── Prometheus.ps1      # kube-prometheus-stack
│   ├── Jaeger.ps1          # Jaeger tracing
│   ├── Kiali.ps1           # Kiali operator
│   └── NetworkPolicies.ps1 # Network security
└── manifests/
    ├── namespace.yaml
    ├── resource-quota.yaml
    ├── limit-range.yaml
    ├── jaeger.yaml
    ├── jaeger-servicemonitor.yaml
    ├── grafana-dashboard.yaml
    └── network-policies.yaml
```

## Security

- RBAC least-privilege service accounts
- Non-root containers
- Read-only filesystem where compatible
- Dropped Linux capabilities
- seccompProfile: RuntimeDefault
- Resource requests/limits
- Network Policies
- ClusterIP services (no public exposure)

## Troubleshooting

### DNS/Image Pull Failures
Check Docker Desktop proxy settings or corporate firewall. The script includes automatic DNS fallback using `nslookup`.

If issues persist, use `-SkipImageValidation` to bypass pre-flight checks:
```powershell
./deploy.ps1 -Target local -SkipImageValidation
```

### Node Exporter on Docker Desktop
Node exporter is **automatically disabled** for local deployments due to Docker Desktop mount propagation limitations. This is expected behavior and does not affect cluster monitoring.

### Kiali Not Installing
Kiali requires Istio. If Istio is not detected, Kiali is skipped.

### Grafana CrashLoopBackOff
If Grafana fails with tracing errors, ensure the deployment includes the fix for `JAEGER_AGENT_PORT` environment variable override.

### Azure Entra ID Not Working
Ensure you provide both `-TenantId` and `-EntraGroupObjectId`. The group must exist in your Azure AD.

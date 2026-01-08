# File: scripts/Prometheus.ps1
<#
.SYNOPSIS
    Prometheus stack installation using kube-prometheus-stack Helm chart.
    Supports both local (no auth) and AKS (Azure Entra ID) deployments.
#>

function Install-PrometheusStack {
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Config
    )
    
    if ($Config.DryRun) {
        Write-Host "  [DRY RUN] Would install Prometheus stack" -ForegroundColor Magenta
        return
    }
    
    Write-StepStart "Adding Prometheus Community Helm repository..."
    Add-HelmRepoIfNotExists -Name "prometheus-community" -Url "https://prometheus-community.github.io/helm-charts"
    Update-HelmRepos
    
    Write-StepStart "Generating Prometheus stack configuration..."
    $valuesContent = Get-PrometheusStackValues -Config $Config
    
    $valuesFile = Join-Path $env:TEMP "prometheus-values.yaml"
    $valuesContent | Out-File -FilePath $valuesFile -Encoding utf8 -Force
    
    Write-StepStart "Installing/upgrading kube-prometheus-stack..."
    $releaseExists = Test-HelmReleaseExists -ReleaseName "prometheus" -Namespace $OBSERVABILITY_NAMESPACE
    
    $helmCmd = if (-not $releaseExists) { "install" } else { "upgrade" }
    Write-Info "$helmCmd Prometheus stack..."
    
    helm $helmCmd prometheus prometheus-community/kube-prometheus-stack `
        --namespace $OBSERVABILITY_NAMESPACE `
        --values $valuesFile `
        --wait `
        --timeout $DEFAULT_HELM_TIMEOUT
    
    if ($LASTEXITCODE -ne 0) { 
        throw "Failed to $helmCmd Prometheus stack" 
    }
    
    Remove-Item $valuesFile -Force -ErrorAction SilentlyContinue
    
    Write-StepStart "Provisioning Grafana dashboards..."
    $dashboardPath = Get-ManifestPath "grafana-dashboard.yaml"
    $dashboardReplacements = @{
        '\$\{NAMESPACE\}' = $OBSERVABILITY_NAMESPACE
    }
    Apply-ManifestFile -FilePath $dashboardPath -Replacements $dashboardReplacements
    
    Write-Info "Prometheus stack installed successfully"
}

function Get-PrometheusStackValues {
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Config
    )
    
    $namespace = $OBSERVABILITY_NAMESPACE
    $promImageTag = $Config.PrometheusVersion
    
    # Grafana authentication configuration
    $grafanaAuth = Get-GrafanaAuthConfig -Config $Config
    
    # Istio-specific scrape configs
    $istioScrapeConfigs = ""
    if ($Config.IstioDetected) {
        $istioScrapeConfigs = Get-IstioScrapeConfigs -Config $Config
    }

    # Node exporter configuration (disable for Docker Desktop due to mount propagation issues)
    $nodeExporterEnabled = if ($Config.Target -eq "local") { "false" } else { "true" }
    
    # Build service annotations for AKS internal LB
    $serviceAnnotations = ""
    $serviceType = "ClusterIP"
    if ($Config.Target -eq "aks" -and $Config.EnableInternalLoadBalancer) {
        $serviceType = "LoadBalancer"
        $serviceAnnotations = @"
    annotations:
      service.beta.kubernetes.io/azure-load-balancer-internal: "true"
"@
    }

    return @"
fullnameOverride: "prometheus"
namespaceOverride: "$namespace"

defaultRules:
  create: true
  rules:
    alertmanager: true
    etcd: false
    configReloaders: true
    general: true
    k8s: true
    kubeApiserverAvailability: true
    kubeApiserverBurnrate: true
    kubeApiserverHistogram: true
    kubeApiserverSlos: true
    kubeControllerManager: false
    kubelet: true
    kubeProxy: false
    kubePrometheusGeneral: true
    kubePrometheusNodeRecording: true
    kubernetesApps: true
    kubernetesResources: true
    kubernetesStorage: true
    kubernetesSystem: true
    kubeSchedulerAlerting: false
    kubeSchedulerRecording: false
    kubeStateMetrics: true
    network: true
    node: true
    nodeExporterAlerting: true
    nodeExporterRecording: true
    prometheus: true
    prometheusOperator: true

prometheusOperator:
  enabled: true
  image:
    registry: quay.io
    repository: prometheus-operator/prometheus-operator
    tag: v0.81.0
  prometheusConfigReloader:
    image:
      registry: quay.io
      repository: prometheus-operator/prometheus-config-reloader
      tag: v0.81.0
    resources:
      requests:
        cpu: 50m
        memory: 50Mi
      limits:
        cpu: 200m
        memory: 100Mi
  resources:
    requests:
      cpu: 100m
      memory: 100Mi
    limits:
      cpu: 500m
      memory: 500Mi
  securityContext:
    runAsNonRoot: true
    runAsUser: 65534
    fsGroup: 65534
    seccompProfile:
      type: RuntimeDefault
  containerSecurityContext:
    allowPrivilegeEscalation: false
    readOnlyRootFilesystem: true
    capabilities:
      drop:
        - ALL
  admissionWebhooks:
    enabled: true
    patch:
      enabled: true
      podAnnotations:
        sidecar.istio.io/inject: "false"

prometheus:
  enabled: true
  prometheusSpec:
    image:
      registry: quay.io
      repository: prometheus/prometheus
      tag: "$promImageTag"
    serviceMonitorSelectorNilUsesHelmValues: false
    podMonitorSelectorNilUsesHelmValues: false
    ruleSelectorNilUsesHelmValues: false
    probeSelectorNilUsesHelmValues: false
    scrapeConfigSelectorNilUsesHelmValues: false
    retention: 15d
    retentionSize: "10GB"
    resources:
      requests:
        cpu: 200m
        memory: 512Mi
      limits:
        cpu: 1000m
        memory: 2Gi
    storageSpec:
      volumeClaimTemplate:
        spec:
          accessModes: ["ReadWriteOnce"]
          resources:
            requests:
              storage: 20Gi
    securityContext:
      runAsNonRoot: true
      runAsUser: 65534
      fsGroup: 65534
      seccompProfile:
        type: RuntimeDefault
    podMetadata:
      annotations:
        sidecar.istio.io/inject: "false"
$istioScrapeConfigs
  service:
    type: $serviceType
    port: 9090
$serviceAnnotations

alertmanager:
  enabled: true
  alertmanagerSpec:
    image:
      registry: quay.io
      repository: prometheus/alertmanager
      tag: v0.28.1
    resources:
      requests:
        cpu: 50m
        memory: 64Mi
      limits:
        cpu: 200m
        memory: 256Mi
    storage:
      volumeClaimTemplate:
        spec:
          accessModes: ["ReadWriteOnce"]
          resources:
            requests:
              storage: 5Gi
    securityContext:
      runAsNonRoot: true
      runAsUser: 65534
      fsGroup: 65534
      seccompProfile:
        type: RuntimeDefault
    podMetadata:
      annotations:
        sidecar.istio.io/inject: "false"
  service:
    type: ClusterIP
    port: 9093

grafana:
  enabled: true
  image:
    repository: grafana/grafana
    tag: "$($Config.GrafanaImageTag)"
$grafanaAuth
  env:
    JAEGER_AGENT_PORT: ""
  resources:
    requests:
      cpu: 100m
      memory: 128Mi
    limits:
      cpu: 500m
      memory: 512Mi
  persistence:
    enabled: true
    size: 5Gi
  securityContext:
    runAsNonRoot: true
    runAsUser: 472
    fsGroup: 472
    seccompProfile:
      type: RuntimeDefault
  containerSecurityContext:
    allowPrivilegeEscalation: false
    readOnlyRootFilesystem: false
    capabilities:
      drop:
        - ALL
  sidecar:
    dashboards:
      enabled: true
      label: grafana_dashboard
      labelValue: "1"
      searchNamespace: ALL
    datasources:
      enabled: true
      defaultDatasourceEnabled: false
  datasources:
    datasources.yaml:
      apiVersion: 1
      datasources:
        - name: Prometheus
          type: prometheus
          url: http://prometheus-prometheus.$namespace.svc:9090
          access: proxy
          isDefault: true
          editable: false
        - name: Jaeger
          type: jaeger
          url: http://jaeger-query.$namespace.svc:16686
          access: proxy
          isDefault: false
          editable: false
  service:
    type: $serviceType
    port: 80
$serviceAnnotations
  podAnnotations:
    sidecar.istio.io/inject: "false"

kube-state-metrics:
  enabled: true
  image:
    registry: registry.k8s.io
    repository: kube-state-metrics/kube-state-metrics
    tag: v2.15.0
  resources:
    requests:
      cpu: 50m
      memory: 64Mi
    limits:
      cpu: 200m
      memory: 256Mi
  securityContext:
    runAsNonRoot: true
    runAsUser: 65534
    fsGroup: 65534
    seccompProfile:
      type: RuntimeDefault
  containerSecurityContext:
    allowPrivilegeEscalation: false
    readOnlyRootFilesystem: true
    capabilities:
      drop:
        - ALL
  podAnnotations:
    sidecar.istio.io/inject: "false"

prometheus-node-exporter:
  enabled: $nodeExporterEnabled
  image:
    registry: quay.io
    repository: prometheus/node-exporter
    tag: v1.8.2
  hostNetwork: false
  hostPID: false
  resources:
    requests:
      cpu: 50m
      memory: 30Mi
    limits:
      cpu: 200m
      memory: 100Mi
  securityContext:
    runAsNonRoot: true
    runAsUser: 65534
    fsGroup: 65534
  containerSecurityContext:
    allowPrivilegeEscalation: false
    readOnlyRootFilesystem: true
    capabilities:
      drop:
        - ALL
      add:
        - SYS_TIME
  podAnnotations:
    sidecar.istio.io/inject: "false"
  service:
    annotations:
      prometheus.io/scrape: "true"
"@
}

function Get-GrafanaAuthConfig {
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Config
    )
    
    if ($Config.Target -eq "local") {
        # Local deployment: NO AUTHENTICATION
        Write-Info $INFO_LOCAL_NO_AUTH
        return @"
  adminPassword: ""
  grafana.ini:
    auth:
      disable_login_form: true
    auth.anonymous:
      enabled: true
      org_role: Admin
    security:
      allow_embedding: true
    tracing.opentelemetry.otlp:
      address: ""
"@
    }
    else {
        # AKS deployment: Azure Entra ID authentication
        Write-Info $INFO_AKS_ENTRA_AUTH
        
        if (-not $Config.EntraGroupObjectId) {
            Write-Warning "EntraGroupObjectId not provided. Using anonymous auth for now."
            Write-Warning "For production, provide -EntraGroupObjectId parameter."
            return @"
  adminPassword: ""
  grafana.ini:
    auth:
      disable_login_form: true
    auth.anonymous:
      enabled: true
      org_role: Admin
    security:
      allow_embedding: true
    tracing.opentelemetry.otlp:
      address: ""
"@
        }
        
        # Azure Entra ID (Azure AD) authentication
        return @"
  adminPassword: "admin"
  grafana.ini:
    server:
      root_url: "%(protocol)s://%(domain)s:%(http_port)s"
    auth:
      disable_login_form: false
    auth.azuread:
      enabled: true
      name: Azure AD
      allow_sign_up: true
      auto_login: false
      client_id: \$__env{AZURE_CLIENT_ID}
      client_secret: \$__env{AZURE_CLIENT_SECRET}
      scopes: openid email profile
      auth_url: https://login.microsoftonline.com/$($Config.TenantId)/oauth2/v2.0/authorize
      token_url: https://login.microsoftonline.com/$($Config.TenantId)/oauth2/v2.0/token
      allowed_groups: $($Config.EntraGroupObjectId)
      role_attribute_path: contains(groups[*], '$($Config.EntraGroupObjectId)') && 'Admin' || 'Viewer'
    security:
      allow_embedding: true
  envFromSecret: grafana-azure-credentials
"@
    }
}

function Get-IstioScrapeConfigs {
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Config
    )
    
    $baseConfig = @"
    additionalScrapeConfigs:
      - job_name: 'istiod'
        kubernetes_sd_configs:
          - role: endpoints
            namespaces:
              names:
                - $ISTIO_NAMESPACE
        relabel_configs:
          - source_labels: [__meta_kubernetes_service_name, __meta_kubernetes_endpoint_port_name]
            action: keep
            regex: istiod;http-monitoring
"@
    
    if ($Config.IstioMode -eq [IstioMode]::Ambient) {
        # Ambient mode: scrape ztunnel
        $baseConfig += @"

      - job_name: 'ztunnel'
        kubernetes_sd_configs:
          - role: pod
            namespaces:
              names:
                - $ISTIO_NAMESPACE
        relabel_configs:
          - source_labels: [__meta_kubernetes_pod_label_app]
            action: keep
            regex: ztunnel
          - source_labels: [__meta_kubernetes_pod_container_port_number]
            action: keep
            regex: "15020"
"@
    }
    else {
        # Sidecar mode: scrape envoy sidecars
        $baseConfig += @"

      - job_name: 'envoy-stats'
        metrics_path: /stats/prometheus
        kubernetes_sd_configs:
          - role: pod
        relabel_configs:
          - source_labels: [__meta_kubernetes_pod_container_port_name]
            action: keep
            regex: '.*-envoy-prom'
"@
    }
    
    return $baseConfig
}

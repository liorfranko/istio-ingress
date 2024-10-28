{{- define "loadBalancerName" -}}
{{- $lbName := .lbName }}
{{- $root := .root }}
{{- $lb := index $root.Values.loadBalancers $lbName }}
{{- if $lb.enabled }}
{{- if ge ($lbName | len) 13 }}
  {{ fail "load balancer name must be up to 12 characters" }}
{{- end -}}
{{ $lbName }}-lb
{{- else -}}
{{- printf "" -}}
{{- end -}}
{{- end -}}

{/*
Map of all the common loadbalancer labels
*/ -}}
{{- define "commonLBLabels" -}}
{{- $lbName := .lbName }}
{{- $root := .root }}
{{- $appname := (include "loadBalancerName" (dict "root" $root "lbName" $lbName)) -}}
app: "{{ $appname -}}"
name: "{{ $appname -}}"
{{- end }}

{{/*
The concurrency config for a LB gateway
*/}}
{{- define "loadBalancerConcurrency" -}}
{{- $lbName := .lbName }}
{{- $root := .root }}
{{- $lb := index $root.Values.loadBalancers $lbName }}
{{- $loadBalancerConcurrencyValue := "" }}
{{- $loadBalancerProxyCpuValue := $lb.deployment.resources.requests | toString | regexFind "[0-9.]+" -}}
{{- $loadBalancerProxyCpuSuffix := $lb.deployment.resources.requests | toString | regexFind "[^0-9.]+" -}}
{{- $loadBalancerConcurrencyMultiplier := $lb.deployment.resources.concurrencyMultiplier -}}
{{- if eq $loadBalancerProxyCpuSuffix "m" -}}
  {{- $loadBalancerConcurrencyValue = divf $loadBalancerProxyCpuValue 1000 | mulf $loadBalancerConcurrencyMultiplier | ceil | toString -}}
{{- else }}
  {{- $loadBalancerConcurrencyValue = mulf $loadBalancerProxyCpuValue $loadBalancerConcurrencyMultiplier | ceil | toString -}}
{{- end }}
{{- printf "%s" $loadBalancerConcurrencyValue }}
{{- end -}}

{{- define "loadBalancerServiceAccountName" -}}
{{- $lbName := .lbName }}
{{- $root := .root }}
{{- $loadBalancerName := (include "loadBalancerName" (dict "root" $root "lbName" $lbName)) -}}
{{- printf "%s-sa" $loadBalancerName }}
{{- end -}}


{{- define "loadBalancerLabels" -}}
{{- $lbName := .lbName }}
{{- $root := .root }}
{{- $loadBalancerName := (include "loadBalancerName" (dict "root" $root "lbName" $lbName)) -}}
istio: {{$loadBalancerName }}
lb_release: istio
lb_type: ingressgateway
{{- end -}}

{{- define "lbPodAnnotations" -}}
{{- $lbName := .lbName }}
{{- $root := .root }}
{{- $loadBalancerConcurrency := include "loadBalancerConcurrency" (dict "root" $root "lbName" $lbName) -}}
prometheus.io/path: /stats/prometheus
prometheus.io/port: "15020"
prometheus.io/scrape: "true"
inject.istio.io/templates: gateway
proxy.istio.io/config: |
  drainDuration: "{{ (index $root.Values.loadBalancers $lbName).deployment.drainDuration }}"
  parentShutdownDuration: "{{ (index $root.Values.loadBalancers $lbName).deployment.parentShutdownDuration }}"
  concurrency: {{ $loadBalancerConcurrency }}
{{- end -}}

{{- define "lbPodLabels" -}}
{{- $lbName := .lbName }}
service.istio.io/canonical-name: {{ $lbName }}
service.istio.io/canonical-revision: latest
operator.istio.io/component: IngressGateways
sidecar.istio.io/inject: "true"
{{- end -}}

{{- define "lbPodAntiAffinity" -}}
{{- $loadBalancerName := (include "loadBalancerName" .) -}}
podAntiAffinity:
  requiredDuringSchedulingIgnoredDuringExecution:
  - labelSelector:
      matchExpressions:
      - key: app
        operator: In
        values:
        - {{ $loadBalancerName }}
    topologyKey: kubernetes.io/hostname
{{- end -}}

{{- define "defaultLBContainerArgs" -}}
{{- $lbName := .lbName }}
{{- $root := .root }}
{{- $lb := index $root.Values.loadBalancers $lbName }}
- proxy
- router
- --domain
- $(POD_NAMESPACE).svc.cluster.local
- --proxyLogLevel={{ $lb.deployment.logLevel }}
- --proxyComponentLogLevel=misc:error
- --log_output_level=default:info
- --log_as_json
{{- end -}}

{{- define "defaultLBImage" -}}
{{- $lbName := .lbName }}
{{- $root := .root }}
{{- $lb := index $root.Values.loadBalancers $lbName -}}
{{- if $lb.deployment.image -}}
{{- $lb.deployment.image -}}
{{- else -}}
auto
{{- end -}}
{{- end -}}

{{- define "defaultLBContainerEnv" -}}
{{- $lbName := .lbName }}
{{- $root := .root }}
{{- $lb := index $root.Values.loadBalancers $lbName }}
{{- $loadBalancerName := (include "loadBalancerName" .) -}}
- name: TERMINATION_DRAIN_DURATION_SECONDS
  value: "{{ $lb.deployment.terminationGracePeriodSeconds }}"
- name: NODE_NAME
  valueFrom:
    fieldRef:
      apiVersion: v1
      fieldPath: spec.nodeName
- name: POD_NAME
  valueFrom:
    fieldRef:
      apiVersion: v1
      fieldPath: metadata.name
- name: POD_NAMESPACE
  valueFrom:
    fieldRef:
      apiVersion: v1
      fieldPath: metadata.namespace
- name: INSTANCE_IP
  valueFrom:
    fieldRef:
      apiVersion: v1
      fieldPath: status.podIP
- name: HOST_IP
  valueFrom:
    fieldRef:
      apiVersion: v1
      fieldPath: status.hostIP
- name: SERVICE_ACCOUNT
  valueFrom:
    fieldRef:
      apiVersion: v1
      fieldPath: spec.serviceAccountName
- name: ISTIO_META_WORKLOAD_NAME
  value: {{ $loadBalancerName }}
- name: ISTIO_META_OWNER
  value: kubernetes://apis/apps/v1/namespaces/istio-ingress/deployments/{{ $loadBalancerName }}
{{- end -}}

{{- define "defaultLBContainerPorts" -}}
{{- $lbName := .lbName }}
{{- $root := .root }}
{{- $lb := index $root.Values.loadBalancers $lbName }}
- containerPort: 80
  protocol: TCP
- containerPort: 15090
  name: http-envoy-prom
  protocol: TCP
{{- end -}}


{{- define "defaultLBContainerVolumeMounts" -}}
- mountPath: /var/run/secrets/workload-spiffe-uds
  name: workload-socket
- mountPath: /var/run/secrets/credential-uds
  name: credential-socket
- mountPath: /var/run/secrets/workload-spiffe-credentials
  name: workload-certs
- mountPath: /etc/istio/proxy
  name: istio-envoy
- mountPath: /etc/istio/config
  name: config-volume
- mountPath: /var/run/secrets/istio
  name: istiod-ca-cert
- mountPath: /var/run/secrets/tokens
  name: istio-token
  readOnly: true
- mountPath: /var/lib/istio/data
  name: istio-data
- mountPath: /etc/istio/pod
  name: podinfo
- mountPath: /etc/istio/ingressgateway-certs
  name: ingressgateway-certs
  readOnly: true
- mountPath: /etc/istio/ingressgateway-ca-certs
  name: ingressgateway-ca-certs
  readOnly: true
{{- end -}}

{{- define "defaultLBContainerVolumes" -}}
- emptyDir: {}
  name: workload-socket
- emptyDir: {}
  name: credential-socket
- emptyDir: {}
  name: workload-certs
- configMap:
    defaultMode: 420
    name: istio-ca-root-cert
  name: istiod-ca-cert
- downwardAPI:
    defaultMode: 420
    items:
    - fieldRef:
        apiVersion: v1
        fieldPath: metadata.labels
      path: labels
    - fieldRef:
        apiVersion: v1
        fieldPath: metadata.annotations
      path: annotations
  name: podinfo
- emptyDir: {}
  name: istio-envoy
- emptyDir: {}
  name: istio-data
- name: istio-token
  projected:
    defaultMode: 420
    sources:
    - serviceAccountToken:
        audience: istio-ca
        expirationSeconds: 43200
        path: istio-token
- configMap:
    defaultMode: 420
    name: istio
    optional: true
  name: config-volume
- name: ingressgateway-certs
  secret:
    defaultMode: 420
    optional: true
    secretName: istio-ingressgateway-certs
- name: ingressgateway-ca-certs
  secret:
    defaultMode: 420
    optional: true
    secretName: istio-ingressgateway-ca-certs
{{- end -}}


{{- define "defaultServicePorts" -}}
{{- $lbName := .lbName }}
{{- $root := .root }}
{{- $lb := index $root.Values.loadBalancers $lbName }}
- name: http
  port: 80
  protocol: TCP
  targetPort: 8080
{{- if $lb.additionalPorts }}
{{- range $portName, $port := $lb.additionalPorts }}
- name: {{ $portName }}
  port: {{ $port.portNumber }}
  protocol: {{ $port.protocol }}
  targetPort: {{ $port.portNumber }}
{{- end -}}
{{- end -}}
{{- end -}}


{{- define "defaultDeploymentStrategy" -}}
rollingUpdate:
  maxSurge: 5%
  maxUnavailable: 0
type: RollingUpdate
{{- end -}}

{{- define "defaultRolloutStrategy" -}}
canary:
  maxSurge: "5%"
  maxUnavailable: 0
{{- end -}}


{{- define "defaultLBServiceAnnotations" -}}
{{- $lbName := .lbName }}
{{- $root := .root }}
argocd.argoproj.io/sync-wave: "1"
service.beta.kubernetes.io/aws-load-balancer-backend-protocol: "http"
service.beta.kubernetes.io/aws-load-balancer-internal: "true"
service.beta.kubernetes.io/aws-load-balancer-type: "nlb-ip"
service.beta.kubernetes.io/aws-load-balancer-attributes: "deletion_protection.enabled=true"
service.beta.kubernetes.io/aws-load-balancer-target-group-attributes: "deregistration_delay.connection_termination.enabled=true"
service.beta.kubernetes.io/aws-load-balancer-subnets: {{ $root.Values.internalSubnets }}
external-dns.alpha.kubernetes.io/hostname: {{ $root.Values.internalDns }}
external-dns.alpha.kubernetes.io/set-identifier: {{ $lbName }}
external-dns.alpha.kubernetes.io/aws-weight: "0"
{{- end -}}

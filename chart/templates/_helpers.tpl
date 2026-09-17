{{/*
Chart name, truncated to 63 chars.
*/}}
{{- define "ellf.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Fully qualified app name.
*/}}
{{- define "ellf.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else if contains .Chart.Name .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name (include "ellf.name" .) | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}

{{/*
Common labels applied to every resource.
*/}}
{{- define "ellf.labels" -}}
app.kubernetes.io/name: {{ include "ellf.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" }}
{{- end }}

{{/*
Selector labels for the broker.
*/}}
{{- define "ellf.selectorLabels" -}}
app: broker
app.kubernetes.io/name: {{ include "ellf.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Bare hostname extracted from cluster.fqdn (which may carry a port for
non-default-port deployments, e.g. "localhost:8443" on BYOC tunnel
setups). K8s Ingress `host:` rules and TLS-cert `dnsNames` are RFC 1123
hostnames — ports are not allowed there. ELLF_BROKER_HOST and
ELLF_CORS_ORIGINS keep the full authority (host:port) since the
browser/clients reach the cluster on that port.
*/}}
{{- define "ellf.brokerHostname" -}}
{{- regexFind "^[^:]+" .Values.cluster.fqdn -}}
{{- end }}

{{/*
Scheme browsers/clients use to reach the cluster. Defaulted here (not only
in values.yaml) so values files written before the key existed keep working.
*/}}
{{- define "ellf.clusterScheme" -}}
{{- .Values.cluster.scheme | default "https" -}}
{{- end }}

{{/*
Credentials secret (registry SA key + license key), created by this chart.
*/}}
{{- define "ellf.credentialsSecretName" -}}
{{- printf "%s-credentials" (include "ellf.fullname" .) -}}
{{- end }}

{{/*
Infra secret name (database password + RSA keypair), created by Terraform.
In local mode without an explicit infraSecretName, falls back to a chart-managed secret.
*/}}
{{- define "ellf.infraSecretName" -}}
{{- if .Values.secrets.infraSecretName -}}
{{- .Values.secrets.infraSecretName -}}
{{- else if .Values.local -}}
{{- printf "%s-infra" (include "ellf.fullname" .) -}}
{{- end -}}
{{- end }}

{{/*
Broker Deployment/Service name.
*/}}
{{- define "ellf.brokerName" -}}
{{- printf "%s-broker" (include "ellf.fullname" .) | trunc 63 | trimSuffix "-" -}}
{{- end }}

{{/*
Preview (prodigy-embed iframe) Deployment/Service name.
*/}}
{{- define "ellf.previewName" -}}
{{- printf "%s-preview" (include "ellf.fullname" .) | trunc 63 | trimSuffix "-" -}}
{{- end }}

{{/*
Embed selector labels.
*/}}
{{- define "ellf.previewSelectorLabels" -}}
app: preview
app.kubernetes.io/name: {{ include "ellf.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Env ConfigMap name.
*/}}
{{- define "ellf.envConfigMapName" -}}
{{- printf "%s-env" (include "ellf.fullname" .) | trunc 63 | trimSuffix "-" -}}
{{- end }}

{{/*
Config files ConfigMap name.
*/}}
{{- define "ellf.configFilesConfigMapName" -}}
{{- printf "%s-config-files" (include "ellf.fullname" .) | trunc 63 | trimSuffix "-" -}}
{{- end }}

{{/*
TLS secret name for broker + task ingresses.
*/}}
{{- define "ellf.ingressTlsSecretName" -}}
{{- .Values.ingress.tls.secretName -}}
{{- end }}

{{/*
Ingress class name for broker + task ingresses.
*/}}
{{- define "ellf.ingressClassName" -}}
{{- .Values.ingress.className -}}
{{- end }}

{{/*
ClusterIssuer name for cert-manager-managed TLS.
*/}}
{{- define "ellf.clusterIssuerName" -}}
{{- if and .Values.certManager .Values.certManager.clusterIssuerName -}}
{{- .Values.certManager.clusterIssuerName | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s-letsencrypt" (include "ellf.fullname" .) | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end }}

{{/*
Private key Secret name for the ClusterIssuer ACME account.
*/}}
{{- define "ellf.clusterIssuerAccountSecretName" -}}
{{- printf "%s-account-key" (include "ellf.clusterIssuerName" .) | trunc 63 | trimSuffix "-" -}}
{{- end }}
{{/*
The upstream Ellf registry: where Explosion publishes broker/cpl/chart and
built-in recipe images (or a customer mirror of it). Canonical value
registries.upstream; falls back to the legacy image.registry key.
*/}}
{{- define "ellf.upstreamRegistry" -}}
{{- if and .Values.registries .Values.registries.upstream -}}
{{- .Values.registries.upstream -}}
{{- else -}}
{{- .Values.image.registry -}}
{{- end -}}
{{- end }}

{{/*
The user's (cluster-owned) writable registry: where custom recipe images built by
publish are pushed. Canonical value registries.user; falls back to the legacy
cluster.containerRegistry key.
*/}}
{{- define "ellf.userRegistry" -}}
{{- if and .Values.registries .Values.registries.user -}}
{{- .Values.registries.user -}}
{{- else -}}
{{- .Values.cluster.containerRegistry -}}
{{- end -}}
{{- end }}

{{/*
Read one container's image tag from the live broker Deployment.
Usage: include "ellf.deployedTag" (dict "ctx" . "container" "api")
Returns "" when the Deployment doesn't exist yet (fresh install, or
template/dry-run where lookup is disabled).
*/}}
{{- define "ellf.deployedTag" -}}
{{- $dep := lookup "apps/v1" "Deployment" .ctx.Release.Namespace (include "ellf.brokerName" .ctx) -}}
{{- range ((($dep.spec).template).spec).containers -}}
{{- if and (eq .name $.container) (contains ":" .image) -}}
{{- regexReplaceAll "^.*:" .image "" -}}
{{- end -}}
{{- end -}}
{{- end }}

{{/*
Broker (and embed/media-gc) image tag. These versions are dynamic state
owned by PAM's cluster settings — the CPL sidecar auto-updates the running
Deployment to PAM's target — so the chart deliberately does not require
them in values. Precedence: an explicit image.brokerVersion value (deploy
tooling injects PAM's target at deploy time; dev flows pin their own tags),
otherwise the tag currently running in the live Deployment, so a plain
`helm upgrade` never rolls back an auto-updated cluster.
*/}}
{{- define "ellf.brokerVersion" -}}
{{- if .Values.image.brokerVersion -}}
{{- toString .Values.image.brokerVersion -}}
{{- else -}}
{{- include "ellf.deployedTag" (dict "ctx" . "container" "api") -}}
{{- end -}}
{{- end }}

{{/*
CPL sidecar image tag. Same resolution rules as ellf.brokerVersion.
*/}}
{{- define "ellf.cplVersion" -}}
{{- if .Values.image.cplVersion -}}
{{- toString .Values.image.cplVersion -}}
{{- else -}}
{{- include "ellf.deployedTag" (dict "ctx" . "container" "cpl") -}}
{{- end -}}
{{- end }}

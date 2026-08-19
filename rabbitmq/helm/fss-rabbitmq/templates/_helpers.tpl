{{/* Cluster name = RabbitmqCluster CR name. Operator labels every pod app.kubernetes.io/name=<this>. */}}
{{- define "fss-rabbitmq.name" -}}
{{- .Values.cluster.name | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "fss-rabbitmq.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/* Common labels for chart-owned resources (SC, NetworkPolicy, PDB, topology CRs). */}}
{{- define "fss-rabbitmq.labels" -}}
helm.sh/chart: {{ include "fss-rabbitmq.chart" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: rabbitmq-platform
{{- end -}}

{{/*
Selector matching the pods the Cluster Operator creates for this RabbitmqCluster.
The operator stamps app.kubernetes.io/name=<cluster name> on every node pod — this is
the stable handle for NetworkPolicy / PDB / anti-affinity. Verified against the
production-ready example in rabbitmq/cluster-operator.
*/}}
{{- define "fss-rabbitmq.podSelector" -}}
app.kubernetes.io/name: {{ include "fss-rabbitmq.name" . }}
{{- end -}}

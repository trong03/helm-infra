{{/* Cluster name = Kafka CR name = strimzi.io/cluster label for all resources. */}}
{{- define "fss-kafka.name" -}}
{{- .Values.cluster.name | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "fss-kafka.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/* Common labels. Note: strimzi.io/cluster is added separately where Strimzi requires it. */}}
{{- define "fss-kafka.labels" -}}
helm.sh/chart: {{ include "fss-kafka.chart" . }}
app.kubernetes.io/name: {{ include "fss-kafka.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: kafka-platform
{{- end -}}

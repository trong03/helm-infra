{{/* CHI (ClickHouseInstallation) name. */}}
{{- define "fss-clickhouse.name" -}}
{{- .Values.cluster.name | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/* CHK (ClickHouseKeeperInstallation) name. */}}
{{- define "fss-clickhouse.keeperName" -}}
{{- .Values.keeper.name | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "fss-clickhouse.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/* Common labels for chart-owned resources (SC, NetworkPolicy, PDB). */}}
{{- define "fss-clickhouse.labels" -}}
helm.sh/chart: {{ include "fss-clickhouse.chart" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: clickhouse-platform
{{- end -}}

{{/*
Label stamped on BOTH CH and Keeper pod templates (via podTemplate metadata.labels).
This is OUR label, not an operator-internal one — so NetworkPolicy/PDB selectors are
guaranteed to match and never drift with operator versions.
*/}}
{{- define "fss-clickhouse.intraLabel" -}}
fss.io/part-of: clickhouse-platform
{{- end -}}

{{/* Labels shared by everything in this chart. */}}
{{- define "self-healing-lab.labels" -}}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: self-healing-lab
{{- end }}

{{/* The demo app's selector labels. The chaos scripts and the healer find pods with app=<name>. */}}
{{- define "self-healing-lab.appSelector" -}}
app: {{ .Values.app.name }}
{{- end }}

{{- define "self-healing-lab.healerSelector" -}}
app: {{ .Values.healer.name }}
{{- end }}

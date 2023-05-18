## {{if .Release}}{{.Release}}{{end}}{{if and (not .Date.IsZero) .Release}} ({{end}}{{timefmt .Date "2006-01-02"}}{{if and (not .Date.IsZero) .Release}}){{end}}
{{- range $section := .Sections }}
{{- if (eq $section.SectionType "commits") }}
{{- template "rn-md-section-commits.tpl" $section }}
{{- else if (eq $section.SectionType "breaking-changes")}}
{{- template "rn-md-section-breaking-changes.tpl" $section }}
{{- end}}
{{- end}}

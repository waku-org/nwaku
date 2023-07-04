{{- if .}}{{- if ne .SectionName ""}}

### {{.SectionName}}
{{range $k,$v := .Items}}
- {{if $v.Message.Scope}}**{{$v.Message.Scope}}:** {{end}}{{$v.Message.Description}} ([{{$v.Hash}}](https://github.com/waku-org/nwaku/commit/{{$v.Hash}})){{if $v.Message.Metadata.issue}} ([https://github.com/waku-org/nwaku/issues/{{$v.Message.Metadata.issue}}]({{$v.Message.Metadata.issue}})){{end}}
{{- end}}
{{- end}}{{- end}}
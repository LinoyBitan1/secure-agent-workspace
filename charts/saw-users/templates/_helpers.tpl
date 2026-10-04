{{/*
Fail the render on a bad user list, or when the Argo CD namespace and git
source cannot be resolved. Applications must land in the namespace Argo CD
watches, not in whatever namespace this chart happens to be released into.
*/}}
{{- define "saw-users.validate" -}}
{{- $argoNS := .Values.global.vpArgoNamespace | default .Values.argo.namespace -}}
{{- if not $argoNS -}}
{{- fail "set global.vpArgoNamespace or argo.namespace so Applications are created in the Argo CD namespace" -}}
{{- end -}}
{{- if not .Values.global.repoURL -}}
{{- fail "global.repoURL is required" -}}
{{- end -}}
{{- if not .Values.global.targetRevision -}}
{{- fail "global.targetRevision is required" -}}
{{- end -}}
{{- $seen := dict -}}
{{- range .Values.users | default list -}}
{{- $name := .name | default "" | toString -}}
{{- if not (regexMatch "^[a-z0-9]([-a-z0-9]*[a-z0-9])?$" $name) -}}
{{- fail (printf "user name %q must be a lowercase DNS label (letters, digits, and hyphens; must start and end with a letter or digit)" $name) -}}
{{- end -}}
{{- if gt (len $name) 19 -}}
{{- fail (printf "user name %q is too long: it names the VM (%d characters) and OpenShell allows 19" $name (len $name)) -}}
{{- end -}}
{{- $route := printf "%s-dashboard-saw-%s" $name $name -}}
{{- if gt (len $route) 63 -}}
{{- fail (printf "user name %q makes dashboard route label %q %d characters; DNS labels allow 63" $name $route (len $route)) -}}
{{- end -}}
{{- if hasKey $seen $name -}}
{{- fail (printf "duplicate user name %q" $name) -}}
{{- end -}}
{{- $_ := set $seen $name "1" -}}
{{- end -}}
{{- end -}}

{{- define "saw-users.argoNamespace" -}}
{{- .Values.global.vpArgoNamespace | default .Values.argo.namespace -}}
{{- end -}}

{{/*
global.* values: openshell-saw only gets the keys in machineGlobals, when
non-empty (an empty helm parameter makes Argo CD flap OutOfSync; framework
internals such as deletePattern are not copied).
*/}}

{{/*
Whether removing this user also deletes the VM and namespace: the user's
own pruneOnRemove, else the chart-wide default. "true" or "".
*/}}
{{- define "saw-users.prune" -}}
{{- $user := .user -}}
{{- $prune := .root.Values.pruneOnRemove -}}
{{- if hasKey $user "pruneOnRemove" -}}
{{- $prune = $user.pruneOnRemove -}}
{{- end -}}
{{- if $prune -}}true{{- end -}}
{{- end -}}

{{/*
openshell-saw values: chart defaults, then this user's owner, then the
user's `values` on top. Nested maps merge; the user's keys win.
*/}}
{{- define "saw-users.openshellValues" -}}
{{- $user := .user -}}
{{- $root := .root -}}
{{- $base := deepCopy ($root.Values.defaults.openshellSaw | default dict) -}}
{{- $ac := deepCopy (index $base "accessControl" | default dict) -}}
{{- $_ := set $ac "owner" $user.name -}}
{{- $_ := set $ac "ownerSubject" ($user.ownerSubject | default "" | toString) -}}
{{- $_ := set $base "accessControl" $ac -}}
{{- $globals := dict -}}
{{- range $k := $root.Values.machineGlobals | default list -}}
{{- $v := index $root.Values.global $k -}}
{{- if $v -}}
{{- $_ := set $globals $k $v -}}
{{- end -}}
{{- end -}}
{{- $_ := set $base "global" $globals -}}
{{- /* Argo CD runs the chart's pre-delete hook when the app is deleted: only
     users with pruneOnRemove get it, the others keep their VM. */ -}}
{{- $_ := set $base "cleanupOnDelete" (eq (include "saw-users.prune" (dict "root" $root "user" $user)) "true") -}}
{{- /* demoHarness puts a harnessRef on a sandbox, which OpenShell 0.1.x
     refuses to mount without allow_driver_config; derive it here so the two
     flags can't drift apart. The user's own `values.allowDriverConfig`
     still wins if set. */ -}}
{{- if $user.demoHarness -}}
{{- $_ := set $base "allowDriverConfig" true -}}
{{- end -}}
{{- $overlay := deepCopy ($user.values | default dict) -}}
{{- mergeOverwrite $base $overlay | toYaml -}}
{{- end -}}

{{- define "saw-users.profiles" -}}
{{- $user := .user -}}
{{- $root := .root -}}
{{- $profiles := $root.Values.defaults.profiles -}}
{{- if hasKey $user "profiles" -}}
{{- $profiles = $user.profiles -}}
{{- end -}}
{{- $bomValues := dict "profiles" $profiles -}}
{{- if $user.demoHarness -}}
{{- $_ := set $bomValues "demoHarness" true -}}
{{- end -}}
{{- toYaml $bomValues -}}
{{- end -}}

{{- define "saw-users.vaultPrefix" -}}
{{- $user := .user -}}
{{- $root := .root -}}
{{- toYaml (dict "vaultPrefix" ($user.vaultPrefix | default $root.Values.defaults.vaultPrefix)) -}}
{{- end -}}

{{- define "saw-users.application" -}}
{{- $root := .root -}}
{{- $user := .user -}}
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: {{ .appName }}
  namespace: {{ include "saw-users.argoNamespace" $root }}
  labels:
    validatedpatterns.io/pattern: {{ $root.Values.global.pattern | default "secure-agent-workspace" | quote }}
    openshell.pattern/owner: {{ $user.name | quote }}
  annotations:
    argocd.argoproj.io/sync-wave: {{ .wave | quote }}
  {{- if include "saw-users.prune" (dict "root" $root "user" $user) }}
  finalizers:
    - {{ $root.Values.argo.finalizer }}
  {{- end }}
spec:
  project: {{ $root.Values.argo.project }}
  destination:
    name: {{ $root.Values.argo.destinationName }}
    namespace: {{ printf "saw-%s" $user.name }}
  source:
    repoURL: {{ $root.Values.global.repoURL | quote }}
    targetRevision: {{ $root.Values.global.targetRevision | quote }}
    path: {{ .path }}
    helm:
      releaseName: {{ .release }}
      values: |
{{ .values | indent 8 }}
  syncPolicy:
    # selfHeal like the pattern's other apps: objects deleted or changed by
    # hand (e.g. while cleaning up an older install) are restored.
    automated:
      selfHeal: true
    retry:
      limit: {{ $root.Values.argo.retryLimit }}
{{- end -}}

# Remove USER sandbox workaround from nemoclaw-sandbox build

**Project:** APPENG
**Type:** Story
**Epic:** Secure Agent Workspace Validated Pattern
**Priority:** Medium
**Component:** RH_AI_Blueprints
**Labels:** secure_agent_workspace, nemoclaw, cleanup, upstream_fix

## Summary

Remove the chained BuildConfig workaround that adds `USER sandbox` and `chown -R sandbox:sandbox /sandbox` to the nemoclaw-sandbox image build, once the upstream fix ([NemoClaw #7882](https://github.com/NVIDIA/NemoClaw/issues/7882)) ships in the base image.

## Background

NemoClaw's upstream Dockerfile defaults to `USER root` at the end of the build, which causes OpenShift to reject the container (non-root UID enforcement). We implemented a workaround in our chained BuildConfig:

**File:** `image-builder-charts/helm/nemoclaw-imagestream/templates/buildconfig.yaml`

```yaml
# Current workaround — chained BuildConfig
spec:
  source:
    type: Dockerfile
    dockerfile: |
      FROM nemoclaw-sandbox-root:latest
      RUN chown -R sandbox:sandbox /sandbox
      USER sandbox
```

This two-stage build:
1. First BuildConfig (`nemoclaw-sandbox-root`) — builds from the upstream NemoClaw Dockerfile as-is
2. Second BuildConfig (`nemoclaw-sandbox`) — layers `chown` + `USER sandbox` on top

### Upstream fix status

- **Issue:** [NemoClaw #7882](https://github.com/NVIDIA/NemoClaw/issues/7882) — Dockerfile should default to USER sandbox
- **PR:** [NemoClaw #7890](https://github.com/NVIDIA/NemoClaw/pull/7890) — Changes the Dockerfile to end with `USER sandbox` after root-only setup steps
- **Status:** PR in review, CI passing (as of Aug 2026)

Once #7890 merges and ships in `ghcr.io/nvidia/nemoclaw/sandbox-base:latest`, our workaround is no longer needed.

## Acceptance Criteria

1. Upstream NemoClaw base image (`ghcr.io/nvidia/nemoclaw/sandbox-base:latest`) ships with `USER sandbox` as default
2. Chained BuildConfig removed — single BuildConfig builds the sandbox image directly
3. `RUN chown -R sandbox:sandbox /sandbox` removed (upstream handles file ownership)
4. Built sandbox image runs without Permission denied errors on `/sandbox/.profile`, `/sandbox/.bashrc`, `/sandbox/.openclaw/openclaw.json`
5. All existing functionality works: sandbox create, TUI, GUI, dashboard

## Implementation

### Before (current workaround)

Two BuildConfigs in `buildconfig.yaml`:

```yaml
# BuildConfig 1: nemoclaw-sandbox-root
FROM ghcr.io/nvidia/nemoclaw/sandbox-base:latest
# ... upstream Dockerfile (ends with USER root)

# BuildConfig 2: nemoclaw-sandbox (chained)
FROM nemoclaw-sandbox-root:latest
RUN chown -R sandbox:sandbox /sandbox
USER sandbox
```

### After (upstream fix shipped)

Single BuildConfig:

```yaml
# BuildConfig: nemoclaw-sandbox
FROM ghcr.io/nvidia/nemoclaw/sandbox-base:latest
# ... upstream Dockerfile (now ends with USER sandbox)
```

### Files to update

- `image-builder-charts/helm/nemoclaw-imagestream/templates/buildconfig.yaml` — remove second BuildConfig, remove root ImageStream
- `image-builder-charts/helm/nemoclaw-imagestream/templates/imagestream.yaml` — remove `nemoclaw-sandbox-root` ImageStream (if separate)

## Verification Steps

1. Confirm upstream NemoClaw base image has `USER sandbox` as default: `docker inspect ghcr.io/nvidia/nemoclaw/sandbox-base:latest --format '{{.Config.User}}'` → should show `sandbox`
2. Build sandbox image with single BuildConfig: `make build-nemoclaw`
3. Verify no Permission denied errors on sandbox create
4. Verify TUI works
5. Verify GUI works (openclaw gateway starts inside sandbox)

## Blocked By

- [NemoClaw #7890](https://github.com/NVIDIA/NemoClaw/pull/7890) merged and shipped in `ghcr.io/nvidia/nemoclaw/sandbox-base:latest`

## Notes

- Monitor NemoClaw releases for when #7890 ships — check the base image tag
- The `chown -R sandbox:sandbox /sandbox` may still be needed if the upstream fix only changes `USER` without fixing file ownership — verify after the upstream release
- The chained BuildConfig pattern can be reused if future upstream changes reintroduce the root user issue

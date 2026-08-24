# Switch gateway VM base image from Fedora to RHEL

**Project:** APPENG
**Type:** Story
**Epic:** Secure Agent Workspace Validated Pattern
**Priority:** Medium
**Component:** RH_AI_Blueprints
**Labels:** secure_agent_workspace, rhel, golden_image, openshell

## Summary

Replace the Fedora 44 Cloud base image with a RHEL 9 (or RHEL 10) base image for the OpenShell gateway VM. Aligns with Red Hat's supported platform strategy, enables NVIDIA GPU Operator compatibility, and provides long-term stability for production deployments.

## Background

The golden gateway VM image is currently built from `Fedora-Cloud-Base-Generic-44`. It should use RHEL for:

- **Support** — Red Hat support coverage for the full stack (OpenShift + VM OS)
- **Stability** — RHEL's longer lifecycle and predictable updates
- **GPU support** — NVIDIA GPU Operator and Container Toolkit are certified for RHEL, not Fedora
- **Security** — RHEL's FIPS compliance, SELinux policies, and CVE response
- **Customer expectation** — enterprise customers expect RHEL in Validated Patterns

## Acceptance Criteria

1. Golden image builds from a RHEL 9 (or 10) qcow2 base image
2. All existing functionality works: Docker CE (short term) should be replaced with Podman, OpenShell gateway, NemoClaw sandbox, dashboard
3. NVIDIA Container Toolkit installs cleanly on RHEL
4. Image size is comparable to current Fedora-based image
5. `make build-openshell-gateway` produces a working RHEL-based golden image

## Implementation Plan

### 1. Update base image source

**File:** `image-builder-charts/helm/openshell-gateway-image/values.yaml`

```yaml
build:
  # Current:
  # fedoraCloud: "https://download.fedoraproject.org/pub/fedora/linux/releases/44/Cloud/x86_64/images/Fedora-Cloud-Base-Generic-44-1.7.x86_64.qcow2"
  # New:
  rhelCloud: "https://access.redhat.com/downloads/content/rhel---9/x86_64/..."
```

### 2. Update virt-customize package installation

**File:** `image-builder-charts/helm/openshell-gateway-image/templates/buildconfig.yaml`

Replace Fedora-specific packages and repos:

| Fedora | RHEL |
|--------|------|
| `dnf config-manager addrepo --from-repofile=...docker-ce.repo` | Same (Docker CE supports RHEL) |
| `dnf install -y docker-ce,docker-ce-cli,containerd.io` | Same |
| `nodejs` (Fedora repo) | `nodejs:20` (RHEL AppStream module) |
| `python3-pip` (Fedora repo) | `python3-pip` (RHEL AppStream) |
| `cloud-init` | `cloud-init` (RHEL base) |
| `lsof`, `binutils`, `jq` | Same (RHEL base/AppStream) |

Key differences:
- RHEL uses `dnf module` for Node.js: `dnf module enable nodejs:20 && dnf install -y nodejs`
- Docker CE repo URL changes to `https://download.docker.com/linux/rhel/docker-ce.repo`
- EPEL may be needed for some packages
- Subscription manager registration may be required for RHEL repos

### 3. Update cloud-user setup

RHEL cloud images typically come with a `cloud-user` already configured. Verify:
- `cloud-user` exists with sudo access
- `loginctl enable-linger` works
- SELinux contexts are correct for OpenShell binaries and Docker

### 4. Update builder image

The build pod uses `registry.fedoraproject.org/fedora:44` with `libguestfs-tools-c`. For RHEL:
- Use `registry.access.redhat.com/ubi9` or `registry.redhat.io/rhel9`
- Ensure `libguestfs-tools` and `qemu-img` are available

### 5. NVIDIA Container Toolkit for RHEL

NVIDIA provides official RHEL packages:

```bash
dnf config-manager --add-repo https://nvidia.github.io/libnvidia-container/stable/rpm/nvidia-container-toolkit.repo
dnf install -y nvidia-container-toolkit
nvidia-ctk runtime configure --runtime=docker
```

This is certified for RHEL 9 (not Fedora), which is a key advantage of the switch.

### 6. SELinux considerations

RHEL enforces SELinux by default. Ensure:
- Docker containers can access GPU devices
- OpenShell gateway binary runs in the correct SELinux context
- systemd user services work with SELinux enforcing
- `/sandbox` directory has correct SELinux labels

## Dependencies

- RHEL 9 qcow2 cloud image availability
- Red Hat subscription (or CentOS Stream for development)
- NVIDIA Container Toolkit RHEL 9 packages
- OpenShell / NemoClaw compatibility with RHEL 9 Python and Node.js versions

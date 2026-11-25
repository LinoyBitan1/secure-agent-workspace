# AIPCC golden image integration (APPENG-6861)

The default VM disk source is
`quay.io/aipcc/saw-golden-image/saw-disk-image-container:0.1.0`, replacing
`ghcr.io/validatedpatterns-sandbox/openshell-gateway:latest`.
The existing internal `openshell-gateway:latest` name and CDI import remain
the same. Existing VM disks are not modified by mirroring or changing the source.

## Image roles

The [AIPCC source repository](https://github.com/red-hat-data-services/openshell-golden-image)
describes this chain: bootc container, generated qcow2, disk-image container.
Its disk recipe puts the qcow2 under `/disk` for CDI.

- `saw-bootc:0.1.0` is the OS source container. It is not passed to CDI.
- `saw-disk-image-container:0.1.0` is the disk wrapper imported for a new VM.

Authenticated inspection confirmed amd64 and arm64 manifests for both 0.1.0
images. The mirror paths retain all architectures that the selected source
actually publishes. VM boot was tested on amd64 only; see the validation
results below.

## Provisioning contract

The upstream source supplies RHEL 9, Podman, cloud-init, the guest agent,
Python and OpenShell RPMs. The consumer chart supplies the runtime user's
gateway service and first-boot setup. That setup enables lingering, starts
the rootless Podman socket and copies the gateway configuration. It runs
before the installer and records completion only on success. Legacy images
with the existing completion marker skip the additional setup.

This change retains the current BOM installer: it installs the pinned
OpenShell binaries under `/usr/local/bin`, and the chart's gateway service
runs those binaries. Reusing the image's baked OpenShell RPMs instead requires
a separate installer/version-contract change; replacing the base disk does
not silently change the running OpenShell version.

The current chart also writes its provisioning helpers under
`/usr/local/sbin` and `/usr/local/libexec`. These paths, and the installer's
`/usr/local/bin`, require a writable `/usr/local`. The published 0.1.0 disk
has an immutable `/usr/local`; cloud-init fails on the first helper write.
Supporting that layout requires a provisioning-path change or a compatible
layout supplied by the image producer.

The installer requires `/usr/bin/python3` to be Python 3.11 or later, with
`tomllib` and PyYAML available. First-boot setup checks this and reports a
specific error before starting the installer. The upstream recipe's generic
`python3`/`python3-pip` package list alone does not establish this contract.
If the released disk lacks these dependencies, they must be added by the
image producer and a compatible disk release selected before boot acceptance
can pass. A bootc image's immutable OS must not rely on cloud-init installing
missing OS packages.

## Repeatable cluster test

Use a new workspace and record its name, cluster architecture and source
digest. Do not reuse an existing VM disk to test a different image.

1. Inspect the release and confirm the cluster's architecture is present:

   ```sh
   oc get nodes -L kubernetes.io/arch
   oc image info --show-multiarch quay.io/aipcc/saw-golden-image/saw-disk-image-container:0.1.0
   ```

   Resolve any registry authorization error first. Local mirroring uses the
   operator's registry authentication; in-cluster skopeo Jobs currently expect
   an anonymously readable source. A private source needs to be made available
   to that path or mirrored with the authenticated local path.

2. Mirror the selected disk. The default is version 0.1.0; use its resolved
   digest for a reproducible run:

   ```sh
   make images-mirror
   # Once the source digest is recorded:
   # make images-mirror GOLDEN_IMAGE_URL=docker://quay.io/aipcc/saw-golden-image/saw-disk-image-container@sha256:<digest>
   oc get istag openshell-gateway:latest -n openshell-agents \
     -o jsonpath='{.image.dockerImageReference}{"\n"}'
   ```

   Both Linux mirroring and in-cluster Jobs retain the published manifest list.
   The standalone `scripts/import-golden-image.sh` uses the same source
   selection when a shared CDI DataSource is required. It skips an existing
   successful DataVolume; use an isolated namespace for a new import test.

3. With the normal provider and Keycloak configuration already supplied:

   For Option A, install the platform and add the test workspace through
   `saw-users` as described in the [README](../README.md#option-a-validated-pattern-automated-gitops).
   Skip `make saw-create` below when GitOps owns the workspace; the inspection
   commands apply to either installation path.

   ```sh
   make saw-create OPENSHELL_SAW_NAME=aipcc-test
   oc get dv,vmi -n saw-aipcc-test
   make saw-status OPENSHELL_SAW_NAME=aipcc-test
   make saw-vm-ssh OPENSHELL_SAW_NAME=aipcc-test
   ```

   Inside the VM, inspect:

   ```sh
   cat /etc/os-release
   python3 -c 'import sys, tomllib, yaml; print(sys.version)'
   sudo journalctl -u saw-gateway-setup -u saw-install -u saw-apply --no-pager
   /usr/local/bin/openshell --version
   ```

4. Run `make saw-configure OPENSHELL_SAW_NAME=aipcc-test`, verify owner OIDC
   login and a sandbox inference request, then restart the test VM with
   `make saw-restart OPENSHELL_SAW_NAME=aipcc-test` and repeat. Record the
   DataVolume import, guest OS, installer result, gateway connectivity and
   inference result for each architecture tested. See [Testing](testing.md)
   for the existing acceptance checks.

## Overrides and rollback

`GOLDEN_IMAGE_URL` selects the external gateway disk independently of its
internal name and accepts a `docker://` reference with a tag or sha256 digest.
It takes precedence over the legacy repo/tag selection.
Explicit `IMAGE_REPO` or `IMAGE_TAG` settings retain the project-built
disk selection when `GOLDEN_IMAGE_URL` is unset. Other mirror images,
including `openshell-gateway-docker`, retain their existing source selection.

To select a previous project disk for new workspaces:

```sh
make images-mirror IMAGE_TAG=sha-<previous-commit>
```

Preserve existing workspace disks and follow the documented workspace
lifecycle before recreating a test workspace. Changing the shared mirror
does not roll back the disk of an existing VM.

## Validation status

Local tests exercise source selection, legacy overrides, mirror Job rendering,
input validation, TLS handling, first-boot setup and chart rendering.
They do not establish that the published disk boots.

Initial source inspection used upstream revision
`fff27c4aff03c6728c40a69a3f43531731581ec6`. Anonymous registry access was
denied. Authenticated release inspection and a fresh-cluster VM test are
recorded below; the published disk does not meet the current provisioning
contract.

### Cluster verification, 2026-11-24

README Option A was installed from commit
`dd192f9bef84e9a69a739caab78a84a190a10f26` on OpenShift 4.22.22 (amd64),
with web search disabled and isolated deployment inputs outside the repository.
The installer exited successfully. All ten Argo CD applications were
`Synced` and `Healthy`; all eight required operators reported `Succeeded`.
OpenShift Virtualization reported `Available=True`, `Degraded=False`, and
four nodes exposed KVM. Developer Hub completed its Deployment rollout.
Its HTTPS root and Keycloak's OIDC discovery endpoint both returned HTTP 200
with TLS certificate verification enabled.

A cluster-side `oc import-image --dry-run=true --import-mode=PreserveOriginal`
probe for the requested disk reference failed with a registry access error.
Anonymous pulls and a pull using the cluster's existing Quay credentials also
failed. The dry-run probe created no ImageStream. No workspace VM was created.
This verifies platform installation, not AIPCC image import, VM boot, gateway
integration or inference. Those checks were blocked on registry access during
that run.

### Authenticated VM verification, 2026-11-25

Both private 0.1.0 references were readable with the supplied read-only
registry credentials. The disk image's published index digest is
`sha256:75226790d56ea0f8c3fb1cd37b741c638d8e4c41f6fd89b3cf824d3a727de992`.
`make images-mirror` succeeded, and the internal ImageStream retained that
digest and both amd64 and arm64 manifests.

README Option A was installed on a fresh OpenShift 4.22.22 amd64 cluster from commit
`5a56488bc29caa0f84003119f9ffb6e45566e398`, with web search disabled.
The installer exited with code 0; all ten platform applications were
`Synced` and `Healthy`. OpenShift Virtualization reported `Available=True`
and `Degraded=False`.

A single GitOps-managed workspace, `aipcc-test` in `saw-aipcc-test`, used
the `ci-nvidia` profile and cluster-only Pattern overrides. Its DataVolume
import succeeded. The VMI reached `Running` and `Ready=True`, and its guest
agent reported RHEL 9.6 on x86_64. These checks establish disk import and
OS boot, not gateway readiness.

Guest diagnostics confirmed two compatibility failures:

- Cloud-init's `write_files` module failed with
  `OSError: [Errno 30] Read-only file system: '/usr/local/sbin/saw-gateway-setup'`.
  The setup script and unit were absent. The `saw-install` and `saw-apply`
  services were inactive, and a guest-local connection to gateway port 17670
  was refused.
- The guest's `python3` is 3.9.21. PyYAML is present, but `tomllib` is absent;
  the current installer requires Python 3.11 or later with both modules.

The image replacement is not ready for acceptance. Gateway startup,
owner OIDC login, sandbox inference, reboot recovery and arm64 VM boot have
not passed. Fixing the writable-path contract alone would still leave the
Python dependency mismatch. No guest OS packages were installed or immutable
filesystems remounted during this test.

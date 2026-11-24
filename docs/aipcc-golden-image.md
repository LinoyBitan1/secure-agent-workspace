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

The announcement confirms amd64 and arm64 for the bootc image. Verify the
disk wrapper's manifest too; its published architectures have not yet been
validated for this integration. The mirror paths retain all architectures
that the selected source actually publishes.

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

Source inspection used upstream revision
`fff27c4aff03c6728c40a69a3f43531731581ec6`. That source may differ from
the published 0.1.0 artifacts. An anonymous manifest request for the disk
release returned `unauthorized`; its digest, platforms, Python dependencies
and boot/gateway behavior remain unverified. Complete the cluster procedure
after registry access and a test cluster are available.

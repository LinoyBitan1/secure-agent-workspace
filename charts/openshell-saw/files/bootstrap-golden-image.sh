#!/usr/bin/env bash
# Phase: ensure the golden image DataSource exists and the VM DataVolume is provisioned.
# Expects: GOLDEN_DS, GOLDEN_NS, GOLDEN_DISK_SIZE, GOLDEN_IMAGE_URL, PULL_METHOD,
#          VM_NAME, NS

if [[ -z "${GOLDEN_IMAGE_URL}" ]]; then
  GOLDEN_IMAGE_URL="docker://image-registry.openshift-image-registry.svc:5000/${GOLDEN_NS}/${GOLDEN_DS}:latest"
fi

if [[ -n "${GOLDEN_DS}" ]]; then
  DS_EXISTS="$(kubectl get datasource "${GOLDEN_DS}" -n "${GOLDEN_NS}" -o name 2>/dev/null || true)"
  DV_PHASE="$(kubectl get dv "${GOLDEN_DS}-golden" -n "${GOLDEN_NS}" -o jsonpath='{.status.phase}' 2>/dev/null || true)"

  # Case 1: No DataVolume — create both DV + DS and wait
  if [[ -z "${DV_PHASE}" ]]; then
    echo "Golden image not found. Creating DataVolume + DataSource from registry..."
    kubectl apply -f - <<DVEOF
apiVersion: cdi.kubevirt.io/v1beta1
kind: DataVolume
metadata:
  name: ${GOLDEN_DS}-golden
  namespace: ${GOLDEN_NS}
  annotations:
    cdi.kubevirt.io/storage.bind.immediate.requested: "true"
spec:
  source:
    registry:
      url: "${GOLDEN_IMAGE_URL}"
      pullMethod: ${PULL_METHOD}
  storage:
    accessModes:
      - ReadWriteOnce
    resources:
      requests:
        storage: ${GOLDEN_DISK_SIZE}
DVEOF
    DV_PHASE="pending"
  fi

  # Case 2: DataVolume exists but not Succeeded — wait for import
  if [[ "${DV_PHASE}" != "Succeeded" ]]; then
    echo "Waiting for golden image import..."
    golden_deadline=$((SECONDS + 900))
    while true; do
      DV_PHASE="$(kubectl get dv "${GOLDEN_DS}-golden" -n "${GOLDEN_NS}" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
      gprog="$(kubectl get dv "${GOLDEN_DS}-golden" -n "${GOLDEN_NS}" -o jsonpath='{.status.progress}' 2>/dev/null || true)"
      echo "  golden image: phase=${DV_PHASE:-pending} progress=${gprog:-N/A}"
      if [[ "${DV_PHASE}" == "Succeeded" ]]; then break; fi
      if (( SECONDS > golden_deadline )); then
        echo "Timed out waiting for golden image import" >&2
        exit 1
      fi
      sleep 15
    done
  fi

  # Case 3: DataVolume Succeeded but DataSource missing — create DS only
  if [[ -z "${DS_EXISTS}" ]]; then
    echo "Creating DataSource '${GOLDEN_DS}'..."
    kubectl apply -f - <<DSEOF
apiVersion: cdi.kubevirt.io/v1beta1
kind: DataSource
metadata:
  name: ${GOLDEN_DS}
  namespace: ${GOLDEN_NS}
spec:
  source:
    pvc:
      name: ${GOLDEN_DS}-golden
      namespace: ${GOLDEN_NS}
DSEOF
  fi

  echo "Golden image ready (DataVolume: Succeeded, DataSource: ${GOLDEN_DS})."

  # If the VM was created before the DataSource existed, its DataVolume
  # was never created by KubeVirt. Create it directly so the VM can boot.
  DV_NAME="${VM_NAME}-root"
  if ! kubectl get dv "${DV_NAME}" -n "${NS}" >/dev/null 2>&1; then
    echo "VM DataVolume '${DV_NAME}' missing — creating clone from DataSource..."
    kubectl apply -f - <<CLONEDV || echo "DataVolume already exists or conflict — continuing"
apiVersion: cdi.kubevirt.io/v1beta1
kind: DataVolume
metadata:
  name: ${DV_NAME}
  namespace: ${NS}
  annotations:
    cdi.kubevirt.io/storage.bind.immediate.requested: "true"
spec:
  sourceRef:
    kind: DataSource
    name: ${GOLDEN_DS}
    namespace: ${GOLDEN_NS}
  storage:
    accessModes:
      - ReadWriteOnce
    resources:
      requests:
        storage: ${GOLDEN_DISK_SIZE}
CLONEDV
  fi
fi

# Wait for VM DataVolume provisioning
DV_NAME="${VM_NAME}-root"
echo "Waiting for DataVolume ${DV_NAME} to be provisioned..."
deadline=$((SECONDS + 900))
while true; do
  dv_phase="$(kubectl -n "${NS}" get datavolume "${DV_NAME}" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
  echo "  datavolume phase=${dv_phase:-unknown}"
  if [[ "${dv_phase}" == "Succeeded" ]]; then
    break
  fi
  if (( SECONDS > deadline )); then
    echo "Timed out waiting for DataVolume provisioning" >&2
    exit 1
  fi
  sleep 10
done

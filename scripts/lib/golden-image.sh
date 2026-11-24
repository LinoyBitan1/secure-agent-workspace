#!/usr/bin/env bash
# Keep the external disk source separate from its internal ImageStream name.
if [[ -n "${GOLDEN_IMAGE_URL:-}" ]]; then
  golden_pattern='^docker://[a-z0-9]([a-z0-9.-]*[a-z0-9])?(:[0-9]{1,5})?(/[a-z0-9]+(([._]|__|-+)[a-z0-9]+)*)+(:[a-zA-Z0-9_][a-zA-Z0-9_.-]*|@sha256:[a-f0-9]{64})$'
  if [[ ! "$GOLDEN_IMAGE_URL" =~ $golden_pattern || "$GOLDEN_IMAGE_URL" == *..* ]]; then
    echo 'Error: GOLDEN_IMAGE_URL must be a docker:// registry image with a tag or sha256 digest.' >&2
    return 1
  fi
fi

saw_image_source() {
  if [[ "$1" == openshell-gateway && -n "${GOLDEN_IMAGE_URL:-}" ]]; then
    printf '%s\n' "$GOLDEN_IMAGE_URL"
  elif [[ "$1" == openshell-gateway && -z "${IMAGE_REPO:-}" && -z "${IMAGE_TAG:-}" ]]; then
    printf '%s\n' 'docker://quay.io/aipcc/saw-golden-image/saw-disk-image-container:0.1.0'
  else
    printf 'docker://%s/%s:%s\n' "${IMAGE_REPO:-ghcr.io/validatedpatterns-sandbox}" "$1" "${IMAGE_TAG:-latest}"
  fi
}

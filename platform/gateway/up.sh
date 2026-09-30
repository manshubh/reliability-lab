#!/usr/bin/env bash
# Bring the lab's front door to the desired state on the running cluster: the
# Gateway API CRDs, Traefik as their implementation, and the lab Gateway.
# Each step changes only what differs, so it is safe to run again at any time.
#
# `make up` runs it after platform/cluster/up.sh, with the pinned tools first
# on PATH and Helm's directories inside the repository.
set -euo pipefail

# shellcheck source=../cluster/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../cluster/common.sh"

GATEWAY_DIR=$ROOT/platform/gateway
# One field manager for every server-side apply, run after run. The CRD file
# also holds a ValidatingAdmissionPolicy, and a second manager setting the
# same fields would conflict with the first.
FIELD_MANAGER=lab

# Read the pins first, so a missing one stops the run before it changes
# anything.
GATEWAY_API_VERSION=$(pin gateway_api_version)
GATEWAY_API_SHA256=$(pin gateway_api_sha256)

# apply_files FILE...: server-side apply FILEs, unless that would change
# nothing. Server-side, because a client-side apply compares lists with the
# defaults the API server filled in, and so reports objects such as
# HTTPRoutes as "configured" on every run. A server-side apply always reports
# "serverside-applied", changed or not, so diff first: kubectl diff exits 0
# when nothing would change, 1 when something would, and above 1 when it
# can't tell (for example, when a namespace in the files doesn't exist yet).
apply_files() {
  local file args=()
  for file in "$@"; do args+=(--filename "$file"); done
  if kubectl --context "$CONTEXT" diff --server-side --field-manager="$FIELD_MANAGER" \
    "${args[@]}" >/dev/null 2>&1; then
    for file in "$@"; do echo "    ${file#"$ROOT"/}: unchanged"; done
    return
  fi
  kubectl --context "$CONTEXT" apply --server-side --field-manager="$FIELD_MANAGER" "${args[@]}"
}

preflight() {
  local tool
  for tool in kubectl helm helmfile curl shasum; do
    command -v "$tool" >/dev/null || die "$tool isn't on PATH. Run this through 'make up'."
  done
  [ -n "${HELM_PLUGINS:-}" ] || die "HELM_PLUGINS isn't set. Run this through 'make up'."
  kubectl --context "$CONTEXT" get --raw /readyz >/dev/null 2>&1 ||
    die "the cluster doesn't answer on context $CONTEXT. Run 'make up'."
  echo "    cluster reachable on context $CONTEXT"
}

# CRDs are cluster-wide and outlive any one release, so they are applied here
# rather than through Helm. As a chart, these would be stored in a Helm
# release Secret, and the file is larger than a Secret may be (1 MiB).
# helmfile hooks don't fit either: presync and preapply hooks are skipped when
# a release is unchanged, and prepare hooks also run on `helmfile diff`. The
# file includes a ValidatingAdmissionPolicy that stops an older or
# experimental-channel CRD from replacing these; it is kept.
install_gateway_api() {
  local file actual
  file=$DOWNLOADS/gateway-api-$GATEWAY_API_VERSION/standard-install.yaml
  if [ -f "$file" ] && [ "$(sha256 "$file")" = "$GATEWAY_API_SHA256" ]; then
    echo "    standard-install.yaml $GATEWAY_API_VERSION already downloaded"
  else
    rm -f "$file"
    download "https://github.com/kubernetes-sigs/gateway-api/releases/download/$GATEWAY_API_VERSION/standard-install.yaml" "$file"
    actual=$(sha256 "$file")
    if [ "$actual" != "$GATEWAY_API_SHA256" ]; then
      rm -f "$file"
      {
        echo "error: standard-install.yaml $GATEWAY_API_VERSION doesn't match gateway_api_sha256 in platform/versions.yaml"
        echo "  expected $GATEWAY_API_SHA256"
        echo "  got      $actual"
      } >&2
      die "nothing was applied. If you just changed the version, update the checksum (see the comment there); otherwise the download was damaged or altered."
    fi
  fi

  apply_files "$file"
  # Gateways and routes can only be created once these are established.
  kubectl --context "$CONTEXT" wait --for=condition=Established --timeout=60s \
    crd/gatewayclasses.gateway.networking.k8s.io crd/gateways.gateway.networking.k8s.io \
    crd/httproutes.gateway.networking.k8s.io >/dev/null
}

# The gateway namespace, our GatewayClass and the lab Gateway. They go in
# before Traefik, whose release lives in that namespace.
apply_gateway() {
  apply_files "$GATEWAY_DIR/gateway.yaml"
}

# helm-diff tells helmfile whether the release would change, so an unchanged
# release is left alone: no upgrade, no new revision. The waits below allow
# for image pulls, which take minutes on a slow link.
install_traefik() {
  helmfile --file "$ROOT/platform/helmfile.yaml" apply
  kubectl --context "$CONTEXT" --namespace gateway rollout status deployment/traefik --timeout=300s
}

# Programmed means Traefik has taken on the Gateway and serves its listener.
wait_for_gateway() {
  kubectl --context "$CONTEXT" --namespace gateway wait --for=condition=Programmed \
    gateway/lab --timeout=120s
}

step "check prerequisites" preflight
step "install the Gateway API CRDs" install_gateway_api
step "apply the Gateway" apply_gateway
step "install Traefik" install_traefik
step "wait for the Gateway" wait_for_gateway
summary

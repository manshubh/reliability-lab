#!/usr/bin/env bash
# Delete everything `make up` created: the cluster, its kubeconfig context,
# the registry, and kind's Docker network when nothing else uses it.
#
# It never fails. Cleanup has to work in any state, including a half-built
# lab, missing tools or a stopped Docker, so each step says what it found and
# the script always exits 0. That is also why `errexit` (set -e) is off.
set -uo pipefail

# shellcheck source=common.sh
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

if ! command -v docker >/dev/null; then
  echo "docker isn't installed, so there is nothing to delete."
  exit 0
fi
if ! docker info >/dev/null 2>&1; then
  echo "Docker isn't reachable, so nothing was deleted. Start your Docker runtime and run 'make down' again."
  exit 0
fi

delete_cluster() {
  if command -v kind >/dev/null; then
    # Removes the node containers, their volumes and the kubeconfig context,
    # and does nothing when the cluster doesn't exist.
    kind delete cluster --name "$CLUSTER"
    return
  fi
  # Without kind, remove the nodes by the label kind gives them. -v also
  # removes each node's anonymous volume.
  local nodes
  nodes=$(docker ps --all --quiet --filter "label=io.x-k8s.kind.cluster=$CLUSTER")
  if [ -n "$nodes" ]; then
    # Word splitting is wanted: one container ID per word.
    # shellcheck disable=SC2086
    docker rm --force --volumes $nodes >/dev/null && echo "    removed the cluster's nodes"
  fi
  echo "    kind isn't installed, so the kubeconfig context $CONTEXT (if any) was left. Run 'make tools', then 'make down'."
}

delete_registry() {
  if ! docker inspect "$REGISTRY" >/dev/null 2>&1; then
    echo "    no registry container"
    return
  fi
  # The registry image declares a volume for its storage. Without --volumes
  # it would be left behind, unnamed, after every run.
  docker rm --force --volumes "$REGISTRY" >/dev/null && echo "    removed $REGISTRY and its storage"
}

delete_network() {
  local users
  if ! users=$(docker network inspect "$NETWORK" --format '{{range .Containers}}{{.Name}} {{end}}' 2>/dev/null); then
    echo "    no '$NETWORK' network"
    return
  fi
  # Other kind clusters, or containers someone attached, may share it.
  if [ -n "$users" ]; then
    echo "    left the '$NETWORK' network, still used by: ${users% }"
    return
  fi
  docker network rm "$NETWORK" >/dev/null && echo "    removed the '$NETWORK' network"
}

step "delete the cluster" delete_cluster
step "delete the registry" delete_registry
step "delete the network if unused" delete_network
summary

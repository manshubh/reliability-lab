#!/usr/bin/env bash
# Bring the lab cluster and its local registry to the desired state: create
# what is missing, start what is stopped, and leave alone what already works.
# Safe to run again at any time.
#
# Run it with `make up`, which puts the pinned kind and kubectl first on PATH.
# Host ports: LAB_GATEWAY_PORT (default 8080) and LAB_GRAFANA_PORT (default
# 3000). They only take effect when the cluster is created.
set -euo pipefail

# shellcheck source=common.sh
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

GATEWAY_PORT=${LAB_GATEWAY_PORT:-8080}
GRAFANA_PORT=${LAB_GRAFANA_PORT:-3000}

# Read the pins first, so a missing one stops the run before it changes
# anything.
NODE_IMAGE=$(pin kind_node_image)
REGISTRY_IMAGE=$(pin registry_image)

# Not `grep -q`: it stops reading at the first match, and with pipefail the
# writer's resulting broken pipe would count as a failure.
cluster_exists() {
  kind get clusters 2>/dev/null | grep -x "$CLUSTER" >/dev/null
}

registry_state() {
  docker inspect --format '{{.State.Status}}' "$REGISTRY" 2>/dev/null || true
}

# port_in_use PORT: true when something on this machine accepts connections
# on 127.0.0.1:PORT. bash's /dev/tcp needs no extra tool on macOS or Linux.
port_in_use() {
  (exec 3<>"/dev/tcp/127.0.0.1/$1") 2>/dev/null
}

check_port_number() {
  case $2 in
    '' | *[!0-9]*) die "$1 must be a port number, got '$2'" ;;
  esac
  if [ "$2" -lt 1 ] || [ "$2" -gt 65535 ]; then
    die "$1 must be between 1 and 65535, got $2"
  fi
}

# check_port_free PORT HINT: fail with HINT when PORT is taken.
check_port_free() {
  if port_in_use "$1"; then
    die "127.0.0.1:$1 is already in use. Stop whatever listens there, $2"
  fi
}

preflight() {
  local out
  check_port_number LAB_GATEWAY_PORT "$GATEWAY_PORT"
  check_port_number LAB_GRAFANA_PORT "$GRAFANA_PORT"
  if [ "$GATEWAY_PORT" = "$GRAFANA_PORT" ] || [ "$GATEWAY_PORT" = "$REGISTRY_PORT" ] ||
    [ "$GRAFANA_PORT" = "$REGISTRY_PORT" ]; then
    die "LAB_GATEWAY_PORT, LAB_GRAFANA_PORT and the registry's $REGISTRY_PORT must all differ"
  fi

  command -v docker >/dev/null || die "docker isn't installed. Install a Docker-compatible runtime (see README)."
  command -v kind >/dev/null || die "kind isn't on PATH. Run this through 'make up'."
  if ! out=$(docker info --format '{{.ServerVersion}}' 2>&1); then
    echo "$out" >&2
    die "Docker isn't reachable. Start your Docker runtime and try again."
  fi

  # Ports are only bound when the cluster or the registry is created. Checking
  # them first turns a Docker error halfway through into a clear message.
  if ! cluster_exists; then
    check_port_free "$GATEWAY_PORT" "or pick another port, for example: LAB_GATEWAY_PORT=18080 make up"
    check_port_free "$GRAFANA_PORT" "or pick another port, for example: LAB_GRAFANA_PORT=13000 make up"
  fi
  if [ -z "$(registry_state)" ]; then
    check_port_free "$REGISTRY_PORT" "as the registry's port is fixed: image names contain it."
  fi
  echo "    Docker $out"
}

# kind.yaml holds the default host ports. Swap in the chosen ones and hand the
# result to kind on stdin, so the file in the repository stays the one source.
cluster_config() {
  sed -e "s/hostPort: 8080$/hostPort: $GATEWAY_PORT/" \
    -e "s/hostPort: 3000$/hostPort: $GRAFANA_PORT/" \
    "$ROOT/platform/cluster/kind.yaml"
}

create_cluster() {
  if cluster_exists; then
    echo "    cluster '$CLUSTER' already exists (to change its ports or version: make down, then make up)"
    return
  fi
  local config port
  config=$(cluster_config)
  # If kind.yaml's defaults drift from the ones above, the swap silently does
  # nothing. Catch that rather than create a cluster on the wrong ports.
  for port in "$GATEWAY_PORT" "$GRAFANA_PORT"; do
    grep -q "hostPort: $port$" <<<"$config" || die "couldn't set hostPort $port in kind.yaml"
  done
  echo "    host ports: gateway $GATEWAY_PORT, Grafana $GRAFANA_PORT"
  kind create cluster --name "$CLUSTER" --image "$NODE_IMAGE" --config=- <<<"$config"
}

# Docker brings kind's nodes back after a crash or a Docker restart, but a
# node someone stopped (an experiment, say) stays stopped. Start any such.
start_stopped_nodes() {
  local stopped
  stopped=$(docker ps --all --filter "label=io.x-k8s.kind.cluster=$CLUSTER" \
    --filter status=exited --filter status=created --format '{{.Names}}')
  if [ -z "$stopped" ]; then
    echo "    every node is running"
    return
  fi
  # Word splitting is wanted: one container name per word.
  # shellcheck disable=SC2086
  docker start $stopped
}

wait_for_nodes() {
  local tries=0
  # A control plane that has just started takes a few seconds to answer, and
  # kubectl wait gives up at once when the connection is refused.
  until kubectl --context "$CONTEXT" get --raw /readyz >/dev/null 2>&1; do
    tries=$((tries + 1))
    [ "$tries" -lt 60 ] || die "the API server didn't answer within 2 minutes"
    sleep 2
  done
  kubectl --context "$CONTEXT" wait --for=condition=Ready nodes --all --timeout=180s
}

start_registry() {
  case $(registry_state) in
    running)
      echo "    registry '$REGISTRY' is already running"
      ;;
    "")
      # On kind's network, the nodes reach the registry by its container name.
      # unless-stopped brings it back after Docker restarts, like the nodes.
      docker run --detach --name "$REGISTRY" --network "$NETWORK" \
        --publish "127.0.0.1:$REGISTRY_PORT:5000" --restart unless-stopped \
        "$REGISTRY_IMAGE"
      ;;
    *)
      docker start "$REGISTRY"
      ;;
  esac
}

# Make the image name localhost:5001/... work everywhere. On the laptop,
# localhost:5001 is the published registry port. Inside a node container,
# localhost is the node itself, so containerd is told to fetch from the
# registry container instead. containerd reads these files at each pull, so
# no restart is needed.
point_nodes_at_registry() {
  local node dir="/etc/containerd/certs.d/localhost:$REGISTRY_PORT"
  for node in $(kind get nodes --name "$CLUSTER"); do
    docker exec "$node" mkdir -p "$dir"
    printf '[host."http://%s:5000"]\n' "$REGISTRY" | docker exec -i "$node" cp /dev/stdin "$dir/hosts.toml"
    echo "    $node"
  done
}

publish_registry_config() {
  kubectl --context "$CONTEXT" apply -f "$ROOT/platform/cluster/local-registry-hosting.yaml"
}

# The ports the cluster really has, which differ from the requested ones when
# it was created earlier with other values.
show_endpoints() {
  local gateway grafana
  gateway=$(docker port "$CLUSTER-control-plane" 30080/tcp)
  grafana=$(docker port "$CLUSTER-control-plane" 30300/tcp)
  echo
  echo "Cluster '$CLUSTER' is ready (kubectl context $CONTEXT)."
  echo "  gateway   http://$gateway"
  echo "  Grafana   http://$grafana"
  echo "  registry  localhost:$REGISTRY_PORT"
}

step "check prerequisites" preflight
step "create the cluster" create_cluster
step "start stopped nodes" start_stopped_nodes
step "wait for nodes to be Ready" wait_for_nodes
step "start the registry" start_registry
step "point nodes at the registry" point_nodes_at_registry
step "publish the registry's location" publish_registry_config
show_endpoints
summary

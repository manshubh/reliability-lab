#!/usr/bin/env bash
# Check the front door end to end: each user journey's request is routed to
# the api, requests no journey matches get a 404, and Traefik's metrics have a
# series per journey with the SLO thresholds as histogram bucket edges, which
# is what the SLOs will be computed from.
#
# Run it with `make smoke`, after `make up`. It prints one line per check and
# exits non-zero if any fails.
set -euo pipefail

# shellcheck source=../cluster/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../cluster/common.sh"

# The journeys, as the HTTPRoutes in routes.yaml name them.
JOURNEYS="browse place-order view-order"
FAILURES=0

pass() { echo "  ok    $*"; }
fail() {
  echo "  FAIL  $*"
  FAILURES=$((FAILURES + 1))
}

command -v docker >/dev/null || die "docker isn't installed. Install a Docker-compatible runtime (see README)."
docker info >/dev/null 2>&1 || die "Docker isn't reachable. Start your Docker runtime, then run 'make up' first."
# The host port the cluster was really created with, which LAB_GATEWAY_PORT
# may have changed.
GATEWAY=$(docker port "$CLUSTER-control-plane" 30080/tcp 2>/dev/null) ||
  die "the lab cluster isn't running. Run 'make up' first."
kubectl --context "$CONTEXT" get --raw /readyz >/dev/null 2>&1 ||
  die "the cluster doesn't answer on context $CONTEXT. Run 'make up' first."

# expect METHOD PATH STATUS: send one request through the gateway and check
# the response's status code.
expect() {
  local got
  got=$(curl --silent --output /dev/null --write-out '%{http_code}' --max-time 10 \
    --request "$1" "http://$GATEWAY$2") || got="no response"
  if [ "$got" = "$3" ]; then
    pass "$1 $2 -> $got"
  else
    fail "$1 $2: expected $3, got $got"
  fi
}

# Every Traefik pod's metrics, one after the other. Each pod counts only the
# requests it served, so a check has to add them up. The API server's proxy
# reaches the pods without a port-forward.
traefik_metrics() {
  local pods pod port
  pods=$(kubectl --context "$CONTEXT" --namespace gateway get pods \
    --selector app.kubernetes.io/name=traefik --output jsonpath='{.items[*].metadata.name}')
  [ -n "$pods" ] || return 1
  for pod in $pods; do
    port=$(kubectl --context "$CONTEXT" --namespace gateway get pod "$pod" \
      --output jsonpath='{.spec.containers[0].ports[?(@.name=="metrics")].containerPort}')
    kubectl --context "$CONTEXT" get --raw "/api/v1/namespaces/gateway/pods/$pod:$port/proxy/metrics"
  done
}

# journey_requests JOURNEY METRICS: the requests Traefik has counted for
# JOURNEY, added up across pods and status codes. Router names start with
# httproute-<namespace>-<route>-gw-.
journey_requests() {
  awk -v prefix="router=\"httproute-app-$1-gw-" '
    /^traefik_router_requests_total\{/ && index($0, prefix) { sum += $NF }
    END { printf "%d", sum }' <<<"$2"
}

# The counters before the requests below, so the checks see this run's
# requests rather than earlier ones.
before=$(traefik_metrics) || before=""

echo "Requests through http://$GATEWAY"
expect GET /catalog 200
expect GET /catalog/42 200
expect POST /orders 200
expect GET /orders/42 200
# GET /orders would match view-order (a PathPrefix ignores the trailing
# slash), so the method check uses a method no journey has.
expect PUT /orders 404
expect GET /does-not-exist 404

echo "Traefik's metrics"
if ! metrics=$(traefik_metrics); then
  fail "couldn't read the metrics of the Traefik pods in namespace gateway"
  metrics=""
fi
for journey in $JOURNEYS; do
  counted=$(($(journey_requests "$journey" "$metrics") - $(journey_requests "$journey" "$before")))
  if [ "$counted" -gt 0 ]; then
    pass "$journey: traefik_router_requests_total counted $counted request(s) from this run"
  else
    fail "$journey: traefik_router_requests_total has no new request for route $journey"
  fi
done
for edge in 0.25 0.5; do
  # grep -c prints 0, and exits 1, when nothing matches.
  buckets=$(grep -c "^traefik_router_request_duration_seconds_bucket{.*le=\"$edge\"" <<<"$metrics" || true)
  if [ "$buckets" -gt 0 ]; then
    pass "traefik_router_request_duration_seconds has a bucket at le=\"$edge\""
  else
    fail "traefik_router_request_duration_seconds has no bucket at le=\"$edge\""
  fi
done

if [ "$FAILURES" -gt 0 ]; then
  die "$FAILURES check(s) failed"
fi
echo "Every check passed."

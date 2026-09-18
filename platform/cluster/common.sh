# shellcheck shell=bash
# Shared by up.sh and down.sh: the names of what the lab creates, and a few
# small helpers. Sourced, not run.
#
# Both scripts run on macOS's bash 3.2 as well as on Linux's bash 5, so they
# stick to features the older one has.

# The names are used by the scripts that source this file, not here.
# shellcheck disable=SC2034

# Everything the lab creates is named after the cluster, so `docker ps` shows
# at a glance what belongs to it.
CLUSTER=lab
# The kubeconfig context kind creates for the cluster. Every kubectl call names
# it, never relying on the current context: a lab script must not act on some
# other cluster just because someone switched context.
CONTEXT=kind-$CLUSTER
REGISTRY=lab-registry
# 5001 rather than the registry's usual 5000, which macOS takes for AirPlay
# Receiver. Fixed, because image names will contain it.
REGISTRY_PORT=5001
# The Docker network kind puts its nodes on. Other kind clusters share it.
NETWORK=kind

# The repository root, so the scripts work from any directory.
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)

die() {
  echo "error: $*" >&2
  exit 1
}

# pin KEY: print the value of KEY from platform/versions.yaml, or fail.
pin() {
  local value
  value=$(awk -v key="$1:" '$1 == key { print $2; exit }' "$ROOT/platform/versions.yaml")
  if [ -z "$value" ]; then
    echo "error: '$1' is missing from platform/versions.yaml" >&2
    return 1
  fi
  echo "$value"
}

# step NAME COMMAND...: run COMMAND as one named, timed step. `summary` then
# prints every step's time. Whole seconds (bash's SECONDS) are precise enough
# for steps that take from nothing to a few minutes.
STEP_NAMES=()
STEP_TIMES=()
step() {
  local name=$1 start=$SECONDS took
  shift
  echo "==> $name"
  "$@"
  took=$((SECONDS - start))
  echo "    took ${took}s"
  STEP_NAMES+=("$name")
  STEP_TIMES+=("$took")
}

summary() {
  local i
  echo
  echo "Step times:"
  for i in "${!STEP_NAMES[@]}"; do
    printf '  %-32s %4ss\n' "${STEP_NAMES[$i]}" "${STEP_TIMES[$i]}"
  done
  printf '  %-32s %4ss\n' "total" "$SECONDS"
}

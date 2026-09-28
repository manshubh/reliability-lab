#!/usr/bin/env bash
# Install, or check for, the helm-diff plugin at the version pinned in
# platform/versions.yaml. helmfile runs it to work out what an apply would
# change, which is how a second `make up` leaves an unchanged release alone.
#
#   diff-plugin.sh install   (make tools) install the pinned version, unless
#                            it is there already; replace any other version
#   diff-plugin.sh check     (make up) fail unless the pinned version is there
#
# The plugin goes into $HELM_PLUGINS, which the Makefile points inside the
# repository, so run this through make.
#
# Every release is signed. Helm checks the archive against its .prov file and
# the release key committed next to this script, helm-diff-release-key.asc,
# which is the pubkey.asc published with each release (and at
# https://github.com/databus23.gpg):
#
#   Fabian Ruff (helm-diff release key)
#   C564 5EF4 7482 257A 1F80  6D2B EA17 A2A2 06AF F8CD
#
# To see the fingerprint for yourself: gpg --show-keys helm-diff-release-key.asc
# If a release is ever signed with another key, compare the new key with both
# sources before replacing the file.
set -euo pipefail

# shellcheck source=../cluster/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../cluster/common.sh"

VERSION=$(pin helm_diff_version)
KEYRING=$ROOT/platform/helm/helm-diff-release-key.asc

[ -n "${HELM_PLUGINS:-}" ] ||
  die "HELM_PLUGINS isn't set. Run this through make (make tools or make up), which keeps Helm's files in .cache/."
command -v helm >/dev/null || die "helm isn't on PATH. Run 'make tools' first."

# The version of the installed diff plugin, or nothing.
installed_version() {
  helm plugin list 2>/dev/null | awk '$1 == "diff" { print $2 }'
}

# The release's archive name for this machine, as the project names them.
archive_name() {
  local os arch
  case $(uname -s) in
    Darwin) os=macos ;;
    Linux) os=linux ;;
    *) die "helm-diff publishes no build for $(uname -s)" ;;
  esac
  case $(uname -m) in
    arm64 | aarch64) arch=arm64 ;;
    x86_64 | amd64) arch=amd64 ;;
    *) die "helm-diff publishes no build for $(uname -m)" ;;
  esac
  echo "helm-diff-$os-$arch.tgz"
}

check() {
  local installed
  installed=$(installed_version)
  if [ "$installed" != "$VERSION" ]; then
    die "the helm-diff plugin $VERSION isn't installed (found: ${installed:-none}). Run 'make tools' first."
  fi
}

# Helm can download and verify the plugin itself, but it gives up on any
# download that takes more than two minutes, which a slow link hits with an
# archive of over 30 MB. So curl downloads it into .cache/, where it is kept
# and a broken download resumes, and Helm checks the signature of the files.
#
# Helm can't install a local archive with verification on: it looks for the
# plugin in a directory named after the archive (helm-diff-macos-arm64), and
# this one holds it in diff/. Renaming the archive to diff.tgz fixes the
# lookup but breaks the signature, which names the original file. So the
# original is verified first, and then the same bytes are installed under the
# name Helm expects, with Helm's own check off.
install() {
  local installed name dir url tmp
  installed=$(installed_version)
  if [ "$installed" = "$VERSION" ]; then
    echo "helm-diff $VERSION is already installed"
    return
  fi
  if [ -n "$installed" ]; then
    echo "Replacing helm-diff $installed with $VERSION"
    helm plugin uninstall diff
  fi

  name=$(archive_name)
  dir=$DOWNLOADS/helm-diff-$VERSION
  url=https://github.com/databus23/helm-diff/releases/download/v$VERSION/$name
  [ -f "$dir/$name" ] || download "$url" "$dir/$name"
  [ -f "$dir/$name.prov" ] || download "$url.prov" "$dir/$name.prov"

  echo "Checking the signature of $name"
  if ! helm plugin verify "$dir/$name" --keyring "$KEYRING"; then
    # Most likely a damaged download: start again from scratch next time.
    rm -f "$dir/$name" "$dir/$name.prov"
    die "helm-diff $VERSION failed its signature check, so it wasn't installed. Run 'make tools' again to download it afresh. If the check fails again, don't work around it: the release may have been altered."
  fi

  tmp=$(mktemp -d)
  # shellcheck disable=SC2064 # expand now: $tmp is local to this function
  trap "rm -rf '$tmp'" EXIT
  cp "$dir/$name" "$tmp/diff.tgz"
  echo "Installing it (Helm warns that it skips verification: that was the check above)"
  helm plugin install "$tmp/diff.tgz" --verify=false
  check
}

case ${1:-} in
  install) install ;;
  check) check ;;
  *) die "usage: $0 install|check" ;;
esac

#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"
source "$REPO_ROOT/ssw/dlk/client_common"
# Accept old VM absolute paths and the Pod path; normalize into the Pod mount.
if [[ $# -ge 8 ]]; then
  args=("$@")
  case "${args[7]}" in
    /mnt/batch_eks/l2/rsvp/*)
      args[7]="/home/jupyter/${args[7]#/mnt/batch_eks/l2/rsvp/}" ;;
    /mnt/batch_gke/l2/rsvp/*)
      # GCP 시절 경로도 그대로 받습니다.
      args[7]="/home/jupyter/${args[7]#/mnt/batch_gke/l2/rsvp/}" ;;
    "$REPO_ROOT"/mnt/batch_eks/l2/rsvp/*)
      args[7]="/home/jupyter/${args[7]#"$REPO_ROOT"/mnt/batch_eks/l2/rsvp/}" ;;
  esac
  set -- "${args[@]}"
fi
exec "$REPO_ROOT/ssw/dlk/run-eks.sh" "$@"

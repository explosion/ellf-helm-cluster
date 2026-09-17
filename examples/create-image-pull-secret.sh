#!/usr/bin/env bash
# Create the `explosion-registry` image pull secret from cluster-creds.json.
# Mirrors what `ellf infra deploy` does: username `_json_key`, password the
# decoded GCP service-account JSON, for the upstream registry's host.
#
# Usage: create-image-pull-secret.sh <namespace> <cluster-creds.json> [secret name]
#
# If you mirror Explosion's images into an internal registry, create a pull
# secret for that registry instead and skip this script.
set -euo pipefail

ns="${1:?namespace}"
creds="${2:?path to cluster-creds.json}"
name="${3:-explosion-registry}"

registry="$(jq -r .upstream_registry "$creds")"
host="${registry%%/*}"
sa_json="$(jq -r .container_sa_key "$creds" | base64 -d)"

kubectl -n "$ns" create secret docker-registry "$name" \
  --docker-server="$host" \
  --docker-username=_json_key \
  --docker-password="$sa_json" \
  --dry-run=client -o yaml | kubectl apply -f -

echo "Created pull secret $ns/$name for $host"

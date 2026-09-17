#!/usr/bin/env bash
# Create the `ellf-infra` Secret: database password plus the cluster's RSA
# signing keypair. Mirrors what Explosion's Terraform and `ellf infra deploy`
# produce.
#
# Usage: create-infra-secret.sh <namespace> <database password> [secret name]
#
# Leaves ellf-public-key.pem in the current directory; send it to Explosion
# (or run `ellf infra deploy`) to register it on the cluster record in PAM.
# The private key is written only into the Secret.
#
# Values are base64 of the PEM text because the broker reads them as
# environment variables. Kubernetes base64-encodes them again in .data.
set -euo pipefail

ns="${1:?namespace}"
db_password="${2:?database password}"
name="${3:-ellf-infra}"

if kubectl -n "$ns" get secret "$name" >/dev/null 2>&1; then
  echo "Secret $ns/$name already exists. Delete it first to regenerate the keypair." >&2
  echo "Rotating the keypair invalidates all outstanding tokens and needs re-registration with PAM." >&2
  exit 1
fi

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out "$tmp/private.pem" 2>/dev/null
openssl pkey -in "$tmp/private.pem" -pubout -out "$tmp/public.pem" 2>/dev/null

private_b64="$(base64 < "$tmp/private.pem" | tr -d '\n')"
public_b64="$(base64 < "$tmp/public.pem" | tr -d '\n')"

kubectl apply -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: $name
  namespace: $ns
type: Opaque
stringData:
  ELLF_DATABASE_PASSWORD: "$db_password"
  ELLF_PRIVATE_KEY: "$private_b64"
  ELLF_PUBLIC_KEY: "$public_b64"
EOF

cp "$tmp/public.pem" ./ellf-public-key.pem
echo "Created secret $ns/$name. Public key written to ./ellf-public-key.pem"

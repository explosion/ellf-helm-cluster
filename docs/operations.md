# Operating an Ellf cluster

## How versions are managed

The broker and sidecar image tags are **owned by PAM**, not by your values
file. Each cluster record in PAM carries a target broker version and a
target sidecar version. The sidecar polls those settings and, when they
change, patches the live Deployment's `api` and `cpl` container images
(and the preview Deployment, which tracks the broker version). Explosion
rolls releases out by moving those targets.

The chart cooperates with this:

- If `image.brokerVersion` and `image.cplVersion` are set in values, the
  chart uses them. This is only intended for the first install, when
  there is no running Deployment to read.
- If they are empty, the chart reads the tags from the live Deployment,
  so a `helm upgrade` for a values change never rolls the images back.
- `helm template` and other offline renders cannot read the live
  Deployment and fail unless the versions are set.

Consequences:

- **First install:** set both versions to the `target_*_version` values
  in `cluster-creds.json`, or let `ellf infra deploy` fetch them from PAM.
- **Later upgrades:** remove the version keys from values, or keep them
  equal to the current PAM targets. `ellf infra deploy` ignores pinned
  versions in values and warns.
- **Helm 4:** the sidecar patches the Deployment under field manager
  `kr8s`. A subsequent `helm upgrade` that changes the same fields hits a
  server-side-apply conflict; pass `--force-conflicts`.

## Upgrading the chart

Chart releases add templates and values; they do not change image
versions (see above). To upgrade:

```bash
git pull                      # or helm pull oci://.../ellf --version <new>
helm dependency build chart
helm upgrade ellf ./chart -n ellf -f values.yaml --wait
```

Read the diff of `chart/values.yaml` between versions for new keys. The
chart's `validation.yaml` fails early on missing required values.

## GitOps (Argo CD, Flux)

Because the sidecar mutates the Deployment's images, a GitOps controller
that continuously reconciles the rendered manifest will fight it. Options:

1. Pin `image.brokerVersion` and `image.cplVersion` in Git and bump them
   whenever Explosion moves the target. Add an `ignoreDifferences` rule for
   `spec.template.spec.containers[*].image` on the two Deployments and the
   `ELLF_VERSION_*` environment variables so the controller tolerates the
   sidecar's patch between bumps.
2. Or render with the CLI and apply the result outside GitOps.

The `lookup` used to read live versions does not run in `helm template`,
so option 1 is required for controllers that render with `helm template`.

## Rotating secrets

| Secret | How to rotate | Effect |
|---|---|---|
| Database password | Update PostgreSQL, patch `ELLF_DATABASE_PASSWORD` in `ellf-infra`, set `secrets.rolloutChecksum` to a new value and upgrade. | Broker restarts. |
| Cluster keypair | Re-run `examples/create-infra-secret.sh`, register the new public key with PAM (Explosion contact or `ellf infra deploy`), restart the broker. | Every outstanding user and job token becomes invalid; running annotation sessions need to be reopened. |
| Registry pull key | Recreate the `explosion-registry` Secret and update `secrets.containerSaKey`, then upgrade. | Chart rerenders `ellf-credentials`; broker restarts via the checksum annotation. |
| Prodigy licence key | Update `secrets.prodigyLicenseKey`, upgrade. | Broker restarts. |
| TLS certificate | Replace the `kubernetes.io/tls` Secret (or let cert-manager renew). | Traefik reloads automatically. |
| Media signing key | Update `secrets.mediaSigningKey`, upgrade. | Existing signed media URLs expire immediately; both pods restart. |

## Scaling

- The broker runs as a single replica with the `Recreate` strategy; it is
  not designed for multiple replicas. A restart takes a few seconds and
  running jobs are unaffected.
- Capacity for user work comes from the worker node pools. Add a pool,
  label it `ellf/node-class=<class>`, and add a matching entry to
  `workerTypes`; the `ellf-worker-types` ConfigMap is read live, so a
  `helm upgrade` is enough.
- Shared volume growth is the main storage concern. Enable `mediaGc`
  (after a dry run with `python -m ellf_broker.media_gc` inside the broker
  pod) to reclaim unreferenced media files.

## Backups

Back up two things:

- The PostgreSQL database.
- The RWX volume (`/mnt/nfs`), which holds uploaded data, datasets,
  models and media.

Everything else is reproducible from values, the two Secrets and PAM.

## Logs and monitoring

- `kubectl -n ellf logs deploy/ellf-broker -c api` and `-c cpl`. Logs
  are JSON by default (`ELLF_JSON_LOGS=true`).
- Job logs are read by the broker through the Kubernetes API and shown
  to users; if you enable `logging` (Vector plus Loki) or set
  `logging.lokiExternalUrl`, users also get logs of finished jobs whose
  pods are gone.
- Health: `GET /api/v1/status` on the cluster hostname (used by the
  readiness and liveness probes) and `GET /api/v1/version`.

## Troubleshooting

| Symptom | Likely cause |
|---|---|
| Helm fails: `image.brokerVersion could not be resolved` | First install without versions set. Set `image.brokerVersion` and `image.cplVersion`. |
| Helm fails: `secrets.infraSecretName must be set` or the broker crashloops on `ELLF_PRIVATE_KEY` | `ellf-infra` Secret missing or keys not base64-of-PEM. |
| Broker pod `ImagePullBackOff` | Pull secret missing, wrong registry host, or nodes cannot reach the registry. Run `helm test`. |
| Broker pod `Pending` | No node labelled `ellf/role=system`, or the taint is present without the label. |
| Broker pod stuck `ContainerCreating` | RWX PVC not bound, or the NFS export is not reachable from the node (security groups, firewall on port 2049). |
| Broker log: connection refused to PostgreSQL | Database unreachable from the pod network, or the NetworkPolicy blocks it (`database.egressCidr` needed when `database.ip` is a hostname). |
| Users see the cluster but opening a task fails with a token error | Public key not registered on the cluster record in PAM, or a stale key after rotation. |
| Jobs stay `Pending` with node-affinity errors | No node carries `ellf/node-class=<class>` for the chosen worker type. |
| GPU jobs `Pending` | GPU nodes lack the `nvidia.com/gpu` resource (device plugin) or the taint value differs from `present`. |
| Service recipe reachable without login | Traefik CRDs not installed, so the Middleware objects were not created; check `kubectl -n ellf get middlewares.traefik.io`. |
| Publishing a custom recipe fails with a registry error | `registries.user` empty, or the broker's ambient identity cannot push (see installation guide, writable registry). |
| Sidecar log: `container_sa_key is required for GCP registries` | `secrets.containerSaKey` empty while `registries.upstream` is on Artifact Registry. |

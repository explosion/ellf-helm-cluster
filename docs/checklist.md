# Ellf cluster: what the infrastructure team needs to provide

This page is the short version. Every item links to the section of
[`installation.md`](installation.md) that explains it.

Ellf installs into one Kubernetes namespace (default `ellf`) as a single
Helm release. The release contains a broker Deployment, a small nginx
preview Deployment, a Service and Ingress for each, RBAC for the broker's
service account, ConfigMaps, one Secret, and a NetworkPolicy. At runtime the
broker creates Kubernetes Jobs, Services, Ingresses, Secrets and ConfigMaps
in the same namespace for the annotation servers and batch jobs users
launch.

## Provided by Explosion

| Item | Form | Notes |
|---|---|---|
| Cluster ID | UUID | Primary key of the cluster record in PAM. |
| Upstream registry address | Hostname and path | Where the broker, sidecar, preview and built-in recipe images are pulled from. Read-only. |
| Registry pull credential | Base64 GCP service-account JSON | Used for an image pull secret, for `helm registry login`, and by the broker for pulling base images. |
| Prodigy licence key | String | Used by the broker to install Prodigy into custom environments. |
| Target broker and sidecar versions | Image tags | Needed for the first install. Afterwards the sidecar keeps the cluster on PAM's target versions. |
| Helm chart | This repository, or `oci://<upstream registry>/ellf` | Same chart either way. |

All of these except the chart arrive together in a `cluster-creds.json`
file, produced by `ellf infra register` or supplied by your Explosion
contact.

## Provided by the infrastructure team

| # | Requirement | Section |
|---|---|---|
| 1 | A Kubernetes cluster, 1.30 or newer, with permission to create namespaced resources plus one ClusterRole and ClusterRoleBinding (read-only on nodes). | [Kubernetes cluster](installation.md#1-kubernetes-cluster) |
| 2 | A **system node pool** labelled `ellf/role=system` and tainted `ellf/role=system:NoSchedule`, sized for the platform pods (2 vCPU, 4 GB RAM is enough). The labels and taint can be changed in values. | [Node pools](installation.md#2-node-pools-and-labels) |
| 3 | One or more **worker node pools** labelled `ellf/node-class=<class>`. GPU pools additionally tainted `nvidia.com/gpu=present:NoSchedule` with the NVIDIA device plugin installed. | [Node pools](installation.md#2-node-pools-and-labels) |
| 4 | **Traefik v3** as the ingress controller, with the Kubernetes Ingress provider enabled and its CRDs installed, reachable on ports 80 and 443 at a stable address. Ingress class name `traefik`. | [Ingress](installation.md#3-ingress-traefik) |
| 5 | A **public DNS name** for the cluster pointing at the Traefik entry point. No wildcard record is needed. | [DNS and TLS](installation.md#4-dns-and-tls) |
| 6 | A **TLS certificate** for that name trusted by users' browsers and workstations. Either cert-manager with Let's Encrypt HTTP-01, or a certificate you issue, stored as a `kubernetes.io/tls` Secret in the namespace. | [DNS and TLS](installation.md#4-dns-and-tls) |
| 7 | A **PostgreSQL** 14 or newer server with one database and one user, reachable from the cluster on port 5432. | [PostgreSQL](installation.md#5-postgresql) |
| 8 | A **ReadWriteMany PersistentVolumeClaim** in the namespace (default name `prodigy-nfs`) backed by NFS, EFS, Filestore, Azure Files or any RWX CSI driver. 100 GB minimum. | [Shared storage](installation.md#6-shared-storage) |
| 9 | **Egress** from the cluster to PAM, the upstream registry, PyPI, the Prodigy package index and, if used, Let's Encrypt. | [Network](installation.md#7-network-access) |
| 10 | Optionally, a **writable container registry** the broker can push to using the cluster's ambient cloud identity (GCP Artifact Registry via Workload Identity, or AWS ECR via node role or IRSA). Without it, users cannot publish custom recipe images; built-in recipes still work. | [Writable registry](installation.md#8-writable-registry-optional) |
| 11 | An operator workstation with `kubectl`, `helm` 3.8 or newer, and optionally the `ellf` CLI, that can reach both the Kubernetes API and PAM. | [Operator tooling](installation.md#9-operator-tooling) |

## Decisions to make before installing

- Namespace name (default `ellf`).
- Cluster hostname, for example `ellf.internal.example.com`.
- TLS: cert-manager with Let's Encrypt, or your own certificate.
- PostgreSQL: existing server, or the chart's bundled PostgreSQL for
  evaluation only.
- Storage backend for the RWX volume and its size.
- Whether custom recipe publishing is required, and therefore which
  writable registry to use.
- Whether to mirror Explosion's images into an internal registry instead
  of pulling from Explosion's registry directly.
- Worker node pool shapes and names (these become the "worker types"
  users pick when they launch jobs).
- Whether to enable in-cluster log shipping (Vector plus Loki) or point
  the broker at an existing Loki.

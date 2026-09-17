# Installing an Ellf cluster into an existing infrastructure stack

This document specifies what an Ellf cluster consists of, what it needs from
the surrounding infrastructure, and how to install it by hand with `kubectl`
and `helm`. It is written for an infrastructure team that already operates
Kubernetes and wants to host Ellf without using Explosion's Terraform.

Contents:

- [Architecture](#architecture)
- [What the Helm release installs](#what-the-helm-release-installs)
- [Requirements](#requirements)
  1. [Kubernetes cluster](#1-kubernetes-cluster)
  2. [Node pools and labels](#2-node-pools-and-labels)
  3. [Ingress (Traefik)](#3-ingress-traefik)
  4. [DNS and TLS](#4-dns-and-tls)
  5. [PostgreSQL](#5-postgresql)
  6. [Shared storage](#6-shared-storage)
  7. [Network access](#7-network-access)
  8. [Writable registry (optional)](#8-writable-registry-optional)
  9. [Operator tooling](#9-operator-tooling)
- [Credentials from Explosion](#credentials-from-explosion)
- [Secrets you must create](#secrets-you-must-create)
- [Helm values reference](#helm-values-reference)
- [Step-by-step installation](#step-by-step-installation)
- [Verification](#verification)
- [Security notes](#security-notes)

## Architecture

```
                 users (browser, ellf CLI, coding assistant)
                        │                      │
                        │ https                │ https
                        ▼                      ▼
   ┌────────────────────────────┐    ┌──────────────────────────────────────┐
   │ PAM (management plane)     │    │ Your Kubernetes cluster              │
   │ hosted by Explosion        │    │                                      │
   │ orgs, users, projects,     │◄───│  broker pod                          │
   │ cluster records, tokens    │    │   ├─ api   (FastAPI, port 8080)      │
   └────────────────────────────┘    │   └─ cpl   (sidecar: polls PAM,      │
             ▲                       │            scans registry, applies   │
             │ https (outbound only) │            version updates)          │
             └───────────────────────│  preview pod (nginx: annotation      │
                                     │            preview and media files)  │
   ┌────────────────────────────┐    │  per-job Jobs + Services + Ingresses │
   │ Explosion upstream         │◄───│            (annotation servers,      │
   │ container registry         │    │             batch jobs, agents)      │
   │ (read-only)                │    │                                      │
   └────────────────────────────┘    │  Traefik ingress ── TLS ── DNS name  │
                                     │  RWX volume (/mnt/nfs)               │
                                     │  PostgreSQL (yours)                  │
                                     └──────────────────────────────────────┘
```

Traffic directions that matter for firewalls:

- **Users → cluster.** Browsers and the `ellf` CLI reach the broker and the
  annotation servers through the cluster's public hostname over HTTPS.
- **Cluster → PAM.** The broker and its sidecar make outbound HTTPS calls to
  PAM. PAM never needs a network path to the cluster: it verifies tokens
  the cluster issues using a public key registered on the cluster record.
- **Cluster → registries and package indexes.** Outbound HTTPS to pull
  images and Python packages.
- **In-cluster.** Annotation servers talk to the broker over the
  in-cluster Service address, never through the public hostname.

Path-based routing on one hostname: the broker API is served at `/`,
annotation previews at `/embed/`, media at `/media/`, annotation servers at
`/tasks/<id>/` and long-running service recipes at `/services/<id>/`. No
wildcard DNS record or wildcard certificate is required.

## What the Helm release installs

All objects are created in the release namespace unless marked
cluster-scoped. Names below assume the release is called `ellf`.

| Object | Name | Purpose |
|---|---|---|
| Deployment | `ellf-broker` | Two containers: `api` (the broker) and `cpl` (the sidecar). One replica, `Recreate` strategy. Mounts the RWX volume at `/mnt/nfs`. |
| Service | `ellf-broker` | ClusterIP, port 8080. |
| Ingress | `ellf-broker` | Host = cluster FQDN, path `/`. |
| Deployment | `ellf-preview` | nginx serving the annotation preview bundle and, when media is enabled, media files from the RWX volume (read-only). Runs as uid 101. |
| Service, Ingress | `ellf-preview` | Paths `/embed` and, when media is enabled, `/media`. |
| ConfigMap | `ellf-env` | All non-secret `ELLF_*` environment variables. |
| ConfigMap | `ellf-config-files` | Optional broker and sidecar config files. |
| ConfigMap | `ellf-worker-types` | The worker-type list users pick from (from `workerTypes` in values). |
| Secret | `ellf-credentials` | Registry pull credential, Prodigy licence key, optional media signing key. Rendered from values. |
| ServiceAccount | `ellf` | Used by the broker, the preview pod and every job pod the broker launches. |
| Role, RoleBinding | `ellf` | Namespaced permissions listed below. |
| ClusterRole, ClusterRoleBinding | `ellf` | **Cluster-scoped.** `get` and `list` on `nodes`, for capacity reporting. |
| NetworkPolicy | `ellf-broker` | Restricts the broker pod's ingress to port 8080 and egress to DNS, PostgreSQL, HTTPS (443 and 6443), job pods on port 80, and Loki. Only applies if your CNI enforces NetworkPolicy. Can be disabled with `networkPolicy: false`. |

Optional objects, enabled by values:

| Object | Enabled by | Purpose |
|---|---|---|
| ClusterIssuer (cluster-scoped), Certificate | `certManager` | Let's Encrypt certificate for the cluster FQDN via HTTP-01. |
| CronJob `ellf-media-gc` | `mediaGc.enabled` and `secrets.mediaSigningKey` | Weekly garbage collection of unreferenced media files. |
| StatefulSet `ellf-loki`, DaemonSet `ellf-vector`, plus ClusterRole and ClusterRoleBinding `ellf-vector` (cluster-scoped) | `logging` | In-cluster log shipping. `logging.lokiExternalUrl` points the broker at an existing Loki instead. |
| PostgreSQL StatefulSet (Bitnami subchart) | `postgresql.enabled` | Bundled database for evaluation only. |
| PersistentVolume and PersistentVolumeClaim | `storage.type: hostPath` | Single-node clusters only. |
| Namespace | `namespace.create` | Off by default; create the namespace yourself. |

The namespaced Role grants the broker's service account:

| API group | Resources | Verbs |
|---|---|---|
| core | configmaps | create, get, list, patch |
| core | secrets | create, get, list, patch, delete |
| core | pods | get, list, watch |
| core | pods/log | get |
| core | services | create, get, list, watch, patch, delete |
| apps | deployments | create, get, list, watch, patch, delete |
| batch | jobs | create, get, list, watch, patch, delete |
| batch | cronjobs | get, list, watch, patch |
| networking.k8s.io | ingresses | create, get, list, watch, patch, delete |
| traefik.io | middlewares | create, get, list, patch |

Objects the broker creates at runtime, all in the release namespace and
labelled `app.kubernetes.io/managed-by=ellf-broker`:

- A **Job**, **Service** and **Ingress** per annotation server, batch job,
  agent or service recipe. Pods run under the `ellf` service account, mount
  the RWX volume at `/mnt/nfs`, carry a `nodeSelector` of
  `ellf/node-class=<class>` from the chosen worker type, and get an
  `nvidia.com/gpu` request plus toleration when the worker type has a GPU.
- **Secrets** for user-managed secrets (prefixed `ellf-`), injected into
  job pods as environment variables.
- **ConfigMaps** recording environment requirements.
- Short-lived **Jobs** that assemble custom recipe images, running the
  broker's own image.
- Three Traefik **Middleware** objects (`ellf-forward-auth`,
  `ellf-forward-auth-session`, `ellf-strip-service-prefix`) created the first
  time a service recipe is launched.

## Requirements

### 1. Kubernetes cluster

- Kubernetes **1.30 or newer**. Explosion's own clusters run 1.34 on EKS
  and the GKE and AKS release-channel defaults. k3s works for single-node
  installs.
- The installer needs permission to create the namespaced objects above,
  plus one ClusterRole and ClusterRoleBinding. If cert-manager or logging
  is enabled, a ClusterIssuer and one more ClusterRole and binding.
- The container runtime must be able to pull from the upstream registry
  using an image pull secret (see [Credentials](#credentials-from-explosion)).
- The default pod security settings in the chart are strict:
  `seccompProfile: RuntimeDefault`, `readOnlyRootFilesystem: true`,
  `allowPrivilegeEscalation: false`, all capabilities dropped. They are
  compatible with the `restricted` Pod Security Standard for the broker
  and preview pods. Job pods launched by the broker do not set a security
  context, so a namespace enforcing `restricted` will reject them; use
  `baseline` or `privileged` on the Ellf namespace.

### 2. Node pools and labels

Ellf separates platform pods from user workloads with labels and taints.

**System pool.** The broker, preview pod, media GC and the Helm test pods
schedule with:

```yaml
nodeSelector:
  ellf/role: system
tolerations:
  - key: ellf/role
    operator: Equal
    value: system
    effect: NoSchedule
```

Create a node pool with label `ellf/role=system` and taint
`ellf/role=system:NoSchedule`, or change `broker.nodeSelector`,
`broker.tolerations`, `preview.nodeSelector` and `preview.tolerations` to
match your own scheme. The taint keeps user jobs off the platform nodes;
the label keeps platform pods together. Traefik and cert-manager should
also tolerate this taint if they are to run on the same pool. Sizing: the
broker requests 500m CPU and 256 Mi, the sidecar 250m and 128 Mi, the
preview pod 50m and 32 Mi. One 2 vCPU, 4 GB node is sufficient; two give
you rolling node upgrades.

**Worker pools.** Every job a user launches resolves to a *worker type*.
Worker types are declared in values and each maps to a `node_class`:

```yaml
workerTypes:
  - name: base
    node_class: base
    description: Standard worker
    per_job: { cores: 1, memory_mb: 1024, memory_max_mb: 2048 }
  - name: gpu-a10
    node_class: gpu
    description: 1x A10 node pool
    per_job: { cores: 4, memory_mb: 16384, memory_max_mb: 32768, gpu: 1 }
```

The broker applies `nodeSelector: {ellf/node-class: <node_class>}` to jobs
of that type. Label each worker pool `ellf/node-class=<class>` (and
`ellf/worker=true` by convention). A job whose class matches no node stays
Pending with a node-affinity error. `per_job` is the default resource
request and limit; `memory_max_mb` is the limit, `memory_mb` the request,
`cores` the CPU request.

**GPU pools.** Taint GPU nodes `nvidia.com/gpu=present:NoSchedule`. Jobs
with `per_job.gpu` automatically get the matching toleration and an
`nvidia.com/gpu` request. The NVIDIA device plugin (and drivers) must be
installed; GKE, EKS and AKS GPU pools do this for you. On k3s or bare
metal, set `runtime_class: nvidia` on the worker type so the pod runs under
the NVIDIA RuntimeClass.

Autoscaling worker pools from zero is fine. Jobs wait for a node.

`defaultWorkerType` names the worker type used when a job does not pick
one. Leave it empty to run such jobs BestEffort with no node affinity.

### 3. Ingress (Traefik)

Ellf requires **Traefik v3** as the ingress controller, with:

- the Kubernetes Ingress provider enabled (`providers.kubernetesIngress.enabled=true`),
- the Traefik CRDs installed (the broker creates `traefik.io/v1alpha1`
  Middleware objects),
- entry points on ports 80 and 443,
- an ingress class named `traefik` (or set `ingress.className`).

Why Traefik specifically: service recipes (long-running HTTP services such
as MCP servers) are protected by a Traefik ForwardAuth middleware that
calls back into the broker for every request, and the preview and media
paths rely on longest-prefix routing on the same host. Annotation servers
and batch jobs would work behind another controller, but service recipes
would be exposed without authentication, so other controllers are not
supported.

Traefik must be reachable from users at a stable address: a cloud
LoadBalancer, an existing edge proxy or firewall forwarding to Traefik's
NodePorts, or an internal load balancer if all users are on the corporate
network. Explosion's tooling installs Traefik with the values in
[`examples/traefik-values.yaml`](../examples/traefik-values.yaml):

```bash
helm repo add traefik https://traefik.github.io/charts
helm upgrade --install traefik traefik/traefik -n traefik --create-namespace \
  -f examples/traefik-values.yaml
```

If you already run Traefik v3 for other workloads, reuse it and set
`ingress.className` to its ingress class. Ellf's Ingress objects use only
standard `networking.k8s.io/v1` fields plus the
`traefik.ingress.kubernetes.io/router.middlewares` annotation.

Annotation sessions use Server-Sent Events and long-lived HTTP requests.
Any proxy in front of Traefik must allow response streaming and idle
connections of at least a few minutes.

### 4. DNS and TLS

**DNS.** Create an A record (or CNAME to an ELB) for the cluster hostname,
for example `ellf.example.com`, pointing at the Traefik entry point. This
hostname is `cluster.fqdn` in values. It must resolve for every user and
for the operator workstation. It does not need to resolve from inside the
cluster and does not need to be reachable by PAM. No wildcard record.

The hostname is also the cluster's identity in PAM (the cluster record's
address), so choose it before registering the cluster and avoid renaming it
later.

**TLS.** Users' browsers and the `ellf` CLI must trust the certificate.
Two supported options:

1. **cert-manager with Let's Encrypt (HTTP-01).** Requires the hostname
   to be reachable from the public internet on port 80. Install
   cert-manager (values in
   [`examples/cert-manager-values.yaml`](../examples/cert-manager-values.yaml)),
   then set in values:

   ```yaml
   ingress:
     tls:
       secretName: ellf-tls
   certManager:
     clusterIssuerName: ellf-letsencrypt   # any name; the chart creates it
     acmeEmail: ops@example.com
   ```

   The chart creates the ClusterIssuer and a Certificate for the FQDN.

2. **Your own certificate.** Issue a certificate for the hostname from
   your PKI or a commercial CA, store it as a `kubernetes.io/tls` Secret in
   the Ellf namespace, and reference it:

   ```yaml
   ingress:
     tls:
       secretName: ellf-tls
   certManager: null
   ```

   If it is signed by a private CA, that CA must be in the trust store of
   every user's workstation (browser and Python `certifi`, which the CLI
   uses). Renewal is your responsibility; Traefik picks up updated Secrets
   automatically.

Plain HTTP (`cluster.scheme: http`) is only for loopback development
clusters and is not supported for shared use.

### 5. PostgreSQL

The broker stores job metadata, environments and annotation bookkeeping in
PostgreSQL. Annotation data itself lives on the shared volume.

- PostgreSQL **14 or newer** (16 recommended).
- One database and one user that owns it. The broker creates and extends
  its own tables at startup, so the user needs `CREATE` on the database.
- Reachable from the cluster's pod network on port 5432. TLS to the
  database is not required by the broker; enable it at the server if your
  policy requires it (the broker's psycopg2 connection honours `sslmode`
  defaults, `prefer`).
- Connection pool: the broker opens up to 30 connections (pool 20,
  overflow 10). Size `max_connections` accordingly.
- Sizing: small. A 2 vCPU, 4 GB instance with 20 GB storage is typical.
- Backups are your responsibility.

In values:

```yaml
database:
  ip: 10.20.30.40            # IP or DNS name
  user: ellf
  name: ellf
  egressCidr: 10.20.30.0/24  # required when ip is a DNS name (NetworkPolicy)
```

The password goes into the `ellf-infra` Secret (see
[Secrets](#secrets-you-must-create)), never into values.

For evaluation only, `postgresql.enabled: true` deploys the Bitnami
PostgreSQL subchart inside the release with the credentials under
`postgresql.auth`. It needs a default StorageClass with dynamic
provisioning. Do not use it for a shared cluster.

### 6. Shared storage

The broker, the preview pod and every job pod mount one
**ReadWriteMany** PersistentVolumeClaim at `/mnt/nfs`. It holds uploaded
data, datasets, build caches, media files and job scratch space.

- Create a PVC named `prodigy-nfs` (or set `nfs.claimName`) in the Ellf
  namespace with `accessModes: [ReadWriteMany]`.
- Any RWX backend works: an NFS server, AWS EFS (via the EFS CSI driver),
  GCP Filestore, Azure Files (NFS or SMB), CephFS, Longhorn RWX, and so on.
- Capacity: 100 GB minimum; Explosion's Terraform defaults to 1 TB.
  Growth is driven by the datasets and model artifacts users store.
- POSIX semantics are needed (file locking is not). Job pods run as the
  image's default user (root in the built-in recipe images), and the
  preview pod reads the volume as uid 101, so the export or share must
  allow those uids to read and write. On NFS, `no_root_squash` or a
  mapped anonymous uid with write access to the export root.
- Explosion's Terraform creates a static PersistentVolume with
  `reclaimPolicy: Retain` bound to the PVC by `volumeName`. See
  [`examples/nfs-static-pv.yaml`](../examples/nfs-static-pv.yaml) for the
  equivalent against a generic NFS server.

The Helm test `test-nfs-mount` writes and reads a canary file through
the claim from a system-pool node; run it before the first deploy.

### 7. Network access

Outbound (from the pod network, HTTPS unless noted):

| Destination | Used by | Purpose |
|---|---|---|
| PAM (`cluster.pamFqdn`, currently `app.ellf.ai` for production) | broker, sidecar, job pods | Cluster registration, settings, user and project metadata, token exchange. |
| Upstream registry host (from `cluster-creds.json`, currently `europe-west1-docker.pkg.dev`) | kubelets, broker, sidecar | Pulling broker, sidecar, preview and recipe images; listing tags for update checks (every 5 minutes). |
| `oauth2.googleapis.com` | broker, sidecar, kubelets | Exchanging the registry service-account key for access tokens. |
| `pypi.org`, `files.pythonhosted.org` | broker, job pods | Installing Python dependencies of custom environments. |
| Prodigy package index (`prodigyPypiIndexUrl`, the value Explosion gives you, for example `download.prodi.gy`) | broker, job pods | Installing Prodigy into custom environments. Not needed when the value is empty. |
| `acme-v02.api.letsencrypt.org` | cert-manager | Only when using Let's Encrypt. |
| Your writable registry | broker | Only when custom recipe publishing is enabled. |
| Model and dataset hubs (for example `huggingface.co`) | job pods | Only if users' recipes download models. Optional. |
| Kubernetes API (port 443 or 6443) | broker, sidecar | Managing jobs. |

Inbound:

| Source | Destination | Purpose |
|---|---|---|
| Users (browsers, CLI, coding assistants) | Traefik, ports 80 and 443 | Everything. Port 80 is only needed for HTTP-01 challenges and redirects. |

PAM does **not** initiate connections to the cluster. If your policy
requires it, the cluster hostname can be reachable only from the corporate
network, in which case Let's Encrypt HTTP-01 is not possible and you must
bring your own certificate.

Inside the cluster, the chart's NetworkPolicy limits the **broker pod's**
egress to DNS, the database (CIDR from `database.egressCidr` or
`database.ip/32`), ports 443 and 6443 anywhere, port 80 to job pods, and
port 3100 to Loki. Job pods are not covered by a policy. If your CNI does
not enforce NetworkPolicy the object is inert; if you enforce a default-deny
policy in the namespace, allow the flows above for job pods too.

**Proxies.** The broker, sidecar and job pods use standard Python HTTP
clients that honour `HTTPS_PROXY` and `NO_PROXY`, but the chart has no
setting to inject them. If all egress must go through a proxy, tell your
Explosion contact before installing so the chart can carry the variables.

**Mirroring images.** If nodes may not pull from external registries,
mirror these repositories from the upstream registry into an internal
registry and set `registries.upstream` to the mirror:

```
broker, cpl, embed, recipes, recipes_pdf, recipes_gpu
```

Mirror every tag Explosion tells you to target (the `embed` image is
tagged with the broker version). The sidecar lists tags on the upstream
registry to discover new recipe versions, so the mirror must support the
OCI tag-list API and be refreshed when Explosion ships new versions. The
image pull secret is then for your mirror, not Explosion's registry, and
`secrets.containerSaKey` is still required by the chart but only used for
the Prodigy package index when that index is on Artifact Registry.

### 8. Writable registry (optional)

Users can *publish* custom recipes: the broker assembles a container image
from the user's code and pushes it to a registry, then launches jobs from
it. The broker does this in-process with the OCI distribution API (no
Docker daemon, kaniko or BuildKit is needed), but it authenticates to the
push target with the **cluster's ambient identity only**:

| Registry | How the broker authenticates | Setup |
|---|---|---|
| GCP Artifact Registry | Workload Identity | Annotate the `ellf` service account with `iam.gke.io/gcp-service-account` (via `serviceAccount.annotations`) and grant that GCP service account `roles/artifactregistry.writer` on the repository. |
| AWS ECR | Node instance role or IRSA | Grant the node role or an IRSA role bound to the `ellf` service account push rights on the repositories. The broker creates ECR repositories on demand, so include `ecr:CreateRepository`. |
| A registry that accepts unauthenticated pushes from the pod network | None | Internal registries only. |

Other registries (Harbor, Nexus, GitHub Container Registry, Docker Hub,
Azure Container Registry with credentials) are **not supported as a push
target today** because the broker has no setting for static push
credentials. If you need one of these, tell your Explosion contact; it is a
broker change, not an infrastructure one.

If custom publishing is not needed, leave `registries.user` empty. Built-in
recipes and custom Python environments (installed at job start from PyPI)
still work; only `ellf publish` of container images is refused.

`registries.user` must be different from `registries.upstream`. Both are
listed in `ELLF_TRUSTED_REGISTRIES`, and the broker refuses to launch images
from any other registry.

### 9. Operator tooling

On the workstation that performs the install:

- `kubectl` with cluster-admin (or the permissions listed above) on the
  target cluster.
- `helm` 3.8 or newer (OCI support). Helm 4 works; Explosion uses 4.x.
  With Helm 4, upgrades of a cluster the sidecar has auto-updated need
  `--force-conflicts` because the sidecar patches the Deployment under a
  different field manager.
- Optionally the `ellf` CLI (`pip install ellf-cli`), logged in to PAM as a
  user with admin rights on the organisation. It automates registration,
  keypair creation and the Helm install (`ellf infra register`, `setup`,
  `init-values`, `deploy`), and `ellf clusters check` verifies the result.
  Everything it does is also described here as plain `kubectl` and `helm`
  steps.
- Network access to both the Kubernetes API and PAM.

## Credentials from Explosion

The cluster must exist as a record in PAM before the broker can start.
Registering it yields a `cluster-creds.json` file:

```json
{
  "cluster_id": "1b2c3d4e-....",
  "upstream_registry": "europe-west1-docker.pkg.dev/ellf-prod-pam/pam-external",
  "container_sa_key": "<base64 of a GCP service-account JSON key>",
  "prodigy_license_key": "....",
  "target_broker_version": "0.1.42",
  "target_cpl_version": "0.1.42"
}
```

Obtain it either by running, as an organisation admin,

```bash
ellf login
ellf infra register --name <cluster name> --cloud-provider k3s \
  --domain https://ellf.example.com
```

(`k3s` here means "not one of the Terraform-managed cloud flows"; it only
affects the placeholder values the CLI writes), or by asking your Explosion
contact to register the cluster and send the file. Treat the file as a
secret: the service-account key grants read access to Explosion's release
registry and the licence key is per customer.

What each field is for:

| Field | Used as |
|---|---|
| `cluster_id` | `cluster.clusterId`. The broker's identity (`ELLF_BROKER_ID`) and the audience of every token PAM issues for this cluster. |
| `upstream_registry` | `registries.upstream`, and the registry host of the image pull secret. |
| `container_sa_key` | `secrets.containerSaKey`, the image pull secret, and `helm registry login`. |
| `prodigy_license_key` | `secrets.prodigyLicenseKey`. |
| `target_broker_version`, `target_cpl_version` | `image.brokerVersion` and `image.cplVersion` on the **first** install only. See [operations.md](operations.md). |

The cluster record's **public key** must also be set in PAM before users
can open annotation servers. That key is generated in the next section and
registered in step 9 of the installation.

## Secrets you must create

Two Secrets exist before the chart is installed. A third is rendered by the
chart from values.

### `ellf-infra` (Opaque)

Holds the database password and the cluster's RSA signing keypair. The
broker signs the tokens it issues to users and job pods with the private
key; PAM verifies them with the public key registered on the cluster
record.

| Key | Value |
|---|---|
| `ELLF_DATABASE_PASSWORD` | The PostgreSQL password, plain. |
| `ELLF_PRIVATE_KEY` | **Base64 of** an RSA 2048 private key in PKCS#8 PEM, unencrypted. |
| `ELLF_PUBLIC_KEY` | **Base64 of** the matching public key in SubjectPublicKeyInfo PEM. |

The key values are base64 of the PEM text (not the raw PEM), because they
are consumed as environment variables. Kubernetes then base64-encodes them
again in `.data`, which is expected.
[`examples/create-infra-secret.sh`](../examples/create-infra-secret.sh)
generates the keypair with `openssl`, writes the Secret, and leaves
`ellf-public-key.pem` on disk for registration with PAM. Keep the private
key only in the Secret. Rotating it invalidates every outstanding token and
requires re-registering the public key.

If you manage secrets with External Secrets Operator or Sealed Secrets,
produce the same Secret by those means and set `secrets.rolloutChecksum` to
any changing string on rotation to force a pod restart.

### `explosion-registry` (kubernetes.io/dockerconfigjson)

Lets kubelets pull from the upstream registry. Username `_json_key`,
password the **decoded** service-account JSON, for the registry's host:

```bash
kubectl -n ellf create secret docker-registry explosion-registry \
  --docker-server=europe-west1-docker.pkg.dev \
  --docker-username=_json_key \
  --docker-password="$(jq -r .container_sa_key cluster-creds.json | base64 -d)"
```

[`examples/create-image-pull-secret.sh`](../examples/create-image-pull-secret.sh)
does this from `cluster-creds.json`. Reference it in values under
`imagePullSecrets`. It is attached both to the pods the chart creates and to
the `ellf` ServiceAccount, so job pods inherit it.

If you mirror images to an internal registry, this secret is for that
registry instead (or is unnecessary if the mirror is unauthenticated from
the nodes).

### `ellf-credentials` (rendered by the chart)

Built from `secrets.containerSaKey`, `secrets.prodigyLicenseKey` and
optionally `secrets.mediaSigningKey`. The chart requires the first two to
be set in values, so keep the values file that carries them out of version
control or split secrets into a second `-f` file with restricted access.

`mediaSigningKey` is any random string of 32 or more characters. Setting it
enables the media server: recipes that show images, audio or PDFs serve
them from the shared volume through the preview pod with signed URLs
instead of inlining them as base64. Recommended.

## Helm values reference

`chart/values.yaml` documents every key. The keys that matter for an
existing-cluster install:

| Key | Required | Meaning |
|---|---|---|
| `registries.upstream` | yes | Upstream registry from `cluster-creds.json`, or your mirror. |
| `registries.user` | no | Writable registry for custom recipe images. Empty disables publishing. |
| `image.brokerVersion`, `image.cplVersion` | first install | Image tags. Leave empty on later upgrades; the chart reads the live Deployment. |
| `image.pullPolicy` | no | `Always` by default. `IfNotPresent` is fine with immutable tags. |
| `imagePullSecrets` | yes | `[{name: explosion-registry}]`. |
| `serviceAccount.annotations` | no | Workload Identity or IRSA annotations. |
| `broker.nodeSelector`, `broker.tolerations`, `preview.nodeSelector`, `preview.tolerations` | no | Change if your system pool uses different labels. |
| `broker.resources`, `preview.resources` | no | Requests and limits. |
| `cluster.clusterId` | yes | From `cluster-creds.json`. |
| `cluster.fqdn` | yes | Bare hostname, optionally `host:port`. No scheme. |
| `cluster.scheme` | no | `https` (default). |
| `cluster.pamFqdn` | yes | PAM hostname, for example `pam.ellf.ai`. Your contact confirms it. |
| `ingress.className` | yes | `traefik`. |
| `ingress.tls.secretName` | yes for TLS | Name of the TLS Secret (yours or cert-manager's). |
| `certManager` | no | `{clusterIssuerName, acmeEmail}` to use Let's Encrypt; `null` otherwise. |
| `database.ip`, `database.user`, `database.name` | yes | External PostgreSQL. |
| `database.egressCidr` | when `ip` is a hostname | CIDR for the NetworkPolicy. |
| `nfs.claimName` | yes | RWX PVC name, default `prodigy-nfs`. |
| `storage.type` | no | Leave empty to use the existing claim. |
| `workerTypes`, `defaultWorkerType` | yes | Worker pool mapping, see [Node pools](#2-node-pools-and-labels). |
| `prodigyPypiIndexUrl` | no | Prodigy package index if not `download.prodi.gy`. |
| `secrets.infraSecretName` | yes | `ellf-infra`. |
| `secrets.containerSaKey`, `secrets.prodigyLicenseKey` | yes | From `cluster-creds.json`. |
| `secrets.mediaSigningKey` | recommended | Enables the media server. |
| `secrets.rolloutChecksum` | no | Change to force a restart after rotating `ellf-infra`. |
| `mediaGc` | no | Enable after a manual dry run. |
| `networkPolicy` | no | `true` by default. |
| `logging` | no | In-cluster Loki and Vector, or `lokiExternalUrl`. |
| `postgresql.enabled` | no | Bundled database, evaluation only. |
| `gcp`, `costViewTable` | no | GCP-only cost reporting. Leave empty. |
| `local`, `development` | no | Development flags. Leave `null`. |

A complete example is in
[`examples/values-existing-cluster.yaml`](../examples/values-existing-cluster.yaml).

## Step-by-step installation

The steps assume namespace `ellf`, release name `ellf` and the files in
`examples/`. Adjust names as needed.

1. **Register the cluster** and obtain `cluster-creds.json` (see
   [Credentials](#credentials-from-explosion)). Decide the hostname first.

2. **Create the namespace.**

   ```bash
   kubectl create namespace ellf
   ```

3. **Label and taint nodes.** For managed node pools, set labels and
   taints on the pool so new nodes inherit them. For existing nodes:

   ```bash
   kubectl label node <system-node> ellf/role=system
   kubectl taint node <system-node> ellf/role=system:NoSchedule
   kubectl label node <worker-node> ellf/node-class=base ellf/worker=true
   ```

4. **Install Traefik** (skip if a suitable Traefik v3 already exists) and,
   if using Let's Encrypt, **cert-manager**:

   ```bash
   helm repo add traefik https://traefik.github.io/charts
   helm upgrade --install traefik traefik/traefik -n traefik --create-namespace \
     -f examples/traefik-values.yaml

   helm repo add jetstack https://charts.jetstack.io
   helm upgrade --install cert-manager jetstack/cert-manager -n cert-manager \
     --create-namespace -f examples/cert-manager-values.yaml
   ```

   Point the DNS record at Traefik's external address:

   ```bash
   kubectl get svc -n traefik traefik -o jsonpath='{.status.loadBalancer.ingress[0]}'
   ```

5. **Provide the RWX volume.** Create the `prodigy-nfs` PVC in the `ellf`
   namespace, for example from `examples/nfs-static-pv.yaml` for a plain
   NFS server, or via your CSI driver's StorageClass. Confirm it is
   `Bound`.

6. **Provide PostgreSQL.** Create the database and user; confirm a pod in
   the cluster can reach port 5432.

7. **Create the Secrets.**

   ```bash
   examples/create-infra-secret.sh ellf '<database password>'
   examples/create-image-pull-secret.sh ellf cluster-creds.json
   ```

   If bringing your own certificate:

   ```bash
   kubectl -n ellf create secret tls ellf-tls --cert=fullchain.pem --key=privkey.pem
   ```

8. **Write `values.yaml`** from `examples/values-existing-cluster.yaml`,
   filling in the values from `cluster-creds.json`. On the first install,
   set `image.brokerVersion` and `image.cplVersion` to the target versions
   in the credentials file. Then install:

   ```bash
   helm dependency build chart
   helm upgrade --install ellf ./chart -n ellf -f values.yaml --wait --timeout 10m
   ```

   Or from Explosion's registry (same chart):

   ```bash
   jq -r .container_sa_key cluster-creds.json | base64 -d | \
     helm registry login europe-west1-docker.pkg.dev -u _json_key --password-stdin
   helm upgrade --install ellf oci://europe-west1-docker.pkg.dev/ellf-prod-pam/pam-external/ellf \
     -n ellf -f values.yaml --wait --timeout 10m
   ```

   The chart validates values before creating anything and fails with a
   message naming the missing key.

9. **Register the public key with PAM.** Send `ellf-public-key.pem` (from
   step 7) to your Explosion contact, or if you have the CLI:

   ```bash
   ellf infra deploy --values values.yaml --chart ./chart --wait
   ```

   `ellf infra deploy` is idempotent: it reuses the existing `ellf-infra`
   Secret and image pull secret, fetches the target versions from PAM,
   runs the same Helm upgrade, updates the cluster record with the public
   key, and labels nodes for any worker type still missing one.

   Until the public key is registered, users can list the cluster but
   opening an annotation server fails with a token verification error.

10. **Verify** (next section) and hand the cluster hostname to your users.

## Verification

Helm tests exercise the four infrastructure dependencies from a
system-pool node:

```bash
helm test ellf -n ellf --logs
```

- `test-registry-pull`: pulls the broker image with the pull secret.
- `test-nfs-mount`: writes and reads through the RWX claim.
- `test-node-scheduling`: a pod can land on the system pool.
- `test-db-connectivity`: TCP connect to PostgreSQL on 5432.

Then:

```bash
kubectl -n ellf get pods                      # ellf-broker and ellf-preview Running, 2/2 and 1/1
kubectl -n ellf logs deploy/ellf-broker -c api | tail
kubectl -n ellf logs deploy/ellf-broker -c cpl | tail
curl -s https://ellf.example.com/api/v1/status
curl -s https://ellf.example.com/api/v1/version
```

The sidecar log should show it polling PAM cluster settings and scanning
the upstream registry. `ellf clusters check` from a workstation runs an
end-to-end check through PAM, and launching a built-in recipe confirms
scheduling onto a worker pool, the shared volume and ingress routing.

## Security notes

- The broker's service account is limited to its namespace except for
  read-only node access. It can create Secrets and Jobs in that namespace,
  so treat the namespace as belonging to the broker; do not co-locate other
  workloads in it.
- Job pods run under the same `ellf` service account with
  `automountServiceAccountToken` unchanged. Set
  `automountServiceAccountToken: false` in values if job pods must not see a
  token; the broker itself uses in-cluster config and needs the token, so
  this is only appropriate when you also give the broker a dedicated
  service account, which the chart does not yet support.
- User authentication is handled by PAM (Explosion's identity provider or
  your OIDC provider federated through PAM). The cluster only checks
  signatures and audiences. Cluster-level access is granted per user in
  PAM.
- The registry service-account key and the licence key live in the
  `ellf-credentials` Secret and in your values file. Restrict both.
- All user traffic is HTTPS at Traefik; in-cluster traffic between the
  broker and job pods is plain HTTP on the pod network.

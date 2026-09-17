# ellf-helm-cluster

The Helm chart that deploys an [Ellf](https://ellf.ai) cluster (the *broker*
data plane) onto a Kubernetes cluster, plus a specification of everything
else an infrastructure team must provide or do to run that cluster inside an
existing infrastructure stack, without Explosion's Terraform.

This is the companion to
[`explosion/ellf-terraform-cluster`](https://github.com/explosion/ellf-terraform-cluster),
which provisions the same prerequisites automatically on GCP, AWS or Azure.
If you already run Kubernetes, a database, shared storage and an ingress
edge, this repository tells you how to map those onto what Ellf needs.

## How Ellf is shaped

Ellf has two planes:

- **Management plane (PAM).** Hosted and operated by Explosion. Holds
  organisations, users, projects and cluster records, and issues the tokens
  that authorise users onto a cluster. You do not install anything for it.
- **Cluster (data plane).** Runs in *your* Kubernetes. One `broker` pod
  (API plus a sidecar that syncs with PAM) launches annotation servers,
  batch jobs and agents as Kubernetes Jobs, stores data on a shared volume
  and in your PostgreSQL, and serves everything behind your ingress. Your
  data never leaves your cluster; only metadata and control traffic go to
  PAM.

Everything in this repository concerns the cluster.

## Repository layout

```
chart/                  The Ellf Helm chart (name: ellf), identical to the one
                        Explosion publishes to its OCI registry
docs/checklist.md       One-page list of what the infra team must provide
docs/installation.md    Full installation specification and step-by-step guide
docs/operations.md      Upgrades, version management, GitOps notes, troubleshooting
examples/               Example values files, secret templates and helper scripts
```

## Where to start

1. Send `docs/checklist.md` to the infrastructure team. It lists every
   external dependency and every decision they need to make.
2. Work through `docs/installation.md` together. It explains each
   requirement, why Ellf has it, and gives the exact objects to create.
3. Use `examples/values-existing-cluster.yaml` as the starting point for
   the cluster's Helm values.

## Installing the chart

The chart in `chart/` can be installed straight from this repository:

```bash
helm dependency build chart
helm upgrade --install ellf ./chart -n ellf -f values.yaml
```

Explosion also publishes the same chart to its OCI registry, and the `ellf`
CLI's `ellf infra deploy` installs it from there. Both routes produce the
same release. See `docs/installation.md` for the values that must be set
and the objects that must exist first.

## Support

Contact your Explosion point of contact for cluster credentials (registry
access, licence key, cluster ID) and for registering the cluster's public
key with PAM. Both are described in the installation guide.

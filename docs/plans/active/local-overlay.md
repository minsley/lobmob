---
status: active
tags: [infrastructure, development, kubernetes, local]
maturity: implementation
created: 2026-02-23
updated: 2026-02-24
---
# Local Overlay

## Summary

Add a `k8s/overlays/local/` Kustomize overlay so lobmob can run locally using k3d (k3s in Docker containers) with multi-node topology matching the cloud deployment. Goal is dev/prod parity for the agent swarm — lobster Jobs, lobwife state, lobboss coordination — all running identically locally, with DOKS being the scaled mirror. Local images are built natively (arm64) and imported directly into k3d; multi-arch builds are deferred to the CI/CD plan.

## Open Questions

- [x] **Local k8s runtime**: k3d — k3s nodes in Docker containers. Multi-node, labeled to match `lobmob.io/role: <x>`, base manifests apply unchanged. No nodeSelector patches needed.
- [x] **Image architecture**: `:local` tag + `k3d image import`. Build natively (arm64, no `--platform` flag), import into k3d, patch `imagePullPolicy: IfNotPresent`. Multi-arch deferred to CI/CD plan.
- [x] **Local registry**: None needed. `k3d image import` loads directly into k3d's internal containerd.
- [x] **Vault repo**: Reuse lobmob-vault-dev. Acceptable noise in dev vault.
- [x] **nodeSelector removal**: Not needed — k3d nodes labeled at cluster creation to match `lobmob.io/role: <x>`. Base manifests unchanged.
- [x] **Secrets**: `secrets-local.env` (gitignored), same structure as dev. Reuse dev Discord bot, new `#lobmob-local` channel — patch `TASK_QUEUE_CHANNEL_ID` in local overlay.
- [x] **GitHub App tokens**: Same GH App, credentials in `secrets-local.env`. Token broker works unchanged.

## Approach

### What changes vs dev overlay

| Concern | Dev (DOKS) | Local (k3d) |
|---|---|---|
| Image pull | GHCR + `imagePullSecrets` | `k3d image import`, `imagePullPolicy: IfNotPresent`, no pull secrets |
| Image arch | amd64 | arm64 (native Mac build, `:local` tag) |
| Node selectors | `lobmob.io/role: lobboss` etc. | Unchanged — k3d nodes labeled to match |
| Storage class | DO block storage | `local-path` (k3d default) |
| Resource limits | Tuned for DOKS node sizes | Relaxed |
| Vault repo | lobmob-vault-dev | lobmob-vault-dev (same) |
| Discord channel | `#lobmob-dev` | `#lobmob-local` |
| Secrets | secrets-dev.env | secrets-local.env |
| LOBMOB_ENV | dev | local |

### Phases

#### Phase 1: k3d cluster setup script — **DONE**
- `lobmob --env local cluster-create`: creates k3d cluster, labels nodes with `lobmob.io/role: <x>`
- Node layout: server-0 (control plane), agent-0 (lobwife), agent-1 (lobboss), agent-2 (lobsigliere), agent-3 (lobsters)
- Sets kubectl context to `k3d-lobmob-local`
- `lobmob --env local cluster-delete`: tears down cluster

#### Phase 2: Kustomize overlay — **DONE**
- `k8s/overlays/local/kustomization.yaml` added
- imagePullPolicy: IfNotPresent on all Deployments
- imagePullSecrets removed from all Deployments
- LOBMOB_ENV=local, LOBSTER_IMAGE=:local, TASK_QUEUE_CHANNEL_ID placeholder in ConfigMap
- storageClassName: local-path for vault-pvc
- Relaxed resource requests/limits
- Note: mcp_tools.py also patched to be LOBMOB_ENV-aware for dynamic job spawning

#### Phase 3: Local build + import command — **DONE**
- `lobmob --env local build [component]`: native build (arm64), `:local` tag, `k3d image import`
- `secrets-local.env` already covered by `secrets-*.env` glob in .gitignore

#### Phase 4: CLI integration — **DONE**
- `local` env added to `scripts/lobmob` (secrets-local.env, no TFVARS)
- apply, connect, status, logs, restart updated for `k3d-lobmob-local` context
- cluster-create, cluster-delete registered; attach registered (from multi-turn plan)

## Decisions Log

| Date | Decision | Rationale |
|------|----------|-----------|
| 2026-02-23 | k3d over Docker Desktop k8s | Multi-node support needed to replicate node pool separation. k3d is k3s in Docker — identical manifest behavior, lighter than Lima VMs |
| 2026-02-23 | k3d over bare k3s | k3d manages cluster lifecycle via CLI (`cluster create/delete`), auto-injects kubeconfig, image import built in. Behavior identical to bare k3s |
| 2026-02-23 | `:local` tag + k3d image import | Low friction for local iteration. No registry, no push/pull cycle. Multi-arch (for cloud parity) deferred to CI/CD plan |
| 2026-02-23 | Reuse lobmob-vault-dev | No extra repo to maintain. Some dev vault noise is acceptable |
| 2026-02-23 | Reuse dev Discord bot, new #lobmob-local channel | Avoids double-responses if local + dev run simultaneously. Same pattern as #lobmob / #lobmob-dev |
| 2026-02-23 | No nodeSelector patches in local overlay | k3d nodes labeled at cluster creation to match `lobmob.io/role: <x>`. Base manifests apply unchanged — better parity than patching selectors out |

## Research Notes

### k8s runtime options considered

**Docker Desktop k8s**
- One checkbox to enable on Mac, native arm64, kubectl context auto-configured
- Single-node only — cannot replicate node pool separation
- Rejected: node selectors and pool-based scheduling are load-bearing in the architecture

**k3s (bare / Lima VMs)**
- Lightweight k8s distribution (~512MB RAM, single binary)
- Multi-node: each node is a Lima VM on Mac
- Storage class: `local-path` provisioner (same as k3d)
- Networking: Flannel (matches many cloud configs)
- More Linux-like than Docker Desktop — closer to DOKS behavior
- Drawback: Lima VM setup and lifecycle management is manual overhead
- Not chosen for local dev, but relevant if running lobmob on a real Linux box

**k3d (chosen)**
- k3s nodes running as Docker containers — uses Docker Desktop as the VM layer
- Multi-node via `k3d cluster create --agents N`
- Same k3s storage class (`local-path`), networking (Flannel), and manifest behavior as bare k3s
- Cluster lifecycle: `k3d cluster create/delete` — much simpler than Lima
- kubectl context auto-injected into `~/.kube/config`
- Built-in image import: `k3d image import <image> -c <cluster>` — loads into k3d's internal containerd, no registry needed
- Key: from the overlay and manifest perspective, k3d and bare k3s are identical

### Image architecture options considered

**Option A: Multi-arch images (linux/amd64 + linux/arm64)**
- Build both platforms, push both to GHCR, registry serves the right one by arch
- Local k3d pulls arm64, DOKS pulls amd64 — same tag, transparent
- Doubles build time; requires all 5 images to be multi-arch
- Correct long-term answer — deferred to CI/CD plan

**Option B: `:local` tag + k3d image import (chosen for now)**
- Build natively on Mac (arm64, no `--platform` flag), tag `:local`
- Import directly into k3d: `k3d image import ... -c lobmob-local`
- Local overlay patches `imagePullPolicy: IfNotPresent` so k3d uses imported image
- No push/pull cycle — fast local iteration
- Cloud builds unchanged (still `--platform linux/amd64`)
- Two build paths, but low maintenance burden

**Option C: Rosetta emulation**
- Run amd64 images locally via Rosetta 2 emulation
- Zero build changes
- Noticeably slower under emulation, especially Agent SDK + Python
- Rejected: defeats dev parity purpose

### Scratch

- `local-path` PVs on k3d persist across pod restarts — fine for vault PVC and lobwife-home
- k3d context name: `k3d-lobmob-local` (k3d prefixes cluster name)
- `imagePullPolicy: Always` in base will always attempt GHCR pull — must patch to `IfNotPresent` for imported images
- lobster Jobs inherit settings from job template — ensure `imagePullPolicy` and `imagePullSecrets` patches cover the Job template too
- Token broker works unchanged locally — it's an HTTP service inside the cluster, GH App just needs credentials in secrets

## Related

- [Roadmap](../roadmap.md)
- [Vault Scaling](../active/vault-scaling.md)
- [CI/CD plan](../draft/ci-cd.md)
- [Dev overlay](../../../k8s/overlays/dev/kustomization.yaml)

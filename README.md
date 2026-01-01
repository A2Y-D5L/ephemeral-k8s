# ephemeral-k8s

An opinionated, "one command" ephemeral Kubernetes playground for macOS (Docker Desktop) that boots a fresh local cluster and immediately starts syncing a GitOps app tree via Argo CD.

Core goals:

- One command: `make up` creates everything needed for a clean local environment.
- Fully disposable: `make down` deletes the entire cluster and local runtime state.
- GitOps by default: once Argo CD is up, it bootstraps a root "app-of-apps" Application and auto-syncs child apps.
- Modern edge: expose UIs/services through Gateway API using kgateway (Envoy Gateway).

## What gets installed

Cluster runtime

- kind (Kubernetes-in-Docker) running on Docker Desktop

Edge / routing

- Kubernetes Gateway API CRDs
- kgateway control plane (GatewayClass + controller)
- A TLS-terminating `Gateway` and `HTTPRoute`s for local hostnames

GitOps

- Argo CD installed via the argo-helm chart
- Root "app-of-apps" Application (auto-sync enabled) that discovers child `Application` manifests recursively
- Child Applications (auto-sync enabled) that deploy real workloads from the repo

Example workload

- LLDAP (LDAP + web UI), deployed via a child Application

## Quick start

Prereqs (macOS):

- Docker Desktop running
- Homebrew-installed tools: kind, kubectl, helm, mkcert, yq, jq

Install prereqs:

```bash
brew install kind kubectl helm mkcert yq jq
mkcert -install
```

(Optional) Set up pre-commit hooks for linting:

```bash
brew install pre-commit shellcheck
pre-commit install
```

Configure the repo URL (required):

- Edit `Makefile` and set:
  - `GIT_REPO_URL` to your repo (e.g. <https://github.com/a2y-d5l/ephemeral-k8s.git>)
  - `GIT_REVISION` (e.g. main)

Bring everything up:

```bash
make up
```

Tear it all down:

```bash
make down
```

Check cluster status:

```bash
make status
```

View Argo CD server logs:

```bash
make logs
```

## After `make up`

You should have:

- Argo CD UI at:
  - <https://argocd.localhost:8443>
- LLDAP UI at:
  - <https://lldap.localhost:8443>
  - Note: this comes online after Argo CD syncs the child app.

The Argo CD initial admin password is printed at the end of `make up`.\
(You can also fetch it with kubectl, but the goal is that you do not need to.)

## How the GitOps bootstrapping works

This repo uses an app-of-apps pattern:

1) `make up` installs Argo CD.
2) `make up` applies a single "root" `Application` into the `argocd` namespace.
3) The root Application points at `gitops/applications/` and uses directory recursion.
4) Argo CD syncs the root Application automatically.
5) The root Application creates/updates all child Applications under `gitops/applications/`.
6) Each child Application has auto-sync enabled, so workloads deploy without manual sync clicks.

**Directory layout:**

- `gitops/applications/`: one YAML per child Argo CD Application (the "catalog" of apps to deploy)
- `gitops/apps/<name>/`: the actual Kubernetes manifests (Kustomize bases/overlays are fine)

> Note: The root Application is generated dynamically at bootstrap time (stored in `.state/root-app.yaml`) with your configured `GIT_REPO_URL` and `GIT_REVISION`.

## Adding a new app

> **Important:** Child Applications must reference the same `repoURL` and `targetRevision` as your root Application. If you fork this repo, update `gitops/applications/*.yaml` to point to your fork.

1) Create the manifests:
   - Add a folder: `gitops/apps/<your-app>/`
   - Add your YAMLs and a `kustomization.yaml` if you're using Kustomize
2) Create a child Application:
   - Add `gitops/applications/<your-app>-app.yaml`
   - Point `spec.source.path` to `gitops/apps/<your-app>`
   - Enable:
     - `spec.syncPolicy.automated.prune: true`
     - `spec.syncPolicy.automated.selfHeal: true`
     - `spec.syncOptions: [CreateNamespace=true]` if your app expects a namespace
3) Commit/push. Argo CD will pick it up automatically.

## Local TLS and hostnames

This setup uses mkcert to generate a local development certificate for `*.localhost` and configures kgateway to terminate TLS at the edge Gateway. Your browser should trust the certificate because mkcert installs a local CA into your macOS trust store.

If you don't want mkcert trust, you can still run it, but your browser will warn about TLS.

## Notes on Argo CD behind an edge proxy

TLS is terminated at kgateway. Argo CD's server is configured to run "insecure" internally (HTTP behind the proxy). This is a common pattern for edge-terminated TLS in local/dev environments.

## Private vs public repo

Default assumption:

- The repo is publicly readable so Argo CD can fetch it without extra credentials.

If the repo is private:

- You must provide Argo CD repo credentials during bootstrap.
- The recommended approach is:
  - supply a read-only GitHub token (fine-grained PAT) via an environment variable at `make up` time, and
  - have `hack/up.sh` create an Argo CD "repo-creds" Secret in the `argocd` namespace before applying the root Application.

This repo is intentionally structured so adding that step is straightforward.

## Security posture (read this if you publish publicly)

- The app-of-apps repo is effectively privileged:
  - Treat write access to the repo as admin-level access to your cluster.
  - Use branch protections and require PR reviews.

- Do not commit real secrets:
  - The included LLDAP/Dex credentials are intentionally "toy" values for local-only use. **Never use these in production.**
  - For anything real, generate secrets at runtime into `.state/` or use a secret manager.

- Local artifacts are ignored by default:
  - `.state/` and certificate/key material are not tracked (see `.gitignore`).

## Troubleshooting

1) Port already in use (8443):
   - Another process may be using 8443.
   - Stop it or change the forwarded port in `hack/portforward-start.sh` and adjust URLs accordingly.
2) kgateway pods not Ready:
   - Ensure Docker Desktop has enough CPU/RAM (4+ CPU, 8+ GB RAM recommended).
   - Check:\
    `kubectl -n kgateway-system get pods`\
    `kubectl -n kgateway-system logs deploy/kgateway`
3) Argo CD isn't syncing apps:
   - Confirm `GIT_REPO_URL` and `GIT_REVISION` are correct.
   - Confirm the root Application exists:\
    `kubectl -n argocd get applications.argoproj.io`
   - Confirm the root points at `gitops/applications` and recursion is enabled.

## Repo structure

- `Makefile`: `make up` / `make down` entrypoints
- `kind.yaml`: kind cluster shape
- `hack/`: lifecycle scripts (up/down + port-forward management)
- `helm/`: Argo CD Helm values
- `manifests/`: Gateway + HTTPRoute resources
- `gitops/`: app-of-apps tree (root + child Applications + workload manifests)

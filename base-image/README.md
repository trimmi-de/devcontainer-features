# trimmi-de devcontainer base image

`ghcr.io/trimmi-de/devcontainer-base`

A **prebuilt image** that bakes the [`trimmi-base`](../src/trimmi-base) feature — and its
whole dependency graph (python 3.14, github-cli, rust, claude-code) plus **rtk + rtk-mcp +
uv** — into one published image. Consuming repos reference it via `image:` instead of
`features:`, so a container rebuild is a layer **pull** (seconds) with **zero** feature
install — no per-rebuild `rtk-mcp` cargo compile.

App-specific features (docker-in-docker, node) are **not** baked in (they install fast and
infra doesn't need them); consumers add those on top via their own `features:` block.

## How a repo consumes it (thin `devcontainer.json`)

```jsonc
{
    "name": "default",
    "image": "ghcr.io/trimmi-de/devcontainer-base:1",
    "remoteUser": "vscode",
    "containerUser": "vscode",

    // app-specific only (infra has none); the shared tooling/env/extensions/scripts
    // come baked in from trimmi-base
    "features": {
        "ghcr.io/devcontainers/features/docker-in-docker:2": { "dockerDashComposeVersion": "v2" },
        "ghcr.io/devcontainers/features/node:1": { "version": "20" }
    },

    "mounts": [ /* host bind-mounts, per repo */ ],
    "remoteEnv": { "HOST_GIT_USER": "${localEnv:GIT_AUTHOR_NAME}", "HOST_GIT_EMAIL": "${localEnv:GIT_AUTHOR_EMAIL}" },
    "postStartCommand": "bash /usr/local/share/trimmi/post-start.sh",
    "postCreateCommand": "bash /usr/local/share/trimmi/post-create.sh && bash .devcontainer/post-create.sh"
}
```

## Reproducible builds (the committed lock)

`base-image/.devcontainer/devcontainer-lock.json` pins the feature graph to exact digests,
so every base-image build (local or CI) is reproducible — the image is the single,
fully-pinned source of truth for shared tooling. The build is **the** consumer of the lock,
so unlike the per-repo (gitignored) locks, this one is committed.

**To update the shared tooling** (pull in a new `trimmi-base`, python, rust, …):

```bash
devcontainer upgrade --workspace-folder base-image   # refresh the lock to latest
git add base-image/.devcontainer/devcontainer-lock.json && git commit
git push                                              # CI rebuilds + republishes
```

`.github/workflows/release-base-image.yml` rebuilds and pushes `:1` + `:latest` on push to
`main` (paths `src/**`, `base-image/**`) and via `workflow_dispatch`.

## Build locally

```bash
devcontainer build --workspace-folder base-image --image-name ghcr.io/trimmi-de/devcontainer-base:local
```

# trimmi-de dev container features

The **one place** that keeps every `trimmi-de` repo's devcontainer from diverging.
Shared tooling, env, extensions, and lifecycle scripts live here as a published
[Dev Container Feature](https://containers.dev/implementors/features/); each repo's
`devcontainer.json` stays a thin stub that references it.

## Features

### `trimmi-base`

`ghcr.io/trimmi-de/devcontainer-features/trimmi-base`

Provides, in one versioned place:

- **rtk + rtk-mcp** (Rust Token Killer) installed on PATH, with the global hook wired
  by the shared post-create script.
- **Dependent features** pulled in automatically (`dependsOn`): `github-cli`, `rust`,
  `claude-code`. (Add the `python` feature per repo — its version is repo-specific.)
- **Shared env**: `EDITOR=nano`, `CLAUDE_CONFIG_DIR=/home/vscode/.claude`.
- **Shared VS Code extensions**: yaml, shellcheck, gitlens, markdown-all-in-one,
  GitHub PR. (Repo-type extras — the Python suite, ansible, etc. — go per repo.)
- **Shared lifecycle scripts** installed to `/usr/local/share/trimmi/`:
  - `post-start.sh` — git identity + `gh` auth from the mounted `~/.gh_token_env`.
  - `post-create.sh` — `safe.directory`, `rtk init`, and GH_TOKEN shell wiring.

**To change something everywhere:** edit this feature, bump `version` in
`src/trimmi-base/devcontainer-feature.json`, merge to `main`. The release workflow
republishes to GHCR; repos pick it up on their next container rebuild.

## How a consuming repo references it (thin `devcontainer.json`)

```jsonc
{
    "name": "default",
    "image": "mcr.microsoft.com/devcontainers/base:ubuntu-24.04",
    "remoteUser": "vscode",
    "containerUser": "vscode",

    "features": {
        // repo-specific: python version
        "ghcr.io/devcontainers/features/python:1": { "version": "3.14" },
        // everything shared (rtk, gh-cli, rust, claude-code, env, extensions, scripts)
        "ghcr.io/trimmi-de/devcontainer-features/trimmi-base:1": {}
    },

    // host bind-mounts stay per repo (they reference ${localEnv:HOME})
    "mounts": [
        { "source": "${localEnv:HOME}/.claude", "target": "/home/vscode/.claude", "type": "bind" },
        { "source": "${localEnv:HOME}/.serena", "target": "/home/vscode/.serena", "type": "bind" },
        "source=${localEnv:HOME}/.gh_token_env,target=/home/vscode/.gh_token_env,type=bind,readonly"
    ],

    "remoteEnv": {
        "HOST_GIT_USER": "${localEnv:GIT_AUTHOR_NAME}",
        "HOST_GIT_EMAIL": "${localEnv:GIT_AUTHOR_EMAIL}"
    },

    // repo-type extras only (e.g. the Python/Django suite for app repos)
    "customizations": { "vscode": { "extensions": [] } },

    "postStartCommand": "bash /usr/local/share/trimmi/post-start.sh",
    // shared base first, then any repo-specific provisioning
    "postCreateCommand": "bash /usr/local/share/trimmi/post-create.sh && bash .devcontainer/post-create.sh"
}
```

A repo's own `.devcontainer/post-create.sh` shrinks to just its repo-specific steps
(e.g. `pip install -r requirements-dev.txt`, `manage.py migrate`).

`.mcp.json` and `.claude/settings.json` remain committed per repo (they're
project-scoped files Claude Code reads from the repo root, not container state).

## Local development

```bash
npm install -g @devcontainers/cli
devcontainer features test -f trimmi-base -i mcr.microsoft.com/devcontainers/base:ubuntu-24.04 .
```

## Publishing

`.github/workflows/release.yml` publishes to GHCR on push to `main` (uses the
in-Actions `GITHUB_TOKEN`, which has `packages: write`). To publish by hand you need a
PAT with `write:packages`:

```bash
echo "$PAT" | docker login ghcr.io -u trimmi-de --password-stdin
devcontainer features publish ./src --namespace trimmi-de/devcontainer-features
```

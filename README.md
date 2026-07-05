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
  by the shared post-create script. `rtk` is fetched as a prebuilt release binary (no
  compile); `rtk-mcp` builds from source via cargo (it ships no prebuilt binaries).
  Pin `rtk` with the `rtkVersion` option (default `latest`).
- **uv** (provides `uvx`, used by each repo's `.mcp.json` to run the serena MCP server).
- **aider** (AI pair programming) installed on PATH via `uv tool` (pinned to a uv-managed
  Python 3.12, since the dependency Python is 3.14). Default model is **DeepSeek**
  (`~/.aider.conf.yml` → `model: deepseek`); **OpenRouter** is usable ad-hoc via
  `aider --model openrouter/...`. Keys come from a host-mounted `~/.aider_env` — see
  [Aider API keys](#aider-api-keys-deepseek--openrouter) below. Toggle with the
  `installAider` option (default `true`).
- **Dependent features** pulled in automatically (`dependsOn`): `python` (3.14),
  `github-cli`, `rust`, `claude-code`.
- **Shared env**: `EDITOR=nano`, `CLAUDE_CONFIG_DIR=/home/vscode/.claude`,
  `RTK_TELEMETRY_DISABLED=1` (rtk telemetry off; the consent prompt is also answered
  `N` non-interactively during install so the container build never blocks).
- **Shared VS Code extensions**: yaml, shellcheck, gitlens, markdown-all-in-one,
  GitHub PR. (Repo-type extras — the Python suite, ansible, etc. — go per repo.)
- **Shared lifecycle scripts** installed to `/usr/local/share/trimmi/`:
  - `post-start.sh` — git identity + `gh` auth from the mounted `~/.gh_token_env`.
  - `post-create.sh` — `safe.directory`, `rtk init`, and GH_TOKEN shell wiring.

**To change something everywhere:** edit this feature, bump `version` in
`src/trimmi-base/devcontainer-feature.json`, merge to `main`. The release workflow
republishes the feature to GHCR; the **base-image** workflow then rebuilds the prebuilt
image (below); repos pick it up on their next container rebuild.

## How consuming repos reference it — the prebuilt base image

Consuming repos do **not** reference the feature directly. They reference the prebuilt
**`ghcr.io/trimmi-de/devcontainer-base`** image (built here in [`base-image/`](base-image/),
which bakes `trimmi-base` + its whole graph). Referencing it via `image:` makes a rebuild a
layer **pull** with **zero** feature install — no per-rebuild `rtk-mcp` cargo compile. See
[`base-image/README.md`](base-image/README.md) for the full consumption + update flow.

```jsonc
{
    "name": "default",
    "image": "ghcr.io/trimmi-de/devcontainer-base:1",
    "remoteUser": "vscode",
    "containerUser": "vscode",

    // app-specific features only (infra has none); the shared tooling/env/
    // extensions/scripts come baked into the base image from trimmi-base
    "features": {
        "ghcr.io/devcontainers/features/docker-in-docker:2": { "dockerDashComposeVersion": "v2" },
        "ghcr.io/devcontainers/features/node:1": { "version": "20" }
    },

    // host bind-mounts stay per repo (they reference ${localEnv:HOME})
    "mounts": [
        { "source": "${localEnv:HOME}/.claude", "target": "/home/vscode/.claude", "type": "bind" },
        { "source": "${localEnv:HOME}/.serena", "target": "/home/vscode/.serena", "type": "bind" },
        "source=${localEnv:HOME}/.gh_token_env,target=/home/vscode/.gh_token_env,type=bind,readonly",
        "source=${localEnv:HOME}/.aider_env,target=/home/vscode/.aider_env,type=bind,readonly"
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

## Aider API keys (DeepSeek / OpenRouter)

aider is baked into the base image, but the API keys are **not** — they live in a host-mounted
read-only `~/.aider_env` (same pattern as `~/.gh_token_env`), so keys never enter the image, git,
or the container's writable layer. Do this **once per developer machine** (on the host):

**1. Get a DeepSeek API key** — sign in at <https://platform.deepseek.com/> → **API keys** →
**Create new API key**. Copy it immediately (shown once); it looks like `sk-...`. DeepSeek is
pay-as-you-go, so add credit under **Top up / Billing** for the key to work.

**2. Get an OpenRouter API key** — sign in at <https://openrouter.ai/> → avatar → **Keys** →
**Create Key**. Copy it (shown once); it looks like `sk-or-v1-...`. Add credit under
**Settings → Credits** for paid models.

**3. Save them securely in `~/.aider_env`** with owner-only permissions:

```bash
umask 077                                   # new file is created 0600 (owner-only)
cat > ~/.aider_env <<'EOF'
export DEEPSEEK_API_KEY=sk-...              # paste your DeepSeek key
export OPENROUTER_API_KEY=sk-or-v1-...      # paste your OpenRouter key
EOF
chmod 600 ~/.aider_env                       # re-assert owner-only in case umask differed
```

Verify with `ls -l ~/.aider_env` → `-rw-------`. Keep this file in `$HOME`; never commit it or put
it inside a repo working tree. The mount line above (`source=${localEnv:HOME}/.aider_env,...`) makes
it available inside the container, and the shared `post-create.sh` sources it into interactive shells.

To rotate a key: revoke the old one in the provider dashboard, edit `~/.aider_env`, then restart the
container (or `. ~/.aider_env`).

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

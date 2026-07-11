# trimmi-de dev container features

## Quick start

```bash
# 1. Clone any trimmi-de repo
git clone <repo-url> && cd <repo>

# 2. Open in VS Code with Dev Containers
code .

# 3. First time? Set up API keys on your host (one-time):
#    See "Aider API keys" section below
```

The **one place** that keeps every `trimmi-de` repo's devcontainer from diverging.
Shared tooling, env, extensions, and lifecycle scripts live here as a published
[Dev Container Feature](https://containers.dev/implementors/features/); each repo's
`devcontainer.json` stays a thin stub that references it.

## Host machine prerequisites

Everything tooling-related is baked into the base image — but a few things are **per-machine**
and can't be: the container engine, and the host files the container bind-mounts for creds/config.
Set these up **once per developer machine**.

### 1. Container engine + Dev Containers tooling

- **Docker** (Docker Desktop / Engine) **or Podman** — see the Podman notes below.
- The **VS Code Dev Containers** extension and/or the `@devcontainers/cli`.
- Access to pull `ghcr.io/trimmi-de/devcontainer-base:1` (if the package is private, run
  `docker login ghcr.io` / `podman login ghcr.io` first).

### 2. The four host paths (bind-mounted by the feature)

The feature bind-mounts these from your `$HOME` into the container. They **must exist** on the
host, or the mount misbehaves (Docker silently creates a **root-owned dir**, corrupting the two
file mounts; rootless Podman hard-errors). The `initializeCommand` guard in each repo's
`devcontainer.json` auto-creates empty ones so a container always comes up — but for the tools
to actually authenticate, the two secret files need real content:

| Host path | Type | Must contain | If empty/missing |
| --- | --- | --- | --- |
| `~/.claude/` | dir | Claude Code login/config (`.credentials.json`, `CLAUDE.md`, …) | Claude Code + aider run without your global memory/creds |
| `~/.serena/` | dir | serena MCP state (auto-managed) | recreated empty; no shared state |
| `~/.aider_env` | file | `export DEEPSEEK_API_KEY=…` and `export OPENROUTER_API_KEY=…` | aider runs **keyless** (no crash; warnings suppressed) |
| `~/.gh_token_env` | file | `export GH_TOKEN=…` (a GitHub PAT) | `gh` stays logged out (post-start guards on `$GH_TOKEN`) |

See [Aider API keys](#aider-api-keys-deepseek--openrouter) for the exact `~/.aider_env` recipe.
`~/.gh_token_env` follows the same shape. Nothing here is baked into the image or committed to
git — the secrets never leave your machine.

### 3. Optional host env vars

`GIT_AUTHOR_NAME` / `GIT_AUTHOR_EMAIL` on the host feed the container's git identity (via
`remoteEnv` → `HOST_GIT_USER` / `HOST_GIT_EMAIL`). Absent → git identity just isn't preset.

### Running Podman instead of Docker

It works, with extra setup:

- **Point the tooling at Podman** — VS Code `dev.containers.dockerPath: "podman"` (+ compose path),
  or `--docker-path podman` for the CLI; a running `podman system service` socket.
- **SELinux hosts (Fedora/RHEL/…)** — bind mounts aren't readable inside the container without a
  relabel, which surfaces as "key not set" again. The feature mounts don't add `:z`/`:Z`, so add
  `--security-opt label=disable` (or relabel) via `runArgs`.
- **Rootless UID mapping** — mounted files are owned by your host UID; without
  `runArgs: ["--userns=keep-id"]` they can appear unreadable inside the container.
- **The `initializeCommand` guard matters more** — rootless Podman hard-errors on a missing bind
  source (vs Docker's silent root-owned dir), so the guard is what keeps `up` working at all.
- **docker-in-docker is shaky rootless** — only relevant to *this* feature-dev repo (it needs dind
  to run `devcontainer features test`); normal app repos don't use it.

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
  Python 3.12, since the dependency Python is 3.14). Default model is **DeepSeek** via the
  `AIDER_MODEL=deepseek` env; **OpenRouter** is usable ad-hoc via `aider --model openrouter/...`.
  Keys come from a host-mounted `~/.aider_env` that aider loads itself (the `AIDER_ENV_FILE`
  env points at it — same idea as Claude reading the bind-mounted `~/.claude`, no shell
  sourcing). The shared global **`CLAUDE.md` is loaded as read-only context** via
  `AIDER_READ=/home/vscode/.claude/CLAUDE.md` (the same file Claude Code reads as user memory),
  so aider follows the same instructions Claude Code does — model-agnostically (it's injected
  into the prompt; if the file is absent it's silently skipped). See
  [Aider API keys](#aider-api-keys-deepseek--openrouter) below. Toggle with the
  `installAider` option (default `true`).
- **Dependent features** pulled in automatically (`dependsOn`): `python` (3.14),
  `github-cli`, `rust`, `claude-code`.
- **Shared env**: `EDITOR=nano`, `CLAUDE_CONFIG_DIR=/home/vscode/.claude-local`
  (a per-container Claude config dir seeded from the shared `~/.claude` mount — see
  Claude Code section below), `RTK_TELEMETRY_DISABLED=1` (rtk telemetry off; the
  consent prompt is also answered `N` non-interactively during install so the
  container build never blocks).
- **Shared VS Code extensions**: yaml, shellcheck, gitlens, markdown-all-in-one,
  GitHub PR. (Repo-type extras — the Python suite, ansible, etc. — go per repo.)
- **Shared lifecycle scripts** installed to `/usr/local/share/trimmi/`:
  - `post-start.sh` — git identity + `gh` auth from the mounted `~/.gh_token_env`,
    plus Claude Code credential isolation (see below).
  - `post-create.sh` — `safe.directory`, `rtk init`, and GH_TOKEN shell wiring.

**To change something everywhere:** edit this feature, bump `version` in
`src/trimmi-base/devcontainer-feature.json`, merge to `main`. The release workflow
republishes the feature to GHCR; the **base-image** workflow then rebuilds the prebuilt
image (below); repos pick it up on their next container rebuild.

## Using Claude Code and aider inside the container

Both tools are available on `PATH` as soon as the container starts.

### Claude Code

Run `claude` from the repo root. Log in once (on the host, or once inside any
container) and it carries across rebuilds.

**Credential isolation.** The host `~/.claude` is bind‑mounted at
`/home/vscode/.claude` and shared by every repo and the host. But Claude actually
runs against a per‑container `CLAUDE_CONFIG_DIR=/home/vscode/.claude-local`, which
`post-start.sh` seeds on every start: it symlinks every entry from the shared mount
(so `CLAUDE.md`, `settings.json`, `plugins/`, and `projects/` — including
auto‑memory — stay shared) **except** `.credentials.json`, which is copied into a
real per‑container file. Claude refreshes its short‑lived OAuth token in the
background and rewrites that file; keeping it per‑container stops parallel
containers from clobbering each other's token and kicking you back to `/login`. A
fresh login on the host (newer file) propagates to each container on its next
start. Project‑specific settings live in `.claude/settings.json` (committed to the
repo); the shared `CLAUDE.md` at the repo root is loaded as context automatically.

### Aider

Run `aider` from the repo root. It loads API keys from the host‑mounted
`~/.aider_env` file. The default model is DeepSeek
(`AIDER_MODEL=deepseek`). To use OpenRouter, pass `--model openrouter/...` on the
command line. The shared global `CLAUDE.md` is injected as read‑only context via
`AIDER_READ=/home/vscode/.claude/CLAUDE.md`.

See the **Aider API keys** section below for one‑time host setup.

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

    // As of trimmi-base 1.5.1 the four host bind-mounts (~/.claude, ~/.serena,
    // ~/.gh_token_env, ~/.aider_env) are baked into the base image by the feature
    // — consuming repos no longer declare a `mounts` block for them.
    //
    // But every repo MUST keep this one host-side guard: a missing bind source
    // makes Docker/Podman silently create a root-owned dir that corrupts the
    // dotenv file mounts. initializeCommand runs on the host before create (a
    // feature cannot contribute it), so it can't be centralized. Empty
    // placeholders degrade gracefully — no key just means aider/gh stay
    // unauthenticated.
    "initializeCommand": "mkdir -p ~/.claude ~/.serena && touch ~/.aider_env ~/.gh_token_env",

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

<details>
<summary>Aider API keys (DeepSeek / OpenRouter) — click to expand</summary>

aider is baked into the base image, but the API keys are **not** — they live in a host-mounted
`~/.aider_env` (same pattern as `~/.gh_token_env`), so keys never enter the image or git. (These
two file mounts were read-only until trimmi-base 1.5.1; the feature Mount schema has no `readonly`
property, so they now mount read-write — the container can write the host file, but the keys still
never leave your machine.) Do this **once per developer machine** (on the host):

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
it inside a repo working tree. The feature-provided bind mount (baked into the base image as of
1.5.1) makes it available inside the container; aider then loads it **itself** — the feature sets
`AIDER_ENV_FILE=/home/vscode/.aider_env`, so no shell sourcing or generated config is involved (the
same way Claude Code reads its creds from the bind-mounted `~/.claude`). The default model is set via
`AIDER_MODEL=deepseek`. (`export ` on each line is fine — aider's dotenv parser tolerates it.)

To rotate a key: revoke the old one in the provider dashboard, edit `~/.aider_env`, then restart the
container (aider picks it up on next launch).

</details>

## Local development

```bash
npm install -g @devcontainers/cli
devcontainer features test -f trimmi-base -i mcr.microsoft.com/devcontainers/base:ubuntu-24.04 .
```

## Releasing a change end-to-end (the two-step)

There are **two separately-published artifacts**, and consuming repos reference only the
second one:

1. **The feature** — `ghcr.io/trimmi-de/devcontainer-features/trimmi-base` — published by
   [`release.yml`](.github/workflows/release.yml).
2. **The prebuilt base image** — `ghcr.io/trimmi-de/devcontainer-base` — published by
   [`release-base-image.yml`](.github/workflows/release-base-image.yml), built from the
   **committed lock** (`base-image/.devcontainer/devcontainer-lock.json`).

Consuming repos pin `image: ghcr.io/trimmi-de/devcontainer-base:1` — **not** the feature. So
a feature change reaches them **only after the base image is rebuilt against the new feature
version**. Publishing the feature alone changes nothing downstream. This is the two-step, and
skipping step 2 is the classic "my fix silently never shipped" trap.

### Step 0 — make + prove the change (in a PR)

1. Edit `src/trimmi-base/` (`install.sh`, `devcontainer-feature.json`, lifecycle scripts).
2. **Bump `version`** in `src/trimmi-base/devcontainer-feature.json` — patch for a fix, minor
   for a feature. *No bump = the publish is a no-op and the lock can never move.* Check the
   real current version against the **registry**, not git tags (tags here are unreliable):
   ```bash
   PKG=trimmi-de/devcontainer-features/trimmi-base
   TOKEN=$(curl -s "https://ghcr.io/token?scope=repository:$PKG:pull" | grep -o '"token":"[^"]*"' | cut -d'"' -f4)
   curl -s -H "Authorization: Bearer $TOKEN" "https://ghcr.io/v2/$PKG/tags/list" | tr ',' '\n' | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | sort -V | tail
   ```
3. Update `test/trimmi-base/test.sh` assertions to match, and run the test locally:
   ```bash
   devcontainer features test -f trimmi-base -i mcr.microsoft.com/devcontainers/base:ubuntu-24.04 .
   ```
4. Open the PR, review, merge to `main`.

### Step 1 — publish the feature

Merging any `src/**` change to `main` triggers `release.yml`, which publishes
`trimmi-base:X.Y.Z` (plus the moving `:X.Y`, `:X`, `:latest` tags) to GHCR via the in-Actions
`GITHUB_TOKEN`. **Wait for that workflow to go green, then confirm the new version is live in
the registry** (rerun the tag-list command above — you should see your `X.Y.Z`). Step 2 reads
the live registry, so it must actually be published first.

<details><summary>Publish the feature by hand (rarely needed — needs a PAT with <code>write:packages</code>)</summary>

```bash
echo "$PAT" | docker login ghcr.io -u trimmi-de --password-stdin
devcontainer features publish ./src --namespace trimmi-de/devcontainer-features
```
</details>

### Step 2 — refresh the base-image lock and rebuild

The base image builds from the committed lock, so it keeps shipping the **old** pinned
feature until you deliberately re-resolve it. Do **not** hand-edit the lock (the digest only
exists post-publish) — let the CLI resolve it against the registry:

```bash
devcontainer upgrade --workspace-folder base-image     # re-resolves trimmi-base:1 -> X.Y.Z + new digest
git add base-image/.devcontainer/devcontainer-lock.json
git commit -m "Refresh base-image lock to trimmi-base X.Y.Z"
git push                                                # commit the lock via a PR to main
```

Confirm the diff actually bumped `trimmi-base` to `X.Y.Z` with a new digest. Merging this
`base-image/**` change triggers `release-base-image.yml`, which rebuilds and republishes
`ghcr.io/trimmi-de/devcontainer-base:1` + `:latest`. **If the version in the lock didn't
change, `devcontainer upgrade` silently re-resolved to the old version — that means step 1
hadn't published yet.**

### Step 3 — consuming repos pick it up

Because repos pin the moving tag `devcontainer-base:1`, the next **container rebuild** pulls
the new image:

- VS Code: **Dev Containers: Rebuild Container** (use *Rebuild Without Cache* / pull if a
  stale image is cached).
- Each consuming repo also needs, **one time**, the host-side pieces a feature cannot bake in
  (see [How consuming repos reference it](#how-consuming-repos-reference-it--the-prebuilt-base-image)):
  the `initializeCommand` guard line, and the host files (`~/.aider_env`, `~/.gh_token_env`,
  `~/.claude`, `~/.serena`) — populated with real secrets for aider/gh to authenticate.

### At a glance

| Step | You do | Trigger | Publishes / result |
| --- | --- | --- | --- |
| 0 | Edit `src/`, **bump `version`**, update tests | — | local test green |
| 1 | Merge `src/**` to `main` | `release.yml` | `trimmi-base:X.Y.Z` in GHCR |
| 2 | `devcontainer upgrade` on `base-image`, commit lock | `release-base-image.yml` | `devcontainer-base:1` rebuilt on X.Y.Z |
| 3 | Rebuild container in each repo | — | change is live downstream |

# Releasing — the two-step process (read this every time)

## Tests run automatically before every push (one-time setup)

The tests (Claude login, aider login, gh token, and all four host mounts) are wired to run
**before every `git push`** via a git hook. Each clone must turn it on **once**:

```bash
git config core.hooksPath .githooks
```

After that, `git push` automatically runs, in order: shell syntax → `test/validate-metadata.sh`
(checks all four mounts + env are declared) → the full container test suite
(`devcontainer features test`). If anything fails, the push is blocked. This needs Docker and
the `@devcontainers/cli` available locally.

A server-side backstop (`.github/workflows/test.yml`) runs the same tests on every push/PR to
GitHub, so nothing broken reaches `main` even if the local hook is skipped. **Do not push with
`--no-verify`** except in a genuine emergency.

There is also a heavier, on-demand runtime check that launches serena and proves its web
dashboard never comes up: `bash test/serena-dashboard-check.sh` (not part of the gate — it
fetches + starts serena over the network).

---

This repo publishes **two separate things** to the GitHub Container Registry (GHCR):

1. **The feature** — `ghcr.io/trimmi-de/devcontainer-features/trimmi-base`
   Built from everything under `src/trimmi-base/`. Published by the workflow
   `.github/workflows/release.yml`.
2. **The base image** — `ghcr.io/trimmi-de/devcontainer-base`
   A prebuilt image that **bakes a specific, pinned version of the feature** inside it.
   Published by `.github/workflows/release-base-image.yml`.

**Your other repos (avail, django-template, …) use the BASE IMAGE, not the feature.**

That is the whole reason there are two steps. When you change the feature, the base image
does **not** notice on its own — it keeps baking the old, pinned version until you deliberately
tell it to pick up the new one. The pin lives in one file:

```
base-image/.devcontainer/devcontainer-lock.json
```

So every feature change ships in two steps, in this exact order:

- **Step 1 — Publish the new feature.** (touches `src/trimmi-base/…`)
- **Step 2 — Re-pin the base image to that new feature and rebuild it.** (touches the lock file)

> ⚠️ **Order is not optional.** Step 2 reads the pin from GHCR. If you do Step 2 before Step 1
> has finished publishing, the new version does not exist yet, so the pin stays on the old one
> and nothing changes. **Always finish Step 1 (green check) before starting Step 2.**

---

## Step 1 — Publish the new feature

### 1a. Bump the version number (REQUIRED for every feature change)

Open **`src/trimmi-base/devcontainer-feature.json`**. **Line 3** is the version:

```jsonc
    "version": "1.5.2",
```

Increase it. We use `MAJOR.MINOR.PATCH`:

- small fix / doc / new env var → bump the last number: `1.5.2` → `1.5.3`
- meaningful new behavior → bump the middle number: `1.5.3` → `1.6.0`

> **If you forget this bump, the release silently does nothing** — GHCR already has that version,
> so the publish overwrites nothing and consumers can’t tell anything changed. This is the #1
> mistake. Bump it whenever *anything* under `src/trimmi-base/` changes (including `install.sh`).

### 1b. Open a Pull Request and merge it

On the command line (from the repo root):

```bash
git checkout -b my-change            # 1. new branch (any name)
git add -A                           # 2. stage everything you changed
git commit -m "trimmi-base 1.5.3: <what you changed>"   # 3. commit
git push -u origin my-change         # 4. push the branch
gh pr create --fill                  # 5. open the PR
gh pr merge --squash --delete-branch # 6. merge it into main
```

Prefer clicking in the browser? Same six actions:
1. Make a branch.
2. Push it.
3. On github.com → the repo → the yellow **“Compare & pull request”** button.
4. Click the green **“Create pull request”** button.
5. Click the green **“Merge pull request”** button → choose **“Squash and merge”** → confirm.
6. Click **“Delete branch”**.

### 1c. Wait for the green check ✅ (this is the part people skip)

Merging to `main` starts the publish automatically (because you changed files under `src/`).

- Watch it: **github.com → the repo → the “Actions” tab → the “Release dev container features” run.**
- Command-line equivalent: `gh run watch` (or `gh run list --workflow=release.yml`).
- **Wait until it shows a green ✅.** That means `trimmi-base 1.5.3` now exists on GHCR.

> You will also see a **“Release devcontainer base image”** run start at the same time.
> **Ignore it.** It is rebuilding the base image from the *old* pin, so it does not contain your
> change yet. Step 2 is what fixes that.

**Step 1 is done only when the “Release dev container features” run is green.**

---

## Step 2 — Re-pin the base image and rebuild it

### 2a. Refresh the lock file (do NOT hand-edit it)

From the repo root, run exactly this one command:

```bash
devcontainer upgrade --workspace-folder base-image
```

This rewrites **`base-image/.devcontainer/devcontainer-lock.json`**. In the `trimmi-base` block
(**around lines 23–26**) the three pinned fields move to the new version:

```jsonc
      "version": "1.5.3",                 // was 1.5.2
      "resolved": "ghcr.io/…@sha256:…",   // new digest
      "integrity": "sha256:…",            // new digest
```

Check it actually changed:

```bash
git diff base-image/.devcontainer/devcontainer-lock.json
```

If the diff is **empty**, Step 1 has not finished publishing yet (or you forgot the version
bump). Go back, wait for the green check, and run the upgrade again.

### 2b. Open a second Pull Request and merge it

Same six actions as Step 1b, just for this one file:

```bash
git checkout main && git pull                    # start from the freshly-merged main
git checkout -b refresh-base-lock-trimmi-base-1.5.3
git add base-image/.devcontainer/devcontainer-lock.json
git commit -m "Refresh base-image lock to trimmi-base 1.5.3"
git push -u origin refresh-base-lock-trimmi-base-1.5.3
gh pr create --fill
gh pr merge --squash --delete-branch
```

### 2c. Wait for the green check ✅ again

Merging this (you changed `base-image/…`) starts **“Release devcontainer base image.”**

- Watch: **Actions tab → “Release devcontainer base image”** → wait for green ✅.
- Command-line: `gh run watch`.

When it is green, `ghcr.io/trimmi-de/devcontainer-base:1` and `:latest` now contain
trimmi-base 1.5.3.

**Step 2 is done only when the “Release devcontainer base image” run is green.**

---

## Step 3 — Pick it up in the consuming repos

In each repo that uses the base image (avail, django-template, …):

> **VS Code → Command Palette (F1) → “Dev Containers: Rebuild Container”.**

That pulls the new base image. Done.

---

## One-screen cheat sheet

| Step | Edit this file | Then | Wait for this Actions run |
| --- | --- | --- | --- |
| 1 | `src/trimmi-base/devcontainer-feature.json` line 3 (`version`) + your code | PR → squash-merge | **Release dev container features** ✅ |
| 2 | `base-image/.devcontainer/devcontainer-lock.json` (via `devcontainer upgrade --workspace-folder base-image`) | PR → squash-merge | **Release devcontainer base image** ✅ |
| 3 | (nothing) | Rebuild Container in each consuming repo | — |

**Never start Step 2 until Step 1’s run is green.**

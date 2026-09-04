# Attribution and modifications

## Bundled third-party content

This kit redistributes **[microsoft/agent365-skills](https://github.com/microsoft/agent365-skills)**.

> Copyright (c) Microsoft Corporation.
> Licensed under the MIT License.

The bundled version and the exact upstream commit are recorded in `.a365-kit/KIT-VERSION.json` in every build.

Everything under `.a365-kit/skills/`, `.a365-kit/shared/`, `.a365-kit/hooks/`, and `.a365-kit/copilot-instructions.md` originates upstream. The files added by this kit are `doctor.js`, `kit-version.js`, `settings-fragment.json`, `KIT-VERSION.json`, the two `agent365-kit` launchers, and `AGENT365-KIT-README.md`.

---

## Modifications made when repackaging

The goal is a faithful repackage: **no skill logic, guidance, or code pattern is changed.** Every modification below exists because the upstream files assume they were installed as a plugin, and that assumption is false in a drop-in install. All are applied mechanically by `build/Build-Kit.ps1`.

### 1. `${CLAUDE_PLUGIN_ROOT}` path tokens

`${CLAUDE_PLUGIN_ROOT}` is set by the host only when skills load as a plugin. In a drop-in install it is unset, so every path built from it resolves to nothing.

Because `.a365-kit/` mirrors the upstream layout exactly (`skills/`, `shared/`, `hooks/`), one substitution fixes every in-body reference:

```
${CLAUDE_PLUGIN_ROOT}/shared/agent-detection.md   ->   .a365-kit/shared/agent-detection.md
```

These are prose instructions the model resolves with its own file tools, and a project-relative path works regardless of whether the host expands variables in skill content.

### 2. Hook commands

Hook `command:` values are executed by the host, so they need an absolute path. These get `${CLAUDE_PROJECT_DIR}` instead, which Claude Code expands reliably, quoted so paths containing spaces survive:

```yaml
# before
command: node ${CLAUDE_PLUGIN_ROOT}/hooks/stop/validate-a365-setup.js
# after
command: node "${CLAUDE_PROJECT_DIR}/.a365-kit/hooks/stop/validate-a365-setup.js"
```

### 3. `path-guard.js` — restoring a guard that would otherwise disable itself

Upstream refuses writes inside `CLAUDE_PLUGIN_ROOT`, so skills cannot rewrite their own instructions. That check is conditional on the variable being set:

```js
const pluginRoot = process.env.CLAUDE_PLUGIN_ROOT
  ? safeRealpath(path.resolve(process.env.CLAUDE_PLUGIN_ROOT))
  : null;   // <- drop-in install lands here; the guard silently switches off
```

The kit adds a fallback to the kit folder inside the project. The environment variable is still honoured first, so the file behaves identically if it ever *is* loaded as a plugin. The block message was updated to name the kit folder rather than an environment variable the user never set.

This is the one change with a security consequence, and it makes the drop-in install **more** protective than it would otherwise be, not less. Verified with four cases: writing into the kit blocks, writing outside the project blocks, writing to agent source is allowed, and non-write tools pass through.

### 4. `/agent365:` command namespace

Upstream instructs the user to re-run skills as `/agent365:<name>`. That namespace is created by installing the plugin. Project skills are invoked as `/<name>`, so `/agent365:make-ai-teammate` becomes `/make-ai-teammate`. CLIs other than Claude Code use trigger phrases and ignore slash commands entirely.

This is applied to reference docs and validator scripts as well as `SKILL.md` files, because the validators print these strings back to the user in failure messages.

### 5. `scripts/check-version.js` replaced

Upstream's version check tells the user to run `gh skill add microsoft/agent365-skills` — the install path this kit exists to avoid. It is replaced by `kit-version.js`, which reports when Microsoft has published a newer skills release than the bundled one and points at re-downloading the kit. It is optional, silent when up to date or offline, and never blocks a session.

### 6. `copilot-instructions.md` relocated

Staged at `.a365-kit/copilot-instructions.md` rather than shipped at `.github/copilot-instructions.md`. That file is commonly project-owned, and an archive extraction would overwrite it with no warning. The launcher's `-WireCopilot` flag creates it, or appends to an existing one. Its relative links are repointed from `../plugins/agent365/...` to `../.a365-kit/...` so they resolve from `.github/`.

### 7. One wording fix-up

`a365-code-validator/SKILL.md` explains how to run its validator "from the plugin source", with a fallback for when the runtime cannot expand `${CLAUDE_PLUGIN_ROOT}`. After the substitution in (1) that passage no longer parses as English. It is rewritten to describe running from the project root, with an absolute-path fallback.

The build asserts this passage still matches upstream before patching it, so an upstream rewording fails the build rather than shipping a broken instruction.

### 8. `validate-make-ai-teammate.js` — one bug fix

This is the only modification that changes behaviour rather than paths, and it is called out here for that reason.

Upstream's `validate-make-ai-teammate.js` detects a Python project **only** by the presence of `pyproject.toml`:

```js
const hasPyproject  = fs.existsSync(path.join(cwd, 'pyproject.toml'));
```

Every sibling validator (`validate-instrument-observability.js`, `validate-add-workiq-tools.js`, `validate-test-local.js`, `validate-a365-code-validator.js`) accepts `requirements.txt` as well, and so does the skills' own stack detection. The result is that a `requirements.txt`-only Python project falls through to the Node.js default and fails eight TypeScript checks that do not apply to it — `src/index.ts not found`, `package.json not found`, `tsconfig.json not found`, and so on.

In Claude Code this validator runs as a **stop hook that refuses to end the session** until it passes, so a false negative is not cosmetic: it blocks the session. Three checks in this one file assume a layout that upstream's own `make-ai-teammate` skill does not enforce when it edits an existing project:

| Check | Upstream assumption | What the kit accepts instead |
|---|---|---|
| Language detection | Python ⇔ `pyproject.toml` exists | `pyproject.toml` **or** `requirements.txt`, matching every sibling validator |
| Check 2, `agent.py` | Must be at the project root | Root, or anywhere in the scanned tree (e.g. `src/agent.py`) |
| Check 4, dependencies | Read from `pyproject.toml` only, underscore-only names | `pyproject.toml` or `requirements.txt`, whichever exists; hyphen and underscore forms compared as equal, as pip treats them |

Without the first fix a `requirements.txt` project falls through to the Node.js default and fails eight TypeScript checks. With only the first fix, Check 4 would then read a `pyproject.toml` that does not exist. So the three are applied together. The *content* of each check — what must be present in `agent.py`, which packages are required — is unchanged.

Found 2026-09-03 while onboarding an existing Python / OpenAI Agents SDK project (`src/` layout, `requirements.txt`) through the kit: the skill adapted to the layout correctly and the validator then reported it as a failed Node.js project. Reported upstream.

---

## Kit add-ons — not Microsoft's

Everything under `.a365-kit/addons/` (and its copies in `.claude/skills/` and `.agents/skills/`) plus the two validators `validate-add-messaging-endpoint.js` and `validate-add-purview-dlp.js` is **written for this kit**, copyright Akram Eleyan, MIT. They follow upstream's skill format so every CLI discovers them the same way, but they are not part of `microsoft/agent365-skills` and should not be reported there.

| Add-on | Fills this gap | Basis |
|---|---|---|
| `add-messaging-endpoint` | `make-a365-agent` asks for a messaging endpoint but never creates the HTTP host; blueprint-based agents built from a CLI or library end up registered but unreachable. Adds the host, the tunnel, and the endpoint registration; hands off the one broker-bound step. | Python host verified live on `microsoft-agents` 1.6.0 (2026-09-04). Node.js and .NET reference upstream's own hosting layers, which need no change for this path. |
| `a365-kit` | Kit maintenance from inside the CLI: prerequisite check, versions, in-place update, and choosing the update source (public release or an internal mirror). Thin wrapper over the launchers. | Kit-authored. |
| `add-purview-dlp` | Upstream has no Purview coverage. Evaluates every prompt and response against tenant DLP via two Graph calls; grants the scopes; hands off the portal policy. | Python adapted from the Agent 365 + Claude reference deployment's `purview_dlp.py`, which ran against a live tenant. The Node.js and .NET files are faithful ports of the same two REST calls, **not yet run against a tenant**; each marks the token-exchange line as the one to verify against the local SDK. |

The seven Microsoft skills are untouched by the add-ons: they reference upstream files, never modify them.

---

## What is *not* changed

- No skill logic, phase ordering, or decision matrix.
- No code patterns in `references/`.
- No validator check logic, with the single exception of the language-detection fix in section 8 — the validators otherwise enforce exactly what upstream enforces.
- No trigger phrases.
- Nothing added to the skills. This kit contains no Purview, hosting, or hardening content; it is a packaging change only.

## Reporting issues

Problems with the skills themselves — what they do, ask, or generate — belong upstream at
[microsoft/agent365-skills](https://github.com/microsoft/agent365-skills/issues). Problems with the
packaging, the launchers, the prerequisite doctor, or the build belong in this repository.

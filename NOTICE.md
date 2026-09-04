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

### 9. `validate-instrument-observability.js` — exporter value, not just presence

The `a365` CLI stamps `ENABLE_A365_OBSERVABILITY_EXPORTER=false` into `.env`, and `instrument-observability` has an explicit invariant not to overwrite an existing value ("Preserve existing values … Add only missing keys"); it is meant to *warn* instead. Upstream's validator then checks only that the key **exists**:

```js
const hasEnvConfig = envFiles.some(f => fileContains(f, 'ENABLE_A365_OBSERVABILITY_EXPORTER'));
```

So an agent with the exporter switched off passes validation as fully instrumented, produces spans on every turn, and exports none of them. The Agent 365 Activity view stays empty with nothing anywhere reporting a fault.

The kit adds a value check to both the Node.js and Python branches: if the key is present but not `true`, the validator fails with *"instrumented but exports nothing; set it to true and restart"*. No other check is altered.

Found 2026-09-04 after several hours of live Teams traffic produced no activity. The instrumentation was correct throughout; only the last hop was disabled.

### 10. `instrument-observability/SKILL.md` — the skill now sets the exporter, not just reports it

Section 9 makes a disabled exporter visible. This makes the skill fix it.

Invariant 1 told the skill to preserve an existing `ENABLE_A365_OBSERVABILITY_EXPORTER`, and rule 6 told it to report that value back to the user when it was `false`. Because `a365 setup` stamps the key as `false` before this skill ever runs, the key always exists, so the preserve branch always won. The outcome of "add observability to my agent" was an agent correctly instrumented, building a span per turn, exporting none of them, with the fact recorded in one line of a long completion summary.

The kit rewrites three passages in the Node.js / Python path:

| Passage | Upstream | Kit |
|---|---|---|
| Invariant 1 | Preserve an existing exporter value | Preserve every value **except** the exporter switch; set that to `true` and say so |
| Rule 6 | Tell the user it is off and how to turn it on | Tell the user it was off and that you turned it on, and to restart |
| Phase 9 next steps | "Enable exporting when ready for production" | "Confirm the exporter is still on — a later `a365 setup` run can reset it" |

Upstream's own .NET path already does exactly this. Invariant 3 reads: *"`EnableAgent365Exporter: true` at the root. `a365 setup` may write `false`; this skill corrects it."* The Node.js and Python branches were inconsistent with .NET on the same decision, and the kit makes them agree.

This matters more outside Claude Code than inside it. The validator in section 9 runs as a stop hook, which only Claude Code honours; the kit ships no hook wiring for Copilot CLI, Cursor or Gemini CLI, so on those the validator never runs unless the reader invokes it. Fixing the skill rather than only the validator is what makes the behaviour identical on every CLI the kit supports.

Found and fixed 2026-09-04, alongside section 9. Reported upstream.


### 11. `references/python-observability.md` — the OBO token resolver must be synchronous

The Python OBO sample wires the exporter's token resolver like this:

```python
a365_token_resolver=_token_cache.get_observability_token,
```

`AgenticTokenCache.get_observability_token` is declared `async def`, and the exporter calls the resolver synchronously from its own batch-export thread:

```python
return self._token_resolver(agent_id, tenant_id)
```

So it receives an un-awaited coroutine rather than a token. The next guard is `if not token:` — and a coroutine object is **truthy**, so the one check that would have caught this passes. The exporter then builds `f"Bearer {token}"`, sending the literal text `Bearer <coroutine object AgenticTokenCache.get_observability_token at 0x...>`. The service cannot read a tenant out of that and answers:

```json
{"code":"EndpointInvalid","message":"Tenant id  is invalid.","innererror":{"code":"TenantIdInvalid"}}
```

The blank in *"Tenant id  is invalid"* is the tell: the tenant is unreadable, not absent from the agent's configuration. Chasing the configured `TENANTID` — which is correct — leads nowhere.

Upstream's own documentation already says what the contract is. Its kwarg table describes `a365_token_resolver` as a *"Sync callable `(agent_id, tenant_id) -> str | None`"*, and its S2S sample passes a sync lambda correctly. Only the OBO sample is wrong, and `AgenticTokenCache` exposes no sync accessor, so that sample cannot work as written.

The kit replaces it with a bridge that marshals the coroutine onto the host's event loop via `run_coroutine_threadsafe` and returns `None` on failure, so a telemetry fault never costs a turn. It is applied in three places, because any one alone leaves a way through:

| Where | Why it is needed |
|---|---|
| `references/python-observability.md` | The code the skill copies from. Also shows where to capture the loop — the per-turn handler the skill already wraps with `InvokeAgentScope`, so nothing outside the skill's own edits has to change. |
| `SKILL.md` | Read before any reference doc, and it stated the broken wiring outright. Fixing only the reference leaves the model with a contradiction and the wrong instruction first. |
| `validate-instrument-observability.js` | Catches the pattern in code already written, including agents onboarded before this kit version. Matches `a365_token_resolver=` bound directly to `get_observability_token`; the bridge mentions the same symbol and is correctly ignored. |

Leaving the captured loop unset is the one remaining way to get no telemetry, and unlike the original defect it is loud: the exporter logs `No token resolved for agent ...; dropping chunk` at ERROR on every export.

Found 2026-09-04 on a live Python OBO agent: the agent answered normally in Teams while every export was rejected. Verified fixed against the same tenant — `HTTP 200`, three spans, all sinks accepting. Reported upstream.


### 12. `instrument-observability` — the Node.js OBO path

Section 11 is Python-only. Node.js does not share that defect: its `AgenticTokenCacheInstance` splits the work that Python collapses into one `async def`, and the shipped types confirm the split.

```ts
getObservabilityToken(agentId, tenantId): string | null;   // sync cache read — the resolver
refreshObservabilityToken(...): Promise<void>;             // async, awaited once per turn
```

Passing the sync getter as `tokenResolver` is therefore correct on Node. But the split creates a different failure with the same outcome — an agent that traces and exports nothing — and `SKILL.md` walks into it twice.

**The cache is only filled per turn.** `tokenResolver` reads a cache that nothing populates unless `refreshObservabilityToken` is called at the start of each handler turn. Miss it and the resolver returns `''` on every export. Upstream instructs the call in Phase 4 and names the symptom in its own troubleshooting table, so this one is documented — but nothing verified it, and the two halves live in different phases.

**The method name is wrong in `SKILL.md`.** It writes `AgenticTokenCacheInstance.RefreshObservabilityToken` — PascalCase, in the Phase 4 code sample a CLI copies verbatim. The shipped API is `refreshObservabilityToken`, camelCase since GA 1.0, which upstream's own reference doc states explicitly at the top of its auth table. The PascalCase name is `undefined`, so the call throws a `TypeError` on the agent's first turn. Both occurrences are corrected.

The kit adds two validator checks for the OBO path: a `tokenResolver` reading the cache with no `refreshObservabilityToken` anywhere, and the PascalCase spelling. Verified across three states — refresh missing, refresh misspelled, refresh correct.

Found 2026-09-04 while confirming whether the section 11 fix left Node.js exposed. Reported upstream.

---

## Kit add-ons — not Microsoft's

Everything under `.a365-kit/addons/` (and its copies in `.claude/skills/` and `.agents/skills/`) plus the two validators `validate-add-messaging-endpoint.js` and `validate-add-purview-dlp.js` is **written for this kit**, copyright Akram Eleyan, MIT. They follow upstream's skill format so every CLI discovers them the same way, but they are not part of `microsoft/agent365-skills` and should not be reported there.

| Add-on | Fills this gap | Basis |
|---|---|---|
| `add-messaging-endpoint` | `make-a365-agent` asks for a messaging endpoint but never creates the HTTP host; blueprint-based agents built from a CLI or library end up registered but unreachable. Adds the host, the tunnel, and the endpoint registration; hands off the one broker-bound step. | Python host verified live on `microsoft-agents` 1.6.0 (2026-09-04). Node.js and .NET reference upstream's own hosting layers, which need no change for this path. |
| `a365-kit` | Kit maintenance from inside the CLI: prerequisite check, versions, in-place update, and choosing the update source (public release or an internal mirror). Thin wrapper over the launchers. | Kit-authored. |
| `add-lab-tools` | Local in-process utility tools an agent otherwise lacks: web fetch / page summarise, encoders/decoders, hashing, text transforms. Dual-use (the web fetch is egress + prompt-injection surface); opt-in and clearly labelled. | Python verified live on a hosted agent (2026-09-04); Node.js and .NET are faithful ports awaiting a run. |
| `add-mcp-server` | Connects the agent to any external / community MCP server (filesystem, git, GitHub, Postgres, web fetch, Slack, Playwright, …) beyond Microsoft's Work IQ set. Governance boundary: external servers are NOT registered in Agent 365 or gated by Entra; opt-in, clearly labelled, paired with DLP guidance. | Python wiring pattern API-verified on the live SDK (`MCPServerStdio`/`StreamableHttp`); Node.js and .NET are faithful ports awaiting a run. |
| `add-purview-dlp` | Upstream has no Purview coverage. Evaluates every prompt and response against tenant DLP via two Graph calls; grants the scopes; hands off the portal policy. | Python adapted from the Agent 365 + Claude reference deployment's `purview_dlp.py`, which ran against a live tenant. The Node.js and .NET files are faithful ports of the same two REST calls, **not yet run against a tenant**; each marks the token-exchange line as the one to verify against the local SDK. |

The seven Microsoft skills are untouched by the add-ons: they reference upstream files, never modify them.

---

## What is *not* changed

- No phase ordering, decision matrix, or trigger phrases.
- No code patterns in `references/` beyond the token-resolver fix in section 11.
- No skill logic beyond the exporter switch in section 10, which is applied to bring the Node.js and Python paths into line with what upstream's .NET path already does.
- No validator check logic beyond the two bug fixes in sections 8 and 9, and no code pattern beyond the token-resolver fix in section 11 — the validators otherwise enforce exactly what upstream enforces.
- Nothing added to the skills. This kit contributes no Purview, hosting, or hardening content of its own to them; that lives in the separately labelled add-ons above.

## Reporting issues

Problems with the skills themselves — what they do, ask, or generate — belong upstream at
[microsoft/agent365-skills](https://github.com/microsoft/agent365-skills/issues). Problems with the
packaging, the launchers, the prerequisite doctor, or the build belong in this repository.

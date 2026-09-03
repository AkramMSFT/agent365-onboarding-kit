# How the repackaging works

Background for maintaining this kit. If you only want to *use* it, read `AGENT365-KIT-README.md` inside a build instead.

## The problem

Microsoft's `agent365-skills` is a **plugin**: seven `SKILL.md` playbooks, a set of Node validators wired as stop hooks, a `preToolUse` path guard, and shared reference docs. Plugins are installed — via marketplace, `--plugin-dir`, or `gh skill add` — and the host then sets `CLAUDE_PLUGIN_ROOT` so the skills can find their own sibling files.

Three things follow from that, and all three are install friction:

1. The install step itself varies per CLI, and at least one common Claude Code host does not expose `/plugin` at all.
2. `--plugin-dir` needs an absolute path, and fails confusingly from an elevated shell because per-user tools are not on the Administrator PATH.
3. The skills do not travel with the project. A teammate cloning the repo gets none of it.

## The idea

Every CLI already looks for skills *inside the project*. Nobody has to install anything if the skills are simply there:

| CLI | Looks in |
|---|---|
| Claude Code | `.claude/skills/<name>/SKILL.md` |
| VS Code agent mode, Copilot cloud agent, `gh skill` | `.agents/skills/<name>/SKILL.md` |
| GitHub Copilot CLI, VS Code Copilot Chat | `.github/copilot-instructions.md` |

So: ship all three surfaces in one archive.

## The layout, and why

The obvious approach — copy the skills into `.claude/skills/` and `.agents/skills/`, rewriting paths in each — produces two divergent copies and doubles every future fix.

Instead the kit keeps **one canonical tree** and treats the CLI-specific folders as pure copies:

```
.a365-kit/            canonical -- skills/, shared/, hooks/, plus kit-only files
.claude/skills/       copy of .a365-kit/skills/
.agents/skills/       copy of .a365-kit/skills/
```

The trick that makes the copies byte-identical: **`.a365-kit/` mirrors the upstream plugin layout exactly.** Upstream has `skills/`, `shared/`, `hooks/` under the plugin root; the kit has the same three under `.a365-kit/`. So every internal reference rewrites with a single substitution:

```
${CLAUDE_PLUGIN_ROOT}/...   ->   .a365-kit/...
```

No per-subpath logic, no divergence between copies, and cross-skill delegation (`make-ai-teammate` reading `a365-setup/SKILL.md`) resolves to the same canonical file no matter which CLI is driving.

Cost is roughly 1.5 MB of duplicated Markdown. Worth it.

## Two kinds of reference, two different rewrites

This distinction is the one thing to keep straight when maintaining the build.

**In-body references** are prose the model reads and resolves with its own file tools:

> **Read** `${CLAUDE_PLUGIN_ROOT}/shared/agent-detection.md` and follow it exactly.

These become **project-relative** (`.a365-kit/shared/agent-detection.md`). Relative works because the CLI's working directory is the project root, and — unlike a variable — it does not depend on the host expanding anything inside skill content.

**Hook commands** are executed by the host, not read by the model:

```yaml
command: node ${CLAUDE_PLUGIN_ROOT}/hooks/stop/validate-a365-setup.js
```

These become **absolute**, via `${CLAUDE_PROJECT_DIR}`, which Claude Code does expand in hook commands. It is quoted, because a project path with a space in it would otherwise split into two arguments:

```yaml
command: node "${CLAUDE_PROJECT_DIR}/.a365-kit/hooks/stop/validate-a365-setup.js"
```

Getting these backwards fails quietly: a relative hook command breaks whenever the CLI is started from a subdirectory, and an unexpanded variable in prose just makes the model read a file that is not there.

## The guard that switches itself off

`path-guard.js` blocks writes outside the project *and* writes into the plugin's own directory, so a skill cannot rewrite its own instructions. The second check is conditional:

```js
const pluginRoot = process.env.CLAUDE_PLUGIN_ROOT ? ... : null;
```

In a drop-in install that variable is unset, `pluginRoot` is `null`, and the check disappears — with no error and nothing in the output to notice. The build patches in a fallback to the kit folder. The environment variable still wins when present, so the file is unchanged in behaviour for a genuine plugin install.

This is the only modification with a security consequence, and it is covered by four test cases in the README's status list.

## Files the kit must not clobber

An archive extraction overwrites blindly, so anything commonly project-owned is staged rather than shipped in place:

| File | Handling |
|---|---|
| `.github/copilot-instructions.md` | Staged in `.a365-kit/`. `-WireCopilot` creates it, or **appends** to an existing one. |
| `.claude/settings.json` | Staged as `settings-fragment.json`. `-WireClaudeHook` creates it only if absent; otherwise it tells the user to merge by hand. |
| `.claude/skills/*`, `.agents/skills/*` | Shipped directly — the seven names are specific enough that collision is not a realistic concern. |

## Why the build verifies so aggressively

Every failure mode here is silent. An unexpanded variable, a stale `/agent365:` command, a reference to a file that moved — none of them throw. They surface later as a model reading a missing file mid-onboarding, in front of a customer.

So the build refuses to produce output unless it can prove the result is coherent:

- no `${CLAUDE_PLUGIN_ROOT}` path tokens remain (but a deliberate `process.env.CLAUDE_PLUGIN_ROOT` read is fine — the check targets the `${...}` form specifically)
- no `/agent365:` plugin command references remain
- every `.a365-kit/...` path referenced by a skill resolves to a real file
- every bundled JS file parses
- the discovery copies match the canonical skill set
- every hook command carries `${CLAUDE_PROJECT_DIR}`

The targeted text fix-ups also assert their own preconditions. If Microsoft rewords a patched passage, the build stops and names the file rather than emitting a mangled instruction.

## Upgrading to a new upstream version

```powershell
.\build\Build-Kit.ps1 -Zip
```

Nothing is hand-maintained; the build re-derives everything. Expect one of two outcomes:

- **It succeeds.** Smoke-test, bump `build/kit.version` if the packaging itself changed, commit `dist/`, cut a release.
- **A fix-up assertion fails.** Upstream reworded a passage the kit patches. Read the named file, update the fix-up in `Build-Kit.ps1`, rebuild.

If upstream ever restructures the plugin — renaming `skills/`, `shared/`, or `hooks/` — the layout-mirroring assumption breaks and the build fails early, at the upstream layout check.

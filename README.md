# Agent 365 Onboarding Kit

Microsoft's [`agent365-skills`](https://github.com/microsoft/agent365-skills), repackaged as a **drop-in folder**.

Download, extract into your agent project, run one script. No plugin install, no marketplace step, and no dependency on which coding CLI you use.

```
Download  ->  extract into your agent project  ->  ./agent365-kit.ps1  ->  "Onboard this agent to Agent 365."
```

---

## Why this exists

The upstream skills are excellent, but every documented install path assumes a specific host:

| Path | Requires |
|---|---|
| `/plugin marketplace add` | A Claude Code host that exposes `/plugin` — several do not |
| `claude --plugin-dir ...` | Knowing an absolute path, and a non-elevated shell |
| `gh skill add` | The `gh skill` extension |

Each is fine on its own; together they make "just try the skills" a support conversation. This kit removes the install step entirely: the skills travel **with the project**, in the locations each CLI already looks in.

It is a **faithful repackage**. The skill content is Microsoft's, unmodified except for the mechanical rewrites in [`NOTICE.md`](NOTICE.md).

## What a user gets

```
your-agent-project/
  .a365-kit/            canonical: skills, shared docs, validators, doctor
  .claude/skills/       discovery copy -- Claude Code
  .agents/skills/       discovery copy -- VS Code agent mode, Copilot cloud agent, gh skill
  agent365-kit.ps1      prereq check + per-CLI activation steps (Windows)
  agent365-kit.sh       same, macOS/Linux
  AGENT365-KIT-README.md
```

Skill files are byte-identical across all three locations, because every internal reference points at `.a365-kit/`. See [`docs/HOW-IT-WORKS.md`](docs/HOW-IT-WORKS.md).

## Supported CLIs

| CLI | Discovery path | Validator hooks |
|---|---|---|
| Claude Code | `.claude/skills/` | Yes |
| VS Code agent mode / Copilot cloud agent | `.agents/skills/` | No |
| GitHub Copilot CLI | `.github/copilot-instructions.md` (opt-in) | No |
| Anything else | point it at `.a365-kit/skills/a365-setup/SKILL.md` | No |

The skills are plain Markdown. Only the Node validator hooks are Claude Code specific, and they are optional — the skills work without them, just without the end-of-session correctness check.

---

## Building

Requires PowerShell 7+, Git, and Node.js.

```powershell
# Build from a local clone of upstream
.\build\Build-Kit.ps1 -UpstreamPath C:\src\agent365-skills

# Or let it shallow-clone upstream itself, and produce a release zip
.\build\Build-Kit.ps1 -Zip
```

Output lands in `dist/`. With `-Zip` you also get `agent365-onboarding-kit-v<version>.zip` at the repo root, ready to attach to a GitHub release.

### Refreshing when Microsoft ships a new version

```powershell
.\build\Build-Kit.ps1 -Zip
```

That is the whole process. The build re-derives everything from upstream; nothing is hand-maintained. Bump `build/kit.version` if the kit's own packaging changed.

The build **fails loudly** rather than shipping something subtly broken. It verifies that:

- no `${CLAUDE_PLUGIN_ROOT}` path tokens survive (they resolve to nothing without a plugin)
- no `/agent365:` plugin command references survive (that namespace does not exist here)
- every `.a365-kit/...` path a skill references actually exists in the output
- every bundled JS file parses
- the discovery copies match the canonical skill set
- every hook command was repointed to `${CLAUDE_PROJECT_DIR}`

It also asserts that its own targeted text fix-ups still match upstream. If Microsoft rewords a passage the kit patches, the build stops and names the file, instead of silently emitting nonsense.

## Repository layout

| Path | Purpose |
|---|---|
| `build/Build-Kit.ps1` | The build. Derives `dist/` from upstream. |
| `build/kit.version` | This kit's packaging version. |
| `payload/` | Hand-written files copied into every build — launchers, doctor, README. |
| `dist/` | Built output. Committed so the repo can be downloaded and used directly. |
| `docs/HOW-IT-WORKS.md` | The repackaging design and why each rewrite is needed. |

## Status

Verified on Windows 11 against upstream v1.0.2:

- builds clean with all verification passing
- Claude Code discovers all seven skills from `.claude/skills/` with no plugin install
- the patched path guard correctly blocks writes into the kit and outside the project, and allows writes to agent source
- stop validators run and correctly report an un-instrumented project
- Copilot wiring creates the instructions file, and appends to a pre-existing one without data loss

Not yet exercised: a full live onboarding run driven end to end through the kit, and the `.agents/skills/` path under VS Code agent mode.

## Licence

This packaging is MIT licensed — see [`LICENSE`](LICENSE). The bundled skills are © Microsoft Corporation, also MIT. See [`NOTICE.md`](NOTICE.md) for attribution and the exact list of modifications.

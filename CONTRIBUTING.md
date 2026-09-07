# Contributing

Thanks for taking a look. This repository has one unusual rule that is worth reading before you change anything.

## Where a change belongs

Most of what ships is **generated**. `dist/` is rebuilt from scratch on every build, so edits made there are silently discarded the next time anyone runs the build.

| You want to change | Edit |
|---|---|
| Microsoft's skill content | the fix-up list in [`build/Build-Kit.ps1`](build/Build-Kit.ps1) |
| An add-on, launcher, or validator written for this kit | [`payload/`](payload/) |
| Build behaviour or a verification check | [`build/Build-Kit.ps1`](build/Build-Kit.ps1) |
| Documentation | `README.md`, `GUIDE.md`, `NOTICE.md`, `docs/` |
| Anything in `dist/` | nothing — rebuild instead |

## Issues that belong upstream

This project repackages [microsoft/agent365-skills](https://github.com/microsoft/agent365-skills). If the problem is with what a skill *does* — the questions it asks, the code it generates, the order of its phases — report it at [their issue tracker](https://github.com/microsoft/agent365-skills/issues), not here.

Report here anything about the packaging, the launchers, the prerequisite checker, the build, the add-ons, or the documentation.

If you are not sure which it is, open it here and we will move it.

## Changing Microsoft's skills

Every edit to upstream content is a **fix-up**: an entry in the `$fixups` array that names a file, the exact text it expects to find, and the replacement.

```powershell
@{
    File = 'skills\instrument-observability\SKILL.md'
    Find = @'
<the exact upstream text>
'@
    Replace = @'
<the replacement>
'@
}
```

The `Find` block must match upstream exactly. If it does not, the build throws rather than continuing, which is deliberate: an upstream rewording should stop the build loudly instead of producing a patched file that no longer says what we assumed.

Three things are expected of a fix-up:

1. **A comment above it** naming the defect and the `NOTICE.md` section that documents it.
2. **An entry in [`NOTICE.md`](NOTICE.md)** explaining the failure it prevents, with upstream's own justification where one exists — several fixes exist only to make one language behave the way another already does.
3. **Evidence.** Say how you know. "Compiled and ran", "verified against a live tenant", "read from the shipped SDK source" and "transcribed, not yet run" are all acceptable; leaving it unsaid is not.

Prefer fixing the skill over fixing only the validator. Validator hooks run under Claude Code and nothing else, so a validator-only fix leaves every other CLI unprotected.

## Building

Requires PowerShell 7+, Git and Node.js.

```powershell
.\build\Build-Kit.ps1 -Zip
```

The build fails rather than emitting output it cannot verify. A green build means no dangling path tokens, every referenced path resolves, every bundled JS file parses, the discovery copies match, and every fix-up still matched its upstream text.

`node --check` is not sufficient on its own for validator changes — it accepts code that fails to load as a CommonJS module. Run the validator against a real project before committing.

## Testing a change

Validators should be exercised against both the broken and the correct pattern, plus whatever is most likely to produce a false positive. A check that fires on correct code is worse than no check, because it trains people to ignore it.

For skill changes, the meaningful test is a CLI actually reading the skill and producing something that builds and runs.

## Commits

Explain the failure the change prevents, not only the change. The commit log is the record of why the kit differs from upstream, and it is expected to be readable a year later by someone deciding whether to trust it.

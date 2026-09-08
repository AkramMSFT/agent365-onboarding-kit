#!/usr/bin/env bash
# Agent 365 Onboarding Kit -- prerequisite check and per-CLI activation steps.
#
# Run this from the root of your agent project after extracting the kit into it.
# The script does not onboard anything itself -- the skills do that. It checks
# that the kit landed correctly, verifies prerequisites, detects which agentic
# CLIs you have, and prints the exact steps to load the skills in each one.
#
# Usage:
#   ./agent365-kit.sh                 check prerequisites, print activation steps
#   ./agent365-kit.sh --doctor-only   check prerequisites and stop
#   ./agent365-kit.sh --skip-doctor   skip the prerequisite check
#   ./agent365-kit.sh --wire-copilot  create/append .github/copilot-instructions.md
#   ./agent365-kit.sh --launch claude launch Claude Code with the trigger phrase
#   ./agent365-kit.sh --update        replace the kit with the latest release (kit paths only)
#   ./agent365-kit.sh --update --update-from <zip|url>   ...one-off, from a local zip or another URL
#   ./agent365-kit.sh --set-update-source <zip|url>      persist the source for this project
#                                     (a365-kit.config.json; commit it). Empty string clears it.
#   Source resolution: --update-from > $A365_KIT_UPDATE_SOURCE > a365-kit.config.json
#                      > build default in .a365-kit/KIT-VERSION.json > public GitHub release

set -euo pipefail

TRIGGER='Onboard this agent to Agent 365.'

KIT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

DOCTOR_ONLY=0
SKIP_DOCTOR=0
WIRE_COPILOT=0
WIRE_CLAUDE_HOOK=0
LAUNCH=''
UPDATE=0
UPDATE_FROM=''
SET_UPDATE_SOURCE=''
SET_UPDATE_SOURCE_GIVEN=0
PUBLIC_SOURCE='https://github.com/AkramMSFT/agent365-onboarding-kit/releases/latest/download/agent365-onboarding-kit-latest.zip'
KIT_CONFIG="$KIT_ROOT/a365-kit.config.json"

while [ $# -gt 0 ]; do
  case "$1" in
    --doctor-only)        DOCTOR_ONLY=1 ;;
    --skip-doctor)        SKIP_DOCTOR=1 ;;
    --wire-copilot)       WIRE_COPILOT=1 ;;
    --wire-claude-hook)   WIRE_CLAUDE_HOOK=1 ;;
    --launch)             shift; LAUNCH="${1:-}" ;;
    --update)             UPDATE=1 ;;
    --update-from)        shift; UPDATE_FROM="${1:-}" ;;
    --set-update-source)  shift; SET_UPDATE_SOURCE="${1:-}"; SET_UPDATE_SOURCE_GIVEN=1 ;;
    -h|--help)            sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "Unknown option: $1" >&2; exit 2 ;;
  esac
  shift
done

# -- Update source ------------------------------------------------------------
# Resolved so an organisation that mirrors the kit internally can pin it once.
resolve_update_source() {
  if [ -n "$UPDATE_FROM" ]; then echo "$UPDATE_FROM|--update-from"; return; fi
  if [ -n "${A365_KIT_UPDATE_SOURCE:-}" ]; then echo "$A365_KIT_UPDATE_SOURCE|A365_KIT_UPDATE_SOURCE"; return; fi
  if [ -f "$KIT_CONFIG" ] && command -v node >/dev/null 2>&1; then
    v="$(node -e 'try{const c=require(process.argv[1]);process.stdout.write(c.updateSource||"")}catch(e){}' "$KIT_CONFIG")"
    if [ -n "$v" ]; then echo "$v|a365-kit.config.json"; return; fi
  fi
  if [ -f "$KIT_ROOT/.a365-kit/KIT-VERSION.json" ] && command -v node >/dev/null 2>&1; then
    v="$(node -e 'try{const c=require(process.argv[1]);process.stdout.write(c.updateSource||"")}catch(e){}' "$KIT_ROOT/.a365-kit/KIT-VERSION.json")"
    if [ -n "$v" ]; then echo "$v|kit build default"; return; fi
  fi
  echo "$PUBLIC_SOURCE|public GitHub release"
}

if [ "$SET_UPDATE_SOURCE_GIVEN" -eq 1 ]; then
  command -v node >/dev/null 2>&1 || { echo "  node is required (it is a kit prerequisite)" >&2; exit 1; }
  node -e '
    const fs=require("fs"); const p=process.argv[1]; const v=process.argv[2];
    let c={}; try{ c=JSON.parse(fs.readFileSync(p,"utf8")); }catch(e){}
    if (v.trim()==="") delete c.updateSource; else c.updateSource=v;
    fs.writeFileSync(p, JSON.stringify(c,null,2)+"\n");' "$KIT_CONFIG" "$SET_UPDATE_SOURCE"
  if [ -z "${SET_UPDATE_SOURCE// }" ]; then echo "  cleared the project update source."; else echo "  project update source set to: $SET_UPDATE_SOURCE"; fi
  echo "  written to a365-kit.config.json -- commit it so your whole team updates from the same place."
  r="$(resolve_update_source)"; echo "  --update will now use: ${r%%|*}  [${r##*|}]"
  exit 0
fi

# -- 0. Self-update -------------------------------------------------------------
# Replaces kit paths only; the user's agent, .env, config and .claude/settings.json
# are never touched. Skill folders to replace come from the NEW kit's manifest
# (plus the old one's, so a skill upstream removed is removed here too).

if [ "$UPDATE" -eq 1 ]; then
  # Node is a hard prerequisite of the kit (the validators run on it), so it is the
  # one JSON reader we can rely on. python3 is deliberately NOT used: on Windows it
  # often resolves to the Store alias stub, which prints an error and returns nothing.
  command -v node >/dev/null 2>&1 || { echo "  node is required to read the kit manifest (it is a kit prerequisite)" >&2; exit 1; }
  r="$(resolve_update_source)"; UPDATE_FROM="${r%%|*}"
  echo "  source  : $UPDATE_FROM  [${r##*|}]"
  STAGE="$(mktemp -d)"
  trap 'rm -rf "$STAGE"' EXIT
  ZIP="$STAGE/kit.zip"
  case "$UPDATE_FROM" in
    http://*|https://*) echo "  downloading $UPDATE_FROM"; curl -fsSL -o "$ZIP" "$UPDATE_FROM" ;;
    *) [ -f "$UPDATE_FROM" ] || { echo "  not found: $UPDATE_FROM" >&2; exit 1; }; cp "$UPDATE_FROM" "$ZIP" ;;
  esac
  NEW="$STAGE/new"; mkdir -p "$NEW"
  if command -v unzip >/dev/null 2>&1; then unzip -q -o "$ZIP" -d "$NEW"
  else tar -xf "$ZIP" -C "$NEW"; fi          # bsdtar (macOS, Windows 10+) extracts zips
  [ -f "$NEW/.a365-kit/KIT-VERSION.json" ] || { echo "  that archive is not an Agent 365 Onboarding Kit" >&2; exit 1; }
  desc()  { node -e 'const d=require(process.argv[1]);console.log(`kit v${d.kitVersion} / upstream v${d.upstreamVersion} (${d.upstreamCommit})`)' "$1"; }
  names() { node -e 'const d=require(process.argv[1]);console.log([...(d.skills||[]),...(d.addons||[])].join("\n"))' "$1"; }
  OLD_M="$KIT_ROOT/.a365-kit/KIT-VERSION.json"
  echo "  current : $([ -f "$OLD_M" ] && desc "$OLD_M" || echo 'no kit installed')"
  echo "  new     : $(desc "$NEW/.a365-kit/KIT-VERSION.json")"
  NAMES="$(names "$NEW/.a365-kit/KIT-VERSION.json"; [ -f "$OLD_M" ] && names "$OLD_M")"
  NAMES="$(printf '%s\n' "$NAMES" | sort -u | sed '/^$/d')"
  rm -rf "$KIT_ROOT/.a365-kit"; cp -R "$NEW/.a365-kit" "$KIT_ROOT/.a365-kit"
  for DISC in .claude/skills .agents/skills; do
    mkdir -p "$KIT_ROOT/$DISC"
    while IFS= read -r NAME; do
      rm -rf "$KIT_ROOT/$DISC/$NAME"
      [ -d "$NEW/$DISC/$NAME" ] && cp -R "$NEW/$DISC/$NAME" "$KIT_ROOT/$DISC/$NAME"
    done <<< "$NAMES"
  done
  for F in agent365-kit.ps1 agent365-kit.sh AGENT365-KIT-README.md; do
    [ -f "$NEW/$F" ] && cp "$NEW/$F" "$KIT_ROOT/$F"
  done
  chmod +x "$KIT_ROOT/agent365-kit.sh" 2>/dev/null || true
  echo "  kit updated. Your agent files, .env, a365 config and .claude/settings.json were not touched."
  echo "  re-run ./agent365-kit.sh to use the new launcher."
  exit 0
fi

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  C_RESET=$'\033[0m'; C_BOLD=$'\033[1m'; C_DIM=$'\033[2m'
  C_RED=$'\033[31m'; C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'; C_CYAN=$'\033[36m'
else
  C_RESET=''; C_BOLD=''; C_DIM=''; C_RED=''; C_GREEN=''; C_YELLOW=''; C_CYAN=''
fi

head_()  { printf '\n%s%s%s\n' "$C_CYAN" "$1" "$C_RESET"; }
ok_()    { printf '  [%s ok %s] %s\n' "$C_GREEN" "$C_RESET" "$1"; }
warn_()  { printf '  [%swarn%s] %s\n' "$C_YELLOW" "$C_RESET" "$1"; }
err_()   { printf '  [%sFAIL%s] %s\n' "$C_RED" "$C_RESET" "$1"; }
note_()  { printf '  %s%s%s\n' "$C_DIM" "$1" "$C_RESET"; }
cmd_()   { printf '      %s%s%s\n' "$C_BOLD" "$1" "$C_RESET"; }

printf '\n%sAgent 365 Onboarding Kit%s\n' "$C_BOLD" "$C_RESET"
printf '%s========================%s\n' "$C_DIM" "$C_RESET"

# -- 1. Confirm the kit landed in the right place -----------------------------

CANONICAL="$KIT_ROOT/.a365-kit/skills/a365-setup/SKILL.md"
if [ ! -f "$CANONICAL" ]; then
  echo ''
  err_ 'Could not find .a365-kit/skills/a365-setup/SKILL.md next to this script.'
  echo ''
  note_ 'Extract the kit into the ROOT of your agent project, so the kit folders sit'
  note_ 'alongside your agent source. Expected layout:'
  echo ''
  note_ '    your-agent-project/'
  note_ '      .a365-kit/'
  note_ '      .claude/skills/'
  note_ '      .agents/skills/'
  note_ '      agent365-kit.sh'
  note_ '      <your agent source>'
  echo ''
  exit 1
fi

SKILL_COUNT="$(find "$KIT_ROOT/.a365-kit/skills" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l | tr -d ' ')"
ADDON_COUNT="$(find "$KIT_ROOT/.a365-kit/addons" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l | tr -d ' ')"
TOTAL_SKILLS="$((SKILL_COUNT + ADDON_COUNT))"
echo ''
ok_ "Kit layout looks correct ($TOTAL_SKILLS skills: $SKILL_COUNT Microsoft, $ADDON_COUNT add-ons)"

cd "$KIT_ROOT"

# -- 2. Prerequisites ---------------------------------------------------------

if [ "$SKIP_DOCTOR" -eq 0 ]; then
  if ! command -v node >/dev/null 2>&1; then
    echo ''
    err_ 'Node.js is not installed (or not on PATH).'
    echo ''
    note_ 'Node.js runs the prerequisite check and the skill validators. Install it:'
    echo ''
    cmd_ 'brew install node        # or https://nodejs.org'
    echo ''
    note_ 'Then open a NEW terminal and re-run this script.'
    echo ''
    exit 1
  fi

  if ! node "$KIT_ROOT/.a365-kit/doctor.js"; then
    note_ 'Install the missing prerequisites above, then re-run this script.'
    note_ '(Open a NEW terminal afterwards so PATH changes take effect.)'
    echo ''
    exit 1
  fi
fi

if [ "$DOCTOR_ONLY" -eq 1 ]; then
  note_ 'Prerequisite check complete. Re-run without --doctor-only for activation steps.'
  echo ''
  exit 0
fi

# -- 3. Optional wiring -------------------------------------------------------

if [ "$WIRE_COPILOT" -eq 1 ]; then
  head_ 'Wiring GitHub Copilot instructions'
  SRC="$KIT_ROOT/.a365-kit/copilot-instructions.md"
  DST="$KIT_ROOT/.github/copilot-instructions.md"
  if [ ! -f "$SRC" ]; then
    err_ 'Missing .a365-kit/copilot-instructions.md -- kit may be incomplete.'
  else
    mkdir -p "$KIT_ROOT/.github"
    if [ ! -f "$DST" ]; then
      cp "$SRC" "$DST"
      ok_ 'Created .github/copilot-instructions.md'
    elif grep -q 'Agent 365 Skills' "$DST"; then
      ok_ 'Already wired -- .github/copilot-instructions.md mentions Agent 365.'
    else
      # Append rather than overwrite: this file is commonly project-owned.
      { printf '\n\n---\n\n'; cat "$SRC"; } >> "$DST"
      ok_ 'Appended Agent 365 instructions to your existing .github/copilot-instructions.md'
    fi
  fi
fi

if [ "$WIRE_CLAUDE_HOOK" -eq 1 ]; then
  head_ 'Wiring the optional upstream-version notice'
  SETTINGS="$KIT_ROOT/.claude/settings.json"
  if [ -f "$SETTINGS" ]; then
    warn_ 'This project already has .claude/settings.json -- leaving it untouched.'
    note_ 'Merge the "hooks" block from .a365-kit/settings-fragment.json by hand.'
  else
    mkdir -p "$KIT_ROOT/.claude"
    cp "$KIT_ROOT/.a365-kit/settings-fragment.json" "$SETTINGS"
    ok_ 'Created .claude/settings.json'
  fi
fi

# -- 4. Detect CLIs and print activation steps --------------------------------

has_claude=0; has_gh_skill=0; has_gh_copilot_launcher=0; has_copilot_cli=0; has_code=0
command -v claude >/dev/null 2>&1 && has_claude=1
command -v code   >/dev/null 2>&1 && has_code=1

# `gh skill` and `gh copilot` are built into gh 2.98+, not extensions, and neither
# supports --version: `gh skill --version` errors with "unknown flag", and
# `gh copilot --version` reports on the *downloaded Copilot CLI*, not on gh itself.
# Probe --help for availability, and --version only to tell whether the Copilot CLI
# binary is actually present.
if command -v gh >/dev/null 2>&1; then
  gh skill   --help >/dev/null 2>&1 && has_gh_skill=1
  gh copilot --help >/dev/null 2>&1 && has_gh_copilot_launcher=1
fi
if command -v copilot >/dev/null 2>&1; then
  has_copilot_cli=1
elif [ "$has_gh_copilot_launcher" -eq 1 ] && gh copilot --version >/dev/null 2>&1; then
  has_copilot_cli=1
fi

head_ 'Detected CLIs'
[ "$has_claude" -eq 1 ] && ok_ 'Claude Code' || note_ '  --   Claude Code (not installed)'
if [ "$has_copilot_cli" -eq 1 ]; then
  ok_ 'GitHub Copilot CLI'
elif [ "$has_gh_copilot_launcher" -eq 1 ]; then
  note_ '  ~    GitHub Copilot CLI (not installed; gh will fetch it on first use)'
else
  note_ '  --   GitHub Copilot CLI (not available)'
fi
[ "$has_gh_skill" -eq 1 ] && ok_ 'gh skill (agent-skill installer)' || note_ '  --   gh skill (needs gh 2.98+)'
[ "$has_code" -eq 1 ]     && ok_ 'VS Code' || note_ '  --   VS Code (not installed)'

head_ 'How to start onboarding'
echo ''
note_ 'The skills are already in place. Pick your CLI:'
echo ''

printf '  %sClaude Code%s\n' "$C_BOLD" "$C_RESET"
note_ '    Project skills in .claude/skills/ load automatically. From this folder:'
cmd_ 'claude'
note_ '    then type:'
cmd_ "\"$TRIGGER\""
echo ''

printf '  %sGitHub Copilot CLI%s\n' "$C_BOLD" "$C_RESET"
note_ '    Reads .agents/skills/ automatically. From this folder:'
cmd_ 'gh copilot'
note_ '    then type the phrase above. For extra grounding, also wire the'
note_ '    instructions file once:'
cmd_ './agent365-kit.sh --wire-copilot'
echo ''

printf '  %sVS Code (Copilot agent mode)%s\n' "$C_BOLD" "$C_RESET"
note_ '    Open this folder in VS Code, switch Copilot Chat to Agent mode,'
note_ '    confirm the skills with /skills list, then ask using the phrase above.'
echo ''

printf '  %sCursor, Codex, Gemini CLI, Amp, Cline, OpenCode, Warp, Antigravity%s\n' "$C_BOLD" "$C_RESET"
note_ '    All of these share the .agents/skills/ directory at project scope, so the'
note_ '    skills are already where they look. Open this folder and use the phrase above.'
echo ''

printf '  %sAny other agentic CLI%s\n' "$C_BOLD" "$C_RESET"
note_ '    Point it at .a365-kit/skills/a365-setup/SKILL.md and tell it to follow that file.'
note_ '    The skills are plain Markdown -- nothing is Claude-specific except the'
note_ '    validator hooks, which are optional.'
echo ''
note_ 'Full per-CLI walkthrough: docs/USING-WITH-YOUR-CLI.md in the kit repository.'
echo ''

head_ 'What you can ask for'
echo ''
note_ 'Say these in whichever CLI you picked. You do not need to know skill names.'
echo ''

printf '  %sCore%s
' "$C_BOLD" "$C_RESET"
cmd_ '"Onboard this agent to Agent 365."'
note_ '        blueprint, Entra identity, permissions'
cmd_ '"Add observability to this agent."'
note_ '        OpenTelemetry and the Agent 365 exporter'
cmd_ '"Add WorkIQ tools to this agent."'
note_ '        Microsoft 365 data: mail, calendar, Teams, SharePoint'
cmd_ '"Validate A365 code."'
note_ '        read-only check of telemetry, identity binding and grants'
echo ''

if [ -d "$KIT_ROOT/.a365-kit/addons" ]; then
  printf '  %sAdd-ons in this kit%s
' "$C_BOLD" "$C_RESET"
  for addon_dir in "$KIT_ROOT"/.a365-kit/addons/*/; do
    [ -d "$addon_dir" ] || continue
    addon_name="$(basename "$addon_dir")"
    case "$addon_name" in
      add-messaging-endpoint)
        cmd_ '"Make this agent chattable in Teams."'
        note_ '        HTTP host, dev tunnel, endpoint registration' ;;
      test-local-channel)
        cmd_ '"Let me test this agent locally."'
        note_ '        loopback-only dev channel: no tunnel, no tenant, no Teams' ;;
      add-mcp-server)
        cmd_ '"Add an MCP server."'
        note_ '        any external MCP server -- not governed by Agent 365' ;;
      add-lab-tools)
        cmd_ '"Add lab tools."'
        note_ '        local utilities: web fetch, encoders, hashing, text transforms' ;;
      add-purview-dlp)
        cmd_ '"Add DLP to this agent."'
        note_ '        Purview checks every prompt and response' ;;
      add-java-agent)
        cmd_ '"Onboard this Java agent."'
        note_ '        hosting and telemetry for Java, which has no Microsoft SDK' ;;
      a365-kit)
        cmd_ '"Update the Agent 365 kit."'
        note_ '        replaces only the kit files, never your agent' ;;
      *)
        cmd_ "\"$addon_name\""
        note_ "        see .a365-kit/addons/$addon_name/SKILL.md" ;;
    esac
  done
  echo ''
fi

printf '  %s---%s\n' "$C_DIM" "$C_RESET"
note_ 'a365-setup is the entry point. It checks prerequisites, asks which capabilities'
note_ 'you want, then hands off to make-ai-teammate or make-a365-agent.'
echo ''

# -- 5. Optional launch -------------------------------------------------------

if [ "$LAUNCH" = 'claude' ]; then
  if [ "$has_claude" -eq 0 ]; then
    err_ 'Claude Code CLI not found on PATH.'
    note_ 'Install it with:  npm install -g @anthropic-ai/claude-code'
    echo ''
    exit 1
  fi
  head_ 'Launching Claude Code'
  echo ''
  exec claude "$TRIGGER"
fi

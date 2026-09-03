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

set -euo pipefail

TRIGGER='Onboard this agent to Agent 365.'

KIT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

DOCTOR_ONLY=0
SKIP_DOCTOR=0
WIRE_COPILOT=0
WIRE_CLAUDE_HOOK=0
LAUNCH=''

while [ $# -gt 0 ]; do
  case "$1" in
    --doctor-only)      DOCTOR_ONLY=1 ;;
    --skip-doctor)      SKIP_DOCTOR=1 ;;
    --wire-copilot)     WIRE_COPILOT=1 ;;
    --wire-claude-hook) WIRE_CLAUDE_HOOK=1 ;;
    --launch)           shift; LAUNCH="${1:-}" ;;
    -h|--help)          sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "Unknown option: $1" >&2; exit 2 ;;
  esac
  shift
done

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

SKILL_COUNT="$(find "$KIT_ROOT/.a365-kit/skills" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')"
echo ''
ok_ "Kit layout looks correct ($SKILL_COUNT skills)"

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

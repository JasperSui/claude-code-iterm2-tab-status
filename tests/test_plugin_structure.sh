#!/usr/bin/env bash
set -euo pipefail

PASS=0
FAIL=0
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

pass() { PASS=$((PASS + 1)); echo "  ✓ $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  ✗ $1: $2"; }

# ── 1. Required plugin files exist ──────────────────────────────────────────

echo "=== Required plugin files ==="

echo "Test: .claude-plugin/plugin.json exists and is valid JSON"
PLUGIN_JSON="$PROJECT_ROOT/.claude-plugin/plugin.json"
if [[ -f "$PLUGIN_JSON" ]]; then
  pass "plugin.json exists"
  if python3 -c "import json; json.load(open('$PLUGIN_JSON'))" 2>/dev/null; then
    pass "plugin.json is valid JSON"
  else
    fail "plugin.json" "not valid JSON"
  fi
else
  fail "plugin.json" "file not found"
fi

echo "Test: hooks/hooks.json exists and is valid JSON"
HOOKS_JSON="$PROJECT_ROOT/hooks/hooks.json"
if [[ -f "$HOOKS_JSON" ]]; then
  pass "hooks.json exists"
  if python3 -c "import json; json.load(open('$HOOKS_JSON'))" 2>/dev/null; then
    pass "hooks.json is valid JSON"
  else
    fail "hooks.json" "not valid JSON"
  fi
else
  fail "hooks.json" "file not found"
fi

# ── 2. plugin.json has required fields ──────────────────────────────────────

echo ""
echo "=== plugin.json required fields ==="

if [[ -f "$PLUGIN_JSON" ]]; then
  echo "Test: name is 'iterm2-tab-status'"
  name=$(python3 -c "import json; print(json.load(open('$PLUGIN_JSON'))['name'])" 2>/dev/null || echo "")
  if [[ "$name" == "iterm2-tab-status" ]]; then
    pass "name is 'iterm2-tab-status'"
  else
    fail "name" "expected 'iterm2-tab-status', got '$name'"
  fi

  echo "Test: version matches semver pattern"
  version=$(python3 -c "import json; print(json.load(open('$PLUGIN_JSON'))['version'])" 2>/dev/null || echo "")
  if [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    pass "version '$version' matches semver"
  else
    fail "version" "expected semver, got '$version'"
  fi

  echo "Test: description exists and is non-empty"
  description=$(python3 -c "import json; print(json.load(open('$PLUGIN_JSON'))['description'])" 2>/dev/null || echo "")
  if [[ -n "$description" ]]; then
    pass "description is non-empty"
  else
    fail "description" "empty or missing"
  fi

  echo "Test: license is 'MIT'"
  license=$(python3 -c "import json; print(json.load(open('$PLUGIN_JSON'))['license'])" 2>/dev/null || echo "")
  if [[ "$license" == "MIT" ]]; then
    pass "license is 'MIT'"
  else
    fail "license" "expected 'MIT', got '$license'"
  fi
else
  fail "plugin.json fields" "file not found, skipping all field checks"
fi

# ── 3. hooks.json structure ─────────────────────────────────────────────────

echo ""
echo "=== hooks.json structure ==="

if [[ -f "$HOOKS_JSON" ]]; then
  echo "Test: has 'hooks' top-level key"
  has_hooks=$(python3 -c "import json; d=json.load(open('$HOOKS_JSON')); print('hooks' in d)" 2>/dev/null || echo "")
  if [[ "$has_hooks" == "True" ]]; then
    pass "has 'hooks' top-level key"
  else
    fail "hooks key" "missing 'hooks' top-level key"
  fi

  echo "Test: has required hook events"
  for event in SessionStart Notification UserPromptSubmit Stop PreToolUse PostToolUse PostToolUseFailure; do
    has_event=$(python3 -c "import json; d=json.load(open('$HOOKS_JSON')); print('$event' in d.get('hooks', {}))" 2>/dev/null || echo "")
    if [[ "$has_event" == "True" ]]; then
      pass "has '$event' hook event"
    else
      fail "hook event" "missing '$event'"
    fi
  done

  echo "Test: all hook commands reference \${CLAUDE_PLUGIN_ROOT}/scripts/ paths"
  bad_commands=$(python3 -c "
import json
d = json.load(open('$HOOKS_JSON'))
for event, entries in d.get('hooks', {}).items():
    for entry in entries:
        for hook in entry.get('hooks', []):
            cmd = hook.get('command', '')
            if '\${CLAUDE_PLUGIN_ROOT}/scripts/' not in cmd:
                print(f'{event}: {cmd}')
" 2>/dev/null)
  if [[ -z "$bad_commands" ]]; then
    pass "all commands reference \${CLAUDE_PLUGIN_ROOT}/scripts/"
  else
    fail "hook commands" "non-conforming commands: $bad_commands"
  fi

  echo "Test: all referenced scripts actually exist"
  missing_scripts=$(python3 -c "
import json, os
d = json.load(open('$HOOKS_JSON'))
root = '$PROJECT_ROOT'
for event, entries in d.get('hooks', {}).items():
    for entry in entries:
        for hook in entry.get('hooks', []):
            cmd = hook.get('command', '')
            script = cmd.replace('\${CLAUDE_PLUGIN_ROOT}', root).split()[0]
            if not os.path.isfile(script):
                print(script)
" 2>/dev/null)
  if [[ -z "$missing_scripts" ]]; then
    pass "all referenced scripts exist (bootstrap.sh, hook.sh)"
  else
    fail "referenced scripts" "missing: $missing_scripts"
  fi
else
  fail "hooks.json structure" "file not found, skipping all structure checks"
fi

# ── 4. Commands directory ───────────────────────────────────────────────────

echo ""
echo "=== Commands directory ==="

for cmd_file in setup.md uninstall.md; do
  cmd_path="$PROJECT_ROOT/commands/$cmd_file"
  echo "Test: commands/$cmd_file exists and has YAML frontmatter with description"
  if [[ -f "$cmd_path" ]]; then
    pass "commands/$cmd_file exists"
    # Check for YAML frontmatter: starts with --- and contains description
    if head -1 "$cmd_path" | grep -q '^---$'; then
      if grep -q '^description:' "$cmd_path"; then
        pass "commands/$cmd_file has YAML frontmatter with description"
      else
        fail "commands/$cmd_file" "YAML frontmatter missing 'description' field"
      fi
    else
      fail "commands/$cmd_file" "missing YAML frontmatter (no leading ---)"
    fi
  else
    fail "commands/$cmd_file" "file not found"
  fi
done

# ── 5. Scripts ──────────────────────────────────────────────────────────────

echo ""
echo "=== Scripts ==="

echo "Test: scripts/hook.sh exists and is executable"
HOOK_SH="$PROJECT_ROOT/scripts/hook.sh"
if [[ -f "$HOOK_SH" ]]; then
  pass "scripts/hook.sh exists"
  if [[ -x "$HOOK_SH" ]]; then
    pass "scripts/hook.sh is executable"
  else
    fail "scripts/hook.sh" "not executable"
  fi
else
  fail "scripts/hook.sh" "file not found"
fi

echo "Test: scripts/bootstrap.sh exists and is executable"
BOOTSTRAP_SH="$PROJECT_ROOT/scripts/bootstrap.sh"
if [[ -f "$BOOTSTRAP_SH" ]]; then
  pass "scripts/bootstrap.sh exists"
  if [[ -x "$BOOTSTRAP_SH" ]]; then
    pass "scripts/bootstrap.sh is executable"
  else
    fail "scripts/bootstrap.sh" "not executable"
  fi
else
  fail "scripts/bootstrap.sh" "file not found"
fi

echo "Test: scripts/claude_tab_status.py exists"
PY_SCRIPT="$PROJECT_ROOT/scripts/claude_tab_status.py"
if [[ -f "$PY_SCRIPT" ]]; then
  pass "scripts/claude_tab_status.py exists"
else
  fail "scripts/claude_tab_status.py" "file not found"
fi

# ── 6. No stale files ──────────────────────────────────────────────────────

echo ""
echo "=== No stale files ==="

STALE_FILES=("install.sh" "install-remote.sh" "hook-clear.sh")
for stale in "${STALE_FILES[@]}"; do
  echo "Test: no stale '$stale' in project root or scripts/"
  if [[ -f "$PROJECT_ROOT/$stale" || -f "$PROJECT_ROOT/scripts/$stale" ]]; then
    fail "stale file" "'$stale' still exists"
  else
    pass "no stale '$stale'"
  fi
done

# ── Summary ─────────────────────────────────────────────────────────────────

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]] && exit 0 || exit 1

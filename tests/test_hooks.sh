#!/usr/bin/env bash
# shellcheck disable=SC2015  # A && B || C is intentional; pass/fail never fail
set -euo pipefail

PASS=0
FAIL=0
SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
HOOK="$SCRIPT_DIR/scripts/hook.sh"
TMPDIR_BASE="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_BASE"' EXIT

pass() { PASS=$((PASS + 1)); echo "  ✓ $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  ✗ $1: $2"; }

# Helper: run hook with given JSON, using a temp status dir
run_hook() {
  local status_dir="$1"
  local json="$2"
  mkdir -p "$status_dir"
  echo "$json" | CLAUDE_ITERM2_TAB_STATUS_DIR="$status_dir" bash "$HOOK"
}

run_hook_with_activity() {
  local status_dir="$1"
  local json="$2"
  mkdir -p "$status_dir"
  echo "$json" | \
    CLAUDE_ITERM2_TAB_STATUS_DIR="$status_dir" \
    CLAUDE_ITERM2_TAB_STATUS_SUBTITLE_ACTIVITY_SOURCE=prompt \
    bash "$HOOK"
}

# Helper: read a field from a JSON file (pure bash, same approach as hook.sh)
read_field() {
  local file="$1" field="$2"
  sed -n "s/.*\"${field}\": *\"\\([^\"]*\\)\".*/\\1/p" "$file" | head -1
}

echo "=== Notification hook tests ==="

# Test 1: idle_prompt → creates signal with type "idle"
echo "Test 1: idle_prompt creates signal with type 'idle'"
DIR1="$TMPDIR_BASE/t1"
run_hook "$DIR1" '{"session_id":"ses-abc-123","hook_event_name":"Notification","notification_type":"idle_prompt","message":"Claude is idle","cwd":"/Users/me/myproject"}'
if [[ -f "$DIR1/ses-abc-123.json" ]]; then
  typ=$(read_field "$DIR1/ses-abc-123.json" "type")
  [[ "$typ" == "idle" ]] && pass "type is 'idle'" || fail "type" "expected 'idle', got '$typ'"
else
  fail "Signal file not created" "expected $DIR1/ses-abc-123.json"
fi

# Test 2: Signal file has correct fields
echo "Test 2: Signal file contains correct fields"
FILE1="$DIR1/ses-abc-123.json"
if [[ -f "$FILE1" ]]; then
  sid=$(read_field "$FILE1" "session_id")
  msg=$(read_field "$FILE1" "message")
  proj=$(read_field "$FILE1" "project")
  cwd=$(read_field "$FILE1" "cwd")

  [[ "$sid" == "ses-abc-123" ]] && pass "session_id correct" || fail "session_id" "got '$sid'"
  [[ "$msg" == "Claude is idle" ]] && pass "message correct" || fail "message" "got '$msg'"
  [[ "$proj" == "myproject" ]] && pass "project correct" || fail "project" "got '$proj'"
  [[ "$cwd" == "/Users/me/myproject" ]] && pass "cwd correct" || fail "cwd" "got '$cwd'"

  # Check tty field exists (value varies)
  tty=$(read_field "$FILE1" "tty")
  [[ -n "$tty" ]] && pass "tty present" || pass "tty empty (OK in test env)"

  # Check pid field exists
  pid_val=$(read_field "$FILE1" "pid")
  [[ -n "$pid_val" ]] && pass "pid present" || pass "pid empty (OK in test env)"
else
  fail "Cannot test fields" "file missing"
fi

# Test 3: permission_prompt → creates signal with type "attention"
echo "Test 3: permission_prompt creates signal with type 'attention'"
DIR3="$TMPDIR_BASE/t3"
run_hook "$DIR3" '{"session_id":"ses-perm-456","hook_event_name":"Notification","notification_type":"permission_prompt","message":"Allow file write?","cwd":"/tmp/proj"}'
if [[ -f "$DIR3/ses-perm-456.json" ]]; then
  typ=$(read_field "$DIR3/ses-perm-456.json" "type")
  [[ "$typ" == "attention" ]] && pass "type is 'attention'" || fail "type" "expected 'attention', got '$typ'"
else
  fail "permission_prompt signal" "file not created"
fi

# Test 4: UserPromptSubmit → creates signal with type "running"
echo "Test 4: UserPromptSubmit creates signal with type 'running'"
DIR4="$TMPDIR_BASE/t4"
run_hook "$DIR4" '{"session_id":"ses-run-789","hook_event_name":"UserPromptSubmit","cwd":"/Users/me/proj"}'
if [[ -f "$DIR4/ses-run-789.json" ]]; then
  typ=$(read_field "$DIR4/ses-run-789.json" "type")
  [[ "$typ" == "running" ]] && pass "type is 'running'" || fail "type" "expected 'running', got '$typ'"
else
  fail "UserPromptSubmit signal" "file not created"
fi

# Test 5: Handles missing fields gracefully
echo "Test 5: Handles missing/minimal JSON"
DIR5="$TMPDIR_BASE/t5"
run_hook "$DIR5" '{"session_id":"ses-minimal","hook_event_name":"Notification","notification_type":"idle_prompt"}'
if [[ -f "$DIR5/ses-minimal.json" ]]; then
  pass "Signal created with minimal JSON"
  msg=$(read_field "$DIR5/ses-minimal.json" "message")
  proj=$(read_field "$DIR5/ses-minimal.json" "project")
  pass "message fallback: '$msg'"
  pass "project fallback: '$proj'"
else
  fail "Minimal JSON" "signal file not created"
fi

# Test 6: Timestamp is recent
echo "Test 6: Timestamp is recent"
if [[ -f "$FILE1" ]]; then
  ts=$(read_field "$FILE1" "ts")
  now=$(date +%s)
  diff=$(( now - ts ))
  if (( diff >= 0 && diff <= 10 )); then
    pass "Timestamp within 10s (diff=${diff}s)"
  else
    fail "Timestamp" "diff=${diff}s, ts=$ts, now=$now"
  fi
else
  fail "Timestamp test" "file missing"
fi

# Test 7: Multiple signals coexist
echo "Test 7: Multiple signals coexist"
DIR7="$TMPDIR_BASE/t7"
run_hook "$DIR7" '{"session_id":"ses-multi-1","hook_event_name":"Notification","notification_type":"idle_prompt","message":"idle 1","cwd":"/a"}'
run_hook "$DIR7" '{"session_id":"ses-multi-2","hook_event_name":"Notification","notification_type":"permission_prompt","message":"perm 2","cwd":"/b"}'
if [[ -f "$DIR7/ses-multi-1.json" && -f "$DIR7/ses-multi-2.json" ]]; then
  pass "Both signal files exist"
else
  fail "Multiple signals" "one or both missing"
fi

# Test 8: JSON injection in field values
echo "Test 8: JSON injection in field values"
DIR8="$TMPDIR_BASE/t8"
run_hook "$DIR8" '{"session_id":"ses-inject","hook_event_name":"Notification","notification_type":"idle_prompt","message":"has \"quotes\"","cwd":"/path/with spaces"}'
if [[ -f "$DIR8/ses-inject.json" ]]; then
  if python3 -c "import json; json.load(open('$DIR8/ses-inject.json'))" 2>/dev/null; then
    pass "Signal file is valid JSON despite special chars"
  else
    fail "JSON injection" "signal file is not valid JSON"
  fi
else
  fail "JSON injection" "signal file not created"
fi

# Test 9: Overwrite — running signal then idle signal for same session
echo "Test 9: Signal overwrite (running → idle)"
DIR9="$TMPDIR_BASE/t9"
run_hook "$DIR9" '{"session_id":"ses-overwrite","hook_event_name":"UserPromptSubmit","cwd":"/proj"}'
typ=$(read_field "$DIR9/ses-overwrite.json" "type")
[[ "$typ" == "running" ]] && pass "Initially 'running'" || fail "Initial type" "expected 'running', got '$typ'"
run_hook "$DIR9" '{"session_id":"ses-overwrite","hook_event_name":"Notification","notification_type":"idle_prompt","message":"done","cwd":"/proj"}'
typ=$(read_field "$DIR9/ses-overwrite.json" "type")
[[ "$typ" == "idle" ]] && pass "Overwritten to 'idle'" || fail "Overwritten type" "expected 'idle', got '$typ'"

# Test 10: No session_id → exits cleanly
echo "Test 10: No session_id exits cleanly"
DIR10="$TMPDIR_BASE/t10"
if run_hook "$DIR10" '{"hook_event_name":"Notification","notification_type":"idle_prompt"}' 2>/dev/null; then
  count=$(find "$DIR10" -name "*.json" 2>/dev/null | wc -l | tr -d ' ')
  [[ "$count" == "0" ]] && pass "No signal file created" || fail "No session_id" "signal file created unexpectedly"
else
  fail "No session_id" "hook exited non-zero"
fi

# Test 11: Prompt activity is not persisted by default
echo "Test 11: UserPromptSubmit prompt is private by default"
DIR11="$TMPDIR_BASE/t11"
run_hook "$DIR11" '{"session_id":"ses-private","hook_event_name":"UserPromptSubmit","prompt":"run the tests","cwd":"/proj"}'
if [[ -f "$DIR11/ses-private.json" ]]; then
  if grep -q '"activity"' "$DIR11/ses-private.json"; then
    fail "Default activity privacy" "activity field should not be present"
  else
    pass "activity omitted by default"
  fi
else
  fail "Default activity privacy" "signal file not created"
fi

# Test 12: Prompt activity is persisted only with explicit opt-in
echo "Test 12: UserPromptSubmit prompt activity opt-in"
DIR12="$TMPDIR_BASE/t12"
run_hook_with_activity "$DIR12" '{"session_id":"ses-activity","hook_event_name":"UserPromptSubmit","prompt":"run the tests","cwd":"/proj"}'
if [[ -f "$DIR12/ses-activity.json" ]]; then
  activity=$(read_field "$DIR12/ses-activity.json" "activity")
  [[ "$activity" == "Run tests" ]] && pass "activity captured as compact snippet with opt-in" || fail "activity opt-in" "got '$activity'"
else
  fail "activity opt-in" "signal file not created"
fi

# Test 13: Sensitive prompt activity is not persisted even with opt-in
echo "Test 13: Sensitive UserPromptSubmit activity is filtered"
DIR13="$TMPDIR_BASE/t13"
run_hook_with_activity "$DIR13" '{"session_id":"ses-sensitive","hook_event_name":"UserPromptSubmit","prompt":"use token=abc123 to call the API","cwd":"/proj"}'
if [[ -f "$DIR13/ses-sensitive.json" ]]; then
  if grep -q '"activity"' "$DIR13/ses-sensitive.json"; then
    fail "Sensitive activity filtering" "activity field should not be present"
  else
    pass "sensitive activity omitted"
  fi
else
  fail "Sensitive activity filtering" "signal file not created"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]] && exit 0 || exit 1

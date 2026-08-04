#!/usr/bin/env bash
# Functional tests for bin/jira-pr. Stubs herdr, gh, and curl, so nothing here
# touches the network or a running Herdr server.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

stub_bin="$work/bin"
mkdir -p "$stub_bin" "$work/jira"

cat >"$stub_bin/herdr" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$STUB_HERDR_LOG"
EOF

cat >"$stub_bin/gh" <<'EOF'
#!/usr/bin/env bash
# Only `gh pr list` is exercised; STUB_PR_JSON is the canned response. Each call is
# logged so a test can assert that an action did not go to the network.
if [ "${1:-}" = "auth" ]; then
  exit 0
fi
printf 'gh %s\n' "$*" >>"${STUB_CALLS:-/dev/null}"
printf '%s' "${STUB_PR_JSON:-[]}"
EOF

cat >"$stub_bin/curl" <<'EOF'
#!/usr/bin/env bash
# Mimics `curl -w '\n%{http_code}'`: body, newline, status code.
url=""
for arg in "$@"; do
  case "$arg" in
    http*) url="$arg" ;;
  esac
done
key="${url##*/issue/}"
key="${key%%\?*}"
if [ "${STUB_JIRA_DOWN:-0}" = "1" ]; then
  printf '\n000'
  exit 0
fi
if [ -f "$STUB_JIRA_DIR/$key.json" ]; then
  printf '%s\n200' "$(cat "$STUB_JIRA_DIR/$key.json")"
else
  printf '{"errorMessages":["Issue Does Not Exist"]}\n404'
fi
EOF

chmod +x "$stub_bin"/*

# A real git repo, because the script asks git for the branch and remote.
repo="$work/repo"
mkdir -p "$repo"
git -C "$repo" -c init.templateDir= init -q
git -C "$repo" config user.email tester@example.com
git -C "$repo" config user.name Tester
git -C "$repo" remote add origin git@github.com:abtris/example.git
git -C "$repo" commit -q --allow-empty -m init

config_dir="$work/config"
mkdir -p "$config_dir"
cat >"$config_dir/config.env" <<EOF
JIRA_URL=http://jira.test
JIRA_API_TOKEN=stub-token
GH_ACCOUNTS=
EOF

jira_issue_fixture() {
  cat >"$work/jira/$1.json" <<EOF
{"fields":{"summary":"$2","status":{"name":"$3"}}}
EOF
}

failures=0
pass() { printf '  ok   %s\n' "$1"; }
fail() {
  printf '  FAIL %s\n         want: %s\n         got:  %s\n' "$1" "$2" "$3"
  failures=$((failures + 1))
}

# Runs bin/jira-pr on a branch and prints what it reported to herdr. Set pin to
# simulate a ticket assigned through the popup.
run_case() {
  local name="$1" branch="$2" pr_json="$3" want="$4" down="${5:-0}" pin="${6:-}"
  local cfg="${7:-$config_dir}"
  local log="$work/herdr.log" got state="$work/state-$RANDOM"
  : >"$log"
  git -C "$repo" checkout -q -B "$branch"
  if [ -n "$pin" ]; then
    # Key the pin off the physical repo root, the same value the script gets from
    # `git rev-parse --show-toplevel`. On macOS $TMPDIR resolves through /private,
    # so $repo and the toplevel differ.
    local toplevel
    toplevel=$(git -C "$repo" rev-parse --show-toplevel)
    mkdir -p "$state/pins"
    printf '%s' "$pin" \
      >"$state/pins/$(printf "%s|%s" "$toplevel" "$branch" | shasum | cut -d' ' -f1)"
  fi
  got=$(
    PATH="$stub_bin:$PATH" \
    STUB_HERDR_LOG="$log" \
    STUB_JIRA_DIR="$work/jira" \
    STUB_JIRA_DOWN="$down" \
    STUB_PR_JSON="$pr_json" \
    HERDR_BIN_PATH="$stub_bin/herdr" \
    HERDR_PANE_ID="w1:p1" \
    HERDR_PLUGIN_CONFIG_DIR="$cfg" \
    HERDR_PLUGIN_STATE_DIR="$state" \
    HERDR_PLUGIN_CONTEXT_JSON="{\"focused_pane_id\":\"w1:p1\",\"focused_pane_cwd\":\"$repo\"}" \
      bash "$root/bin/jira-pr" refresh >/dev/null 2>"$work/stderr" || {
      printf 'script exited %s; stderr: %s' "$?" "$(cat "$work/stderr")"
      return
    }
    cat "$log"
  )
  if [ "$got" = "$want" ]; then
    pass "$name"
  else
    fail "$name" "$want" "$got"
  fi
}

# Drives the popup by feeding it raw keystrokes, then reports what reached herdr
# plus whether a ticket ended up pinned. ESC is a literal escape byte, so this
# exercises the same input path a terminal delivers.
menu_case() {
  local name="$1" branch="$2" pr_json="$3" keys="$4" want_report="$5" want_pin="${6:-}"
  local want_gh="${7:-}"
  local log="$work/herdr.log" state="$work/state-menu-$RANDOM" got pin toplevel gh_calls
  : >"$log"
  git -C "$repo" checkout -q -B "$branch"
  toplevel=$(git -C "$repo" rev-parse --show-toplevel)
  printf '%b' "$keys" | (
    PATH="$stub_bin:$PATH" \
    STUB_HERDR_LOG="$log" \
    STUB_JIRA_DIR="$work/jira" \
    STUB_PR_JSON="$pr_json" \
    STUB_CALLS="$state.gh" \
    HERDR_BIN_PATH="$stub_bin/herdr" \
    HERDR_PANE_ID="w1:p1" \
    HERDR_PLUGIN_CONFIG_DIR="$config_dir" \
    HERDR_PLUGIN_STATE_DIR="$state" \
    OPEN_CMD="$stub_bin/opener" \
    HERDR_PLUGIN_CONTEXT_JSON="{\"focused_pane_id\":\"w1:p1\",\"focused_pane_cwd\":\"$repo\"}" \
      bash "$root/bin/jira-pr" menu >/dev/null 2>"$work/stderr"
  ) || {
    fail "$name" "$want_report" "script exited: $(cat "$work/stderr")"
    return
  }
  got=$(cat "$log")
  pin=$(cat "$state/pins/$(printf "%s|%s" "$toplevel" "$branch" | shasum | cut -d' ' -f1)" \
    2>/dev/null || true)
  gh_calls=$(wc -l <"$state.gh" 2>/dev/null | tr -d ' ' || echo 0)
  if [ "$got" = "$want_report" ] && [ "$pin" = "$want_pin" ] &&
    { [ -z "$want_gh" ] || [ "$gh_calls" = "$want_gh" ]; }; then
    pass "$name"
  else
    fail "$name" "report=[$want_report] pin=[$want_pin] gh=[${want_gh:-any}]" \
      "report=[$got] pin=[$pin] gh=[$gh_calls]"
  fi
}

cat >"$stub_bin/opener" <<'EOF'
#!/usr/bin/env bash
printf 'opened %s\n' "$1" >>"$STUB_HERDR_LOG"
EOF
# Shadow the real browser openers too. OPEN_CMD is the intended path, but if it
# ever stops being honoured the fallback must not reach an actual browser: an
# earlier version of this suite opened tabs on the developer's machine.
cp "$stub_bin/opener" "$stub_bin/open"
cp "$stub_bin/opener" "$stub_bin/xdg-open"
chmod +x "$stub_bin/opener" "$stub_bin/open" "$stub_bin/xdg-open"

jira_issue_fixture KR-1234 "Fix retry loop" "In Review"
jira_issue_fixture KR-1240 "Unrelated work" "Backlog"
jira_issue_fixture KRI-77 "Cluster incident triage" "Open"
# Real summaries do carry stray whitespace; KR-14644 on the live instance does.
jira_issue_fixture KR-2000 "  Padded summary  " "Done"

prefix="pane report-metadata w1:p1 --source abtris.jira-pr"

run_case "branch and PR agree" \
  "feat/kr-1234-retry" \
  '[{"number":45,"title":"KR-1234 Fix retry loop","body":"see KR-1234"}]' \
  "$prefix --token jira=#45 KR-1234 Fix retry loop · In Review --ttl-ms 900000 --token jira_key=KR-1234 --ttl-ms 900000"

run_case "branch and PR name different real issues" \
  "feat/kr-1234-retry" \
  '[{"number":45,"title":"KR-1240 something else","body":""}]' \
  "$prefix --token jira=⚠ #45 KR-1234 (branch) ≠ KR-1240 (PR) --ttl-ms 900000 --token jira_key=KR-1234 --ttl-ms 900000"

run_case "key only in the PR title" \
  "quick-cleanup" \
  '[{"number":46,"title":"KR-1234 Fix retry loop","body":""}]' \
  "$prefix --token jira=#46 KR-1234 Fix retry loop · In Review --ttl-ms 900000 --token jira_key=KR-1234 --ttl-ms 900000"

run_case "a key merely mentioned in the body does not count" \
  "tidy-things" \
  '[{"number":49,"title":"tidy up the config","body":"the row looks like #45 KR-1234 Fix the retry loop"}]' \
  "$prefix --token jira=#49 --ttl-ms 900000 --clear-token jira_key"

run_case "a key behind a linking word in the body counts" \
  "tidy-things" \
  '[{"number":50,"title":"tidy up the config","body":"Fixes KR-1234 as a side effect"}]' \
  "$prefix --token jira=#50 KR-1234 Fix retry loop · In Review --ttl-ms 900000 --token jira_key=KR-1234 --ttl-ms 900000"

run_case "a key in a Jira link in the body counts" \
  "tidy-things" \
  '[{"number":51,"title":"tidy up the config","body":"http://jira.test/browse/KR-1240 has context"}]' \
  "$prefix --token jira=#51 KR-1240 Unrelated work · Backlog --ttl-ms 900000 --token jira_key=KR-1240 --ttl-ms 900000"

run_case "KRI incident keys are recognized, not read as KR" \
  "triage/kri-77-cluster" \
  '[{"number":52,"title":"KRI-77 triage the cluster incident","body":""}]' \
  "$prefix --token jira=#52 KRI-77 Cluster incident triage · Open --ttl-ms 900000 --token jira_key=KRI-77 --ttl-ms 900000"

# The assignment lives in the branch name, per the team convention that a branch
# is $USER/KR-XXXXX-name and the PR title must repeat the ticket. A ticket that
# never reached the title is the case worth seeing.
run_case "a branch ticket missing from the PR title is flagged" \
  "lprskavec/KR-1234-retry" \
  '[{"number":55,"title":"fix(api): handle the retry","body":"no ticket here"}]' \
  "$prefix --token jira=⚠ #55 KR-1234 not in PR title --ttl-ms 900000 --token jira_key=KR-1234 --ttl-ms 900000"

run_case "a branch ticket repeated in the PR title is fine" \
  "lprskavec/KR-1234-retry" \
  '[{"number":56,"title":"fix(api): KR-1234 handle the retry","body":""}]' \
  "$prefix --token jira=#56 KR-1234 Fix retry loop · In Review --ttl-ms 900000 --token jira_key=KR-1234 --ttl-ms 900000"

# kr-dev-44 is a testbed, and triage work carries no ticket by design.
run_case "a testbed name is not a ticket key, and triage is not nagged" \
  "triage/2026-08-04-reservation" \
  '[{"number":7,"title":"Triaged the dev kr-dev-44 reservation 400","body":"kr-dev-44 returned 400"}]' \
  "$prefix --token jira=#7 --ttl-ms 900000 --clear-token jira_key"

run_case "a chore branch with no ticket is fine" \
  "chore/bump-deps" \
  '[{"number":54,"title":"chore: bump deps","body":"no ticket for this"}]' \
  "$prefix --token jira=#54 --ttl-ms 900000 --clear-token jira_key"

run_case "a branch that only looks like a key is ignored" \
  "fix/retry-2" \
  '[{"number":53,"title":"retry twice before giving up","body":""}]' \
  "$prefix --token jira=#53 --ttl-ms 900000 --clear-token jira_key"

run_case "no Jira key anywhere" \
  "tidy-things" \
  '[{"number":47,"title":"tidy up the config","body":"no ticket"}]' \
  "$prefix --token jira=#47 --ttl-ms 900000 --clear-token jira_key"

run_case "key that does not exist in Jira" \
  "feat/kr-9999-ghost" \
  '[{"number":48,"title":"KR-9999 ghost issue","body":""}]' \
  "$prefix --token jira=⚠ #48 KR-9999 not in Jira --ttl-ms 900000 --clear-token jira_key"

run_case "no PR for this branch clears the line" \
  "local-only" \
  '[]' \
  "$prefix --clear-token jira --clear-token jira_key"

run_case "Jira unreachable keeps the key but flags it" \
  "feat/kr-1234-retry" \
  '[{"number":45,"title":"KR-1234 Fix retry loop","body":""}]' \
  "$prefix --token jira=#45 KR-1234 · jira? --ttl-ms 900000 --token jira_key=KR-1234 --ttl-ms 900000" \
  1

run_case "a padded Jira summary does not double the separator" \
  "feat/kr-2000-padded" \
  '[{"number":59,"title":"KR-2000 padded summary","body":""}]' \
  "$prefix --token jira=#59 KR-2000 Padded summary · Done --ttl-ms 900000 --token jira_key=KR-2000 --ttl-ms 900000"

# A ticket assigned through the popup outranks the branch, and carries the same
# expectation: it has to show up in the PR title.
run_case "an assigned ticket missing from the PR title is flagged" \
  "spike/no-ticket-in-name" \
  '[{"number":57,"title":"spike: try the new client","body":""}]' \
  "$prefix --token jira=⚠ #57 KR-1234 not in PR title --ttl-ms 900000 --token jira_key=KR-1234 --ttl-ms 900000" \
  0 KR-1234

run_case "an assigned ticket shows before any PR exists" \
  "spike/no-ticket-yet" \
  '[]' \
  "$prefix --token jira=KR-1240 Unrelated work · Backlog --ttl-ms 900000 --token jira_key=KR-1240 --ttl-ms 900000" \
  0 KR-1240

# A token command that hangs must not hang the event hook. TOKEN_CMD_TIMEOUT is 1
# here so the test is quick; the plugin defaults to 10 seconds.
hang_config="$work/config-hang"
mkdir -p "$hang_config"
cat >"$hang_config/config.env" <<EOF
JIRA_URL=http://jira.test
JIRA_API_TOKEN_CMD="sleep 30"
TOKEN_CMD_TIMEOUT=1
GH_ACCOUNTS=
EOF

run_case "a hanging token command is bounded, not waited on" \
  "feat/kr-1234-retry" \
  '[{"number":58,"title":"KR-1234 Fix retry loop","body":""}]' \
  "$prefix --token jira=#58 KR-1234 · jira? --ttl-ms 900000 --token jira_key=KR-1234 --ttl-ms 900000" \
  0 "" "$hang_config"

ESC='\033'
ENTER='\n'
DOWN='\033[B'

# Escape must close the menu from the top level and from inside the ticket prompt.
# The prompt was the bug: `read -r` treats Escape as just another character, so it
# sat there waiting for a newline.
menu_case "escape closes the menu without reporting" \
  "feat/kr-1234-retry" \
  '[{"number":45,"title":"KR-1234 Fix retry loop","body":""}]' \
  "$ESC" \
  ""

# Backing out must cost nothing: no report, and exactly the one gh call the menu
# already made when it opened. Re-resolving here is what made Escape feel like a
# two second hang.
menu_case "escape cancels the ticket prompt without touching the network" \
  "spike/no-ticket" \
  '[{"number":60,"title":"spike: no ticket","body":""}]' \
  "a${ESC}${ESC}" \
  "" \
  "" \
  1

menu_case "refresh does re-resolve" \
  "spike/no-ticket" \
  '[{"number":60,"title":"spike: no ticket","body":""}]' \
  "r${ESC}" \
  "$prefix --token jira=#60 --ttl-ms 900000 --clear-token jira_key" \
  "" \
  2

menu_case "a ticket typed at the prompt is pinned and reported" \
  "spike/no-ticket" \
  '[{"number":60,"title":"spike: no ticket","body":""}]' \
  "aKR-1234${ENTER}${ESC}" \
  "$prefix --token jira=⚠ #60 KR-1234 not in PR title --ttl-ms 900000 --token jira_key=KR-1234 --ttl-ms 900000" \
  KR-1234

menu_case "a bad key at the prompt is refused and changes nothing" \
  "spike/no-ticket" \
  '[{"number":60,"title":"spike: no ticket","body":""}]' \
  "anonsense${ENTER} ${ESC}" \
  "" \
  "" \
  1

menu_case "backspace edits the ticket being typed" \
  "spike/no-ticket" \
  '[{"number":60,"title":"spike: no ticket","body":""}]' \
  "aKR-123499\0177\0177${ENTER}${ESC}" \
  "$prefix --token jira=⚠ #60 KR-1234 not in PR title --ttl-ms 900000 --token jira_key=KR-1234 --ttl-ms 900000" \
  KR-1234

# Enter activates the highlighted row, so the first row opens the PR.
menu_case "enter on the first row opens the pull request" \
  "feat/kr-1234-retry" \
  '[{"number":45,"title":"KR-1234 Fix retry loop","body":"","url":"https://github.test/pr/45"}]' \
  "$ENTER" \
  "opened https://github.test/pr/45"

# Down then enter picks the second row, which is the Jira issue.
menu_case "down then enter opens the Jira issue" \
  "feat/kr-1234-retry" \
  '[{"number":45,"title":"KR-1234 Fix retry loop","body":"","url":"https://github.test/pr/45"}]' \
  "${DOWN}${ENTER}" \
  "opened http://jira.test/browse/KR-1234"

# The letter shortcuts stay as a backup for the arrow keys.
menu_case "the letter shortcut still opens the issue" \
  "feat/kr-1234-retry" \
  '[{"number":45,"title":"KR-1234 Fix retry loop","body":"","url":"https://github.test/pr/45"}]' \
  "j" \
  "opened http://jira.test/browse/KR-1234"

if [ "$failures" -gt 0 ]; then
  printf '\n%s test(s) failed\n' "$failures"
  exit 1
fi
printf '\nall tests passed\n'

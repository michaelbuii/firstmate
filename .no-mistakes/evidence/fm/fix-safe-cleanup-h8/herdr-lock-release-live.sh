#!/usr/bin/env bash
# Live isolated Herdr check: a second projected worker must acquire the
# presentation lock while the first worker is blocked at its post-projection
# `treehouse get` startup step. The named lab helper owns session lifecycle.
set -euo pipefail

ROOT=/Users/michael.bui/.no-mistakes/worktrees/4a24a4f26029/01M29KZBEQMGXKP8KZ2Z8W69J7
HELPER="$ROOT/bin/fm-herdr-lab.sh"
REAL_HERDR=/opt/homebrew/bin/herdr
REAL_TREEHOUSE=/etc/profiles/per-user/michael.bui/bin/treehouse
ORIGINAL_PATH=$PATH
TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-live-lock-release.XXXXXX")
FAKEBIN="$TMP_ROOT/fakebin"
HOME_DIR="$TMP_ROOT/home"
PROJECT_A="$TMP_ROOT/project-a"
PROJECT_B="$TMP_ROOT/project-b"
GATE_DIR="$TMP_ROOT/gate"
LAB_SESSION=$(PATH="$ORIGINAL_PATH" "$HELPER" name lock-release-live)
LAB_READY=0
ANCHOR_SPAWNED=0
A_PID=
mkdir -p "$FAKEBIN" "$HOME_DIR/state" "$HOME_DIR/config" "$HOME_DIR/data/anchor" "$HOME_DIR/data/hold-a" "$HOME_DIR/data/hold-b" "$GATE_DIR"

cleanup() {
  : > "$GATE_DIR/release" 2>/dev/null || true
  if [ -n "$A_PID" ]; then wait "$A_PID" 2>/dev/null || true; fi
  for task in hold-b hold-a anchor; do
    if [ -e "$HOME_DIR/state/$task.meta" ]; then
      PATH="$FAKEBIN:$ORIGINAL_PATH" FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$ROOT" \
        FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
        FM_GATE_REFUSE_BYPASS=1 "$ROOT/bin/fm-teardown.sh" "$task" --force >/dev/null 2>&1 || true
    fi
  done
  if [ "$LAB_READY" = 1 ]; then
    PATH="$ORIGINAL_PATH" "$HELPER" teardown "$LAB_SESSION" >/dev/null 2>&1 || true
  fi
  rm -rf "$TMP_ROOT"
}
trap cleanup EXIT

# The server inherits this PATH. The treehouse shim blocks exactly the first
# post-enable pane-side `treehouse get`; all other Treehouse commands remain real.
cat > "$FAKEBIN/treehouse" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
# Herdr does not preserve arbitrary server environment variables in every
# pane, so the isolated temporary gate path is embedded by the test harness.
GATE_DIR='__GATE_DIR__'
if [ "${1:-}" = get ] && [ -e "$GATE_DIR/enabled" ] && [ ! -e "$GATE_DIR/consumed" ]; then
  : > "$GATE_DIR/consumed"
  : > "$GATE_DIR/worker-startup-blocked"
  attempt=0
  while [ ! -e "$GATE_DIR/release" ] && [ "$attempt" -lt 120 ]; do
    sleep 0.1
    attempt=$((attempt + 1))
  done
  [ -e "$GATE_DIR/release" ] || { echo 'live lock-release check: startup gate timed out' >&2; exit 70; }
fi
exec "$REAL_TREEHOUSE" "$@"
SH
sed -i '' "s|__GATE_DIR__|$GATE_DIR|g" "$FAKEBIN/treehouse"
cat > "$FAKEBIN/herdr" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
args=("$@")
n=${#args[@]}
# Herdr's protocol/version preflight is documented as session-independent.
if [ "$n" = 2 ] && [ "${args[0]} ${args[1]}" = 'status --json' ]; then
  exec "$REAL_HERDR" status --json
fi
if [ "$n" -lt 2 ] || [ "${args[$((n - 2))]}" != --session ] || [ "${args[$((n - 1))]}" != "$LAB_SESSION" ]; then
  echo 'live lock-release check: Herdr call lacked the explicit lab session' >&2
  exit 71
fi
unset 'args[$((n - 1))]' 'args[$((n - 2))]'
set -- "${args[@]}"
# The lab helper calls these while provisioning. They are scoped read/start
# operations on the exact named lab; all product workspace/tab/pane operations
# below route back through the lab helper's guarded run interface.
case "${1:-} ${2:-}" in
  'session list'|'status --json'|'server ')
    exec "$REAL_HERDR" "$@" --session "$LAB_SESSION"
    ;;
esac
if [ "${1:-}" = --version ]; then
  exec "$REAL_HERDR" "$@" --session "$LAB_SESSION"
fi
exec env PATH="$ORIGINAL_PATH" "$HELPER" run "$LAB_SESSION" "$@"
SH
chmod +x "$FAKEBIN/treehouse" "$FAKEBIN/herdr"
export REAL_TREEHOUSE REAL_HERDR GATE_DIR HELPER LAB_SESSION ORIGINAL_PATH
export HERDR_SESSION="$LAB_SESSION"

make_project() {
  local project=$1
  mkdir -p "$project"
  git -C "$project" init -q
  printf '# live lock-release fixture\n' > "$project/README.md"
  git -C "$project" add README.md
  git -C "$project" -c user.name=Live -c user.email=live@example.invalid commit -qm initial
  git clone --quiet --bare "$project" "$project.origin.git"
  git -C "$project" remote add origin "file://$project.origin.git"
}
write_brief() {
  local id=$1
  cat > "$HOME_DIR/data/$id/brief.md" <<EOF
# Task
## Captain's intent
Live isolated Herdr presentation lock-release fixture for $id.
## Firstmate spec
Keep this fixture running until the test tears it down.
EOF
}
spawn() {
  local id=$1 project=$2
  PATH="$FAKEBIN:$ORIGINAL_PATH" FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$ROOT" \
    FM_GATE_REFUSE_BYPASS=1 FM_SPAWN_NO_GUARD=1 \
    "$ROOT/bin/fm-spawn.sh" "$id" "$project" "sh -c 'while :; do sleep 60; done'" \
      --mode no-mistakes --yolo off --backend herdr
}

make_project "$PROJECT_A"
make_project "$PROJECT_B"
write_brief anchor
write_brief hold-a
write_brief hold-b

# Provision through the named lab; the wrapper's server operation preserves the
# explicit session while giving the lab server the gated Treehouse PATH.
PATH="$FAKEBIN:$ORIGINAL_PATH" "$HELPER" provision "$LAB_SESSION"
LAB_READY=1
printf 'lab=%s\n' "$LAB_SESSION"

# Establish the ordinary parent workspace first, then enable default projection.
printf 'off\n' > "$HOME_DIR/config/herdr-presentation-spaces"
spawn anchor "$PROJECT_A" > "$TMP_ROOT/anchor.out"
ANCHOR_SPAWNED=1
printf 'on\n' > "$HOME_DIR/config/herdr-presentation-spaces"

# A is now blocked only after its projected workspace/tab/journal work. While
# it remains blocked at worker startup, B must still project rather than timing
# out on the presentation lock and falling back flat.
: > "$GATE_DIR/enabled"
spawn hold-a "$PROJECT_A" > "$TMP_ROOT/hold-a.out" 2> "$TMP_ROOT/hold-a.err" &
A_PID=$!
attempt=0
while [ ! -e "$GATE_DIR/worker-startup-blocked" ] && kill -0 "$A_PID" 2>/dev/null && [ "$attempt" -lt 120 ]; do
  sleep 0.1
  attempt=$((attempt + 1))
done
[ -e "$GATE_DIR/worker-startup-blocked" ] || { cat "$TMP_ROOT/hold-a.err" >&2; exit 72; }
[ -f "$HOME_DIR/state/hold-a.herdr-presentation" ] || { echo 'A did not create a projected presentation journal before startup gate' >&2; exit 73; }
printf 'observation=A is blocked at pane-side treehouse-get after projected creation\n'

start=$(date +%s)
spawn hold-b "$PROJECT_B" > "$TMP_ROOT/hold-b.out" 2> "$TMP_ROOT/hold-b.err"
elapsed=$(( $(date +%s) - start ))
[ -f "$HOME_DIR/state/hold-b.herdr-presentation" ] || { cat "$TMP_ROOT/hold-b.err" >&2; echo 'B fell back flat or failed while A was blocked' >&2; exit 74; }
a_workspace=$(awk -F= '$1=="herdr_workspace_id"{print $2}' "$HOME_DIR/state/hold-a.meta")
b_workspace=$(awk -F= '$1=="herdr_workspace_id"{print $2}' "$HOME_DIR/state/hold-b.meta")
[ -n "$a_workspace" ] && [ -n "$b_workspace" ] && [ "$a_workspace" != "$b_workspace" ] || { echo 'projected workers lack distinct workspace identities' >&2; exit 75; }
printf 'observation=B projected successfully in %ss while A startup remained blocked (A=%s B=%s)\n' "$elapsed" "$a_workspace" "$b_workspace"

: > "$GATE_DIR/release"
wait "$A_PID"
A_PID=
printf 'observation=A completed startup after release gate\n'

# Normal product cleanup, followed by lab teardown that verifies the default
# session snapshot matches its pre-test tripwire.
for task in hold-b hold-a anchor; do
  PATH="$FAKEBIN:$ORIGINAL_PATH" FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$ROOT" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_GATE_REFUSE_BYPASS=1 "$ROOT/bin/fm-teardown.sh" "$task" --force >/dev/null
done
PATH="$ORIGINAL_PATH" "$HELPER" teardown "$LAB_SESSION"
LAB_READY=0
printf 'observation=guarded lab teardown completed; default-session tripwire remained intact\n'

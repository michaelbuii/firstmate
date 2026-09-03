#!/usr/bin/env bash
# tests/fm-stat-lib.test.sh - regression coverage for bin/fm-stat-lib.sh.
#
# Reproduces the confirmed defect from data/handoff/stat-shadowing-defect.md: a
# GNU-coreutils `stat` earlier on PATH than the genuine BSD stat treats `-f` as
# `--file-system`, prints its error to stderr, prints a multi-line filesystem
# dump to stdout, and can exit either 0 or 1 depending on the coreutils build.
# Every case below runs with a fixture GNU-look-alike `stat` placed first on
# PATH, exactly as a nix or Homebrew coreutils install shadows /usr/bin/stat on
# a real Mac, so the suite is executable on any platform (including Linux CI)
# without depending on a real macOS host or a real GNU coreutils build.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP=$(fm_test_tmproot fm-stat-lib)

# Absolute bash path baked into every fixture's shebang, so a test that
# deliberately narrows PATH (to prove fm_stat_bsd_bin fails closed with
# nothing genuine reachable) does not also break `env`'s own bash lookup.
FAKE_STAT_BASH=$(command -v bash)

# fake_gnu_stat <dir> <exit-code>: a `stat` that mimics GNU coreutils' `-f`
# handling of the failure mode this defect depends on - error to stderr, a
# multi-line filesystem dump to stdout, exiting with <exit-code> (0 or 1, since
# the confirmed real-world behavior varies by coreutils build).
fake_gnu_stat() {
  local dir=$1 rc=$2
  mkdir -p "$dir"
  {
    printf '#!%s\n' "$FAKE_STAT_BASH"
    printf 'STAT_EXIT_RC=%s\n' "$rc"
    cat <<'BODY'
if [ "${1:-}" = -f ]; then
  echo "stat: cannot read file system information for '$2': No such file or directory" >&2
  printf '  File: "%s"\n    ID: 100000e0000001a Namelen: ?       Type: apfs\n' "${3:-$2}"
  printf 'Block size: 4096       Fundamental block size: 4096\n'
  exit "$STAT_EXIT_RC"
fi
exit 1
BODY
  } > "$dir/stat"
  chmod +x "$dir/stat"
}

# fake_bsd_stat <dir>: a genuine-BSD-like `stat -f <fmt> <path>` stand-in.
# Recognizes every format specifier this codebase's affected call sites use and
# returns one deterministic, single-line value per specifier so a caller can
# assert an exact expected read.
fake_bsd_stat() {
  local dir=$1
  mkdir -p "$dir"
  {
    printf '#!%s\n' "$FAKE_STAT_BASH"
    cat <<'BODY'
[ "${1:-}" = -f ] || exit 1
fmt=$2
case "$fmt" in
  %m)             printf '1700000000\n' ;;
  %d)             printf '16777230\n' ;;
  %Lp)            printf '700\n' ;;
  %l)             printf '1\n' ;;
  %i)             printf '312402\n' ;;
  %u)             printf '502\n' ;;
  %z)             printf '4096\n' ;;
  %B)             printf '1\n' ;;
  %FB)            printf '2026-09-02 00:00:00\n' ;;
  '%d:%i')        printf '16777230:312402\n' ;;
  '%d:%i:%z:%m:%c') printf '16777230:312402:4096:1700000000:1700000000\n' ;;
  '%z:%Fm')       printf '4096:1700000000\n' ;;
  '%HT:%p')       printf 'Regular File:/tmp/fixture\n' ;;
  *)              exit 1 ;;
esac
BODY
  } > "$dir/stat"
  chmod +x "$dir/stat"
}

fake_darwin_uname() {
  local dir=$1
  {
    printf '#!%s\n' "$FAKE_STAT_BASH"
    printf '%s\n' "printf 'Darwin\\n'"
  } > "$dir/uname"
  chmod +x "$dir/uname"
}

# ORIGINAL_PATH restores a clean, un-prefixed PATH before every case so
# fixture directories from an earlier case can never leak into a later one.
ORIGINAL_PATH=$PATH

# shellcheck source=bin/fm-stat-lib.sh
. "$ROOT/bin/fm-stat-lib.sh"

# reset_lib resets fm_stat_bsd_bin's resolution cache and restores a clean
# PATH/anchor, without re-sourcing the library: fm_stat_bsd_bin reads
# FM_STAT_BSD_ANCHOR fresh on every call (see bin/fm-stat-lib.sh), so a test
# only needs the cache cleared, not a fresh source. `export`, not a prefix
# assignment on the `.` command, is required here: a prefix assignment on a
# special builtin like `.` (or on any command) does not persist afterward, so
# a later, separate call to fm_stat_bsd_bin would not see it.
reset_lib() {
  _FM_STAT_BSD_BIN=""
  _FM_STAT_BSD_RESOLVED=false
  _FM_STAT_BSD_RESOLVED_ANCHOR=""
  unset FM_STAT_BSD_ANCHOR
  export PATH=$ORIGINAL_PATH
}

# --- resolution skips a shadowing GNU stat and finds the verified anchor ----

reset_lib
GNU_DIR="$TMP/gnu-first"
ANCHOR_DIR="$TMP/anchor"
fake_gnu_stat "$GNU_DIR" 0
fake_bsd_stat "$ANCHOR_DIR"
export FM_STAT_BSD_ANCHOR="$ANCHOR_DIR/stat"
export PATH="$GNU_DIR:$PATH"
resolved=$(fm_stat_bsd_bin) || fail "fm_stat_bsd_bin should resolve when the anchor is a genuine BSD stat"
[ "$resolved" = "$ANCHOR_DIR/stat" ] || fail "fm_stat_bsd_bin should resolve to the verified anchor, not the shadowing PATH stat: got $resolved"
pass "fm_stat_bsd_bin resolves to the verified BSD stat even with a GNU-look-alike leading PATH (exit 0 variant)"

# --- same proof against the exit-1 GNU-look-alike variant ------------------

reset_lib
GNU_DIR1="$TMP/gnu-first-exit1"
fake_gnu_stat "$GNU_DIR1" 1
export FM_STAT_BSD_ANCHOR="$ANCHOR_DIR/stat"
export PATH="$GNU_DIR1:$PATH"
resolved=$(fm_stat_bsd_bin) || fail "fm_stat_bsd_bin should resolve regardless of the GNU-look-alike's exit code"
[ "$resolved" = "$ANCHOR_DIR/stat" ] || fail "fm_stat_bsd_bin should still resolve to the anchor: got $resolved"
pass "fm_stat_bsd_bin resolves to the verified BSD stat with a GNU-look-alike leading PATH (exit 1 variant)"

# --- every affected format specifier still returns a single-line value -----

reset_lib
export FM_STAT_BSD_ANCHOR="$ANCHOR_DIR/stat"
export PATH="$GNU_DIR:$PATH"

assert_single_line() {  # <label> <format> <expected>
  local label=$1 fmt=$2 expected=$3 out
  out=$(fm_stat_bsd "$fmt" /tmp/fixture) || fail "$label: fm_stat_bsd failed for format $fmt"
  case "$out" in
    *$'\n'*) fail "$label: expected a single-line value for format $fmt, got: $out" ;;
  esac
  [ "$out" = "$expected" ] || fail "$label: expected '$expected' for format $fmt, got '$out'"
}

assert_single_line "mtime"                 '%m'                '1700000000'
assert_single_line "device"                 '%d'                '16777230'
assert_single_line "mode"                   '%Lp'               '700'
assert_single_line "link count"             '%l'                '1'
assert_single_line "inode"                  '%i'                '312402'
assert_single_line "uid"                    '%u'                '502'
assert_single_line "size"                   '%z'                '4096'
assert_single_line "device:inode"           '%d:%i'             '16777230:312402'
assert_single_line "device:inode:size:mtime:ctime" '%d:%i:%z:%m:%c' '16777230:312402:4096:1700000000:1700000000'
assert_single_line "size:birth-fallback"    '%z:%Fm'            '4096:1700000000'
assert_single_line "type:permissions"       '%HT:%p'            'Regular File:/tmp/fixture'
pass "fm_stat_bsd preserves every affected format specifier and returns single-line values with a GNU stat shadowing PATH"

# --- affected production reads all cross the shared Darwin boundary --------

fake_darwin_uname "$GNU_DIR"
export PATH="$GNU_DIR:$ORIGINAL_PATH"
export FM_STAT_BSD_ANCHOR="$ANCHOR_DIR/stat"

# shellcheck source=bin/fm-supervision-lib.sh
. "$ROOT/bin/fm-supervision-lib.sh"
# shellcheck source=bin/fm-classify-lib.sh
. "$ROOT/bin/fm-classify-lib.sh"
# shellcheck source=bin/fm-startup-memory-budget-lib.sh
. "$ROOT/bin/fm-startup-memory-budget-lib.sh"
# shellcheck source=bin/backends/herdr.sh
. "$ROOT/bin/backends/herdr.sh"

assert_single_line "supervision beacon mtime" '%m' '1700000000'
[ "$(fm_sup_stat_mtime /tmp/fixture)" = 1700000000 ] \
  || fail "fm_sup_stat_mtime did not use the verified BSD stat"
[ "$(_fm_status_file_size /tmp/fixture)" = 4096 ] \
  || fail "status presentation size did not use the verified BSD stat"
[ "$(_fm_status_file_mtime /tmp/fixture)" = 1700000000 ] \
  || fail "status presentation mtime did not use the verified BSD stat"
[ "$(_fm_open_decisions_file_ident /tmp/fixture)" = 'strong:16777230:312402:2026-09-02 00:00:00' ] \
  || fail "status presentation identity did not use the verified BSD stat"
[ "$(fm_startup_memory_budget_link_count /tmp/fixture)" = 1 ] \
  || fail "startup memory link count did not use the verified BSD stat"
[ "$(fm_backend_herdr_presentation_lock_namespace_mode /tmp/fixture)" = 700 ] \
  || fail "Herdr presentation mode did not use the verified BSD stat"
[ "$(fm_backend_herdr_presentation_lock_namespace_uid /tmp/fixture)" = 502 ] \
  || fail "Herdr presentation uid did not use the verified BSD stat"
pass "supervision, status presentation, startup memory, and Herdr reads remain single-line with a GNU stat first on PATH"

# --- fails closed when the multi-line dump is the only thing on PATH -------

reset_lib
GNU_ONLY_DIR="$TMP/gnu-only"
fake_gnu_stat "$GNU_ONLY_DIR" 0
# PATH is deliberately narrowed to ONLY the fixture dir here (not appended to
# the ambient PATH): a real BSD stat elsewhere on this host's PATH (a real
# macOS /usr/bin/stat, say) must not rescue this case, since the whole point is
# to prove fm_stat_bsd_bin fails closed when nothing genuine is reachable.
# fm_stat_bsd_bin needs no external command beyond `stat` itself to resolve.
export FM_STAT_BSD_ANCHOR="$TMP/missing/stat"
export PATH="$GNU_ONLY_DIR"
fail_closed_out="$TMP/fail-closed-out"
if fm_stat_bsd_bin >"$fail_closed_out" 2>/dev/null; then
  fail "fm_stat_bsd_bin should fail closed when no genuine BSD stat is reachable"
fi
# PATH is still narrowed to the fixture-only dir here, so read the captured
# file with a builtin (no external `cat`) rather than restoring PATH first.
IFS= read -r out < "$fail_closed_out" || out=""
[ -z "$out" ] || fail "fm_stat_bsd_bin must print nothing on failure, got: $out"
pass "fm_stat_bsd_bin fails closed (empty output, non-zero exit) when only a GNU-look-alike is reachable"
reset_lib

# --- the historical crash this defect caused: unguarded arithmetic on $m ---
# bin/fm-supervision-lib.sh:63 (fm_supervision_status) used to feed the raw
# stat -f output straight into `$(( $(date +%s) - m ))`. Show the raw multi-line
# capture that fed that crash, then show fm_stat_bsd removes it by construction:
# its output is never multi-line, so the same arithmetic can never see the
# unbound-variable token ("File") that a raw `stat -f` capture handed it.

reset_lib
GNU_ONLY_DIR2="$TMP/gnu-only-2"
fake_gnu_stat "$GNU_ONLY_DIR2" 0
raw_m=$(PATH="$GNU_ONLY_DIR2" stat -f %m /etc 2>/dev/null)
case "$raw_m" in
  *$'\n'*) : ;;
  *) fail "expected the raw unguarded capture to reproduce the multi-line dump this defect causes, got: $raw_m" ;;
esac
case "$raw_m" in
  *File:*) : ;;
  *) fail "expected the raw capture's dump to contain the 'File:' token that caused the historical crash, got: $raw_m" ;;
esac
pass "reproduced the historical fm_supervision_status defect: a raw, unguarded stat -f read captures a multi-line dump"

reset_lib
export FM_STAT_BSD_ANCHOR="$ANCHOR_DIR/stat"
export PATH="$GNU_ONLY_DIR2:$PATH"
fixed_m=$(fm_stat_bsd %m /etc) || fixed_m=""
case "$fixed_m" in
  *$'\n'*) fail "fm_stat_bsd must never return a multi-line value, got: $fixed_m" ;;
esac
case "$fixed_m" in
  *File:*) fail "fm_stat_bsd must never return the multi-line dump token, got: $fixed_m" ;;
esac
[ "$fixed_m" = 1700000000 ] || fail "expected the fixture anchor's fixed mtime, got: $fixed_m"
pass "fm_stat_bsd's single-line shape check removes the historical fm_supervision_status crash by never producing a multi-line value"

echo "All fm-stat-lib tests passed."

#!/usr/bin/env bash
# Single owner for resolving a genuine BSD `stat` on Darwin and reading one
# `stat -f` format safely.
#
# macOS ships /usr/bin/stat as SIP-protected BSD stat, but GNU coreutils can
# put another `stat` earlier on PATH. GNU stat treats `-f` as `--file-system`,
# not "format", and can print a filesystem report to stdout even when the
# requested format is invalid. A caller cannot distinguish that failure by
# exit status alone.
#
# fm_stat_bsd_bin resolves a verified BSD stat binary. fm_stat_bsd is the
# single call every Darwin `stat -f` read should use. It caches the resolution
# when called in the current shell and accepts only nonempty, single-line read
# output, so the known multi-line GNU report cannot reach callers.
#
# Sourced, never executed.

[ -n "${_FM_STAT_LIB_SOURCED:-}" ] && return 0 2>/dev/null || true
_FM_STAT_LIB_SOURCED=1

_FM_STAT_BSD_BIN=""
_FM_STAT_BSD_RESOLVED=false
_FM_STAT_BSD_RESOLVED_ANCHOR=""

# fm_stat_bsd_probe <candidate>: 0 iff <candidate> -f %m / prints exactly one
# line of digits - the shape a genuine BSD stat -f always returns and a
# GNU-coreutils stat -f never does (it errors to stderr and prints a
# filesystem report to stdout instead, regardless of its exit status).
fm_stat_bsd_probe() {
  local candidate=$1 out
  [ -n "$candidate" ] && [ -x "$candidate" ] || return 1
  out=$("$candidate" -f %m / 2>/dev/null)
  case "$out" in
    *$'\n'*|'') return 1 ;;
    *[!0-9]*) return 1 ;;
  esac
  return 0
}

# fm_stat_bsd_resolve: resolve and cache a genuine BSD stat binary in the
# current shell. The anchor is /usr/bin/stat, the SIP-protected path on stock
# macOS. FM_STAT_BSD_ANCHOR exists only so portable tests can provide a BSD
# stand-in. The probe still verifies the anchor instead of trusting its path.
fm_stat_bsd_resolve() {
  local anchor="${FM_STAT_BSD_ANCHOR:-/usr/bin/stat}" candidate
  if [ "$_FM_STAT_BSD_RESOLVED" = true ] && [ "$_FM_STAT_BSD_RESOLVED_ANCHOR" = "$anchor" ]; then
    [ -n "$_FM_STAT_BSD_BIN" ]
    return
  fi

  _FM_STAT_BSD_RESOLVED=true
  _FM_STAT_BSD_RESOLVED_ANCHOR=$anchor
  _FM_STAT_BSD_BIN=""
  if fm_stat_bsd_probe "$anchor"; then
    _FM_STAT_BSD_BIN=$anchor
    return 0
  fi

  while IFS= read -r candidate; do
    [ -n "$candidate" ] || continue
    if fm_stat_bsd_probe "$candidate"; then
      _FM_STAT_BSD_BIN=$candidate
      return 0
    fi
  done < <(type -a -p -- stat 2>/dev/null)
  return 1
}

# fm_stat_bsd_bin: print the resolved genuine BSD stat binary path. Returns 1
# with empty output when no genuine BSD stat can be found.
fm_stat_bsd_bin() {
  fm_stat_bsd_resolve || return 1
  printf '%s' "$_FM_STAT_BSD_BIN"
}

# fm_stat_bsd <format> <path> [more stat -f args...]: run the resolved BSD
# stat with <format> against <path>, printing the result only when it is a
# single line. Fails closed - empty stdout, non-zero exit - when no BSD stat
# is available or the read does not look like a single-value result, so a
# caller cannot silently accept multi-line output regardless of exit status.
fm_stat_bsd() {
  local fmt=$1 out
  shift
  fm_stat_bsd_resolve || return 1
  out=$("$_FM_STAT_BSD_BIN" -f "$fmt" "$@" 2>/dev/null)
  case "$out" in *$'\n'*) return 1 ;; esac
  [ -n "$out" ] || return 1
  printf '%s' "$out"
}

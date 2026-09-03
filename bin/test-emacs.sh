#!/usr/bin/env bash
# Run the suites -- and interactive experiments -- in an Emacs of their own.
#
# Nothing here needs the working Emacs, and everything here is better off
# without it: fixtures that pop windows, ediffs and *claude-client* buffers
# stop landing in the middle of a real editing session, and a suite that
# wedges or kills its instance costs nothing but that instance.
#
# Isolation is by state, not just by process.  A second Emacs sharing the
# working one's MCP port or emacsclient socket is not isolated at all, so the
# test instance gets:
#
#   - its own init directory (test/init/ -- no Doom, no user config)
#   - its own emacsclient socket name (mcp-emacs-test)
#   - the MCP HTTP server on 8775 rather than 8765
#   - a package dir under .test-emacs/ shared across runs, so deps are
#     installed once and ~/.emacs.d is never touched
#
# Modes:
#   bin/test-emacs.sh                     run every suite in batch
#   bin/test-emacs.sh test/foo-test.el    run just these suites
#   bin/test-emacs.sh --quiet [SUITE...]  report only, logs on failure (CI)
#   bin/test-emacs.sh --compile           byte-compile elisp/ (warnings shown)
#   bin/test-emacs.sh --compile --strict  ... and treat warnings as errors
#   bin/test-emacs.sh --daemon            start the test daemon and leave it up
#   bin/test-emacs.sh --gui               start a windowed test Emacs
#   bin/test-emacs.sh --eval FORM         eval FORM in the test daemon
#   bin/test-emacs.sh --stop              kill the test daemon
#   bin/test-emacs.sh --deps              install/refresh deps only

set -uo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"

EMACS="${EMACS:-emacs}"
EMACSCLIENT="${EMACSCLIENT:-emacsclient}"

server_name="mcp-emacs-test"
state_dir="$root/.test-emacs"
package_dir="$state_dir/package"
home_dir="$state_dir/home"
init_file="$root/test/init/init.el"

export MCP_EMACS_TEST_REPO="$root"
export MCP_EMACS_TEST_PACKAGE_DIR="$package_dir"
export MCP_EMACS_TEST_PORT="${MCP_EMACS_TEST_PORT:-8775}"

# plz is an optional runtime dependency of opencode-client, but installing it
# here is what lets that file compile and be tested with plz present rather
# than only through its soft-require fallback.
deps=(web-server websocket plz)

# `--init-directory' (Emacs 29+) is what keeps the personal config out; there
# is no supported way to do this on 28 short of clobbering HOME.
#
# It points at the git-ignored state dir, not at test/init/ where init.el
# actually lives, because `native-comp-eln-load-path' is derived from
# `user-emacs-directory' at startup -- before any init file runs.  Pointing it
# at the tracked directory made every daemon dump an eln-cache/ into the repo
# no matter what init.el set afterwards.  So: state dir for the location,
# explicit `-l' for the config.  `--batch' implies `-q' anyway, so the
# explicit load is required there regardless.
emacs_batch() {
  mkdir -p "$home_dir"
  "$EMACS" --batch --init-directory "$home_dir" -l "$init_file" "$@"
}

ensure_deps() {
  local missing=()
  for d in "${deps[@]}"; do
    # Presence check only -- a versioned dir named after the package is enough
    # to skip the (slow) MELPA refresh; package.el makes the real decision.
    compgen -G "$package_dir/$d-*" >/dev/null || missing+=("$d")
  done
  if [ ${#missing[@]} -eq 0 ]; then
    return 0
  fi
  mkdir -p "$package_dir"
  echo "== installing deps: ${missing[*]}"
  local forms=()
  for d in "${missing[@]}"; do
    forms+=(--eval "(unless (package-installed-p '$d) (package-install '$d))")
  done
  emacs_batch --eval '(package-refresh-contents)' "${forms[@]}" || {
    echo "error: dependency install failed" >&2
    exit 1
  }
}

# Test names are free text, and a `check' label containing & or < would
# otherwise produce a JUnit file no parser accepts.
#
# The backslashes are load-bearing: since bash 5.2 an unescaped `&' in the
# replacement half of ${var//pat/repl} means "the text that matched", so a
# plain `&lt;' silently expanded to `<lt;' and produced invalid XML.
# Ampersand is substituted first, or the `&' of each later entity would be
# escaped again.
xml_escape() {
  local s="$1"
  s="${s//&/\&amp;}"
  s="${s//</\&lt;}"
  s="${s//>/\&gt;}"
  s="${s//\"/\&quot;}"
  printf '%s' "$s"
}

# The suites do not use `ert-run-tests-batch'; each has its own `check' that
# princ's "PASS name" / "FAIL name".  So the report is assembled here, from
# those lines plus each run's exit status -- there is no ert summary to read.
run_suites() {
  local quiet="$1"; shift
  local suites=("$@")
  if [ ${#suites[@]} -eq 0 ]; then
    # Globbed rather than listed for the same reason CI globs: an explicit
    # list silently falls behind as suites are added.
    suites=(test/*-test.el)
  fi

  local status=0 out report
  out="$(mktemp)"
  report="$(mktemp)"
  trap 'rm -f "$out" "$report"' RETURN

  mkdir -p "$state_dir"
  local junit="$state_dir/report.xml"
  : >"$junit"

  # xml_* totals count the synthetic errored/empty cases; the human totals
  # deliberately do not, so "700 assertions" stays the number of real checks.
  local total_pass=0 total_fail=0 bad_suites=0 xml_total=0 xml_total_fail=0
  for t in "${suites[@]}"; do
    [ "$quiet" = 1 ] || echo "== $t =="
    local exit_ok=1
    if [ "$quiet" = 1 ]; then
      emacs_batch -l "$t" >"$out" 2>&1 || exit_ok=0
    else
      emacs_batch -l "$t" 2>&1 | tee "$out"
      # Careful: with the pipe, $? is tee's.  The suite's own status is the
      # first element of PIPESTATUS.
      [ "${PIPESTATUS[0]}" = 0 ] || exit_ok=0
    fi

    local pass fail verdict
    pass="$(grep -c '^PASS' "$out")"
    fail="$(grep -c '^FAIL' "$out")"
    total_pass=$((total_pass + pass))
    total_fail=$((total_fail + fail))

    # A suite that dies before printing anything must not pass, so require a
    # clean exit AND at least one PASS -- same contract CI has always had.
    if [ "$exit_ok" = 0 ]; then
      verdict="ERRORED"
    elif [ "$fail" -gt 0 ]; then
      verdict="FAILED"
    elif [ "$pass" = 0 ]; then
      verdict="NO ASSERTIONS"
    else
      verdict="ok"
    fi

    if [ "$verdict" != ok ]; then
      status=1
      bad_suites=$((bad_suites + 1))
      [ "$quiet" = 1 ] || echo "$verdict: $t"
      # In quiet mode the per-assertion output was swallowed, so replay the
      # failing suite's log -- a bare count is not something you can debug.
      [ "$quiet" = 1 ] && { echo "== $t ($verdict) =="; cat "$out"; }
    fi

    # Text report: the suite line, then every test name under it.  Listing
    # the names is the point -- counts alone do not tell you which tests
    # exist, so a test that silently stops being run looks like a pass.
    local name
    printf '\n%-38s %5s pass %5s fail  %s\n' \
           "$(basename "$t")" "$pass" "$fail" "$verdict" >>"$report"
    # DESCRIBE lines are group headers from test-helper's `describe'; the
    # expectations under one get indented beneath it.  A suite not yet
    # converted emits no DESCRIBE at all and simply reads as a flat list.
    while IFS= read -r line; do
      case "$line" in
        DESCRIBE\ *) printf '  %s\n' "${line#DESCRIBE }" >>"$report" ;;
        *)           printf '    %s\n' "$line" >>"$report" ;;
      esac
    done < <(grep -E '^(PASS|FAIL|DESCRIBE) ' "$out")
    [ "$verdict" = ERRORED ] && printf '  (suite errored before finishing)\n' >>"$report"
    [ "$verdict" = "NO ASSERTIONS" ] && printf '  (no tests ran)\n' >>"$report"

    # JUnit: one testsuite per file, one testcase per check.  This is what
    # lets CI and Emacs-side viewers render the per-test result natively
    # instead of re-parsing the log.
    # An errored or empty suite gets one synthetic testcase below, so it has
    # to be counted here too -- a testsuite claiming tests="0" while holding
    # a case renders as empty in viewers that trust the attribute.
    local xml_tests=$((pass + fail)) xml_failures="$fail"
    case "$verdict" in
      ERRORED|"NO ASSERTIONS")
        xml_tests=$((xml_tests + 1))
        xml_failures=$((xml_failures + 1))
        ;;
    esac
    xml_total=$((xml_total + xml_tests))
    xml_total_fail=$((xml_total_fail + xml_failures))
    {
      printf '  <testsuite name="%s" tests="%d" failures="%d">\n' \
             "$(xml_escape "$(basename "$t" .el)")" "$xml_tests" "$xml_failures"
      # A `describe' becomes the testcase classname, which is how JUnit
      # viewers show grouping -- the same nesting the text report indents.
      local classname=""
      while IFS= read -r line; do
        if [ "${line%% *}" = DESCRIBE ]; then
          classname="$(xml_escape "${line#DESCRIBE }")"
          continue
        fi
        name="$(xml_escape "${line#* }")"
        if [ "${line%% *}" = PASS ]; then
          printf '    <testcase classname="%s" name="%s"/>\n' "$classname" "$name"
        else
          printf '    <testcase classname="%s" name="%s"><failure message="check failed"/></testcase>\n' \
                 "$classname" "$name"
        fi
      done < <(grep -E '^(PASS|FAIL|DESCRIBE) ' "$out")
      # An errored or empty suite has no testcases to report, so carry the
      # verdict on the suite element instead -- otherwise it reads as green.
      if [ "$verdict" = ERRORED ]; then
        printf '    <testcase name="%s"><error message="suite errored"><![CDATA[\n' \
               "$(xml_escape "$(basename "$t")")"
        sed 's/]]>/]] >/g' "$out"
        printf ']]></error></testcase>\n'
      elif [ "$verdict" = "NO ASSERTIONS" ]; then
        printf '    <testcase name="%s"><failure message="no assertions ran"/></testcase>\n' \
               "$(xml_escape "$(basename "$t")")"
      fi
      printf '  </testsuite>\n'
    } >>"$junit"
  done

  # Written last: the totals belong on the root element, and they are not
  # known until every suite has run.
  local xml_body
  xml_body="$(cat "$junit")"
  {
    printf '<?xml version="1.0" encoding="UTF-8"?>\n'
    printf '<testsuites tests="%d" failures="%d">\n' \
           "$xml_total" "$xml_total_fail"
    printf '%s\n' "$xml_body"
    printf '</testsuites>\n'
  } >"$junit"

  echo
  echo "== report =="
  cat "$report"
  echo
  printf -- '-- %d suites, %d assertions, %d failed, %d suites not ok\n' \
         "${#suites[@]}" "$((total_pass + total_fail))" "$total_fail" "$bad_suites"
  printf -- '-- JUnit XML: %s\n' "${junit#"$root"/}"
  return $status
}

daemon_running() {
  "$EMACSCLIENT" -s "$server_name" --eval t >/dev/null 2>&1
}

start_daemon() {
  if daemon_running; then
    echo "test daemon already running (socket: $server_name)"
    return 0
  fi
  ensure_deps
  mkdir -p "$home_dir"
  # `-l' rather than relying on the init directory to hold init.el: see
  # `emacs_batch' for why the two are deliberately different places.
  "$EMACS" --daemon="$server_name" \
           --init-directory "$home_dir" -l "$init_file" || {
    echo "error: test daemon failed to start" >&2
    exit 1
  }
  echo "test daemon up: emacsclient -s $server_name"
  echo "  MCP port would be $MCP_EMACS_TEST_PORT (start with --eval '(mcp-emacs-server-ensure)')"
}

case "${1:-}" in
  --deps)
    ensure_deps
    ;;
  --compile)
    shift
    ensure_deps
    # Warnings stay non-fatal by default, matching CI: the tree carries
    # pre-existing Emacs-31 obsoletions and over-80-column docstrings, so
    # `-Werror' here would fail every run for reasons unrelated to the change
    # under test.  `--compile --strict' opts in when cleaning those up.
    strict=()
    [ "${1:-}" = "--strict" ] && strict=(--eval '(setq byte-compile-error-on-warn t)')
    emacs_batch "${strict[@]}" -f batch-byte-compile elisp/*.el
    ;;
  --daemon)
    start_daemon
    ;;
  --gui)
    ensure_deps
    # Not exec'd through the daemon: a windowed instance is for watching a
    # fixture misbehave, and killing the frame should end the instance.
    mkdir -p "$home_dir"
    "$EMACS" --init-directory "$home_dir" -l "$init_file" "${@:2}" &
    echo "test GUI Emacs started (pid $!)"
    ;;
  --eval)
    shift
    [ $# -gt 0 ] || { echo "usage: bin/test-emacs.sh --eval FORM" >&2; exit 2; }
    start_daemon >/dev/null
    "$EMACSCLIENT" -s "$server_name" --eval "$*"
    ;;
  --stop)
    if daemon_running; then
      "$EMACSCLIENT" -s "$server_name" --eval '(kill-emacs)' >/dev/null 2>&1
      echo "test daemon stopped"
    else
      echo "no test daemon running"
    fi
    ;;
  -h|--help)
    # Print the header comment: everything from line 2 up to the blank line
    # that ends it, so adding a mode to the list keeps --help in sync.
    sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'
    ;;
  --quiet|-q)
    shift
    ensure_deps
    run_suites 1 "$@"
    ;;
  --*)
    echo "error: unknown option '$1'" >&2
    exit 2
    ;;
  *)
    ensure_deps
    run_suites 0 "$@"
    ;;
esac

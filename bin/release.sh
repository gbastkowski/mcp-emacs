#!/usr/bin/env bash
# Cut a release: stamp the version everywhere it is declared, tag it, publish.
#
# The version lives in three places that have already drifted apart once --
# the `Version:' header of every elisp/*.el file, the plugin manifest, and the
# git tag.  Doing this by hand is what let plugin.json sit at 1.0.0 while the
# tags reached v1.7.0, and what left agent-session-overview.el claiming a
# version it was never part of.  One script writes all three from one
# argument, so they cannot disagree.
#
# The tag is what matters to consumers: Doom's `:pin' resolves a tag, so a
# release is what makes a version installable by name rather than by SHA.
#
# Usage: bin/release.sh <version> [--dry-run]
#   version: bare semver, no leading v (e.g. 1.8.0)

set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"

version="${1:-}"
dry_run=""
[ "${2:-}" = "--dry-run" ] && dry_run=1

if [ -z "$version" ]; then
  echo "usage: bin/release.sh <version> [--dry-run]" >&2
  exit 2
fi

# Bare semver only.  A leading v here would produce tag `vv1.8.0' and a
# `Version: v1.8.0' header that package.el cannot parse.
if ! printf '%s' "$version" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+$'; then
  echo "error: version must be bare semver, e.g. 1.8.0 (got '$version')" >&2
  exit 2
fi

tag="v$version"

# Refuse to release from a dirty tree or a side branch: the tag would point at
# a commit that does not contain the working state it was cut from.
branch="$(git rev-parse --abbrev-ref HEAD)"
if [ "$branch" != "main" ]; then
  echo "error: on branch '$branch', releases are cut from main" >&2
  exit 1
fi
if [ -n "$(git status --porcelain)" ]; then
  echo "error: working tree is dirty; commit or stash first" >&2
  git status --short >&2
  exit 1
fi
if git rev-parse "$tag" >/dev/null 2>&1; then
  echo "error: tag $tag already exists" >&2
  exit 1
fi

previous="$(git describe --tags --abbrev=0 2>/dev/null || echo '')"

echo "== releasing $tag ${previous:+(previous: $previous)}${dry_run:+ [dry run]}"

# Tests gate the release.  A tagged version is what other people install by
# name, so it is the one point where a red suite must stop the line.  Mirrors
# the CI loop: a suite that dies before printing anything must not pass.
#
# CI installs the soft dependencies (web-server, websocket) from MELPA; a
# local run has to find them or orgspec-mcp-test.el dies on `require' and the
# gate reports a dependency gap as a test failure.  Doom's straight build dir
# already holds them, so those two directories are added when present.
#
# Only those two, never the whole straight tree: adding all of Doom's packages
# also puts `eat' on the load-path, and mcp-emacs-run-test.el asserts that
# `--ensure-eat' signals when eat is absent -- so a broad path turns a passing
# suite red by removing its precondition.  The gate must mirror CI's
# environment, not the editor's.
#
# Deliberately not a fallback that skips a suite it cannot load: a gate that
# cannot tell broken code from a missing package is a gate that gets bypassed.
echo "-- running tests"
straight_build="$HOME/.emacs.doom/.local/straight/build-$(emacs -Q --batch --eval '(princ emacs-version)' 2>/dev/null)"
dep_args=()
for dep in web-server websocket; do
  if [ -d "$straight_build/$dep" ]; then
    dep_args+=(-L "$straight_build/$dep")
  fi
done

failed=""
for t in test/*.el; do
  out="$(emacs --batch \
           --eval "(require 'package)" \
           --eval "(package-initialize)" \
           "${dep_args[@]}" \
           -L elisp -l "$t" 2>&1)" || { failed="$failed $t(errored)"; continue; }
  if printf '%s' "$out" | grep -q '^FAIL'; then
    failed="$failed $t(failed)"
    printf '%s\n' "$out" | grep '^FAIL' >&2
  elif ! printf '%s' "$out" | grep -q '^PASS'; then
    failed="$failed $t(no-assertions)"
  fi
done
if [ -n "$failed" ]; then
  echo "error: tests not clean:$failed" >&2
  exit 1
fi
echo "   all suites clean"

# Every declaration of the version, rewritten from the argument.
echo "-- stamping version"
stamped=0
for f in elisp/*.el; do
  if grep -qE '^;; Version: ' "$f"; then
    # A literal replacement, anchored to the header comment, so a `Version:'
    # appearing in prose or a docstring is left alone.
    perl -pi -e "s/^;; Version: .*/;; Version: $version/ if \$. < 20" "$f"
    stamped=$((stamped + 1))
  fi
done
echo "   $stamped elisp files"

if [ -f .claude-plugin/plugin.json ]; then
  perl -pi -e 's/("version"\s*:\s*")[^"]*(")/${1}'"$version"'${2}/' \
    .claude-plugin/plugin.json
  echo "   .claude-plugin/plugin.json"
fi

if [ -n "$dry_run" ]; then
  echo "-- dry run, restoring tree"
  git checkout -- .
  echo "would commit, tag $tag, push, and create the release"
  exit 0
fi

git add -A
git commit -q -m "Bump version to $version"
git tag -a "$tag" -m "$tag"
echo "-- committed and tagged"

git push -q origin main
git push -q origin "$tag"
echo "-- pushed main and $tag"

# Notes from the log, so the release says what landed without hand-writing it.
if [ -n "$previous" ]; then
  notes="$(git log --no-merges --pretty='- %s' "$previous..$tag^")"
else
  notes="$(git log --no-merges --pretty='- %s' "$tag^")"
fi

if command -v gh >/dev/null 2>&1; then
  printf '%s\n' "$notes" | gh release create "$tag" --title "$tag" --notes-file -
  echo "-- created GitHub release $tag"
else
  echo "-- gh not found; tag pushed, create the release manually"
fi

# The hash, not the tag: Doom's `:pin' abbreviates its value with
# `substring', so a tag name dies with args-out-of-range before straight ever
# resolves it.  Printing the tag here once sent a consumer straight into that
# error, so the copy-pasteable form is the hash with the version beside it.
echo
echo "$tag released.  Pin it with:"
echo
echo "  ;; $tag"
echo "  :pin \"$(git rev-list -n 1 "$tag")\""

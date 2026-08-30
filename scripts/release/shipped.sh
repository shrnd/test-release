#!/usr/bin/env bash
# Records that the current version went live on the App Store, then opens
# the next release. Tags the newest archive of the current version
# <app>/shipped/<version> (pushed), and — when run on main — immediately
# bumps the minor so main always means "the next release". On a hotfix
# branch it records the ship and leaves versions alone (merge back to main;
# main keeps its higher version).
#
# Usage: scripts/release/shipped.sh <App> [build]
#   build   which archived build went live; defaults to the version's
#           highest build number

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
app_arg="${1:?usage: shipped.sh <App> [build]}"
build_arg="${2:-}"

app=""
for dir in "$REPO_ROOT"/Apps/*/; do
    name="$(basename "$dir")"
    if [ "$(tr '[:upper:]' '[:lower:]' <<<"$name")" = "$(tr '[:upper:]' '[:lower:]' <<<"$app_arg")" ]; then
        app="$name"
    fi
done
if [ -z "$app" ]; then
    echo "error: no app named '$app_arg' under Apps/" >&2
    exit 2
fi

cd "$REPO_ROOT"
app_lc="$(tr '[:upper:]' '[:lower:]' <<<"$app")"
version="$(sed -n 's/^ *MARKETING_VERSION: *//p' "Apps/$app/project.yml" | head -1 | tr -d '"')"

git fetch --quiet origin "refs/tags/$app_lc/*:refs/tags/$app_lc/*"

if git rev-parse --quiet --verify "refs/tags/$app_lc/shipped/$version" >/dev/null; then
    echo "error: $app_lc/shipped/$version already recorded" >&2
    exit 1
fi

# The build that shipped: highest build number archived for this version,
# unless one was named explicitly.
build=""
for t in $(git tag --list "$app_lc/$version-*"); do
    n="${t##*-}"
    case "$n" in ''|*[!0-9]*) continue ;; esac
    if [ -n "$build_arg" ]; then
        [ "$n" = "$build_arg" ] && build="$n"
    elif [ -z "$build" ] || [ "$n" -gt "$build" ]; then
        build="$n"
    fi
done
if [ -z "$build" ]; then
    echo "error: no archive tag matches $app_lc/$version-${build_arg:-*} — archive before shipping" >&2
    exit 1
fi

shipped_tag="$app_lc/shipped/$version"
git tag "$shipped_tag" "$app_lc/$version-$build^{}"
git push --quiet origin "refs/tags/$shipped_tag"
echo "Shipped:  $app $version ($build) — tagged $shipped_tag (pushed)"

branch="$(git branch --show-current)"
if [ "$branch" = "main" ]; then
    "$REPO_ROOT/scripts/release/version.sh" "$app" minor
else
    echo "Hotfix shipped from '$branch' — merge it back to main; main keeps its own version."
fi

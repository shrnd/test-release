#!/usr/bin/env bash
# Starts (or resumes) a hotfix for the latest shipped release: cuts
# release/<app>/<major.minor> from the shipped tag (or switches to it when
# it already exists) and bumps the patch there. If the branch already
# carries an unshipped patch, nothing is bumped — add the fix and
# re-archive under the pending version.
#
# After this: cherry-pick the fix onto the branch, run the release gate,
# archive.sh, ship, then run shipped.sh from the branch and merge it back
# to main (keep main's version if project.yml conflicts).
#
# Usage: scripts/release/hotfix.sh <App>

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
app_arg="${1:?usage: hotfix.sh <App>}"

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

if [ -n "$(git status --porcelain)" ]; then
    echo "error: working tree is dirty — commit or stash first" >&2
    exit 1
fi

git fetch --quiet origin

shipped="$(git tag --list "$app_lc/shipped/*" | sed "s|^$app_lc/shipped/||" | sort -V | tail -1)"
if [ -z "$shipped" ]; then
    echo "error: nothing shipped yet (no $app_lc/shipped/* tag) — a hotfix needs a shipped release" >&2
    exit 1
fi

IFS=. read -r maj min _ <<<"$shipped"
branch="release/$app_lc/$maj.$min"

if git rev-parse --quiet --verify "refs/heads/$branch" >/dev/null ||
   git rev-parse --quiet --verify "refs/remotes/origin/$branch" >/dev/null; then
    git switch --quiet "$branch"
    branch_version="$(sed -n 's/^ *MARKETING_VERSION: *//p' "Apps/$app/project.yml" | head -1 | tr -d '"')"
    if [ "$branch_version" != "$shipped" ] &&
       [ "$(printf '%s\n%s\n' "$shipped" "$branch_version" | sort -V | tail -1)" = "$branch_version" ]; then
        echo "note: $branch already carries unshipped $branch_version — add your fix there and re-archive; bumping nothing."
        exit 0
    fi
    echo "Resumed $branch at shipped $shipped."
else
    git switch --quiet -c "$branch" "$app_lc/shipped/$shipped"
    echo "Cut $branch from $app_lc/shipped/$shipped."
fi

"$REPO_ROOT/scripts/release/version.sh" "$app" patch
echo "Next: cherry-pick the fix, run the release gate, then scripts/release/archive.sh $app"

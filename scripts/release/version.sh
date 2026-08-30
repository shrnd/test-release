#!/usr/bin/env bash
# Bumps MARKETING_VERSION in Apps/<App>/project.yml and commits the bump.
# The only place the version ever changes; shipped.sh and hotfix.sh call
# this rather than editing the file themselves. Typing it yourself is for
# the exceptional cases: a rejection redo (patch a version that never
# shipped) or a deliberate major.
#
# Usage: scripts/release/version.sh <App> major|minor|patch|<x.y.z>

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
app="${1:?usage: version.sh <App> major|minor|patch|<x.y.z>}"
bump="${2:?usage: version.sh <App> major|minor|patch|<x.y.z>}"
cd "$REPO_ROOT"

yml="Apps/$app/project.yml"
if [ ! -f "$yml" ]; then
    echo "error: no $yml" >&2
    exit 2
fi

cur="$(sed -n 's/^ *MARKETING_VERSION: *//p' "$yml" | head -1 | tr -d '"')"
IFS=. read -r maj min pat <<<"$cur"
case "$bump" in
    major) new="$((maj + 1)).0.0" ;;
    minor) new="$maj.$((min + 1)).0" ;;
    patch) new="$maj.$min.$((pat + 1))" ;;
    [0-9]*.[0-9]*.[0-9]*) new="$bump" ;;
    *) echo "error: unknown bump '$bump'" >&2; exit 2 ;;
esac

# Versions only move forward.
if [ "$new" = "$cur" ] || [ "$(printf '%s\n%s\n' "$cur" "$new" | sort -V | tail -1)" != "$new" ]; then
    echo "error: $new is not ahead of $cur" >&2
    exit 1
fi

if [ -n "$(git status --porcelain)" ]; then
    echo "error: working tree is dirty — commit first" >&2
    exit 1
fi

sed -i '' "s/^\( *MARKETING_VERSION: *\).*/\1\"$new\"/" "$yml"
git add "$yml"
git commit -q -m "$app $new opened"
echo "$app: $cur -> $new (committed)"

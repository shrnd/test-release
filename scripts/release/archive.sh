#!/usr/bin/env bash
# Sandbox twin of scripts/release/archive.sh: identical guards, numbering,
# tagging, and pushing — only xcodebuild is stubbed. A "successful archive"
# is a line in ARCHIVES.log (the stand-in for Xcode's Organizer).
#
# Real archives get the next incremental build number, derived from the
# app's archive tags on origin (highest existing + 1 — global across
# versions and branches). Two guards run first:
#   - closed train: the version already has a datetime-stamped build, so any
#     incremental build would be rejected by App Store Connect
#   - already shipped: the version is <= the latest <app>/shipped/* tag
# Throwaway archives (--no-tag / --allow-dirty) stamp the UTC minute instead
# and are never tagged or uploaded.
#
# Usage: scripts/release/archive.sh <App> [--no-tag] [--allow-dirty]

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

tag=1
app_arg=""
for arg in "$@"; do
    case "$arg" in
        --no-tag) tag=0 ;;
        --allow-dirty) allow_dirty=1 ;;
        --*) echo "unknown option: $arg" >&2; exit 2 ;;
        *) app_arg="$arg" ;;
    esac
done
allow_dirty="${allow_dirty:-0}"
if [ -z "$app_arg" ]; then
    echo "Usage: scripts/release/archive.sh <App> [--no-tag] [--allow-dirty]" >&2
    exit 2
fi

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

git_sha="$(git rev-parse HEAD)"
git_state="$(git rev-parse --short HEAD)"
if [ -n "$(git status --porcelain)" ]; then
    if [ "$allow_dirty" -ne 1 ]; then
        echo "error: working tree is dirty — commit first, or pass --allow-dirty for an untagged throwaway archive" >&2
        git status --short >&2
        exit 1
    fi
    git_state="$git_state-dirty"
    tag=0
    echo "warning: working tree is dirty — archiving untagged ($git_state)" >&2
fi

marketing_version="$(sed -n 's/^ *MARKETING_VERSION: *//p' "Apps/$app/project.yml" | head -1 | tr -d '"')"
if [ -z "$marketing_version" ]; then
    echo "error: no MARKETING_VERSION in Apps/$app/project.yml" >&2
    exit 1
fi

app_lc="$(tr '[:upper:]' '[:lower:]' <<<"$app")"
if [ "$tag" -eq 1 ]; then
    git fetch --quiet origin "refs/tags/$app_lc/*:refs/tags/$app_lc/*"

    # Guard: closed train. A datetime-stamped build on this version means the
    # train's counter is stuck above any incremental number.
    if git tag --list "$app_lc/$marketing_version-*" | grep -qE -- '-[0-9]{7,}$'; then
        echo "error: $marketing_version's build counter is locked by a datetime stamp — bump the version (scripts/release/version.sh $app patch)" >&2
        exit 1
    fi

    # Guard: already shipped. A version is frozen the moment users have it.
    shipped_latest="$(git tag --list "$app_lc/shipped/*" | sed "s|^$app_lc/shipped/||" | sort -V | tail -1)"
    if [ -n "$shipped_latest" ]; then
        highest="$(printf '%s\n%s\n' "$marketing_version" "$shipped_latest" | sort -V | tail -1)"
        if [ "$marketing_version" = "$shipped_latest" ] || [ "$highest" != "$marketing_version" ]; then
            echo "error: $marketing_version already shipped ($app_lc/shipped/$shipped_latest) — open the next release (scripts/release/version.sh $app minor)" >&2
            exit 1
        fi
    fi

    # Next incremental build number: one past the highest build across the
    # app's archive tags. Datetime-stamped tags (the pre-incremental scheme)
    # each spent an ordinal, so they count into the floor instead of the max.
    max=0
    legacy=0
    for t in $(git tag --list "$app_lc/*"); do
        n="${t##*-}"
        case "$n" in ''|*[!0-9]*) continue ;; esac
        if [ "$n" -ge 1000000 ]; then
            legacy=$((legacy + 1))
        elif [ "$n" -gt "$max" ]; then
            max="$n"
        fi
    done
    [ "$legacy" -gt "$max" ] && max="$legacy"
    build_number=$((max + 1))
else
    # Throwaway archive: UTC minute stamp — visibly not a release.
    build_number="$(date -u +%y%m%d%H%M)"
fi
tag_name="$app_lc/$marketing_version-$build_number"

echo "Archiving $app $marketing_version ($build_number) at $git_state... (simulated)"
echo "$(date -u +%FT%TZ)  $app $marketing_version ($build_number)  [$git_state]" >>ARCHIVES.log

if [ "$tag" -eq 1 ]; then
    git tag "$tag_name" "$git_sha"
    if ! git push --quiet origin "refs/tags/$tag_name"; then
        git tag -d "$tag_name" >/dev/null
        echo "error: pushing $tag_name failed — the build number may have been taken by a concurrent archive; re-run for the next number" >&2
        exit 1
    fi
fi

echo
echo "Archived: $app $marketing_version ($build_number)  [$git_state]  -> ARCHIVES.log"
if [ "$tag" -eq 1 ]; then
    echo "Tagged:   $tag_name (pushed)"
    echo "Next:     pretend to upload + submit it; when Apple approves and it goes live, run scripts/release/shipped.sh $app"
fi

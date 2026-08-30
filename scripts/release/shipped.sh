#!/usr/bin/env bash
# Records that the current version went live on the App Store, then opens
# the next release. Tags the archived build that shipped
# <app>/shipped/<version> (pushed), and — when run on main — immediately
# bumps the minor so main always means "the next release". On a hotfix
# branch it records the ship and leaves versions alone (merge back to main;
# main keeps its higher version).
#
# The build must be named explicitly when the version has more than one
# archive — the record never guesses which binary Apple approved. The build
# going live must contain every previously shipped fix as a git ancestor;
# --without <version> acknowledges a named, deliberate regression.
#
# Usage: scripts/release/shipped.sh <App> [build] [--without <version>]...

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

app_arg=""
build_arg=""
without=""
expect_without=0
for arg in "$@"; do
    if [ "$expect_without" -eq 1 ]; then
        without="$without $arg"
        expect_without=0
        continue
    fi
    case "$arg" in
        --without) expect_without=1 ;;
        --*) echo "unknown option: $arg" >&2; exit 2 ;;
        *)
            if [ -z "$app_arg" ]; then
                app_arg="$arg"
            elif [ -z "$build_arg" ]; then
                build_arg="$arg"
            else
                echo "unexpected argument: $arg" >&2
                exit 2
            fi
            ;;
    esac
done
if [ -z "$app_arg" ] || [ "$expect_without" -eq 1 ]; then
    echo "Usage: scripts/release/shipped.sh <App> [build] [--without <version>]..." >&2
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
app_lc="$(tr '[:upper:]' '[:lower:]' <<<"$app")"
version="$(sed -n 's/^ *MARKETING_VERSION: *//p' "Apps/$app/project.yml" | head -1 | tr -d '"')"
shipped_tag="$app_lc/shipped/$version"

# All preconditions before any mutation: a failure past the tag push would
# strand a half-recorded ship.
if [ -n "$(git status --porcelain)" ]; then
    echo "error: working tree is dirty — commit first (shipping tags and bumps the version)" >&2
    exit 1
fi

git fetch --quiet origin "refs/tags/$app_lc/*:refs/tags/$app_lc/*"

if git rev-parse --quiet --verify "refs/tags/$shipped_tag" >/dev/null; then
    if git ls-remote --exit-code origin "refs/tags/$shipped_tag" >/dev/null 2>&1; then
        echo "error: $shipped_tag already recorded" >&2
        exit 1
    fi
    # A stranded half-record: the tag exists locally but its push failed.
    # Complete the record instead of erroring.
    git push --quiet origin "refs/tags/$shipped_tag"
    echo "Recovered: $shipped_tag was recorded locally but never pushed — pushed now."
else
    # The build that shipped. With several archives for the version the
    # record must not guess which binary Apple approved.
    builds=""
    for t in $(git tag --list "$app_lc/$version-*"); do
        n="${t##*-}"
        case "$n" in ''|*[!0-9]*) continue ;; esac
        builds="$builds $n"
    done
    # shellcheck disable=SC2086
    builds="$(printf '%s\n' $builds | sort -n | tr '\n' ' ')"
    build=""
    count=0
    for n in $builds; do
        count=$((count + 1))
        if [ -n "$build_arg" ]; then
            [ "$n" = "$build_arg" ] && build="$n"
        else
            build="$n"
        fi
    done
    if [ "$count" -eq 0 ]; then
        echo "error: no archive tag matches $app_lc/$version-* — archive before shipping" >&2
        exit 1
    fi
    if [ -n "$build_arg" ] && [ -z "$build" ]; then
        echo "error: no archive tag matches $app_lc/$version-$build_arg" >&2
        exit 1
    fi
    if [ -z "$build_arg" ] && [ "$count" -gt 1 ]; then
        echo "error: $version has $count archived builds ($(echo $builds | tr ' ' ',')) — name the one Apple approved:" >&2
        echo "  scripts/release/shipped.sh $app <build>" >&2
        exit 1
    fi

    # The build going live must contain everything already shipped — a
    # release archived before a hotfix merge would silently roll that fix
    # back. --without acknowledges a named regression.
    build_commit="$(git rev-parse "$app_lc/$version-$build^{commit}")"
    for s in $(git tag --list "$app_lc/shipped/*"); do
        sv="${s#"$app_lc/shipped/"}"
        skipped=0
        for w in $without; do
            [ "$w" = "$sv" ] && skipped=1
        done
        if [ "$skipped" -eq 1 ]; then
            echo "WARNING: shipping $version ($build) WITHOUT shipped $sv — a deliberate regression."
            continue
        fi
        if ! git merge-base --is-ancestor "$s" "$build_commit"; then
            echo "error: $version ($build) does not contain shipped $sv — shipping it would roll that fix back." >&2
            echo "       Archive a new build from a tree that includes it (merge the hotfix branch first)," >&2
            echo "       or acknowledge a deliberate regression: scripts/release/shipped.sh $app $build --without $sv" >&2
            exit 1
        fi
    done

    git tag "$shipped_tag" "$app_lc/$version-$build^{}"
    git push --quiet origin "refs/tags/$shipped_tag"
    echo "Shipped:  $app $version ($build) — tagged $shipped_tag (pushed)"
fi

branch="$(git branch --show-current)"
if [ "$branch" = "main" ]; then
    "$REPO_ROOT/scripts/release/version.sh" "$app" minor
elif [ -z "$branch" ]; then
    echo "Shipped from a detached HEAD — no version bump; check out main and bump manually."
else
    echo "Hotfix shipped from '$branch' — merge it back to main; main keeps its own version."
fi

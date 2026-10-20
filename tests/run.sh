#!/bin/bash
# Run the golden-vector tests off-device in the RokuCommunity brs interpreter.
# The interpreter is a first check only: it gets some LongInteger operations
# wrong, and the port avoids those, but a pass here is confirmed on a TV with
# `scripts/deploy.sh --test`.
#
# Also checks, against the upstream clone ($NOSTALGEX_DIR, default ../nostalgex)
# when there is one, that data/ and the vectors match the commit pinned in
# data/UPSTREAM, and warns when the clone's origin/main has moved past it.
set -euo pipefail
cd "$(dirname "$0")/.."
# Inside the personal repo's roku/ submodule the clone is two levels up.
upstream=${NOSTALGEX_DIR:-../nostalgex}
[ -n "${NOSTALGEX_DIR:-}" ] || [ -d "$upstream/.git" ] || [ ! -d ../../nostalgex/.git ] || upstream=../../nostalgex
pinned=$(sed -nE 's/^commit ([0-9a-f]{40}).*/\1/p' data/UPSTREAM)
if [ -d "$upstream/.git" ]; then
    git -C "$upstream" cat-file -e "$pinned^{commit}" 2>/dev/null || {
        echo "FAIL the upstream clone lacks the pinned commit ${pinned:0:7}; fetch it" >&2
        exit 1
    }
    # A throwaway checkout of the pin, so the check doesn't depend on, or move,
    # whatever the clone has checked out.
    pin_dir=$(mktemp -d)
    trap 'rm -rf "$pin_dir"' EXIT
    git clone -q --shared --no-checkout "$upstream" "$pin_dir"
    git -C "$pin_dir" checkout -q "$pinned"
    for f in channels.json channels-memberships.json franchises.json; do
        cmp -s "$pin_dir/$f" "data/$f" || { echo "FAIL data/$f differs from upstream ${pinned:0:7}" >&2; exit 1; }
    done
    for g in franchise-golden.json filter-golden.json season-golden.json; do
        cmp -s "$pin_dir/scripts/$g" "tests/vectors/$g" ||
            { echo "FAIL tests/vectors/$g differs from upstream ${pinned:0:7}" >&2; exit 1; }
    done
    # Upstream's own builder and filter must pass their golden files, or the files
    # prove nothing, and its collections module its own smoke test, or the vectors
    # from it don't.
    (cd "$pin_dir" && node scripts/nostalgex-franchise-smoke.mjs && node scripts/nostalgex-filter-golden-smoke.mjs && node scripts/nostalgex-collections-smoke.mjs && node scripts/nostalgex-season-smoke.mjs)
    NOSTALGEX_DIR=$pin_dir node tests/gen-vectors.mjs --check
    if ahead=$(git -C "$upstream" rev-list --count "$pinned..origin/main" 2>/dev/null) && [ "$ahead" -gt 0 ]; then
        echo "note: upstream origin/main is $ahead commits past the pinned ${pinned:0:7} (as of the clone's last fetch)"
    fi
else
    echo "no upstream clone at $upstream; skipping the staleness check"
fi
# Secrets never reach the debug console, which anyone on the network can read:
# no print statement may output a variable named like a token, URL or header.
# Quoted text is ignored, so a message may say "token".
leaks=$(grep -rnE '^\s*print\b' source components | perl -ne '
    my ($loc, $code) = /^([^:]+:\d+):(.*)$/; $code =~ s/"(?:[^"]|"")*"//g;
    print "$loc\n" if $code =~ /token|\buri\b|\burl\b|header/i;')
if [ -n "$leaks" ]; then
    echo "FAIL a print statement may output a secret:" >&2
    echo "$leaks" >&2
    exit 1
fi

python3 tests/tools/check-includes.py

# `m` is BrightScript's implicit this: a variable of that name silently holds
# the component's AA instead. It has cost three debugging rounds; fail fast.
shadow=$(grep -rnE '^\s*(for\s+)?m\s*=[^=]|\bas\s+\w+\s*,?\s*m\s+as\b|\(\s*m\s+as\b' source components tests --include=*.brs || true)
if [ -n "$shadow" ]; then
    echo "FAIL a variable named m (BrightScript's this):" >&2
    echo "$shadow" >&2
    exit 1
fi

# The components never run here, so a parse error in one (a reserved word
# such as `box` or `pos` as a name) would show only on a TV: parse each.
for f in components/*.brs; do
    parsed=$(npx -y -p @rokucommunity/brs@0.47.6 brs --root . "$f" 2>&1 || true)
    if grep -q "Error occurred parsing" <<<"$parsed"; then
        echo "FAIL $f doesn't parse:" >&2
        grep -v "^Warning: XML\|^npm warn" <<<"$parsed" | head -5 >&2
        exit 1
    fi
done

out=$(npx -y -p @rokucommunity/brs@0.47.6 brs --root . \
    tests/main.brs tests/runtime-interpreter.brs tests/ScheduleTests.brs tests/FilterTests.brs tests/FilterGoldenTests.brs tests/LineupTests.brs tests/FranchiseTests.brs tests/FranchiseGuideTests.brs tests/EnrichmentTests.brs tests/SubtitleTests.brs tests/GuideNavTests.brs tests/TuneQueueTests.brs tests/AdvanceTests.brs tests/SleepTimerTests.brs tests/DeepLinkTests.brs tests/CollectionTests.brs tests/ServerChoiceTests.brs tests/ServerResolveTests.brs tests/SnapshotTests.brs tests/SeasonalTests.brs tests/MediaBrowserTests.brs tests/QrTests.brs source/plex/ServerChoice.brs source/plex/ServerResolve.brs source/plex/LibrarySnapshot.brs source/plex/PlexLibrary.brs source/plex/PlexApi.brs source/util/*.brs source/schedule/*.brs source/filter/*.brs source/guide/*.brs source/franchise/*.brs source/enrich/*.brs source/subtitles/*.brs source/collections/*.brs source/mediabrowser/*.brs 2>&1 | grep -v '^npm warn')
echo "$out"
grep -q '^ALL TESTS PASSED' <<<"$out"

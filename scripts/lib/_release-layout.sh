#!/bin/bash
# _release-layout.sh — the facts a release archive must have, in one place.
#
# scripts/build/release.sh and scripts/build/package-release.sh both have to
# answer the same two questions about a candidate release:
#
#   1. Does the archive carry everything a recipient needs to read it
#      offline — the documentation, the licence texts, the notices?
#   2. Does every relative link in the shipped documentation resolve inside
#      the shipped tree?
#
# Both questions have exactly one answer, so the answers live here and both
# scripts assert them. Every function takes the tree or the archive listing as
# an argument and returns non-zero on a violation, which also means they can
# be exercised on a synthetic tree — no build, no packaging, no artifacts —
# when a gate needs to be shown to have discriminating power.
#
# Nothing here reads a global: every path arrives as an argument, so a caller
# cannot assert a layout of a tree it did not mean to assert.

# The licence texts live in one tracked directory in the checkout and are
# copied from it into both places a recipient can reach: the app bundle's
# Resources (so the app can name them) and the archive root (so a recipient
# can read them without unpacking the bundle).
MP_LICENSES_DIRNAME="Licenses"

# The documents whose relative links are asserted. These are the files the
# archive ships as documentation; a licence text is not documentation and its
# own links are its author's business, not this gate's.
mp_shipped_documents() {
    printf '%s\n' \
        "README.md" \
        "CONTRIBUTING.md" \
        "THIRD-PARTY-NOTICES.md" \
        "docs/README.zh-TW.md" \
        "docs/build.md" \
        "docs/usage.md" \
        "docs/language.md" \
        "docs/configuration.md"
}

# mp_release_root_entries — the archive-root files that must sit next to the
# app bundle, one path per line, relative to the archive root.
#
# README.md, LICENSE, THIRD-PARTY-NOTICES.md and CONTRIBUTING.md are the files
# README.md links to; docs/ carries every document the documentation links to
# (including the two screenshots README.md shows); .github/ISSUE_TEMPLATE
# carries the two issue forms CONTRIBUTING.md links to. A document whose links
# are dead is the same defect as a missing file, so the things they link to
# travel with them.
#
# The list is explicit on purpose: a missing entry is a refusal, not a
# silently shorter archive.
mp_release_root_entries() {
    printf '%s\n' \
        "README.md" \
        "LICENSE" \
        "THIRD-PARTY-NOTICES.md" \
        "CONTRIBUTING.md" \
        "docs/README.zh-TW.md" \
        "docs/build.md" \
        "docs/usage.md" \
        "docs/language.md" \
        "docs/configuration.md" \
        "docs/images/panel-stopped.png" \
        "docs/images/panel-connected.png" \
        ".github/ISSUE_TEMPLATE/bug_report.yml" \
        ".github/ISSUE_TEMPLATE/feature_request.yml"
}

# mp_license_file_names — the names of the vendored licence texts in <dir>,
# one per line, sorted. Hidden files are skipped: they are metadata, not
# licence texts, and none of them may reach the archive.
mp_license_file_names() {   # <dir>
    local d="$1" f
    [ -d "$d" ] || return 0
    for f in "$d"/*; do
        [ -f "$f" ] || continue
        case "${f##*/}" in
            .*) continue ;;
        esac
        printf '%s\n' "${f##*/}"
    done | LC_ALL=C sort
}

# mp_license_file_names_expected — the licence texts a release must carry, one
# per line, sorted.
#
# One full text per licence, not one per component: components under the same
# licence share a file, and THIRD-PARTY-NOTICES.md is what says which component
# a text covers. The list is explicit rather than derived from the checkout,
# because "the archive matches the tree" accepts any tree — including one that
# had silently lost a text. Every licence a bundled component needs must appear
# here by name or the release is refused.
#
# GPL-3 is deliberately absent: its canonical text is the repo's LICENSE, which
# ships at the archive root and in the bundle's Resources, so a copy here would
# duplicate a file the recipient already has. Filenames name the licence, never
# the component, so upgrading a component does not rename its text.
mp_license_file_names_expected() {
    printf '%s\n' \
        "0BSD.txt" \
        "Apache-2.0.txt" \
        "BSD-2-Clause-AOM.txt" \
        "BSD-2-Clause-Patent.txt" \
        "BSD-2-Clause.txt" \
        "BSD-3-Clause-Clear.txt" \
        "BSD-3-Clause-WITH-PCRE2-exception.txt" \
        "BSD-3-Clause.txt" \
        "GPL-2.0.txt" \
        "LGPL-2.0.txt" \
        "LGPL-2.1-and-GPL-2.0.txt" \
        "LGPL-2.1.txt" \
        "MIT.txt" \
        | LC_ALL=C sort
}

# mp_listing_licenses — the licence text names carried under <prefix> in an
# archive listing. <prefix> is the directory the licence directory sits in;
# the licence directory's own name is appended to it. Directory entries (the
# `Licenses/` record `unzip -Z1` prints) reduce to an empty name once the prefix
# is stripped and are dropped, so the result is exactly the file set.
mp_listing_licenses() {   # <listing-file> <prefix>
    local listing="$1" prefix="$2"
    grep -F "$prefix/$MP_LICENSES_DIRNAME/" "$listing" 2>/dev/null \
        | sed "s#^$prefix/$MP_LICENSES_DIRNAME/##" \
        | grep -v '/' \
        | grep -v '^$' \
        | LC_ALL=C sort
}

# mp_check_archive_entries — every entry the archive must carry.
#
# <listing-file> is a `unzip -Z1` listing (one path per line), <folder> the
# single top-level folder inside the archive, <app-name> the bundle's file
# name, <repo-root> the checkout the archive is built from. Prints what is
# missing and returns non-zero if anything is.
#
# The licence texts are checked in both directions: every vendored text must
# be present in both places a recipient can reach, and neither place may
# carry a text the checkout does not have. The forward direction catches a
# staging or copy-in bug; the reverse direction catches a bundle built from
# an older checkout, which is the same "the archive does not match the tree
# it claims to come from" failure the provenance gate exists for.
mp_check_archive_entries() {   # <listing-file> <folder> <app-name> <repo-root>
    local listing="$1" folder="$2" app="$3" repo="$4"
    local missing=0 entry name shipped expected
    local bundle_prefix="$folder/$app/Contents/Resources"

    while IFS= read -r entry; do
        [ -n "$entry" ] || continue
        grep -qxF "$folder/$entry" "$listing" || {
            printf 'missing archive entry: %s/%s\n' "$folder" "$entry" >&2
            missing=1
        }
    done <<EOF
$(mp_release_root_entries)
EOF

    # The bundle's own resources: the project's licence, the notices, and every
    # vendored third-party licence text.
    for entry in "Contents/Info.plist" "Contents/Resources/LICENSE" \
                 "Contents/Resources/THIRD-PARTY-NOTICES.md"; do
        grep -qxF "$folder/$app/$entry" "$listing" || {
            printf 'missing bundle entry: %s/%s/%s\n' "$folder" "$app" "$entry" >&2
            missing=1
        }
    done

    expected="$(mp_license_file_names_expected)"
    local checkout_set
    checkout_set="$(mp_license_file_names "$repo/$MP_LICENSES_DIRNAME")"
    if [ -z "$checkout_set" ]; then
        printf 'the checkout has no %s/ directory — refusing to publish an archive without licence texts\n' \
            "$MP_LICENSES_DIRNAME" >&2
        missing=1
        return $missing
    fi

    # The checkout itself is checked against the manifest, not against itself.
    # A tree that lost a text would otherwise pass every archive comparison
    # below, because both sides of that comparison would have lost it.
    if [ "$checkout_set" != "$expected" ]; then
        printf 'the checkout'"'"'s %s/ does not carry the expected licence texts:\n' \
            "$MP_LICENSES_DIRNAME" >&2
        printf '  unexpected in the checkout: %s\n' \
            "$(comm -13 <(printf '%s\n' "$expected") <(printf '%s\n' "$checkout_set") | tr '\n' ' ')" >&2
        printf '  missing from the checkout: %s\n' \
            "$(comm -23 <(printf '%s\n' "$expected") <(printf '%s\n' "$checkout_set") | tr '\n' ' ')" >&2
        missing=1
    fi

    # The same set must be present in both places, and in neither place may
    # be a text the checkout does not have.
    for where in "$bundle_prefix" "$folder"; do
        shipped="$(mp_listing_licenses "$listing" "$where")"
        while IFS= read -r name; do
            [ -n "$name" ] || continue
            grep -qxF "$where/$MP_LICENSES_DIRNAME/$name" "$listing" || {
                printf 'missing licence text: %s/%s/%s\n' "$where" "$MP_LICENSES_DIRNAME" "$name" >&2
                missing=1
            }
        done <<EOF
$expected
EOF
        if [ "$shipped" != "$expected" ]; then
            printf 'licence texts at %s do not match the checkout:\n' "$where" >&2
            printf '  only in the archive: %s\n' \
                "$(comm -13 <(printf '%s\n' "$expected") <(printf '%s\n' "$shipped") | tr '\n' ' ')" >&2
            printf '  only in the checkout: %s\n' \
                "$(comm -23 <(printf '%s\n' "$expected") <(printf '%s\n' "$shipped") | tr '\n' ' ')" >&2
            missing=1
        fi
    done

    return $missing
}

# mp_check_relative_links — every relative link in the given files resolves
# inside <root>.
#
# <root> is the tree the files are read from; the files are given as paths
# relative to <root>. Links are resolved against the directory of the file
# that contains them, which is what a Markdown reader does, so a link in
# docs/README.zh-TW.md to ../LICENSE is checked against <root>/LICENSE.
#
# Absolute URLs, mail addresses and pure anchors are not the archive's
# business and are skipped; an anchor that only qualifies a path
# (docs/usage.md#status-colours) is checked against the path.
#
# Prints every broken link and returns non-zero if any is broken.
mp_check_relative_links() {   # <root> <file>...
    local root="$1"; shift
    local f link target dir broken=0
    for f in "$@"; do
        [ -f "$root/$f" ] || continue
        dir="$(dirname "$f")"
        while IFS= read -r link; do
            case "$link" in
                http://*|https://*|mailto:*|'#'*) continue ;;
            esac
            target="${link%%#*}"
            [ -n "$target" ] || continue
            case "$target" in
                /*) continue ;;
            esac
            if [ ! -e "$root/$dir/$target" ]; then
                printf 'broken relative link: %s -> %s\n' "$f" "$link" >&2
                broken=1
            fi
        done <<EOF
$(grep -oE '\]\([^)]*\)' "$root/$f" 2>/dev/null | sed -e 's/^](//' -e 's/)$//' || true)
EOF
    done
    return $broken
}

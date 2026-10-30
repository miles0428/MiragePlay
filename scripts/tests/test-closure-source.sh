#!/bin/bash
# test-closure-source.sh — the closure must ship the GStreamer the helper was
# linked against, and must refuse to guess when it cannot tell.
#
# WHY THIS TEST EXISTS
#   The closure used to ask this shell's `pkg-config` / `brew --prefix` which
#   GStreamer to ship, while the helper had been linked by the core's configure
#   step — and the vendored CMakeLists prefers an installed GStreamer.framework.
#   On a machine with the framework installed the two answer differently, so the
#   bundle got Homebrew libraries for a framework-linked helper: two GStreamers
#   in one bundle, with every self-check green.
#
#   The authority is the core build record (its CMakeCache.txt). This test
#   builds two fake installations, makes the shell's pkg-config point at the
#   wrong one, and asserts the closure ships the record's one — then makes the
#   record itself unusable in three different ways and asserts each is a hard
#   failure that names both sides.
#
#   positive             record=A, shell pkg-config=B -> the closure is built
#                        from A only (and says so), version comes from A's .pc
#   negative (ambiguous) record names two installations -> fail, both named
#   negative (no source) record names no GStreamer at all -> fail, record and
#                        shell pkg-config both named
#   negative (plugin axis) plugin dir resolves into the other installation
#                        -> fail, both axes named
#   negative (scanner)   scanner from the other installation handed in -> fail,
#                        both axes named
#
# Usage:  ./scripts/tests/test-closure-source.sh
# Exit:   0 = every assertion held, 1 = at least one did not.

set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJ="$(cd "$HERE/../.." && pwd)"

# shellcheck source=scripts/lib/_canonical-path.sh
. "$HERE/../lib/_canonical-path.sh"
PROJ="$(mp_canonical_dir "$PROJ")" || {
    echo "test-closure-source: cannot resolve the repo root" >&2
    exit 1
}
# shellcheck source=scripts/lib/_pkg-closure.sh
. "$HERE/../lib/_pkg-closure.sh"

PASS=0
FAIL=0
WORK="$(mktemp -d "${TMPDIR:-/tmp}/closure-source.XXXXXX")" || exit 1
cleanup() {
    if [ "$FAIL" -eq 0 ]; then
        rm -rf "$WORK"
    else
        echo "evidence kept at $WORK"
    fi
}
trap cleanup EXIT

pass() { PASS=$((PASS + 1)); printf '  ok   %s\n' "$*"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$*"; }
section() { printf '\n== %s\n' "$*"; }

# --- fixture: two fake GStreamer installations -------------------------------

command -v clang >/dev/null 2>&1 || {
    echo "test-closure-source: clang is required to build the fixture" >&2
    exit 1
}

cat >"$WORK/foo.c" <<'CEOF'
int fixture_symbol(void) { return 42; }
CEOF
cat >"$WORK/main.c" <<'CEOF'
int fixture_symbol(void);
int main(void) { return fixture_symbol() == 42 ? 0 : 1; }
CEOF
cat >"$WORK/plug.c" <<'CEOF'
int fixture_symbol(void);
int fixture_plugin_init(void) { return fixture_symbol(); }
CEOF

# Build one installation: <root>/lib/libgstreamer-1.0.dylib, the 14 plugins, a
# scanner, a pkgconfig file, a helper executable and a plugin image.
#   $1  installation root   $2  version string
make_install() {
    local root="$1" version="$2"
    mkdir -p "$root/lib/gstreamer-1.0" "$root/lib/pkgconfig" "$root/libexec/gstreamer-1.0"
    clang -dynamiclib -o "$root/lib/libgstreamer-1.0.dylib" "$WORK/foo.c" \
        -Wl,-install_name,"$root/lib/libgstreamer-1.0.dylib" \
        -Wl,-headerpad_max_install_names >/dev/null 2>&1 || return 1
    clang -dynamiclib -o "$WORK/plugin-$version.dylib" "$WORK/plug.c" \
        -L"$root/lib" -lgstreamer-1.0 \
        -Wl,-headerpad_max_install_names >/dev/null 2>&1 || return 1
    local name
    for name in $(pkg_core_plugin_names); do
        cp "$WORK/plugin-$version.dylib" "$root/lib/gstreamer-1.0/libgst$name.dylib"
    done
    cp "$WORK/plugin-$version.dylib" "$root/libexec/gstreamer-1.0/gst-plugin-scanner"
    chmod +x "$root/libexec/gstreamer-1.0/gst-plugin-scanner"
    clang -o "$WORK/uxplay-$version" "$WORK/main.c" -L"$root/lib" -lgstreamer-1.0 \
        -Wl,-headerpad_max_install_names >/dev/null 2>&1 || return 1
    printf 'Name: gstreamer-1.0\nVersion: %s\nlibdir=%s/lib\n' "$version" "$root" \
        >"$root/lib/pkgconfig/gstreamer-1.0.pc"
    return 0
}

A="$WORK/installA/1.26.10"
B="$WORK/installB/1.28.8"
make_install "$A" "1.26.10" || { echo "test-closure-source: fixture A failed" >&2; exit 1; }
make_install "$B" "1.28.8"  || { echo "test-closure-source: fixture B failed" >&2; exit 1; }

# The shell's pkg-config answers with installation B, whatever the record says.
mkdir -p "$WORK/stubbin"
cat >"$WORK/stubbin/pkg-config" <<CEOF
#!/bin/bash
case "\$1" in
    --variable=libdir*) printf '%s\\n' "$B/lib" ;;
    --modversion*)      printf '%s\\n' "1.28.8" ;;
    *)                  exit 1 ;;
esac
CEOF
chmod +x "$WORK/stubbin/pkg-config"

CACHE_A="$WORK/cache-A.txt"
{
    printf 'PKG_CONFIG_EXECUTABLE:FILEPATH=/usr/bin/pkg-config\n'
    printf 'GST_FOUND:INTERNAL=1\n'
    printf 'GST_LIBRARY_DIRS:INTERNAL=%s\n' "$A/lib"
    printf 'GST_LDFLAGS:INTERNAL=-L%s/lib;-lgstreamer-1.0\n' "$A"
    printf 'GST_LIBRARIES:INTERNAL=gstreamer-1.0\n'
} >"$CACHE_A"

# --- positive: the record wins over the shell ---------------------------------

section "positive: record says A, shell pkg-config says B"
export PATH="$WORK/stubbin:$PATH"
export PKG_CLOSURE_CORE_CACHE="$CACHE_A"

printf '  shell pkg-config libdir: %s\n' "$(pkg-config --variable=libdir gstreamer-1.0)"
libdir="$(pkg_gst_libdir 2>/dev/null)"
if [ "$libdir" = "$A/lib" ]; then
    pass "pkg_gst_libdir followed the core build record ($libdir)"
else
    fail "pkg_gst_libdir returned '$libdir' instead of the record's $A/lib"
fi
version="$(pkg_gst_version 2>/dev/null)"
if [ "$version" = "1.26.10" ]; then
    pass "the version comes from the record's installation (1.26.10), not from pkg-config"
else
    fail "the version came from '$version' instead of the record's 1.26.10"
fi
scanner="$(pkg_gst_scanner 2>/dev/null)"
case "$(realpath "$scanner" 2>/dev/null)" in
    "$(realpath "$A")"/*) pass "the scanner comes from the same installation ($scanner)" ;;
    *)                    fail "the scanner is '$scanner', not from $A" ;;
esac

OUT="$WORK/closure"
ERR="$WORK/closure.err"
pkg_compute_closure "$OUT" "$WORK/uxplay-1.26.10" "$scanner" 2>"$ERR"
rc=$?
if [ "$rc" -eq 0 ]; then
    pass "closure built from the record's installation (rc=0)"
else
    fail "closure failed (rc=$rc) although the record names a usable installation"
    sed -n '1,6p' "$ERR" | sed 's/^/    | /'
fi
if [ -s "$OUT/closure.tsv" ]; then
    if grep -Fq "$(realpath "$A")/lib/gstreamer-1.0/" "$OUT/closure.tsv"; then
        pass "the closure's plugins come from installation A"
    else
        fail "the closure contains no plugin from installation A"
    fi
    if grep -Fq "$(realpath "$B")/" "$OUT/closure.tsv"; then
        fail "the closure also contains images from installation B (mixed sources)"
        grep -F "$(realpath "$B")/" "$OUT/closure.tsv" | sed -n '1,3p' | sed 's/^/    | /'
    else
        pass "the closure contains nothing from installation B (no mixed sources)"
    fi
    printf '  %s\n' "$(pkg_closure_summary "$OUT/closure.tsv")"
else
    fail "no closure.tsv was written"
fi
if grep -Fq "note: this shell's pkg-config points at $B/lib" "$ERR"; then
    pass "the divergence is stated in the build log instead of being silent"
else
    fail "the build log does not mention that the shell's pkg-config disagrees"
    sed -n '1,6p' "$ERR" | sed 's/^/    | /'
fi

# --- negative: the record is ambiguous ---------------------------------------

section "negative: the record names two installations"
CACHE_TWO="$WORK/cache-two.txt"
{
    printf 'GST_LIBRARY_DIRS:INTERNAL=%s/lib;%s/lib\n' "$A" "$B"
    printf 'GST_LDFLAGS:INTERNAL=-L%s/lib;-L%s/lib\n' "$A" "$B"
} >"$CACHE_TWO"
out="$(PKG_CLOSURE_CORE_CACHE="$CACHE_TWO" pkg_gst_libdir 2>&1)"
rc=$?
if [ "$rc" -ne 0 ]; then
    pass "an ambiguous record fails closed (rc=$rc)"
else
    fail "an ambiguous record was resolved to '$out' instead of failing"
fi
if printf '%s\n' "$out" | grep -Fq "more than one GStreamer library directory" \
    && printf '%s\n' "$out" | grep -Fq "$A/lib" \
    && printf '%s\n' "$out" | grep -Fq "$B/lib"; then
    pass "the error names both candidate directories"
    printf '%s\n' "$out" | grep -F 'candidate' | sed -n '1,3p' | sed 's/^/    | /'
else
    fail "the error does not name both candidates"
    printf '%s\n' "$out" | sed -n '1,6p' | sed 's/^/    | /'
fi
if printf '%s\n' "$out" | grep -Fq "shell pkg-config  : $B/lib"; then
    pass "the error also names what the shell's pkg-config would have said"
else
    fail "the error does not name the shell's pkg-config answer"
fi

# --- negative: the record says nothing about GStreamer -----------------------

section "negative: the record names no GStreamer at all"
CACHE_NONE="$WORK/cache-none.txt"
printf 'GST_FOUND:INTERNAL=0\n' >"$CACHE_NONE"
out="$(PKG_CLOSURE_CORE_CACHE="$CACHE_NONE" pkg_gst_libdir 2>&1)"
rc=$?
if [ "$rc" -ne 0 ] && printf '%s\n' "$out" | grep -Fq "names no GStreamer library directory"; then
    pass "a record with no GStreamer fails closed instead of falling back to pkg-config"
else
    fail "a record with no GStreamer did not fail closed (rc=$rc)"
    printf '%s\n' "$out" | sed -n '1,5p' | sed 's/^/    | /'
fi
if printf '%s\n' "$out" | grep -Fq "shell pkg-config  : $B/lib"; then
    pass "the error names the pkg-config answer it refused to use"
else
    fail "the error does not name the pkg-config answer"
fi

# --- negative: the plugin axis belongs to another installation ---------------

section "negative: the plugin directory resolves into the other installation"
C="$WORK/installA-plugswap/1.26.10"
mkdir -p "$C/lib"
cp "$A/lib/libgstreamer-1.0.dylib" "$C/lib/libgstreamer-1.0.dylib"
ln -s "$B/lib/gstreamer-1.0" "$C/lib/gstreamer-1.0"
CACHE_C="$WORK/cache-pluginaxis.txt"
printf 'GST_LIBRARY_DIRS:INTERNAL=%s/lib\n' "$C" >"$CACHE_C"
out="$(PKG_CLOSURE_CORE_CACHE="$CACHE_C" pkg_gst_plugindir 2>&1)"
rc=$?
if [ "$rc" -ne 0 ]; then
    pass "lib axis and plugin axis disagreeing is a hard failure (rc=$rc)"
else
    fail "a plugin directory from another installation was accepted: $out"
fi
if printf '%s\n' "$out" | grep -Fq "lib axis and plugin axis disagree" \
    && printf '%s\n' "$out" | grep -Fq "$(realpath "$C")" \
    && printf '%s\n' "$out" | grep -Fq "$(realpath "$B")/"; then
    pass "the error names both axes"
    printf '%s\n' "$out" | grep -F 'axis' | sed 's/^/    | /'
else
    fail "the error does not name both axes"
    printf '%s\n' "$out" | sed -n '1,6p' | sed 's/^/    | /'
fi

# --- negative: a scanner from another installation must be refused -----------

section "negative: a scanner from the other installation"
rm -rf "$WORK/closure-mixed"
out="$(PKG_CLOSURE_CORE_CACHE="$CACHE_A" pkg_compute_closure "$WORK/closure-mixed" \
        "$WORK/uxplay-1.26.10" "$B/libexec/gstreamer-1.0/gst-plugin-scanner" 2>&1)"
rc=$?
if [ "$rc" -ne 0 ]; then
    pass "a scanner from another installation is refused (rc=$rc)"
else
    fail "a scanner from another installation was accepted"
fi
if printf '%s\n' "$out" | grep -Fq "lib axis and plugin axis disagree" \
    && printf '%s\n' "$out" | grep -Fq "$(realpath "$B")/libexec"; then
    pass "the refusal names the foreign scanner and the record's installation"
    printf '%s\n' "$out" | grep -F 'axis' | sed 's/^/    | /'
else
    fail "the refusal does not name the foreign scanner"
    printf '%s\n' "$out" | sed -n '1,6p' | sed 's/^/    | /'
fi

# --- summary -----------------------------------------------------------------

printf '\n== summary: PASS=%d FAIL=%d ==\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] && exit 0
exit 1

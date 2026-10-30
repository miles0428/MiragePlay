#!/bin/bash
# test-closure-rpath.sh — @rpath / @loader_path / @executable_path resolution in
# the GStreamer closure, plus the "no build-machine rpath in the bundle" guard.
#
# WHY THIS TEST EXISTS
#   The closure used to hand every LC_LOAD_DYLIB string straight to `[ -e ]`.
#   That is true for Homebrew (absolute install names) and false for the
#   official GStreamer.framework .pkg, whose install names are
#   @rpath/lib<name>.dylib: every such dependency was reported as
#   "closure: dangling dependency @rpath/..." even though dyld loads it fine.
#   The second half of the same blind spot: pkg_assert_no_homebrew only greps
#   /opt/homebrew, so a bundle that still carried @rpath/... dependencies passed
#   every self-check and died at dyld on the recipient's Mac.
#
# WHAT IT BUILDS (nothing outside this run's temp directory is touched)
#   a fake GStreamer installation with one dylib referenced through @rpath, the
#   14 core plugins, a scanner, a helper executable, and a CMakeCache that names
#   that installation as the core's GStreamer — then it runs the real
#   pkg_compute_closure over the lot.
#
#   positive             @rpath/libfoo.dylib resolves through the referencing
#                        image's own LC_RPATH to the real file
#   positive (last resort) @rpath/libgstreamer-1.0.dylib resolves through the
#                        library directory the core build record names, when no
#                        LC_RPATH of any image covers it
#   positive             @loader_path/<x> and @executable_path/<x> expand
#   negative #1          LC_RPATH pointing at a directory that does not exist
#                        -> still dangling, non-zero
#   negative #2          a same-named, different dylib in the rpath directory
#                        -> rejected (its install name disagrees), still dangling
#   negative #3          a same-named non-Mach-O file in the rpath directory
#                        -> rejected, still dangling
#   guard                pkg_assert_no_rpath_deps fails on a bundle that carries
#                        @rpath/... and passes once it is @loader_path/...
#                        (pkg_assert_no_homebrew stays green on that same bundle,
#                        which is the "all green, still cannot start" case)
#
# Usage:  ./scripts/tests/test-closure-rpath.sh
# Exit:   0 = every assertion held, 1 = at least one did not.

set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJ="$(cd "$HERE/../.." && pwd)"

# shellcheck source=scripts/lib/_canonical-path.sh
. "$HERE/../lib/_canonical-path.sh"
PROJ="$(mp_canonical_dir "$PROJ")" || {
    echo "test-closure-rpath: cannot resolve the repo root" >&2
    exit 1
}
# shellcheck source=scripts/lib/_pkg-closure.sh
. "$HERE/../lib/_pkg-closure.sh"
# shellcheck source=scripts/lib/_pkg-relocate.sh
. "$HERE/../lib/_pkg-relocate.sh"

PASS=0
FAIL=0
WORK="$(mktemp -d "${TMPDIR:-/tmp}/closure-rpath.XXXXXX")" || exit 1
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

# --- fixture -----------------------------------------------------------------

command -v clang >/dev/null 2>&1 || {
    echo "test-closure-rpath: clang is required to build the fixture" >&2
    exit 1
}

KEG="$WORK/keg/1.99.0"          # fake GStreamer installation
LIB="$KEG/lib"
PLUGINS="$LIB/gstreamer-1.0"
OTHER="$WORK/otherlib"          # the directory the rpath points at
CORE="$WORK/core"
BIN="$KEG/libexec/gstreamer-1.0"
mkdir -p "$LIB" "$PLUGINS" "$OTHER" "$CORE" "$BIN"

cat >"$WORK/foo.c" <<'CEOF'
int fixture_symbol(void) { return 42; }
CEOF
cat >"$WORK/decoy.c" <<'CEOF'
int fixture_symbol(void) { return 7; }
CEOF
cat >"$WORK/main.c" <<'CEOF'
int fixture_symbol(void);
int main(void) { return fixture_symbol() == 42 ? 0 : 1; }
CEOF
cat >"$WORK/plug.c" <<'CEOF'
int fixture_symbol(void);
int fixture_plugin_init(void) { return fixture_symbol(); }
CEOF

# The GStreamer installation itself: one dylib so source resolution has
# something to point at.
clang -dynamiclib -o "$LIB/libgstreamer-1.0.dylib" "$WORK/foo.c" \
    -Wl,-install_name,"@rpath/libgstreamer-1.0.dylib" \
    -Wl,-headerpad_max_install_names >/dev/null 2>&1 || {
    echo "test-closure-rpath: could not build the fixture dylib" >&2
    exit 1
}

# The dependency under test: a dylib whose install name is @rpath/libfoo.dylib
# (set with install_name_tool, exactly like a framework .pkg would ship it).
clang -dynamiclib -o "$OTHER/libfoo.dylib" "$WORK/foo.c" \
    -Wl,-install_name,"/tmp/libfoo.dylib" \
    -Wl,-headerpad_max_install_names >/dev/null 2>&1
install_name_tool -id "@rpath/libfoo.dylib" "$OTHER/libfoo.dylib" >/dev/null 2>&1

# A different image that will be planted under the same file name.
clang -dynamiclib -o "$WORK/libdecoy.dylib" "$WORK/decoy.c" \
    -Wl,-install_name,"@rpath/libdecoy.dylib" \
    -Wl,-headerpad_max_install_names >/dev/null 2>&1

# plugin image: links libfoo through @rpath, carries its own LC_RPATH.
clang -dynamiclib -o "$WORK/plugin.dylib" "$WORK/plug.c" \
    -L"$OTHER" -lfoo \
    -Wl,-install_name,"@rpath/libgstfixture.dylib" \
    -Wl,-rpath,"$OTHER" \
    -Wl,-headerpad_max_install_names >/dev/null 2>&1 || {
    echo "test-closure-rpath: could not build the fixture plugin" >&2
    exit 1
}
for name in $(pkg_core_plugin_names); do
    cp "$WORK/plugin.dylib" "$PLUGINS/libgst$name.dylib"
done

# scanner: a Mach-O that references the same @rpath dependency.
cp "$WORK/plugin.dylib" "$BIN/gst-plugin-scanner"
chmod +x "$BIN/gst-plugin-scanner"

# helper executable: links @rpath/libfoo.dylib with an LC_RPATH that resolves it.
clang -o "$CORE/uxplay" "$WORK/main.c" -L"$OTHER" -lfoo \
    -Wl,-rpath,"$OTHER" \
    -Wl,-headerpad_max_install_names >/dev/null 2>&1 || {
    echo "test-closure-rpath: could not build the fixture helper" >&2
    exit 1
}

# The core build record: this is what the closure is allowed to believe.
CACHE="$WORK/CMakeCache.txt"
{
    printf 'GST_FOUND:INTERNAL=1\n'
    printf 'GST_LIBRARY_DIRS:INTERNAL=%s\n' "$LIB"
    printf 'GST_LDFLAGS:INTERNAL=-L%s;-lgstreamer-1.0\n' "$LIB"
    printf 'GST_LIBRARIES:INTERNAL=gstreamer-1.0\n'
} >"$CACHE"
export PKG_CLOSURE_CORE_CACHE="$CACHE"

section "fixture sanity"
printf '  helper deps : %s\n' "$(pkg_dylib_deps "$CORE/uxplay" | tr '\n' ' ')"
printf '  helper rpath: %s\n' "$(pkg_dylib_rpaths "$CORE/uxplay" | tr '\n' ' ')"
if pkg_dylib_deps "$CORE/uxplay" | grep -Fxq '@rpath/libfoo.dylib'; then
    pass "fixture helper really carries an @rpath/... dependency"
else
    fail "fixture helper does not carry @rpath/libfoo.dylib (fixture is wrong)"
fi
if pkg_dylib_rpaths "$CORE/uxplay" | grep -Fxq "$OTHER"; then
    pass "fixture helper carries an LC_RPATH at $OTHER"
else
    fail "fixture helper has no LC_RPATH at $OTHER"
fi

# --- positive: @rpath resolves, the closure completes --------------------------

section "@rpath/<leaf> resolves through the referencing image's LC_RPATH"
OUT="$WORK/closure-ok"
STDERR="$WORK/closure-ok.err"
rm -rf "$OUT"
pkg_compute_closure "$OUT" "$CORE/uxplay" "$BIN/gst-plugin-scanner" 2>"$STDERR"
rc=$?
cat "$STDERR" | sed 's/^/    | /'
if [ "$rc" -eq 0 ]; then
    pass "closure completed (rc=0) instead of reporting the @rpath dependency as dangling"
else
    fail "closure failed (rc=$rc) on a resolvable @rpath dependency"
fi
want_real="$(realpath "$OTHER/libfoo.dylib")"
if awk -F'\t' -v r="$want_real" '$4 == r {found=1} END{exit !found}' "$OUT/closure.tsv" 2>/dev/null; then
    pass "libfoo was recorded at its real path ($want_real)"
else
    fail "libfoo is missing from closure.tsv (or recorded at the wrong path)"
fi
if grep -q 'dangling' "$STDERR"; then
    fail "closure printed a dangling dependency despite resolving it"
else
    pass "no dangling dependency was reported"
fi
if awk -F'\t' '$4 ~ /^@/ {bad=1} END{exit bad}' "$OUT/closure.tsv" 2>/dev/null; then
    pass "every manifest row carries a real path, not a dyld token"
else
    fail "closure.tsv contains a row whose path is still @rpath/@loader_path"
fi
# The leaf must stay the name written in the load command (that is what the
# alias logic and the relocation rules work from).
if awk -F'\t' -v r="$want_real" '$4 == r {print $3}' "$OUT/closure.tsv" | grep -Fxq 'libfoo.dylib'; then
    pass "the recorded leaf name is the one from the load command (libfoo.dylib)"
else
    fail "the recorded leaf name is not libfoo.dylib"
fi

section "@rpath/<leaf> resolves through the core build record's library directory"
# A helper whose dependency can only be resolved from the GStreamer install
# directory named by the core build record (no LC_RPATH covers it).
clang -o "$WORK/core/lastresort" "$WORK/main.c" -L"$LIB" -lgstreamer-1.0 \
    -Wl,-rpath,"/nonexistent/fixture-rpath" \
    -Wl,-headerpad_max_install_names >/dev/null 2>&1
got="$(_pkg_resolve_dep_reference '@rpath/libgstreamer-1.0.dylib' "$WORK/core/lastresort" "" "$LIB" 2>/dev/null)"
if [ -n "$got" ] && [ "$(realpath "$got")" = "$(realpath "$LIB/libgstreamer-1.0.dylib")" ]; then
    pass "resolved via the core build record's libdir: $got"
else
    fail "@rpath resolution did not fall back to the core build record's libdir (got '${got:-nothing}')"
fi

section "@loader_path/<x> and @executable_path/<x> expand"
mkdir -p "$WORK/loader" "$WORK/exe/priv"
cp "$OTHER/libfoo.dylib" "$WORK/loader/libfoo.dylib"
cp "$OTHER/libfoo.dylib" "$WORK/exe/priv/libfoo.dylib"
cp "$CORE/uxplay" "$WORK/loader/client"
cp "$CORE/uxplay" "$WORK/exe/client"
got="$(_pkg_resolve_dep_reference '@loader_path/libfoo.dylib' "$WORK/loader/client" "" 2>/dev/null)"
if [ "$(realpath "${got:-/nonexistent}" 2>/dev/null)" = "$(realpath "$WORK/loader/libfoo.dylib")" ]; then
    pass "@loader_path expands against the referencing image's directory"
else
    fail "@loader_path did not expand (got '${got:-nothing}')"
fi
got="$(_pkg_resolve_dep_reference '@executable_path/priv/libfoo.dylib' "$WORK/exe/client" "$WORK/exe/client" 2>/dev/null)"
if [ "$(realpath "${got:-/nonexistent}" 2>/dev/null)" = "$(realpath "$WORK/exe/priv/libfoo.dylib")" ]; then
    pass "@executable_path expands against the main executable's directory"
else
    fail "@executable_path did not expand (got '${got:-nothing}')"
fi

# --- negative #1: rpath pointing nowhere must still be dangling ---------------

section "negative control #1: LC_RPATH points at a directory that does not exist"
clang -o "$WORK/core/broken" "$WORK/main.c" -L"$OTHER" -lfoo \
    -Wl,-rpath,"$WORK/nowhere/nothing-here" \
    -Wl,-headerpad_max_install_names >/dev/null 2>&1
rm -rf "$WORK/closure-neg1"
pkg_compute_closure "$WORK/closure-neg1" "$WORK/core/broken" "$BIN/gst-plugin-scanner" \
    2>"$WORK/closure-neg1.err"
rc=$?
if [ "$rc" -ne 0 ]; then
    pass "closure failed (rc=$rc) as it must"
else
    fail "closure succeeded although the @rpath dependency cannot be resolved"
fi
if grep -Fq 'closure: dangling dependency @rpath/libfoo.dylib' "$WORK/closure-neg1.err"; then
    pass "the failure is reported as a dangling @rpath dependency"
    sed -n '1,3p' "$WORK/closure-neg1.err" | sed 's/^/    | /'
else
    fail "no 'dangling dependency @rpath/libfoo.dylib' line in the output"
    sed -n '1,5p' "$WORK/closure-neg1.err" | sed 's/^/    | /'
fi

# --- negative #2: same name, different image ---------------------------------

section "negative control #2: a same-named but different dylib in the rpath directory"
DECOY="$WORK/decoydir"
rm -rf "$DECOY"
mkdir -p "$DECOY"
cp "$WORK/libdecoy.dylib" "$DECOY/libfoo.dylib"     # right name, wrong image
clang -o "$WORK/core/decoyed" "$WORK/main.c" -L"$OTHER" -lfoo \
    -Wl,-rpath,"$DECOY" \
    -Wl,-headerpad_max_install_names >/dev/null 2>&1
rm -rf "$WORK/closure-neg2"
pkg_compute_closure "$WORK/closure-neg2" "$WORK/core/decoyed" "$BIN/gst-plugin-scanner" \
    2>"$WORK/closure-neg2.err"
rc=$?
if [ "$rc" -ne 0 ]; then
    pass "closure failed (rc=$rc): the decoy was not adopted"
else
    fail "closure adopted a same-named decoy image"
fi
if grep -Fq "install name is '@rpath/libdecoy.dylib'" "$WORK/closure-neg2.err"; then
    pass "the rejection says why: the decoy's install name disagrees"
    grep -F 'install name is' "$WORK/closure-neg2.err" | sed -n '1,2p' | sed 's/^/    | /'
else
    fail "the decoy was not rejected on its install name"
    sed -n '1,5p' "$WORK/closure-neg2.err" | sed 's/^/    | /'
fi

# --- negative #3: same name, not a Mach-O ------------------------------------

section "negative control #3: a same-named non-Mach-O file in the rpath directory"
JUNK="$WORK/junkdir"
rm -rf "$JUNK"
mkdir -p "$JUNK"
printf 'not an image\n' >"$JUNK/libfoo.dylib"
clang -o "$WORK/core/junked" "$WORK/main.c" -L"$OTHER" -lfoo \
    -Wl,-rpath,"$JUNK" \
    -Wl,-headerpad_max_install_names >/dev/null 2>&1
rm -rf "$WORK/closure-neg3"
pkg_compute_closure "$WORK/closure-neg3" "$WORK/core/junked" "$BIN/gst-plugin-scanner" \
    2>"$WORK/closure-neg3.err"
rc=$?
if [ "$rc" -ne 0 ] && grep -Fq 'not a Mach-O image' "$WORK/closure-neg3.err"; then
    pass "closure failed (rc=$rc) and said the candidate is not a Mach-O image"
else
    fail "a non-Mach-O file with the right name was accepted (rc=$rc)"
    sed -n '1,5p' "$WORK/closure-neg3.err" | sed 's/^/    | /'
fi

# --- guard: the bundle must not carry @rpath/@executable_path dependencies ----

section "guard: pkg_assert_no_rpath_deps must fail on a build-machine load path"
BUNDLE="$WORK/bundle/Contents"
mkdir -p "$BUNDLE/MacOS" "$BUNDLE/Frameworks" "$BUNDLE/plugins" "$BUNDLE/bin"
cp "$OTHER/libfoo.dylib" "$BUNDLE/Frameworks/libfoo.dylib"
cp "$CORE/uxplay" "$BUNDLE/MacOS/uxplay"           # dep: @rpath/libfoo.dylib
cp "$WORK/plugin.dylib" "$BUNDLE/plugins/libgstapp.dylib"
cp "$WORK/plugin.dylib" "$BUNDLE/bin/gst-plugin-scanner"

out="$(pkg_assert_no_rpath_deps "$BUNDLE" 2>&1)"
rc=$?
if [ "$rc" -ne 0 ]; then
    pass "the new guard fails on a bundle that still carries @rpath (rc=$rc)"
    printf '%s\n' "$out" | sed -n '1,4p' | sed 's/^/    | /'
else
    fail "the new guard passed a bundle that carries @rpath/... dependencies"
fi
if printf '%s\n' "$out" | grep -Fq 'UNRESOLVED_DYLD_LOAD_PATH uxplay'; then
    pass "the guard names the offending Mach-O and its load path"
else
    fail "the guard output does not name the offending Mach-O"
fi
# The point of the guard: the pre-existing check is green on the same bundle.
if pkg_assert_no_homebrew "$BUNDLE" >/dev/null 2>&1; then
    pass "pkg_assert_no_homebrew alone is green on that bundle (the blind spot is real)"
else
    fail "pkg_assert_no_homebrew was already red, so this bundle does not demonstrate the blind spot"
fi

# Repair exactly what relocation is supposed to have done, and the guard clears.
install_name_tool -change "@rpath/libfoo.dylib" \
    "@loader_path/../Frameworks/libfoo.dylib" "$BUNDLE/MacOS/uxplay" >/dev/null 2>&1
for f in "$BUNDLE/plugins/libgstapp.dylib" "$BUNDLE/bin/gst-plugin-scanner"; do
    install_name_tool -change "@rpath/libfoo.dylib" \
        "@loader_path/../Frameworks/libfoo.dylib" "$f" >/dev/null 2>&1
done
if pkg_assert_no_rpath_deps "$BUNDLE" >/dev/null 2>&1; then
    pass "the guard is green once every load path is @loader_path (not a constant failure)"
else
    fail "the guard is still red after the load paths were rewritten to @loader_path"
fi

# --- summary -----------------------------------------------------------------

printf '\n== summary: PASS=%d FAIL=%d ==\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] && exit 0
exit 1

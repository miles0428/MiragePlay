#!/bin/bash
# _pkg-closure.sh — compute the shipping closure of the uxplay/GStreamer stack.
#
# Source this file from build-app.sh / package-release.sh (do not execute it):
#
#     . "$REPO_ROOT/scripts/lib/_pkg-closure.sh"
#
# The closure is what has to travel inside the helper bundle for it to run on a
# machine without Homebrew. It is NOT "the helper's direct dependencies": it is
# the transitive image set rooted at the GStreamer plugins uxplay asks for,
# plus the helper executable and the GStreamer plugin scanner.
#
# Why the plugins are the root and not the uxplay binary: uxplay itself links
# only 8 GStreamer-family dylibs, but a pipeline that cannot find
# libgstlibav.dylib / libgstcoreelements.dylib fails at gst_parse_launch with a
# far less obvious error ("Required gstreamer plugin 'app' not found"). Rooting
# at the plugin set makes the closure complete by construction (release contract
# P-7.2).
#
# WHICH GStreamer (the single source of record)
#   The one the helper was LINKED against: whatever the core's configure step
#   wrote into its CMakeCache.txt. That is not necessarily what this shell's
#   `pkg-config` answers — the vendored CMakeLists prefers an installed
#   GStreamer.framework, so on such a machine configure used the framework while
#   a plain shell still reports Homebrew. Following the shell there produced a
#   bundle whose libraries came from Homebrew while the helper had been linked
#   against the framework: two GStreamers, one bundle. Every source below is
#   derived from the core build record (pkg_gst_core_cache), and the three axes
#   (libraries, plugins, scanner) are verified to belong to the same
#   installation or the computation fails closed with both sides named.
#
# Public API (all read-only, no bundle writes):
#   pkg_brew_prefix                 Apple-Silicon-or-Intel Homebrew prefix
#                                   (diagnostics only — never a closure source)
#   pkg_gst_core_cache              CMakeCache.txt of the core build (authority)
#   pkg_gst_libdir        [cache]   GStreamer library directory of that build
#   pkg_gst_plugindir     [cache]   GStreamer plugin directory (same build)
#   pkg_gst_scanner       [cache]   gst-plugin-scanner of the same build
#   pkg_gst_version       [cache]   GStreamer version of that build
#   pkg_core_plugin_names           the 14 plugin basenames uxplay needs
#   pkg_is_system_image <path>      true for /usr/lib, /System, /Library/Apple
#   pkg_dylib_deps <macho>          LC_LOAD_DYLIB paths of a Mach-O
#   pkg_dylib_rpaths <macho>        LC_RPATH search paths of a Mach-O
#   pkg_dylib_id <macho>            LC_ID_DYLIB path of a Mach-O (empty if none)
#   pkg_compute_closure <dir> <uxplay> <scanner>
#                                   writes <dir>/closure.tsv and echoes a
#                                   summary; returns 1 on a dangling reference
#
# closure.tsv is tab separated:
#   role  size_bytes  basename  realpath  aliases  minos
# where `aliases` is a comma separated list of additional leaf names the image
# is referenced by (the version-alias symlinks required by P-7.2/R7-R8), and
# `minos` is the LC_BUILD_VERSION minimum. Empty fields are written as "-"
# because tab is IFS whitespace: an empty field between two tabs would be
# collapsed by `read` and silently shift every column after it.

PKG_CLOSURE_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PKG_CLOSURE_REPO_ROOT="$(cd "$PKG_CLOSURE_SCRIPT_DIR/../.." && pwd)"

# --- the GStreamer source of record: the core build record --------------------
#
# Everything in this section reads the CMakeCache.txt of the core build. Nothing
# here asks `pkg-config` what it thinks: the shell's answer is only ever printed
# inside an error message, so a human can see how far the two pointers diverged.

# Print the value of one CMake cache entry (empty when the entry is absent).
#   $1  cache file
#   $2  variable name (without the ":TYPE" suffix)
_pkg_cache_value() {
    awk -v want="$2:" '
        index($0, want) == 1 {
            eq = index($0, "=")
            if (eq > 0) { print substr($0, eq + 1); exit }
        }
    ' "$1" 2>/dev/null
}

# Print every library directory the record gives for the GStreamer pkg-config
# modules, most specific first, one per line (duplicates and blanks are fine;
# the caller deduplicates by real path).
#   $1  cache file
_pkg_gst_record_libdirs() {
    local cache="$1" module value
    for module in GST GST124; do
        value="$(_pkg_cache_value "$cache" "${module}_LIBRARY_DIRS")"
        printf '%s\n' "$value" | tr ';' '\n' | sed '/^[[:space:]]*$/d'
        value="$(_pkg_cache_value "$cache" "${module}_LIBDIR")"
        [ -z "$value" ] || printf '%s\n' "$value"
        value="$(_pkg_cache_value "$cache" "${module}_PREFIX")"
        [ -z "$value" ] || printf '%s/lib\n' "$value"
        value="$(_pkg_cache_value "$cache" "${module}_LDFLAGS")"
        printf '%s\n' "$value" | tr ';' '\n' | sed -n 's/^-L//p'
    done
}

# True when a directory holds a libgstreamer-1.0 image: that is what makes it a
# candidate for "the GStreamer this build used" at all.
_pkg_gst_dir_has_lib() {
    local dir="$1" f
    [ -d "$dir" ] || return 1
    for f in "$dir"/libgstreamer-1.0*.dylib; do
        if [ -e "$f" ]; then
            return 0
        fi
    done
    return 1
}

# The library directory a macOS framework bundle really spells, for a recorded
# path that uses the pkg-config spelling.
#
# A framework bundle is laid out as <Name>.framework/Libraries (a symlink to
# Versions/<v>/lib), but the .pc files shipped by the "Official" GStreamer .pkg
# say `libdir=${prefix}/lib`. The vendored configure step rewrites its own link
# lines (renderers/CMakeLists.txt) yet CMakeCache.txt keeps the pkg-config
# spelling verbatim, so on such a machine the record names <bundle>/lib — a
# directory that has never existed there — while the libraries sit one alias
# away under <bundle>/Libraries.
#
# The filesystem decides, never the string shape:
#   - the recorded path must be ABSENT. An <bundle>/lib that exists but holds
#     no libgstreamer is dependency drift inside an installed bundle (a
#     framework upgraded in place), not a spelling, and must stay a hard error.
#   - a component of it must end in `.framework` and the component immediately
#     below that bundle must be exactly `lib`: that is the only spelling
#     pkg-config produces.
#   - <bundle>/Libraries must exist AND hold a libgstreamer-1.0 image, so the
#     alias is granted by the same evidence every other candidate needs.
#
# Args:
#     path (string): a recorded library directory.
#
# Echoes:
#     the counterpart library directory, when the alias resolves.
#
# Returns:
#     int: 0 when the path is a framework `lib` alias with the libraries under
#          `Libraries`; 1 otherwise (including for every framework path whose
#          counterpart is missing or empty — a framework-shaped string alone is
#          never evidence that the libraries are there).
_pkg_gst_framework_lib_root() {
    local path="$1" bundle="" root=""
    bundle="$(_pkg_gst_framework_bundle "$path")" || return 1
    # A spelling only applies to a path that is not there. Whatever exists is
    # judged on its contents by the caller.
    if [ -d "$path" ]; then
        return 1
    fi
    # A dangling alias into an uninstalled framework is dependency drift.
    [ -d "$bundle" ] || return 1
    root="$bundle/Libraries"
    [ -d "$root" ] || return 1
    _pkg_gst_dir_has_lib "$root" || return 1
    printf '%s\n' "$root"
}

# One-line-per-directory account of what the framework alias was tried on, for
# the zero-candidate error message: a log that only says "nothing exists" leaves
# the reader unable to tell a missing alias from an alias that was never
# considered.
#
# Args:
#     cache (string): the core build record.
#
# Echoes:
#     one line per distinct recorded directory: the resolved alias when it is
#     usable, or the reason it was refused when the path is framework-shaped;
#     a single "tried (...)" line when no recorded directory is spelled
#     <bundle>.framework/lib at all.
_pkg_gst_alias_report() {
    local cache="$1" dir alt="" lines=""
    while IFS= read -r dir; do
        [ -n "$dir" ] || continue
        alt="$(_pkg_gst_framework_lib_root "$dir")" || alt=""
        if [ -n "$alt" ]; then
            lines="${lines}gst-source:   framework alias  : $dir -> $alt (usable)"$'\n'
            continue
        fi
        if _pkg_gst_framework_bundle "$dir" >/dev/null; then
            lines="${lines}gst-source:   framework alias  : $dir -> refused (bundle absent, not a <bundle>/lib spelling, or Libraries without libgstreamer)"$'\n'
        fi
    done < <(_pkg_gst_record_libdirs "$cache" | awk 'NF && !seen[$0]++')
    printf '%s' "${lines:-gst-source:   framework alias  : tried (no recorded dir is spelled <bundle>.framework/lib)}"
}

# The framework bundle a recorded library directory is spelled under, when the
# spelling is pkg-config's `<bundle>/lib`.
#
# String shape only — existence and contents belong to the caller. `lib` must be
# the component IMMEDIATELY below the bundle (that is the only spelling
# pkg-config produces) and the bundle component must end at a '/' boundary, so
# `foo.frameworkish/lib` never qualifies and `lib/gstreamer-1.0` (a real
# directory: the plugin directory) is not a spelling.
#
# Args:
#     path (string): a recorded library directory.
#
# Echoes:
#     the bundle directory, when the path is spelled `<bundle>/lib`.
#
# Returns:
#     int: 0 when the path has that shape, 1 otherwise.
_pkg_gst_framework_bundle() {
    local raw="$1" path="" parts=() part="" prefix="" bundle=""
    # Collapse repeated slashes before parsing: the record — and any path that
    # came through a TMPDIR with a trailing slash — can spell `/a//b`, and the
    # component-by-component rebuild below would then not line up with the raw
    # string. `tr -s` is a no-op for a path that is already spelled once.
    path="$(printf '%s\n' "$raw" | tr -s '/')"
    path="${path%/}"
    case "$path" in
        *.framework|*.framework/*) ;;
        *) return 1 ;;
    esac
    IFS='/' read -r -a parts <<<"$path"
    for part in ${parts[@]+"${parts[@]}"}; do
        [ -n "$part" ] || continue
        prefix="$prefix/$part"
        case "$part" in
            *.framework) bundle="$prefix" ;;
        esac
    done
    [ -n "$bundle" ] || return 1
    [ "${path#"$bundle"/}" = "lib" ] || return 1
    printf '%s\n' "$bundle"
}

# What this shell's pkg-config answers, for error messages only.
_pkg_gst_shell_libdir() {
    local dir
    dir="$(pkg-config --variable=libdir gstreamer-1.0 2>/dev/null)" || dir=""
    if [ -z "$dir" ]; then
        printf '%s\n' "(pkg-config has no gstreamer-1.0)"
        return 0
    fi
    printf '%s\n' "$dir"
}

# Print a fail-closed GStreamer-source error: the problem, the record it was
# read from, whatever extra lines the caller wants, and the shell's own answer
# so the divergence that caused it is visible in the build log.
#   $1  problem (one line)
#   $2  core build record path
#   $3.. extra lines, each already prefixed by the caller
_pkg_gst_source_error() {
    local problem="$1" cache="$2"
    shift 2
    {
        printf 'gst-source: %s\n' "$problem"
        printf 'gst-source:   core build record : %s\n' "$cache"
        while [ "$#" -gt 0 ]; do
            printf '%s\n' "$1"
            shift
        done
        printf 'gst-source:   shell pkg-config  : %s (version %s)\n' \
            "$(_pkg_gst_shell_libdir)" \
            "$(pkg-config --modversion gstreamer-1.0 2>/dev/null || echo unknown)"
        printf 'gst-source: refusing to guess: the closure must ship the GStreamer the helper was linked against\n'
    } >&2
}

# Path of the CMake cache that recorded the configure step of this core build.
# Callers that know their build directory export PKG_CLOSURE_CORE_CACHE; the
# fallbacks exist so a sourced-only use (tests, ad-hoc checks) still lands on
# the same file the entry points use.
pkg_gst_core_cache() {
    local cache="${PKG_CLOSURE_CORE_CACHE:-}" root=""
    if [ -n "$cache" ]; then
        printf '%s\n' "$cache"
        return 0
    fi
    if command -v uxplay_core_build_dir >/dev/null 2>&1 \
        && command -v uxplay_default_build_root >/dev/null 2>&1; then
        root="$(uxplay_default_build_root 2>/dev/null)" || root=""
        if [ -n "$root" ]; then
            printf '%s/CMakeCache.txt\n' "$(uxplay_core_build_dir "$root")"
            return 0
        fi
    fi
    printf '%s/_build/core/CMakeCache.txt\n' "$PKG_CLOSURE_REPO_ROOT"
}

# GStreamer library directory of the build the helper came from.
#
# Echoes <dir> and returns 0 only when the core build record names exactly one
# directory that actually holds libgstreamer. Zero candidates (the record does
# not know a GStreamer) and two or more distinct ones (the record is ambiguous)
# are both hard errors: either way this shell cannot know which GStreamer the
# helper was linked against, and picking one would be a guess that ships.
#
# One spelling is converted, never guessed: a recorded <bundle>.framework/lib
# that does not exist is the alias of <bundle>.framework/Libraries when — and
# only when — that directory exists and holds the libgstreamer image
# (_pkg_gst_framework_lib_root). The conversion still goes through the same
# evidence check as every other candidate, and the alias does not add a
# candidate: it resolves the one the record named. Ambiguity and emptiness stay
# hard errors.
#   [cache file]
pkg_gst_libdir() {
    local cache="${1:-$(pkg_gst_core_cache)}"
    local dir real resolved seen="" candidates="" count=0 chosen=""

    if [ ! -f "$cache" ]; then
        _pkg_gst_source_error \
            "no core build record at $cache; cannot tell which GStreamer the helper was linked against" \
            "$cache"
        return 1
    fi

    while IFS= read -r dir; do
        [ -n "$dir" ] || continue
        resolved="$dir"
        if ! _pkg_gst_dir_has_lib "$resolved"; then
            # A directory that exists without libgstreamer is drift, not a
            # spelling; only an absent path may be a framework alias.
            if [ -d "$dir" ]; then
                continue
            fi
            resolved="$(_pkg_gst_framework_lib_root "$dir")" || continue
        fi
        real="$(realpath "$resolved")"
        case "$seen" in
            *"|$real|"*) continue ;;
        esac
        seen="$seen|$real|"
        if [ "$resolved" = "$dir" ]; then
            candidates="${candidates}gst-source:   candidate        : $dir -> $real"$'\n'
        else
            candidates="${candidates}gst-source:   candidate        : $dir -> $resolved (framework alias) -> $real"$'\n'
        fi
        count=$((count + 1))
        chosen="$resolved"
    done < <(_pkg_gst_record_libdirs "$cache")

    if [ "$count" -eq 0 ]; then
        # One line per distinct recorded directory (the record often spells the
        # same directory twice, e.g. GST_LIBRARY_DIRS and GST_PREFIX), then one
        # line per framework alias that was tried and refused: the log must show
        # what was attempted, not repeat what was not.
        local raw=""
        raw="$(_pkg_gst_record_libdirs "$cache" | awk 'NF && !seen[$0]++' | tr '\n' ' ')"
        _pkg_gst_source_error \
            "the core build record names no GStreamer library directory that exists on disk" \
            "$cache" \
            "gst-source:   recorded dirs    : ${raw:-(none)}" \
            "$(_pkg_gst_alias_report "$cache")"
        return 1
    fi
    if [ "$count" -gt 1 ]; then
        _pkg_gst_source_error \
            "the core build record names more than one GStreamer library directory" \
            "$cache" \
            "$(printf '%s' "$candidates")"
        return 1
    fi
    printf '%s\n' "$chosen"
}

# True when <path> is <dir> or lies below it. Both are expected to be
# realpath'ed by the caller.
#   $1 path   $2 dir
_pkg_path_within() {
    case "$1" in
        "$2"|"$2"/*) return 0 ;;
    esac
    return 1
}

# The installation a GStreamer library directory belongs to, as a real path:
# the directory that holds the lib/ tree the images really live in. Homebrew's
# /opt/homebrew/lib is a flat directory of symlinks into the Cellar, so the
# library directory's own real path is not it — the image's is.
#   $1  library directory
_pkg_gst_install_root() {
    local dir="$1" f
    [ -d "$dir" ] || return 1
    for f in "$dir"/libgstreamer-1.0*.dylib; do
        [ -e "$f" ] || continue
        printf '%s\n' "$(dirname "$(dirname "$(realpath "$f")")")"
        return 0
    done
    return 1
}

# GStreamer plugin directory of the same build: <libdir>/gstreamer-1.0.
#
# The plugin axis must belong to the same installation as the library axis — a
# plugin directory that resolves outside it means the record describes two
# installations, which is exactly the split the closure refuses to ship.
#   [cache file]
pkg_gst_plugindir() {
    local cache="${1:-$(pkg_gst_core_cache)}"
    local libdir plugindir root real_plug

    libdir="$(pkg_gst_libdir "$cache")" || return 1
    plugindir="$libdir/gstreamer-1.0"
    if [ ! -d "$plugindir" ]; then
        _pkg_gst_source_error \
            "the plugin directory $plugindir (library directory of the core build) does not exist" \
            "$cache" \
            "gst-source:   lib axis         : $libdir"
        return 1
    fi
    root="$(_pkg_gst_install_root "$libdir")" || {
        _pkg_gst_source_error \
            "cannot locate the GStreamer installation behind $libdir" \
            "$cache" \
            "gst-source:   lib axis         : $libdir"
        return 1
    }
    real_plug="$(realpath "$plugindir")"
    if ! _pkg_path_within "$real_plug" "$root"; then
        _pkg_gst_source_error \
            "the plugin directory is not inside the library installation: lib axis and plugin axis disagree" \
            "$cache" \
            "gst-source:   lib axis         : $root" \
            "gst-source:   plugin axis      : $real_plug"
        return 1
    fi
    printf '%s\n' "$plugindir"
}

# gst-plugin-scanner of the same build. It must travel with the bundle (its own
# LC_LOAD_DYLIBs point into the installation and it generally has no rpath), and
# it must come from the same installation as the libraries: a scanner from
# another GStreamer writes a registry the shipped plugins cannot load.
#
# Only the core build record is searched, from the library directory upwards.
# How many levels that takes is a property of each GStreamer's layout, so no
# fixed count is assumed: a Homebrew keg keeps libexec/ at the keg, a framework
# version dir at Versions/<v>/, a prefix install at the prefix — and a framework
# whose Libraries alias resolves into Versions/<v>/lib needs the scan from the
# version dir, not from the bundle. The walk therefore goes one ancestor at a
# time up to (but excluding) the filesystem root, nearest ancestor first, and
# every hit must still resolve inside the ancestor it was found under, so a
# scanner can only come from a directory that contains these libraries.
# The Homebrew prefix is never used as a fallback — it is only named in the
# error so the divergence is visible.
#   [cache file]
pkg_gst_scanner() {
    local cache="${1:-$(pkg_gst_core_cache)}"
    local libdir real root cand roots="" tried=""

    libdir="$(pkg_gst_libdir "$cache")" || return 1
    real="$(_pkg_gst_install_root "$libdir")" || real="$(realpath "$libdir")"
    root="$real"
    while [ -n "$root" ] && [ "$root" != "/" ]; do
        roots="${roots}${roots:+ }$root"
        for cand in \
            "$root/libexec/gstreamer-1.0/gst-plugin-scanner" \
            "$root/bin/gst-plugin-scanner" \
            "$root/libexec/gst-plugin-scanner" \
            "$root/Commands/gst-plugin-scanner"; do
            tried="${tried}gst-source:   searched         : $cand"$'\n'
            [ -f "$cand" ] || continue
            if _pkg_path_within "$(realpath "$cand")" "$root"; then
                printf '%s\n' "$cand"
                return 0
            fi
        done
        root="$(dirname "$root")"
    done
    _pkg_gst_source_error \
        "no gst-plugin-scanner in the GStreamer the core build record names (searched upwards from $real)" \
        "$cache" \
        "gst-source:   roots            : $roots" \
        "gst-source:   brew would give  : $(brew --prefix gstreamer 2>/dev/null)/libexec/gstreamer-1.0/gst-plugin-scanner (a DIFFERENT GStreamer, not used)"
    return 1
}

# Version of the GStreamer the core build record names. Read from the .pc file
# next to the libraries; the directory name is the last resort (a Cellar keg is
# named after its version).
#   [cache file]
pkg_gst_version() {
    local cache="${1:-$(pkg_gst_core_cache)}"
    local libdir real pc value

    libdir="$(pkg_gst_libdir "$cache")" || return 1
    real="$(_pkg_gst_install_root "$libdir")" || real="$(realpath "$libdir")"
    for pc in "$real/lib/pkgconfig/gstreamer-1.0.pc" \
              "$real/pkgconfig/gstreamer-1.0.pc"; do
        [ -f "$pc" ] || continue
        value="$(sed -n 's/^Version:[[:space:]]*//p' "$pc" | sed -n '1p')"
        if [ -n "$value" ]; then
            printf '%s\n' "$value"
            return 0
        fi
    done
    printf '%s\n' "$(basename "$real")"
}

# Homebrew prefix of this machine (never assume /opt/homebrew). Diagnostics
# only: no path of this file derives a closure source from it.
pkg_brew_prefix() {
    local p
    p="$(brew --prefix 2>/dev/null)" || return 1
    [ -n "$p" ] || return 1
    printf '%s\n' "$p"
}

# The 14 plugins uxplay needs. 5 are named by check_plugins(); the other 9 are
# what the audio/video pipelines actually instantiate at runtime (P-7.2 C-5).
pkg_core_plugin_names() {
    printf '%s\n' \
        app libav playback autodetect videoparsersbad \
        coreelements videoconvertscale audioconvert audioresample \
        volume level osxvideo osxaudio typefindfunctions
}

# --- Mach-O inspection --------------------------------------------------------

# System images never travel with the bundle.
pkg_is_system_image() {
    case "$1" in
        /usr/lib/*|/System/*|/Library/Apple/*) return 0 ;;
        *) return 1 ;;
    esac
}

# Print every LC_LOAD_DYLIB / LC_LOAD_WEAK_DYLIB / LC_REEXPORT_DYLIB path of a
# Mach-O, including duplicates (callers dedupe).
pkg_dylib_deps() {
    otool -l "$1" 2>/dev/null | awk '
        /^[[:space:]]*cmd[[:space:]]+LC_LOAD(_WEAK)?_DYLIB[[:space:]]*$/ { want = 1; next }
        /^[[:space:]]*cmd[[:space:]]+LC_REEXPORT_DYLIB[[:space:]]*$/     { want = 1; next }
        want && /^[[:space:]]*name[[:space:]]/ {
            sub(/^[[:space:]]*name[[:space:]]+/, "")
            sub(/ \(offset .*$/, "")
            print
            want = 0
        }
    '
}

# Print every LC_RPATH search path of a Mach-O, in load-command order. The paths
# are printed verbatim (they may themselves contain @loader_path or
# @executable_path); expansion is _pkg_expand_dyld_path's job.
pkg_dylib_rpaths() {
    otool -l "$1" 2>/dev/null | awk '
        /^[[:space:]]*cmd[[:space:]]+LC_RPATH[[:space:]]*$/ { want = 1; next }
        want && /^[[:space:]]*path[[:space:]]/ {
            sub(/^[[:space:]]*path[[:space:]]+/, "")
            sub(/ \(offset .*$/, "")
            print
            want = 0
        }
    '
}

# Print the LC_ID_DYLIB install name of a Mach-O (nothing for plain
# executables). `otool -D` prints "<file>:" then the id on the next line.
pkg_dylib_id() {
    otool -D "$1" 2>/dev/null | sed -n '2p'
}

# Print the LC_BUILD_VERSION minos of a Mach-O (empty when the load command is
# absent, e.g. some prebuilt helper binaries).
pkg_dylib_minos() {
    otool -l "$1" 2>/dev/null | awk '
        /LC_BUILD_VERSION/ { f = 1; next }
        f && /^[[:space:]]*minos[[:space:]]/ { print $2; exit }
    '
}

# True for a Mach-O file (any byte order, thin or fat). `otool` cannot be used
# here: it prints "is not an object file" and still exits 0, so it would call a
# text file an image.
_pkg_is_macho() {
    local magic
    [ -f "$1" ] || return 1
    magic="$(od -An -tx1 -N4 "$1" 2>/dev/null | tr -d ' \n')"
    case "$magic" in
        feedface|feedfacf|cefaedfe|cffaedfe|cafebabe|bebafeca) return 0 ;;
    esac
    return 1
}

# --- dyld path resolution -----------------------------------------------------
#
# The closure used to treat every load command as a stat-able absolute path.
# That holds for Homebrew (absolute install names) and fails for the official
# GStreamer.framework .pkg, whose install names are @rpath/lib<name>.dylib:
# `[ -e "@rpath/..." ]` is always false, so every such dependency was reported
# as dangling even though dyld loads it fine.
#
# Resolution here mirrors dyld's, per referencing image:
#   @loader_path/<x>       <directory of the referencing image>/<x>
#   @executable_path/<x>   <directory of the main executable>/<x>
#   @rpath/<leaf>          for each LC_RPATH of the referencing image, then for
#                          each LC_RPATH of the main executable (last resort),
#                          then the GStreamer library directory the core build
#                          record names: <search dir>/<leaf>, first real image
#                          wins
# Nothing resolves -> the caller still reports a dangling dependency. A string
# that merely looks like @rpath is never waved through.

# Expand @loader_path / @executable_path inside one dyld path.
#   $1  path as written in a load command (or an LC_RPATH entry)
#   $2  directory @loader_path means here (the referencing image's directory)
#   $3  directory @executable_path means here (the main executable's directory)
_pkg_expand_dyld_path() {
    local path="$1" loader="${2:-}" exe="${3:-}"
    case "$path" in
        @loader_path)       printf '%s\n' "$loader" ;;
        @loader_path/*)     printf '%s/%s\n' "${loader%/}" "${path#@loader_path/}" ;;
        @executable_path)   printf '%s\n' "$exe" ;;
        @executable_path/*) printf '%s/%s\n' "${exe%/}" "${path#@executable_path/}" ;;
        *)                  printf '%s\n' "$path" ;;
    esac
}

# True when a file found for <leaf> is the image the load command designates
# rather than an unrelated file that happens to carry the name. dyld matches on
# the name alone, so a same-named decoy in an rpath directory would be loaded;
# shipping one is a silent runtime failure, so the candidate must be a Mach-O
# whose own install name agrees with the leaf. A version alias (the directory
# entry is a symlink) is accepted as-is: that is how the Cellar spells aliases.
#   $1  candidate path   $2  referenced leaf name
_pkg_candidate_ok() {
    local cand="$1" leaf="$2" id idleaf

    [ -f "$cand" ] || return 1
    if ! _pkg_is_macho "$cand"; then
        echo "closure: rejected $cand: not a Mach-O image" >&2
        return 1
    fi
    if [ -L "$cand" ]; then
        return 0
    fi
    id="$(pkg_dylib_id "$cand")"
    if [ -z "$id" ]; then
        return 0
    fi
    idleaf="${id##*/}"
    if [ "$idleaf" = "$leaf" ]; then
        return 0
    fi
    echo "closure: rejected $cand: its install name is '$id', not '$leaf'" >&2
    return 1
}

# Resolve <leaf> inside one search directory; echo the candidate on success.
#   $1  search directory   $2  referenced leaf name
_pkg_try_candidate() {
    local dir="$1" leaf="$2" cand
    [ -n "$dir" ] || return 1
    [ -n "$leaf" ] || return 1
    cand="${dir%/}/$leaf"
    _pkg_candidate_ok "$cand" "$leaf" || return 1
    printf '%s\n' "$cand"
}

# Resolve one load command path to the file it designates.
#   $1  path as written in the load command
#   $2  referencing image (the Mach-O that carries the load command; empty when
#       the path is a closure root)
#   $3  main executable (the core binary), owner of the last-resort LC_RPATH;
#       may be empty
#   $4  GStreamer library directory from the core build record; may be empty
# Echoes the resolved path and returns 0, or returns 1 when nothing on disk
# matches (the caller reports that as dangling — never as "looks relative, fine").
_pkg_resolve_dep_reference() {
    local dep="$1" referrer="${2:-}" core="${3:-}" gst_libdir="${4:-}"
    local refdir="" core_dir="" leaf="" path="" search_owner="" dir=""

    [ -n "$referrer" ] && refdir="$(dirname "$referrer")"
    [ -n "$core" ] && core_dir="$(dirname "$core")"

    case "$dep" in
        @loader_path|@loader_path/*)
            path="$(_pkg_expand_dyld_path "$dep" "$refdir" "$core_dir")"
            if [ -n "$path" ] && [ -e "$path" ]; then
                printf '%s\n' "$path"
                return 0
            fi
            return 1
            ;;
        @executable_path|@executable_path/*)
            if [ -z "$core_dir" ]; then
                return 1
            fi
            path="$(_pkg_expand_dyld_path "$dep" "$refdir" "$core_dir")"
            if [ -n "$path" ] && [ -e "$path" ]; then
                printf '%s\n' "$path"
                return 0
            fi
            return 1
            ;;
        @rpath|@rpath/*)
            leaf="${dep#@rpath}"
            leaf="${leaf#/}"
            ;;
        *)
            printf '%s\n' "$dep"
            return 0
            ;;
    esac

    [ -n "$leaf" ] || return 1

    # (i) the referencing image's own LC_RPATH, in load-command order.
    if [ -n "$referrer" ]; then
        while IFS= read -r path; do
            [ -n "$path" ] || continue
            dir="$(_pkg_expand_dyld_path "$path" "$refdir" "$core_dir")"
            if _pkg_try_candidate "$dir" "$leaf"; then
                return 0
            fi
        done < <(pkg_dylib_rpaths "$referrer")
    fi

    # (ii) the main executable's LC_RPATH — last resort for an image whose own
    # rpath list does not cover the dependency (a plugin that inherited the
    # helper's search path at link time).
    if [ -n "$core" ] && [ "$core" != "$referrer" ]; then
        while IFS= read -r path; do
            [ -n "$path" ] || continue
            dir="$(_pkg_expand_dyld_path "$path" "$core_dir" "$core_dir")"
            if _pkg_try_candidate "$dir" "$leaf"; then
                return 0
            fi
        done < <(pkg_dylib_rpaths "$core")
    fi

    # (iii) the GStreamer library directory the core build record names. Not an
    # rpath of any image, but it is the directory these images were linked from,
    # so it is the last place the closure can honestly look.
    if [ -n "$gst_libdir" ]; then
        if _pkg_try_candidate "$gst_libdir" "$leaf"; then
            return 0
        fi
    fi

    return 1
}

# --- closure computation ------------------------------------------------------

# Flatten a path into a filename-safe key (macOS filenames cannot contain "/").
_pkg_key() {
    printf '%s' "$1" | tr '/' '%'
}

# Record one referenced image: note the leaf name it was referenced by, then
# enqueue it for expansion when it is the first time we see its real path.
#   $1  referencing path (as written in a load command, or a seed path)
#   $2  closure working directory
#   $3  queue file to append newly discovered images to
#   $4  referencing image (owner of the load command; empty for a seed)
#   $5  main executable (the core binary; owner of the last-resort LC_RPATH)
#   $6  GStreamer library directory from the core build record
# Prints the real path on stdout when the image is new (diagnostics only);
# returns 1 on a dangling non-system reference.
_pkg_touch_image() {
    local ref="$1" outdir="$2" next="$3"
    local referrer="${4:-}" core="${5:-}" gst_libdir="${6:-}"
    local resolved real key leaf

    resolved="$ref"
    case "$ref" in
        @rpath|@rpath/*|@loader_path|@loader_path/*|@executable_path|@executable_path/*)
            resolved="$(_pkg_resolve_dep_reference "$ref" "$referrer" "$core" "$gst_libdir")" || {
                echo "closure: dangling dependency $ref (unresolvable; referenced by ${referrer:-the closure root})" >&2
                return 1
            }
            ;;
    esac
    if pkg_is_system_image "$resolved"; then
        return 0
    fi
    if [ ! -e "$resolved" ]; then
        echo "closure: dangling dependency $resolved" >&2
        return 1
    fi
    real="$(realpath "$resolved")"
    key="$(_pkg_key "$real")"
    # The leaf stays the one written in the load command (not the resolved
    # file's name): the alias logic below needs to know how the image is called,
    # while `real` is where it actually lives.
    leaf="${ref##*/}"
    # Every leaf name an image is referenced by is recorded; a leaf that
    # differs from the physical file name is a version alias that has to be
    # reproduced as a relative symlink (contract P-7.2 / rules R7-R8).
    touch "$outdir/leaves/$key"
    grep -Fxq "$leaf" "$outdir/leaves/$key" || printf '%s\n' "$leaf" >>"$outdir/leaves/$key"
    if [ -f "$outdir/images/$key" ]; then
        return 0
    fi
    printf '%s\n' "$real" >"$outdir/images/$key"
    printf '%s\n' "$real" >>"$next"
    return 0
}

# Compute the closure rooted at the core plugin set and write <dir>/closure.tsv.
#
#   $1  working directory for the manifest and scratch
#   $2  helper executable (uxplay) — travels as role `bin`
#   $3  gst-plugin-scanner       — travels as role `scanner`
#
# All GStreamer paths come from the core build record (the GStreamer the helper
# was linked against), never from this shell's pkg-config. Returns 1 (with a
# message on stderr) when a source cannot be established, when the axes disagree,
# or when a referenced image is missing.
pkg_compute_closure() {
    local outdir="$1" uxplay="$2" scanner="$3"
    local plugindir libdir names plugin real key dep leaf rc
    local cache keg scanner_real plugindir_real uxplay_real scanner_real_path

    cache="$(pkg_gst_core_cache)"
    libdir="$(pkg_gst_libdir "$cache")" || return 1
    plugindir="$(pkg_gst_plugindir "$cache")" || {
        echo "closure: cannot resolve the GStreamer plugin directory" >&2
        return 1
    }
    [ -d "$plugindir" ] || { echo "closure: no plugin dir at $plugindir" >&2; return 1; }
    [ -f "$uxplay" ]    || { echo "closure: no helper binary at $uxplay" >&2; return 1; }
    [ -f "$scanner" ]   || { echo "closure: no gst-plugin-scanner at $scanner" >&2; return 1; }

    scanner_real_path="$(realpath "$scanner")"
    keg="$(_pkg_gst_install_root "$libdir")" || keg="$(realpath "$libdir")"
    if ! _pkg_path_within "$scanner_real_path" "$keg" \
        && ! _pkg_path_within "$scanner_real_path" "$(dirname "$keg")"; then
        _pkg_gst_source_error \
            "the gst-plugin-scanner does not belong to the GStreamer in the core build record (lib axis and plugin axis disagree)" \
            "$cache" \
            "gst-source:   lib axis         : $(realpath "$libdir")" \
            "gst-source:   plugin axis      : $scanner_real_path"
        return 1
    fi

    # One line of provenance: the build log should say which GStreamer was
    # shipped and where that answer came from, and should say so loudly when the
    # shell's pkg-config would have answered differently.
    echo "closure: gstreamer source: $libdir (version $(pkg_gst_version "$cache"), from $cache)" >&2
    local shell_libdir shell_root core_root
    shell_libdir="$(_pkg_gst_shell_libdir)"
    shell_root="$(_pkg_gst_install_root "$shell_libdir" 2>/dev/null)" || shell_root=""
    core_root="$(_pkg_gst_install_root "$libdir" 2>/dev/null)" || core_root=""
    if [ -n "$shell_root" ] && [ "$shell_root" != "$core_root" ]; then
        echo "closure: note: this shell's pkg-config points at $shell_libdir ($shell_root), but the core was configured against $core_root — following the core, the only GStreamer the helper was linked against" >&2
    fi

    plugindir_real="$(realpath "$plugindir")"
    uxplay_real="$(realpath "$uxplay")"
    scanner_real="$(realpath "$scanner")"

    mkdir -p "$outdir/images" "$outdir/leaves" "$outdir/queue" || return 1
    : >"$outdir/closure.tsv"
    rc=0

    # Seed: the 14 plugins are the expansion roots. The helper and the scanner
    # travel too; they are expanded as well so that a future relink cannot
    # silently under-ship (their deps are a subset of the plugin closure today).
    local seed="$outdir/queue/0"
    : >"$seed"
    for names in $(pkg_core_plugin_names); do
        plugin="$plugindir/libgst$names.dylib"
        if [ ! -f "$plugin" ]; then
            echo "closure: missing core plugin $plugin" >&2
            return 1
        fi
        _pkg_touch_image "$plugin" "$outdir" "$seed" "" "$uxplay_real" "$libdir" || rc=1
    done
    _pkg_touch_image "$uxplay"  "$outdir" "$seed" "" "$uxplay_real" "$libdir" || rc=1
    _pkg_touch_image "$scanner" "$outdir" "$seed" "" "$uxplay_real" "$libdir" || rc=1

    local cur="$seed" nxt round=0 ref dep
    while [ -s "$cur" ]; do
        nxt="$outdir/queue/$((round + 1))"
        : >"$nxt"
        while IFS= read -r ref; do
            [ -n "$ref" ] || continue
            while IFS= read -r dep; do
                [ -n "$dep" ] || continue
                _pkg_touch_image "$dep" "$outdir" "$nxt" "$ref" "$uxplay_real" "$libdir" || rc=1
            done < <(pkg_dylib_deps "$ref")
        done <"$cur"
        [ -s "$nxt" ] || rm -f "$nxt"
        cur="$nxt"
        round=$((round + 1))
    done

    # Emit one row per image.
    for img in "$outdir"/images/*; do
        [ -f "$img" ] || continue
        real="$(cat "$img")"
        key="$(_pkg_key "$real")"
        base="${real##*/}"
        case "$real" in
            "$uxplay_real")       role=bin ;;
            "$scanner_real")      role=scanner ;;
            "$plugindir_real"/*)  role=plugin ;;
            *)                    role=lib ;;
        esac
        # aliases = referenced leaf names minus the physical file name, plus the
        # LC_ID_DYLIB basename (a dylib whose id is the alias must keep the
        # alias as its install name — R8).
        local aliases="" l id idleaf
        if [ -f "$outdir/leaves/$key" ]; then
            while IFS= read -r l; do
                [ -n "$l" ] || continue
                [ "$l" = "$base" ] && continue
                case ",$aliases," in
                    *",$l,"*) ;;
                    *) aliases="${aliases:+$aliases,}$l" ;;
                esac
            done <"$outdir/leaves/$key"
        fi
        id="$(pkg_dylib_id "$real")"
        if [ -n "$id" ]; then
            idleaf="${id##*/}"
            if [ "$idleaf" != "$base" ]; then
                case ",$aliases," in
                    *",$idleaf,"*) ;;
                    *) aliases="${aliases:+$aliases,}$idleaf" ;;
                esac
            fi
        fi
        printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
            "$role" "$(stat -f%z "$real")" "$base" "$real" "${aliases:--}" \
            "$(pkg_dylib_minos "$real" | sed 's/^$/-/')" >>"$outdir/closure.tsv"
    done

    return "$rc"
}

# Print a one-line summary of a closure.tsv (counts + total bytes).
pkg_closure_summary() {
    awk -F'\t' '
        { n++; bytes += $2; c[$1]++
          if ($5 != "-") a += (split($5, t, ",")) }
        END {
            printf "images=%d bytes=%d roles(bin=%d scanner=%d plugin=%d lib=%d) aliases=%d\n",
                   n, bytes, c["bin"], c["scanner"], c["plugin"], c["lib"], a
        }
    ' "$1"
}

#!/usr/bin/env bash
#
# build-macos.sh — Build SDLPoP.app for macOS.
#
# Two build modes, picked automatically from the macOS version you build on:
#
#   framework  (default on macOS 11+):
#       Universal (arm64 + x86_64) binary with the official universal SDL2 /
#       SDL2_image frameworks (libsdl.org) bundled inside the .app. Fully
#       self-contained. Runs on Apple Silicon and modern Intel Macs (macOS 11+).
#
#   pkgconfig  (default on macOS 10.x, e.g. High Sierra):
#       Native binary linked against a locally installed SDL2 found via
#       pkg-config — MacPorts (/opt/local) is preferred, then Homebrew, then
#       whatever pkg-config finds. The prebuilt framework is NOT used here: it
#       is built on a newer SDK and is missing symbols on High Sierra (10.13),
#       so on old macOS we rely on MacPorts' SDL2 instead.
#
# Usage:
#   ./build-macos.sh                 # auto-pick the mode for this macOS
#   ./build-macos.sh --framework     # force universal framework build
#   ./build-macos.sh --pkgconfig     # force local (MacPorts/Homebrew) build
#   ./build-macos.sh --macports      # alias for --pkgconfig (prefers /opt/local)
#   ./build-macos.sh --bundle-libs   # (pkgconfig) also bundle the dylibs via
#                                    #   dylibbundler, for a self-contained .app
#   ./build-macos.sh clean           # remove build output (keeps framework cache)
#   ./build-macos.sh distclean       # remove build output including the cache
#
# Environment overrides:
#   SDL2_VERSION, SDL2_IMAGE_VERSION   pin framework versions (framework mode)
#   MACOS_MIN_X86_64 (default 10.13)   Intel deployment target
#   MACOS_MIN_ARM64  (default 11.0)    Apple Silicon deployment target
#   PKG_CONFIG                         pkg-config to use (pkgconfig mode)
#   CODESIGN_IDENTITY                  signing identity (default: "-", ad-hoc)
#   JOBS                               parallel compile jobs (default: CPU count)
#
set -euo pipefail

# ----------------------------------------------------------------------------
# Configuration
# ----------------------------------------------------------------------------
SDL2_VERSION="${SDL2_VERSION:-2.32.10}"
SDL2_IMAGE_VERSION="${SDL2_IMAGE_VERSION:-2.8.12}"
MACOS_MIN_X86_64="${MACOS_MIN_X86_64:-10.13}"   # High Sierra
MACOS_MIN_ARM64="${MACOS_MIN_ARM64:-11.0}"      # Big Sur (earliest Apple Silicon)
CODESIGN_IDENTITY="${CODESIGN_IDENTITY:--}"     # "-" == ad-hoc signature
JOBS="${JOBS:-$(sysctl -n hw.ncpu 2>/dev/null || echo 4)}"

APP_NAME="prince"
BUNDLE_NAME="Prince of Persia (SDLPoP)"
BUNDLE_ID="org.princed.SDLPoP"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_DIR="$ROOT_DIR/src"
BUILD_DIR="$ROOT_DIR/build-macos"
CACHE_DIR="$BUILD_DIR/cache"
FRAMEWORKS_DIR="$BUILD_DIR/Frameworks"
OBJ_DIR="$BUILD_DIR/obj"
SHIM_DIR="$BUILD_DIR/shim"
APP_DIR="$BUILD_DIR/$APP_NAME.app"

MODE=""              # framework | pkgconfig  (empty => auto)
BUNDLE_LIBS=0        # pkgconfig mode: bundle dylibs with dylibbundler
PREFER_MACPORTS=0

# The .c files to compile (mirrors src/Makefile OBJ list; icon.rc is Windows-only).
SOURCES=(
    main.c data.c
    seg000.c seg001.c seg002.c seg003.c seg004.c seg005.c
    seg006.c seg007.c seg008.c seg009.c
    seqtbl.c replay.c options.c lighting.c screenshot.c menu.c
    midi.c opl3.c stb_vorbis.c
)

# ----------------------------------------------------------------------------
# Helpers
# ----------------------------------------------------------------------------
log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mWARNING:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

# ----------------------------------------------------------------------------
# Argument parsing
# ----------------------------------------------------------------------------
for arg in "$@"; do
    case "$arg" in
        clean)          log "Removing build output (keeping cache)"
                        rm -rf "$OBJ_DIR" "$APP_DIR" "$FRAMEWORKS_DIR" "$SHIM_DIR"; exit 0 ;;
        distclean)      log "Removing $BUILD_DIR entirely"; rm -rf "$BUILD_DIR"; exit 0 ;;
        --framework)    MODE="framework" ;;
        --pkgconfig)    MODE="pkgconfig" ;;
        --macports)     MODE="pkgconfig"; PREFER_MACPORTS=1 ;;
        --bundle-libs)  BUNDLE_LIBS=1 ;;
        -h|--help)      sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *)              die "Unknown argument: $arg (try --help)" ;;
    esac
done

command -v clang >/dev/null || die "clang not found. Install the Xcode command line tools: xcode-select --install"

# ----------------------------------------------------------------------------
# Mode auto-detection
# ----------------------------------------------------------------------------
macos_major="$(sw_vers -productVersion 2>/dev/null | cut -d. -f1)"
macos_minor="$(sw_vers -productVersion 2>/dev/null | cut -d. -f2)"
is_legacy_macos=0    # macOS 10.x (High Sierra .. Catalina)
case "${macos_major:-0}" in 10) is_legacy_macos=1 ;; esac

if [ -z "$MODE" ]; then
    if [ "$is_legacy_macos" -eq 1 ]; then
        MODE="pkgconfig"
        log "Detected macOS ${macos_major}.${macos_minor} — using local SDL2 via pkg-config (MacPorts/Homebrew)."
    else
        MODE="framework"
        log "Detected macOS ${macos_major}.x — using the universal SDL2 frameworks."
    fi
elif [ "$MODE" = "framework" ] && [ "$is_legacy_macos" -eq 1 ]; then
    warn "The prebuilt SDL2 framework is missing symbols on macOS 10.x (e.g. High Sierra)."
    warn "It may not run here. Prefer --pkgconfig (MacPorts) on this machine."
fi

# Read the game version straight from the source so the app stays in sync.
SDLPOP_VERSION="$(sed -n 's/^#define SDLPOP_VERSION "\(.*\)".*/\1/p' "$SRC_DIR/config.h" | head -1)"
SDLPOP_VERSION="${SDLPOP_VERSION:-1.24}"
SHORT_VERSION="$(printf '%s' "$SDLPOP_VERSION" | grep -oE '^[0-9]+(\.[0-9]+){0,2}' || echo "1.24")"

mkdir -p "$BUILD_DIR"

# ============================================================================
# Shared: assemble the .app skeleton (executable, resources, game data, plist)
# ============================================================================
assemble_app_skeleton() {
    local binary="$1" min_system="$2"
    log "Assembling $APP_NAME.app"
    rm -rf "$APP_DIR"
    mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources" "$APP_DIR/Contents/Frameworks"

    cp "$binary"            "$APP_DIR/Contents/MacOS/$APP_NAME"
    cp "$SRC_DIR/icon.icns" "$APP_DIR/Contents/Resources/icon.icns"

    # Game data lives next to the executable — SDLPoP builds paths relative to argv[0].
    cp -R "$ROOT_DIR/data"       "$APP_DIR/Contents/MacOS/data"
    cp -R "$ROOT_DIR/doc"        "$APP_DIR/Contents/MacOS/doc"
    cp    "$ROOT_DIR/SDLPoP.ini" "$APP_DIR/Contents/MacOS/SDLPoP.ini"
    [ -d "$ROOT_DIR/mods" ]    && cp -R "$ROOT_DIR/mods"    "$APP_DIR/Contents/MacOS/mods"
    [ -d "$ROOT_DIR/replays" ] && cp -R "$ROOT_DIR/replays" "$APP_DIR/Contents/MacOS/replays"

    cat > "$APP_DIR/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>              <string>SDLPoP</string>
    <key>CFBundleDisplayName</key>       <string>$BUNDLE_NAME</string>
    <key>CFBundleIdentifier</key>        <string>$BUNDLE_ID</string>
    <key>CFBundleExecutable</key>        <string>$APP_NAME</string>
    <key>CFBundleIconFile</key>          <string>icon.icns</string>
    <key>CFBundlePackageType</key>       <string>APPL</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>CFBundleShortVersionString</key><string>$SHORT_VERSION</string>
    <key>CFBundleVersion</key>           <string>$SHORT_VERSION</string>
    <key>LSMinimumSystemVersion</key>    <string>$min_system</string>
    <key>NSHighResolutionCapable</key>   <true/>
    <key>NSHumanReadableCopyright</key>  <string>GNU General Public License, v3</string>
</dict>
</plist>
PLIST
}

codesign_app() {
    log "Code-signing (identity: $CODESIGN_IDENTITY)"
    local fw
    for fw in "$APP_DIR"/Contents/Frameworks/*.framework "$APP_DIR"/Contents/Frameworks/*.dylib; do
        [ -e "$fw" ] || continue
        codesign --force --sign "$CODESIGN_IDENTITY" --timestamp=none "$fw" >/dev/null 2>&1 \
            || warn "codesign of $(basename "$fw") failed"
    done
    codesign --force --deep --sign "$CODESIGN_IDENTITY" --timestamp=none "$APP_DIR" \
        || warn "codesign of app bundle failed (harmless on Intel; required for arm64)"
}

# ============================================================================
# Mode: framework  — universal, self-contained (macOS 11+)
# ============================================================================
build_framework() {
    command -v hdiutil >/dev/null || die "hdiutil not found (are you on macOS?)"

    # --- 1. Fetch the official universal frameworks (cached) ---
    fetch_framework() {
        local repo="$1" dmg_base="$2" version="$3" fw="$4"
        local dmg="$CACHE_DIR/${dmg_base}-${version}.dmg"
        local url="https://github.com/libsdl-org/${repo}/releases/download/release-${version}/${dmg_base}-${version}.dmg"
        if [ ! -f "$dmg" ]; then
            log "Downloading $fw $version"
            mkdir -p "$CACHE_DIR"
            curl -fL --retry 3 -o "$dmg.part" "$url" || die "Download failed: $url"
            mv "$dmg.part" "$dmg"
        else
            log "Using cached $(basename "$dmg")"
        fi
        local mnt; mnt="$(mktemp -d)"
        hdiutil attach -nobrowse -quiet "$dmg" -mountpoint "$mnt" || die "Could not mount $dmg"
        rm -rf "${FRAMEWORKS_DIR:?}/$fw"; mkdir -p "$FRAMEWORKS_DIR"
        cp -R "$mnt/$fw" "$FRAMEWORKS_DIR/$fw"     # -R preserves internal symlinks
        hdiutil detach -quiet "$mnt" || warn "Could not unmount $mnt"
        rmdir "$mnt" 2>/dev/null || true
        lipo -archs "$FRAMEWORKS_DIR/$fw/$(basename "$fw" .framework)" | grep -q arm64 \
            || warn "$fw has no arm64 slice!"
    }
    fetch_framework "SDL"       "SDL2"       "$SDL2_VERSION"       "SDL2.framework"
    fetch_framework "SDL_image" "SDL2_image" "$SDL2_IMAGE_VERSION" "SDL2_image.framework"

    # --- 2. Header shim: source uses <SDL2/SDL_image.h>, framework exposes it
    #        as <SDL2_image/SDL_image.h>. A one-line forwarding header bridges it. ---
    mkdir -p "$SHIM_DIR/SDL2"
    printf '#include <SDL2_image/SDL_image.h>\n' > "$SHIM_DIR/SDL2/SDL_image.h"

    local COMMON_CFLAGS=(
        -std=c99 -O2 -Wall -Werror=implicit-function-declaration
        -D_GNU_SOURCE=1 -D_THREAD_SAFE -DOSX -D_DARWIN_C_SOURCE
        -I"$SHIM_DIR" -F"$FRAMEWORKS_DIR"
    )
    local ARCHES=("x86_64:$MACOS_MIN_X86_64" "arm64:$MACOS_MIN_ARM64")

    # --- 3. Compile per arch (up to $JOBS in parallel; works on bash 3.2) ---
    compile_arch() {
        local arch="$1" minver="$2" pids=() fail=0 src obj pid
        for src in "${SOURCES[@]}"; do
            obj="$OBJ_DIR/$arch/${src%.c}.o"; mkdir -p "$(dirname "$obj")"
            clang -arch "$arch" -mmacosx-version-min="$minver" \
                "${COMMON_CFLAGS[@]}" -c "$SRC_DIR/$src" -o "$obj" &
            pids+=("$!")
            if [ "${#pids[@]}" -ge "$JOBS" ]; then wait "${pids[0]}" || fail=1; pids=("${pids[@]:1}"); fi
        done
        for pid in "${pids[@]}"; do wait "$pid" || fail=1; done
        return $fail
    }
    rm -rf "$OBJ_DIR"
    log "Compiling ${#SOURCES[@]} source files for x86_64 + arm64 (jobs: $JOBS)"
    for entry in "${ARCHES[@]}"; do
        arch="${entry%%:*}"; minver="${entry##*:}"
        log "  arch $arch (min macOS $minver)"
        compile_arch "$arch" "$minver" || die "Compile failed for $arch"
    done

    # --- 4. Link per arch, then lipo into a universal binary ---
    log "Linking"
    mkdir -p "$OBJ_DIR/bin"
    for entry in "${ARCHES[@]}"; do
        arch="${entry%%:*}"; minver="${entry##*:}"
        clang -arch "$arch" -mmacosx-version-min="$minver" "$OBJ_DIR/$arch"/*.o \
            -F"$FRAMEWORKS_DIR" -framework SDL2 -framework SDL2_image \
            -Wl,-rpath,@executable_path/../Frameworks -lm \
            -o "$OBJ_DIR/bin/$APP_NAME.$arch" || die "Link failed ($arch)"
    done
    lipo -create "$OBJ_DIR/bin/$APP_NAME".* -output "$OBJ_DIR/bin/$APP_NAME"

    # --- 5. Assemble, embed frameworks, sign ---
    assemble_app_skeleton "$OBJ_DIR/bin/$APP_NAME" "$MACOS_MIN_X86_64"
    local fw
    for fw in SDL2.framework SDL2_image.framework; do
        cp -R "$FRAMEWORKS_DIR/$fw" "$APP_DIR/Contents/Frameworks/$fw"
        rm -rf "$APP_DIR/Contents/Frameworks/$fw/Headers" \
               "$APP_DIR/Contents/Frameworks/$fw/Versions/A/Headers"
    done
    codesign_app
}

# ============================================================================
# Mode: pkgconfig  — native build against installed SDL2 (MacPorts/Homebrew)
# ============================================================================
build_pkgconfig() {
    # Pick pkg-config: MacPorts first (High Sierra target), then Homebrew, then PATH.
    local PKGCFG="${PKG_CONFIG:-}"
    if [ -z "$PKGCFG" ]; then
        if [ "$PREFER_MACPORTS" -eq 1 ] && [ -x /opt/local/bin/pkg-config ]; then
            PKGCFG=/opt/local/bin/pkg-config
        elif [ -x /opt/local/bin/pkg-config ]; then
            PKGCFG=/opt/local/bin/pkg-config
        elif command -v pkg-config >/dev/null; then
            PKGCFG="$(command -v pkg-config)"
        else
            die "pkg-config not found. On High Sierra: sudo port install libsdl2 libsdl2_image pkgconfig"
        fi
    fi
    log "Using pkg-config: $PKGCFG"
    "$PKGCFG" --exists sdl2 || die "SDL2 not found by pkg-config. Install it (MacPorts: sudo port install libsdl2 libsdl2_image)"
    "$PKGCFG" --exists SDL2_image || die "SDL2_image not found by pkg-config. Install it (MacPorts: sudo port install libsdl2_image)"

    local sdl_prefix; sdl_prefix="$("$PKGCFG" --variable=prefix sdl2 2>/dev/null || echo "?")"
    log "SDL2 prefix: $sdl_prefix  (version $("$PKGCFG" --modversion sdl2))"

    local CFLAGS_PKG LIBS_PKG
    # shellcheck disable=SC2207
    CFLAGS_PKG=($("$PKGCFG" --cflags sdl2 SDL2_image))
    # shellcheck disable=SC2207
    LIBS_PKG=($("$PKGCFG" --libs sdl2 SDL2_image))

    local host_arch; host_arch="$(uname -m)"
    local COMMON_CFLAGS=(
        -std=c99 -O2 -Wall -Werror=implicit-function-declaration
        -mmacosx-version-min="$MACOS_MIN_X86_64"
        -D_GNU_SOURCE=1 -D_THREAD_SAFE -DOSX -D_DARWIN_C_SOURCE
        "${CFLAGS_PKG[@]}"
    )

    # Compile (native host arch) up to $JOBS in parallel.
    rm -rf "$OBJ_DIR"
    log "Compiling ${#SOURCES[@]} source files for $host_arch (min macOS $MACOS_MIN_X86_64, jobs: $JOBS)"
    local pids=() fail=0 src obj pid
    for src in "${SOURCES[@]}"; do
        obj="$OBJ_DIR/$host_arch/${src%.c}.o"; mkdir -p "$(dirname "$obj")"
        clang "${COMMON_CFLAGS[@]}" -c "$SRC_DIR/$src" -o "$obj" &
        pids+=("$!")
        if [ "${#pids[@]}" -ge "$JOBS" ]; then wait "${pids[0]}" || fail=1; pids=("${pids[@]:1}"); fi
    done
    for pid in "${pids[@]}"; do wait "$pid" || fail=1; done
    [ $fail -eq 0 ] || die "Compile failed"

    log "Linking"
    mkdir -p "$OBJ_DIR/bin"
    clang -mmacosx-version-min="$MACOS_MIN_X86_64" "$OBJ_DIR/$host_arch"/*.o \
        "${LIBS_PKG[@]}" -lm -o "$OBJ_DIR/bin/$APP_NAME" || die "Link failed"

    assemble_app_skeleton "$OBJ_DIR/bin/$APP_NAME" "$MACOS_MIN_X86_64"

    if [ "$BUNDLE_LIBS" -eq 1 ]; then
        command -v dylibbundler >/dev/null \
            || die "--bundle-libs needs dylibbundler (MacPorts: sudo port install dylibbundler)"
        log "Bundling dependent dylibs with dylibbundler"
        dylibbundler -of -cd -b \
            -x "$APP_DIR/Contents/MacOS/$APP_NAME" \
            -d "$APP_DIR/Contents/Frameworks" \
            -p @executable_path/../Frameworks || die "dylibbundler failed"
    else
        log "Linking against installed SDL2 in place (not bundled)."
        log "The .app needs SDL2/SDL2_image installed (MacPorts) to run on another machine."
        log "Use --bundle-libs to make it self-contained."
    fi
    codesign_app
}

# ============================================================================
# Build
# ============================================================================
case "$MODE" in
    framework) build_framework ;;
    pkgconfig) build_pkgconfig ;;
    *)         die "Internal error: unknown mode '$MODE'" ;;
esac

# ============================================================================
# Verify
# ============================================================================
log "Verifying ($MODE mode)"
BIN="$APP_DIR/Contents/MacOS/$APP_NAME"
echo "  architectures : $(lipo -archs "$BIN")"
for arch in $(lipo -archs "$BIN"); do
    minos="$(otool -l -arch "$arch" "$BIN" 2>/dev/null \
        | awk '/LC_VERSION_MIN_MACOSX|LC_BUILD_VERSION/{f=1} f&&/version |minos /{print $2; exit}')"
    echo "  $arch min macOS: ${minos:-?}"
done
echo "  linked SDL    :"
otool -L "$BIN" | awk '/SDL2/{print "    "$1}'
echo "  rpaths        : $(otool -l "$BIN" | awk '/LC_RPATH/{f=1} f&&/path /{print $2; f=0}' | tr '\n' ' ')"
codesign --verify --deep --strict "$APP_DIR" 2>/dev/null && echo "  codesign      : OK" || warn "codesign verify failed"

log "Done: $APP_DIR"
echo
echo "Run it with:   open \"$APP_DIR\""
echo "Or from CLI:   \"$BIN\""

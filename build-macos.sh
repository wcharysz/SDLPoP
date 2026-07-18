#!/usr/bin/env bash
#
# build-macos.sh — Build a self-contained, universal SDLPoP.app for macOS.
#
# The resulting prince.app runs on:
#   * Apple Silicon (arm64), macOS 11 Big Sur .. macOS 26 Tahoe and later
#   * Intel (x86_64),        macOS 10.13 High Sierra and later
#
# It bundles the official universal SDL2 / SDL2_image frameworks
# (from libsdl.org) inside the app, so nothing extra needs to be installed
# on the target machine — no Homebrew, no MacPorts.
#
# Usage:
#   ./build-macos.sh                # build build-macos/prince.app
#   ./build-macos.sh clean          # remove build-macos/ (keeps the framework cache)
#   ./build-macos.sh distclean      # remove build-macos/ including the cache
#
# Environment overrides:
#   SDL2_VERSION, SDL2_IMAGE_VERSION   pin framework versions
#   MACOS_MIN_X86_64 (default 10.13)   Intel deployment target
#   MACOS_MIN_ARM64  (default 11.0)    Apple Silicon deployment target
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

# Read the game version straight from the source so the app stays in sync.
SDLPOP_VERSION="$(sed -n 's/^#define SDLPOP_VERSION "\(.*\)".*/\1/p' "$SRC_DIR/config.h" | head -1)"
SDLPOP_VERSION="${SDLPOP_VERSION:-1.24}"
# CFBundleShortVersionString must be numeric-ish; strip any trailing " RC" etc.
SHORT_VERSION="$(printf '%s' "$SDLPOP_VERSION" | grep -oE '^[0-9]+(\.[0-9]+){0,2}' || echo "1.24")"

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

case "${1:-}" in
    clean)     log "Removing $BUILD_DIR (keeping cache)"; rm -rf "$OBJ_DIR" "$APP_DIR" "$FRAMEWORKS_DIR" "$SHIM_DIR"; exit 0 ;;
    distclean) log "Removing $BUILD_DIR entirely"; rm -rf "$BUILD_DIR"; exit 0 ;;
    "")        ;;
    *)         die "Unknown command: $1 (use: clean | distclean)" ;;
esac

command -v clang   >/dev/null || die "clang not found. Install the Xcode command line tools: xcode-select --install"
command -v hdiutil >/dev/null || die "hdiutil not found (are you on macOS?)"

# ----------------------------------------------------------------------------
# 1. Fetch the official universal frameworks (cached)
# ----------------------------------------------------------------------------
fetch_framework() {
    # $1 = repo (SDL / SDL_image), $2 = dmg-basename, $3 = version, $4 = framework name
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
    rm -rf "${FRAMEWORKS_DIR:?}/$fw"
    mkdir -p "$FRAMEWORKS_DIR"
    # -R preserves the framework's internal symlinks (Versions/Current, etc.)
    cp -R "$mnt/$fw" "$FRAMEWORKS_DIR/$fw"
    hdiutil detach -quiet "$mnt" || warn "Could not unmount $mnt"
    rmdir "$mnt" 2>/dev/null || true

    lipo -archs "$FRAMEWORKS_DIR/$fw/$(basename "$fw" .framework)" | grep -q arm64 \
        || warn "$fw does not contain an arm64 slice!"
}

mkdir -p "$BUILD_DIR"
fetch_framework "SDL"       "SDL2"       "$SDL2_VERSION"       "SDL2.framework"
fetch_framework "SDL_image" "SDL2_image" "$SDL2_IMAGE_VERSION" "SDL2_image.framework"

# ----------------------------------------------------------------------------
# 2. Header shim
#    The source includes <SDL2/SDL_image.h>, but in the framework layout that
#    header lives in SDL2_image.framework (addressable as <SDL2_image/SDL_image.h>).
#    A one-line forwarding header keeps the source untouched.
# ----------------------------------------------------------------------------
mkdir -p "$SHIM_DIR/SDL2"
printf '#include <SDL2_image/SDL_image.h>\n' > "$SHIM_DIR/SDL2/SDL_image.h"

# ----------------------------------------------------------------------------
# 3. Compile — one object file per source, per architecture, then lipo together
# ----------------------------------------------------------------------------
COMMON_CFLAGS=(
    -std=c99 -O2 -Wall
    -Werror=implicit-function-declaration
    -D_GNU_SOURCE=1 -D_THREAD_SAFE -DOSX
    -D_DARWIN_C_SOURCE   # expose strcasecmp/strncasecmp (<strings.h>) under -std=c99
    -I"$SHIM_DIR"
    -F"$FRAMEWORKS_DIR"
)

ARCHES=("x86_64:$MACOS_MIN_X86_64" "arm64:$MACOS_MIN_ARM64")

# Compile every source for one architecture, up to $JOBS compiles in parallel.
# Written to work on the system bash 3.2 (no `wait -n`).
compile_arch() {
    local arch="$1" minver="$2"
    local pids=() fail=0 src obj pid
    for src in "${SOURCES[@]}"; do
        obj="$OBJ_DIR/$arch/${src%.c}.o"
        mkdir -p "$(dirname "$obj")"
        clang -arch "$arch" -mmacosx-version-min="$minver" \
            "${COMMON_CFLAGS[@]}" -c "$SRC_DIR/$src" -o "$obj" &
        pids+=("$!")
        if [ "${#pids[@]}" -ge "$JOBS" ]; then
            wait "${pids[0]}" || fail=1        # throttle: block on the oldest job
            pids=("${pids[@]:1}")
        fi
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

# ----------------------------------------------------------------------------
# 4. Link — one executable per arch, then combine with lipo
# ----------------------------------------------------------------------------
log "Linking"
mkdir -p "$OBJ_DIR/bin"
for entry in "${ARCHES[@]}"; do
    arch="${entry%%:*}"; minver="${entry##*:}"
    clang -arch "$arch" -mmacosx-version-min="$minver" \
        "$OBJ_DIR/$arch"/*.o \
        -F"$FRAMEWORKS_DIR" -framework SDL2 -framework SDL2_image \
        -Wl,-rpath,@executable_path/../Frameworks \
        -lm -o "$OBJ_DIR/bin/$APP_NAME.$arch" || die "Link failed ($arch)"
done
lipo -create "$OBJ_DIR/bin/$APP_NAME".* -output "$OBJ_DIR/bin/$APP_NAME"

# ----------------------------------------------------------------------------
# 5. Assemble the .app bundle
# ----------------------------------------------------------------------------
log "Assembling $APP_NAME.app"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources" "$APP_DIR/Contents/Frameworks"

cp "$OBJ_DIR/bin/$APP_NAME" "$APP_DIR/Contents/MacOS/$APP_NAME"
cp "$SRC_DIR/icon.icns"     "$APP_DIR/Contents/Resources/icon.icns"

# Game data lives next to the executable — SDLPoP builds paths relative to argv[0].
cp -R "$ROOT_DIR/data"    "$APP_DIR/Contents/MacOS/data"
cp -R "$ROOT_DIR/doc"     "$APP_DIR/Contents/MacOS/doc"
cp    "$ROOT_DIR/SDLPoP.ini" "$APP_DIR/Contents/MacOS/SDLPoP.ini"
[ -d "$ROOT_DIR/mods" ]    && cp -R "$ROOT_DIR/mods"    "$APP_DIR/Contents/MacOS/mods"
[ -d "$ROOT_DIR/replays" ] && cp -R "$ROOT_DIR/replays" "$APP_DIR/Contents/MacOS/replays"

# Embed the frameworks (strip headers/docs to keep the bundle lean).
for fw in SDL2.framework SDL2_image.framework; do
    cp -R "$FRAMEWORKS_DIR/$fw" "$APP_DIR/Contents/Frameworks/$fw"
    rm -rf "$APP_DIR/Contents/Frameworks/$fw/Headers" \
           "$APP_DIR/Contents/Frameworks/$fw/Versions/A/Headers"
done

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
    <key>LSMinimumSystemVersion</key>    <string>$MACOS_MIN_X86_64</string>
    <key>NSHighResolutionCapable</key>   <true/>
    <key>NSHumanReadableCopyright</key>  <string>GNU General Public License, v3</string>
</dict>
</plist>
PLIST

# ----------------------------------------------------------------------------
# 6. Code-sign (ad-hoc by default) — required for the arm64 slice to run.
#    Sign the frameworks first, then the app, deep.
# ----------------------------------------------------------------------------
log "Code-signing (identity: $CODESIGN_IDENTITY)"
for fw in SDL2.framework SDL2_image.framework; do
    codesign --force --sign "$CODESIGN_IDENTITY" --timestamp=none \
        "$APP_DIR/Contents/Frameworks/$fw" >/dev/null 2>&1 \
        || warn "codesign of $fw failed"
done
codesign --force --deep --sign "$CODESIGN_IDENTITY" --timestamp=none "$APP_DIR" \
    || warn "codesign of app bundle failed"

# ----------------------------------------------------------------------------
# 7. Verify
# ----------------------------------------------------------------------------
log "Verifying"
BIN="$APP_DIR/Contents/MacOS/$APP_NAME"
echo "  architectures : $(lipo -archs "$BIN")"
for arch in x86_64 arm64; do
    # 10.13-and-earlier targets emit LC_VERSION_MIN_MACOSX ("version X.Y");
    # 10.14+ targets emit LC_BUILD_VERSION ("minos X.Y").
    minos="$(otool -l -arch "$arch" "$BIN" 2>/dev/null \
        | awk '/LC_VERSION_MIN_MACOSX|LC_BUILD_VERSION/{f=1} f&&/version |minos /{print $2; exit}')"
    echo "  $arch min macOS: ${minos:-?}"
done
echo "  linked SDL    :"
otool -L "$BIN" | awk '/SDL2/{print "    "$1}'
echo "  rpaths        : $(otool -l "$BIN" | awk '/LC_RPATH/{f=1} f&&/path /{print $2; f=0}' | tr '\n' ' ')"
codesign --verify --deep --strict "$APP_DIR" 2>&1 && echo "  codesign      : OK" || warn "codesign verify failed"

log "Done: $APP_DIR"
echo
echo "Run it with:   open \"$APP_DIR\""
echo "Or from CLI:   \"$BIN\""
echo "To distribute: zip -r -y prince-macos.zip \"$APP_DIR\""

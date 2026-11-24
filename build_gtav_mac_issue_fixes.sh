#!/bin/sh
# Builds GTAV.app (gtav-recomp) on an Apple silicon Mac from the `issue-fixes` branch, which contains
# commit c169a5a (keyboard + mouse from the native window, stereo mix by default) plus the fixes that
# came after it (incl. b2276fa, which repairs that commit for the phone shells).
#
# Usage:   sh build_gtav_mac_issue_fixes.sh
# Options (environment variables):
#   WORK=~/gtav-recomp     where the source trees go (default ~/gtav-recomp)
#   JOBS=6                 parallel compile jobs (default: number of performance cores)
#   BRANCH=issue-fixes     branch/commit of gtav-recomp to build
#
# Needs: macOS 15+, Apple silicon, Xcode command-line tools, and `brew install cmake ninja python git`.
# About 30-40 GB free disk, 1-2 hours. Your game files are not touched.
set -eu

WORK=${WORK:-$HOME/gtav-recomp}
BRANCH=${BRANCH:-issue-fixes}
JOBS=${JOBS:-$(sysctl -n hw.perflevel0.physicalcpu 2>/dev/null || echo 4)}
export JOBS

SDK_PIN=f5337cd       # rexglue-sdk v0.10.0
PLUME_PIN=0ce184b
XR_PIN=990d03b
LLVM_VER=19.1.7
LLVM_NAME=LLVM-$LLVM_VER-macOS-ARM64

say() { printf '\n==> %s\n' "$*"; }
die() { printf '\nERROR: %s\n' "$*" >&2; exit 1; }

# 0. Prerequisites ---------------------------------------------------------------------------------
say "Checking prerequisites"
[ "$(uname -s)" = Darwin ] || die "run this on macOS"
[ "$(uname -m)" = arm64 ] || die "Apple silicon (M1 or newer) is required"
xcode-select -p >/dev/null 2>&1 || die "install the Xcode command-line tools: xcode-select --install"
for t in git cmake ninja python3 curl tar; do
  command -v "$t" >/dev/null 2>&1 || die "missing '$t' (brew install cmake ninja python git)"
done

# Resets a git tree to a pinned commit and removes leftovers of an earlier patch (keeps ignored build dirs).
reset_tree() { # dir pin
  git -C "$1" fetch -q origin 2>/dev/null || true
  git -C "$1" reset -q --hard "$2"
  git -C "$1" clean -fdq
  git -C "$1" submodule update -q --init --recursive
  git -C "$1" submodule foreach -q --recursive 'git reset -q --hard && git clean -fdq'
}

# 1. gtav-recomp on the issue-fixes branch ---------------------------------------------------------
say "gtav-recomp ($BRANCH) in $WORK"
if [ -d "$WORK/.git" ]; then
  if [ -n "$(git -C "$WORK" status --porcelain --untracked-files=no)" ]; then
    die "$WORK has local changes; commit/stash them or set WORK to another folder"
  fi
  git -C "$WORK" fetch -q origin
else
  git clone -q https://github.com/andrewnakas/gtav-recomp "$WORK"
fi
cd "$WORK"
git checkout -q "$BRANCH" 2>/dev/null || git checkout -q -b "$BRANCH" "origin/$BRANCH"
git merge -q --ff-only "origin/$BRANCH" 2>/dev/null || true
git merge-base --is-ancestor c169a5a HEAD || die "this checkout does not contain c169a5a"
git merge-base --is-ancestor b2276fa HEAD || die "this checkout does not contain b2276fa (phone-shell fix)"
echo "building $(git log -1 --format='%h %ad %s' --date=short)"

# 2. Upstream trees at their pins, with this branch's patches ---------------------------------------
say "ReXGlue SDK v0.10.0 + rexglue-sdk-gtav-linux.patch (all platforms, incl. macOS)"
[ -d rexglue-sdk/.git ] || git clone -q https://github.com/rexglue/rexglue-sdk rexglue-sdk
reset_tree rexglue-sdk "$SDK_PIN"
git -C rexglue-sdk apply ../rexglue-sdk-gtav-linux.patch
git -C rexglue-sdk/thirdparty/sdl3 apply ../../../sdl3-gtav.patch
git -C rexglue-sdk/thirdparty/FFmpeg apply ../../../ffmpeg-gtav.patch

mkdir -p thirdparty
say "plume + plume-gtav.patch"
[ -d thirdparty/plume/.git ] || git clone -q --recursive https://github.com/renderbag/plume thirdparty/plume
reset_tree thirdparty/plume "$PLUME_PIN"
git -C thirdparty/plume apply ../../plume-gtav.patch

say "XenosRecomp + xenosrecomp-gtav.patch"
[ -d thirdparty/XenosRecomp/.git ] || git clone -q --recursive https://github.com/hedge-dev/XenosRecomp thirdparty/XenosRecomp
reset_tree thirdparty/XenosRecomp "$XR_PIN"
git -C thirdparty/XenosRecomp apply ../../xenosrecomp-gtav.patch

# 3. LLVM (ships inside GTAV.app; it compiles the game library on your Mac) and license texts --------
mkdir -p "$WORK/deps/licenses"
cd "$WORK/deps"
if [ ! -x "$LLVM_NAME/bin/clang" ]; then
  say "Downloading $LLVM_NAME (~1 GB)"
  curl -fL --retry 3 -o "$LLVM_NAME.tar.xz" \
    "https://github.com/llvm/llvm-project/releases/download/llvmorg-$LLVM_VER/$LLVM_NAME.tar.xz"
  tar -xJf "$LLVM_NAME.tar.xz"
  rm -f "$LLVM_NAME.tar.xz"
fi
[ -f licenses/LLVM.txt ] || curl -fsSL -o licenses/LLVM.txt \
  "https://raw.githubusercontent.com/llvm/llvm-project/llvmorg-$LLVM_VER/llvm/LICENSE.TXT"
[ -f licenses/DirectXShaderCompiler.txt ] || curl -fsSL -o licenses/DirectXShaderCompiler.txt \
  "https://raw.githubusercontent.com/microsoft/DirectXShaderCompiler/main/LICENSE.TXT"
cd "$WORK"

# 4. Build: SDK runtime, XenosRecomp, gtav runtime + renderer, launcher, then package GTAV.app ------
# The build script makes fresh trees (build/release-mac) on every run.
OUT="$WORK/dist/mac-$(git rev-parse --short HEAD)"
say "Building (JOBS=$JOBS) -> $OUT  (this takes a while)"
sh tools/release/build_release_macos.sh "$OUT" "$WORK/deps/$LLVM_NAME" "$WORK/deps/licenses" --zip

say "Done"
echo "Package folder: $OUT"
ls "$OUT"
cat <<EOF

Next steps:
  1. Quit the game. Rename the old app (keep it as a fallback):
       mv /Applications/GTAV.app /Applications/GTAV-0.3.0.app
  2. Copy the new GTAV.app from $OUT to /Applications, then:
       xattr -dr com.apple.quarantine /Applications/GTAV.app
  3. REQUIRED: open it holding Option -> setup window -> same discs, TU and game folder -> Install.
     The game library (gtav_game.dylib in your game folder) must be rebuilt against the new runtime's
     hook list (15-30 min). Without this the new app would start the old 0.3.0 library.
  4. In game: Esc / F1 settings menu -> Mouse look, Mouse sensitivity, Stereo mix (on by default).
EOF

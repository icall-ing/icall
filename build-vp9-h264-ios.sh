#!/usr/bin/env bash
# Add VP9 (config flag; libvpx already has it) + H.264 (OpenH264, device slice)
# to the existing PJSIP 2.17 iOS build. Reuses cached libvpx. Rebuilds pjproject
# for device (VP9+H264) and simulator (VP9 only), repackages the xcframework, and
# installs it to Frameworks/PJSIP.xcframework.
set -euxo pipefail

APPDIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$APPDIR/pjsip-build-217"

OH_TAG="v2.4.1"
MINIOS="15.0"
NPROC="$(sysctl -n hw.ncpu)"
export PATH="/opt/homebrew/opt/libtool/libexec/gnubin:/opt/homebrew/bin:$PATH"
IOS_SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
SIM_SDK="$(xcrun --sdk iphonesimulator --show-sdk-path)"
CLANG="$(xcrun -f clang)"

cd "$ROOT/src"
[ -d openh264 ] || git clone --depth=1 --branch="$OH_TAG" https://github.com/cisco/openh264

# ── OpenH264 (device arm64 only) ──
OH="$ROOT/out/oh264-device"
if [ ! -f "$OH/lib/libopenh264.a" ]; then
  cd "$ROOT/src/openh264"
  make clean >/dev/null 2>&1 || true
  make OS=ios ARCH=arm64 SDK_MIN="$MINIOS" -j"$NPROC" libraries
  rm -rf "$OH"; mkdir -p "$OH/lib" "$OH/include/wels"
  cp libopenh264.a "$OH/lib/"
  cp codec/api/wels/*.h "$OH/include/wels/"
fi
echo "openh264 ready: $(ls -la "$OH/lib/libopenh264.a")"

# ── PJSIP one slice ──  $1=device|sim
build_pjsip () {
  local SLICE=$1 OUT="$ROOT/out/pj-$1"
  local SYSROOT TGT VPX="$ROOT/out/vpx-$1" PLATPATH MINF OH264FLAG
  if [ "$SLICE" = device ]; then
    SYSROOT="$IOS_SDK"; TGT="aarch64-apple-darwin_ios"; MINF="-miphoneos-version-min=$MINIOS"
    PLATPATH="$(xcrun --sdk iphoneos --show-sdk-platform-path)/Developer"
    OH264_ENABLE=0   # H264 dropped (patent licensing) — VP8 + VP9 only
  else
    SYSROOT="$SIM_SDK"; TGT="aarch64-apple-darwin_ios"; MINF="-mios-simulator-version-min=$MINIOS"
    PLATPATH="$(xcrun --sdk iphonesimulator --show-sdk-platform-path)/Developer"
    OH264_ENABLE=0
  fi

  # Per-slice config_site.h: VP9 on both; OpenH264 only on the device slice.
  cat > "$ROOT/src/pjproject/pjlib/include/pj/config_site.h" <<CFG
#define PJ_CONFIG_IPHONE 1
#include <pj/config_site_sample.h>
#define PJMEDIA_HAS_VIDEO            1
#define PJMEDIA_HAS_VPX_CODEC        1
#define PJMEDIA_HAS_VPX_CODEC_VP8    1
#define PJMEDIA_HAS_VPX_CODEC_VP9    1
#define PJMEDIA_HAS_OPENH264_CODEC   ${OH264_ENABLE}
#define PJMEDIA_HAS_OPUS_CODEC       0
#define PJ_HAS_SSL_SOCK             1
#define PJ_SSL_SOCK_IMP            PJ_SSL_SOCK_IMP_APPLE
CFG

  cd "$ROOT/src/pjproject"; make distclean 2>/dev/null || true
  export DEVPATH="$PLATPATH" IPHONESDK="$SYSROOT" ARCH="-arch arm64" MIN_IOS="$MINF"
  local INC="-I$VPX/include"
  local LFW="-L$VPX/lib"
  local CONFIGOPT="--with-vpx=$VPX"
  if [ "$OH264_ENABLE" = 1 ]; then
    INC="$INC -I$OH/include"
    LFW="$LFW -L$OH/lib"
    CONFIGOPT="$CONFIGOPT --with-openh264=$OH"
  fi
  export CFLAGS="-arch arm64 $MINF -isysroot $SYSROOT $INC"
  FW="-framework AVFoundation -framework AudioToolbox -framework CFNetwork -framework CoreAudio -framework CoreFoundation -framework CoreGraphics -framework CoreMedia -framework CoreVideo -framework Foundation -framework Metal -framework MetalKit -framework Network -framework OpenGLES -framework QuartzCore -framework Security -framework UIKit -framework VideoToolbox"
  export LDFLAGS="-arch arm64 $MINF -isysroot $SYSROOT $LFW $FW -lc++"
  ./configure-iphone $CONFIGOPT
  make dep; make
  rm -rf "$OUT"; mkdir -p "$OUT"
  find . -name "*-$TGT.a" -exec cp {} "$OUT/" \;
  local -a MERGE_ARGS=( "$OUT"/*.a "$VPX/lib/libvpx.a" )
  if [ "$OH264_ENABLE" = 1 ]; then MERGE_ARGS+=( "$OH/lib/libopenh264.a" ); fi
  /usr/bin/libtool -static -o "$ROOT/out/libpjproject-$SLICE-arm64.a" "${MERGE_ARGS[@]}"
  unset CFLAGS LDFLAGS ARCH IPHONESDK DEVPATH MIN_IOS
}
build_pjsip device
build_pjsip sim

# ── xcframework (Headers from the device config_site = VP9+H264) ──
rm -rf "$ROOT/out/PJSIP.xcframework" "$ROOT/out/Headers"
mkdir -p "$ROOT/out/Headers"
cp -r "$ROOT/src/pjproject"/{pjlib,pjlib-util,pjnath,pjmedia,pjsip,pjsip-apps}/include/* "$ROOT/out/Headers/" 2>/dev/null || true
xcodebuild -create-xcframework \
  -library "$ROOT/out/libpjproject-device-arm64.a" -headers "$ROOT/out/Headers" \
  -library "$ROOT/out/libpjproject-sim-arm64.a"    -headers "$ROOT/out/Headers" \
  -output "$ROOT/out/PJSIP.xcframework"

# ── install into the app ──
rm -rf "$APPDIR/Frameworks/PJSIP.xcframework.prevh264"
mv "$APPDIR/Frameworks/PJSIP.xcframework" "$APPDIR/Frameworks/PJSIP.xcframework.prevh264"
cp -R "$ROOT/out/PJSIP.xcframework" "$APPDIR/Frameworks/PJSIP.xcframework"
# refresh the headers the app's HEADER_SEARCH_PATHS points at
rm -rf "$APPDIR/pjsip-build/out/include"
mkdir -p "$APPDIR/pjsip-build/out/include"
cp -r "$ROOT/out/Headers/"* "$APPDIR/pjsip-build/out/include/"

echo "=== VP9+H264 BUILD COMPLETE $(date) ==="
nm "$APPDIR/Frameworks/PJSIP.xcframework/ios-arm64/libpjproject-device-arm64.a" 2>/dev/null | grep -ciE "WelsCreateSVCEncoder|ISVCEncoder" | xargs echo "openh264 symbols (device):"

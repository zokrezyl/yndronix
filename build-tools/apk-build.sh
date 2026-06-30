#!/usr/bin/env bash
#
# Manual APK build for the com.yndronix wrapper, for hosts that only have the
# Debian android-sdk build-tools (no gradle/platform). Runs ON the build host.
#
# Expects, in $WORK:
#   proj/                 <- the android/ project (rsynced here), including
#                            proj/app/src/main/jniLibs/arm64-v8a/libyndld.so
#   android.jar           <- API 35 platform jar (>=33: the app uses
#                            POST_NOTIFICATIONS / TIRAMISU / foregroundServiceType)
#   commons-compress.jar  <- tar reader
#   brotli-dec.jar        <- org.brotli:dec, brotli decompressor (runtime dep)
#   r8.jar                <- provides com.android.tools.r8.D8
#
# Produces $WORK/out/yndronix.apk (debug-signed, target-sdk 35). This is the
# SIDELOAD path; for a Google Play upload build the .aab with build-release-aab.sh.

set -euo pipefail

WORK="${WORK:-$HOME/yndronix-build}"
BT="${ANDROID_BUILD_TOOLS:-/usr/lib/android-sdk/build-tools/debian}"
SRC="$WORK/proj/app/src/main"

cd "$WORK"
rm -rf out
mkdir -p out/classes out/dex

echo ">> [1/6] javac (--release 8)"
javac --release 8 -cp "android.jar:commons-compress.jar" -d out/classes \
    $(find "$SRC/java" -name '*.java')

echo ">> [2/6] d8 -> classes.dex (app + commons-compress + brotli)"
java -cp r8.jar com.android.tools.r8.D8 \
    --release --min-api 24 --lib android.jar --output out/dex \
    commons-compress.jar brotli-dec.jar $(find out/classes -name '*.class')

echo ">> [3/7] aapt2 link (manifest + assets; target-sdk 35; .br stored uncompressed)"
"$BT/aapt2" link -I android.jar \
    --manifest "$SRC/AndroidManifest.xml" \
    -A "$SRC/assets" \
    --min-sdk-version 24 --target-sdk-version 35 \
    -0 br \
    -o out/base.apk

echo ">> [4/7] add classes.dex"
( cd out && zip -qj base.apk dex/classes.dex )

echo ">> [5/7] add the musl loader (lib/arm64-v8a/libyndld.so -> nativeLibraryDir)"
loader="$SRC/jniLibs/arm64-v8a/libyndld.so"
[ -f "$loader" ] || { echo "error: missing $loader (run make-apk-assets first)" >&2; exit 1; }
mkdir -p out/lib/arm64-v8a
cp "$loader" out/lib/arm64-v8a/libyndld.so
( cd out && zip -q base.apk lib/arm64-v8a/libyndld.so )

echo ">> [6/7] zipalign"
"$BT/zipalign" -f -p 4 out/base.apk out/aligned.apk

echo ">> [7/7] sign (debug key)"
if [ ! -f debug.ks ]; then
    keytool -genkeypair -keystore debug.ks -storepass android -keypass android \
        -alias d -dname "CN=yndronix" -keyalg RSA -keysize 2048 -validity 10000 >/dev/null 2>&1
fi
"$BT/apksigner" sign --ks debug.ks --ks-pass pass:android --key-pass pass:android \
    --out out/yndronix.apk out/aligned.apk
"$BT/apksigner" verify out/yndronix.apk && echo ">> signature OK"
ls -lh out/yndronix.apk

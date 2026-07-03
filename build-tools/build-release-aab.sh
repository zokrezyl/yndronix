#!/usr/bin/env bash
#
# Build a signed release Android App Bundle (.aab) for Google Play -- no gradle,
# straight from the repo, on the build host. This encodes the exact manual
# aapt2 + bundletool flow that is known to produce a Play-valid bundle.
#
# Why an asset pack: the baked store (store.tar.br) is ~270 MB, but Google Play
# caps the BASE module at 200 MB. So the store ships as an INSTALL-TIME asset
# pack (limit 1 GB); its assets are merged into the app's asset namespace at
# install, so Installer.java's getAssets().open("store.tar.br") is unchanged.
# The base module is then ~1.5 MB (dex + manifest + the musl loader).
#
# Inputs (produced by build-tools/make-apk-assets):
#   android/app/src/main/assets/store.tar.br
#   android/app/src/main/jniLibs/arm64-v8a/libyndld.so
#
# SDK / tools are auto-detected (override with env): ANDROID_HOME or
# ANDROID_SDK_ROOT, else ~/android-sdk. The build deps (commons-compress, the
# brotli decoder, bundletool-all) are taken from the gradle cache or downloaded
# to tmp/libs if missing.
#
# Upload-key signing (else a debug key, which Play will NOT accept):
#   YNDRONIX_KEYSTORE  YNDRONIX_KEYSTORE_PASSWORD  YNDRONIX_KEY_ALIAS  YNDRONIX_KEY_PASSWORD
#
# Output: out/yndronix.aab

set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
SRC="${YND_ANDROID_SRC:-$repo_root/android/app/src/main}"
LIBS="${YND_LIBS:-$repo_root/tmp/libs}"
OUT="${YND_OUT:-$repo_root/out}"
B="${YND_AAB_WORK:-$repo_root/tmp/aabbuild}"
VERSION_CODE="${VERSION_CODE:-1}"
VERSION_NAME="${VERSION_NAME:-1.0}"
TARGET_SDK="${TARGET_SDK:-35}"

die() { printf 'build-release-aab: %s\n' "$*" >&2; exit 1; }

# --- detect SDK + build-tools + platform jar --------------------------------
SDK="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-}}"
if [ -z "$SDK" ]; then
    for d in "$HOME/android-sdk" "$HOME/Android/Sdk" /opt/android-sdk /usr/lib/android-sdk; do
        [ -d "$d/build-tools" ] && { SDK="$d"; break; }
    done
fi
[ -n "$SDK" ] && [ -d "$SDK/build-tools" ] || die "Android SDK not found (set ANDROID_HOME)"
BT="${ANDROID_BUILD_TOOLS:-$(ls -d "$SDK"/build-tools/*/ 2>/dev/null | sort -V | tail -1)}"; BT="${BT%/}"
AJAR="${ANDROID_JAR:-$(ls "$SDK"/platforms/android-*/android.jar 2>/dev/null | sort -V | tail -1)}"
[ -x "$BT/aapt2" ] || die "aapt2 not found under $BT"
[ -f "$AJAR" ]     || die "android.jar not found under $SDK/platforms (install one, e.g. android-35)"

# --- inputs -----------------------------------------------------------------
[ -f "$SRC/assets/store.tar.br" ]            || die "missing $SRC/assets/store.tar.br (run make-apk-assets)"
[ -f "$SRC/jniLibs/arm64-v8a/libyndld.so" ]  || die "missing the musl loader (run make-apk-assets)"

mkdir -p "$LIBS" "$OUT"

# --- build deps: from the gradle cache, or downloaded to tmp/libs -----------
fetch() {  # url dest
    [ -f "$2" ] && return 0
    command -v curl >/dev/null 2>&1 || die "need $2 but curl is unavailable to fetch it"
    printf '>> fetching %s\n' "$(basename "$2")" >&2
    curl -fsSL -o "$2" "$1" || die "failed to download $1"
}
CC="$(find "$HOME/.gradle/caches/modules-2" -name 'commons-compress-1.21.jar' 2>/dev/null | head -1)"
[ -n "$CC" ] || { CC="$LIBS/commons-compress-1.21.jar"; fetch https://repo1.maven.org/maven2/org/apache/commons/commons-compress/1.21/commons-compress-1.21.jar "$CC"; }
BROTLI="$LIBS/dec-0.1.2.jar";              fetch https://repo1.maven.org/maven2/org/brotli/dec/0.1.2/dec-0.1.2.jar "$BROTLI"
BUNDLETOOL="${BUNDLETOOL:-$LIBS/bundletool-all.jar}"
fetch https://github.com/google/bundletool/releases/download/1.15.2/bundletool-all-1.15.2.jar "$BUNDLETOOL"

# --- build ------------------------------------------------------------------
rm -rf "$B"; mkdir -p "$B/classes" "$B/dex" "$B/proto" \
    "$B/base/manifest" "$B/base/dex" "$B/base/lib/arm64-v8a" "$B/pack/manifest" "$B/pack/assets"

echo ">> [1/7] javac"
javac --release 8 -cp "$AJAR:$CC" -d "$B/classes" $(find "$SRC/java" -name '*.java')

echo ">> [2/7] d8 -> classes.dex (app + commons-compress + brotli)"
"$BT/d8" --release --min-api 24 --lib "$AJAR" --output "$B/dex" \
    "$CC" "$BROTLI" $(find "$B/classes" -name '*.class')

# Base module: protobuf-format manifest, NO assets, version code injected (gradle
# normally injects it; the manual path must, or bundletool rejects the bundle).
echo ">> [3/7] aapt2 link --proto-format: base (target-sdk $TARGET_SDK, no big asset)"
"$BT/aapt2" link --proto-format -I "$AJAR" --manifest "$SRC/AndroidManifest.xml" \
    --min-sdk-version 24 --target-sdk-version "$TARGET_SDK" \
    --version-code "$VERSION_CODE" --version-name "$VERSION_NAME" \
    -o "$B/proto/base.apk"
( cd "$B/proto" && unzip -qo base.apk -d base-x )
cp "$B/proto/base-x/AndroidManifest.xml" "$B/base/manifest/AndroidManifest.xml"
cp "$B/proto/base-x/resources.pb"        "$B/base/resources.pb"
cp "$B/dex/classes.dex"                  "$B/base/dex/classes.dex"
cp "$SRC/jniLibs/arm64-v8a/libyndld.so"  "$B/base/lib/arm64-v8a/libyndld.so"
( cd "$B/base" && zip -qr -X ../base.zip manifest dex lib resources.pb )

# Asset-pack module. Three things bundletool is strict about, learned the hard way:
#   * the manifest must NOT carry <uses-sdk> -> do NOT pass --min-sdk-version here
#   * it MUST declare <dist:fusing>
#   * the module zip must NOT contain a resources.pb (asset packs have no resources)
echo ">> [4/7] aapt2 link --proto-format: asset pack manifest"
cat > "$B/pack-manifest.xml" <<'XML'
<?xml version="1.0" encoding="utf-8"?>
<manifest xmlns:dist="http://schemas.android.com/apk/distribution"
    package="com.yndronix" split="store_pack">
    <dist:module dist:type="asset-pack">
        <dist:delivery>
            <dist:install-time/>
        </dist:delivery>
        <dist:fusing dist:include="true"/>
    </dist:module>
</manifest>
XML
"$BT/aapt2" link --proto-format -I "$AJAR" --manifest "$B/pack-manifest.xml" -o "$B/proto/pack.apk"
( cd "$B/proto" && unzip -qo pack.apk -d pack-x )
cp "$B/proto/pack-x/AndroidManifest.xml" "$B/pack/manifest/AndroidManifest.xml"
cp "$SRC/assets/store.tar.br"            "$B/pack/assets/store.tar.br"
( cd "$B/pack" && zip -qr -X ../store_pack.zip manifest assets )   # NO resources.pb

echo ">> [5/7] bundletool build-bundle -> $OUT/yndronix.aab"
cat > "$B/BundleConfig.json" <<'JSON'
{ "compression": { "uncompressedGlob": ["assets/**.br", "lib/**/libyndld.so"] } }
JSON
rm -f "$OUT/yndronix.aab"
java -jar "$BUNDLETOOL" build-bundle \
    --modules="$B/base.zip,$B/store_pack.zip" \
    --config="$B/BundleConfig.json" \
    --output="$OUT/yndronix.aab"

echo ">> [6/7] sign the .aab (jarsigner; AABs are jar-signed, not apksigner)"
if [ -n "${YNDRONIX_KEYSTORE:-}" ]; then
    jarsigner -keystore "$YNDRONIX_KEYSTORE" \
        -storepass "${YNDRONIX_KEYSTORE_PASSWORD:?set YNDRONIX_KEYSTORE_PASSWORD}" \
        -keypass "${YNDRONIX_KEY_PASSWORD:-${YNDRONIX_KEYSTORE_PASSWORD}}" \
        -sigalg SHA256withRSA -digestalg SHA-256 \
        "$OUT/yndronix.aab" "${YNDRONIX_KEY_ALIAS:?set YNDRONIX_KEY_ALIAS}"
    echo ">> signed with the upload key"
elif [ -f "$HOME/.android/debug.keystore" ]; then
    jarsigner -keystore "$HOME/.android/debug.keystore" -storepass android -keypass android \
        -sigalg SHA256withRSA -digestalg SHA-256 "$OUT/yndronix.aab" androiddebugkey
    echo ">> WARNING: signed with the DEBUG key -- Google Play will NOT accept this."
    echo ">>          Set YNDRONIX_KEYSTORE / YNDRONIX_KEY_ALIAS (+ passwords) for the upload key."
else
    echo ">> WARNING: unsigned (no upload key, no debug keystore)."
fi

echo ">> [7/7] validate"
java -jar "$BUNDLETOOL" validate --bundle "$OUT/yndronix.aab" >/dev/null && echo ">> bundle is valid"
ls -lh "$OUT/yndronix.aab" | awk '{print ">> AAB:", $5, $9}'
echo ">> upload:  build-tools/upload-to-googl-play.sh --key <service-account>.json --artifact $OUT/yndronix.aab --track internal"

#!/usr/bin/env bash
#
# Upload the yndronix Android artifact to Google Play via the Play Developer
# Publishing API v3 (a service-account JSON key, no browser/OAuth dance).
#
# It runs two phases:
#
#   1. PREFLIGHT -- inspect the artifact + the android/ project for the things
#      Google Play rejects at upload time (debuggable build, debug signature,
#      below-minimum target SDK, APK where an AAB is required). This phase is
#      the answer to "can I publish what I have right now?" -- run the script
#      and read the report even if you have no service account yet.
#
#   2. UPLOAD -- create an edit, push the bundle/apk, assign it to a track,
#      and commit. Skipped automatically unless a service-account key is
#      provided. Hard-blocking preflight findings abort the upload unless
#      --force is passed.
#
# The upload itself is done by a small inline Python program (the official
# google-api-python-client), executed through `uv run` with the deps declared
# inline -- no venv to set up, matching the repo's other uv-run tooling.
#
# Usage:
#   build-tools/upload-to-googl-play.sh [options]
#
# Options:
#   --artifact PATH     .aab (preferred) or .apk to upload.
#                       Default: first existing of
#                         out/yndronix.aab, android/app/build/outputs/.../*.aab,
#                         out/yndronix.apk
#   --key PATH          Service-account JSON key. Also: $GOOGLE_PLAY_SERVICE_ACCOUNT_JSON
#   --package NAME      Application id. Default: com.yndronix
#   --track NAME        internal | alpha | beta | production. Default: internal
#   --status NAME       completed | draft | inProgress | halted. Default: draft
#   --release-name STR  Human label for the release. Default: derived from versionName
#   --force             Attempt the upload even if preflight found hard blockers.
#   --preflight-only    Run phase 1 only; never contact Google.
#   -h, --help          This help.
#
# Exit status: 0 ok; 1 usage/runtime error; 2 preflight found a hard blocker
# (and --force was not given).

set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"

# --- Google Play moving targets (verify against the Play Console; these change
#     yearly). As of 2026-06: new apps/updates must target API 35 (Android 15);
#     API 36 (Android 16) becomes mandatory 2025-08-31 -> 2026-08-31 window.
required_target_sdk=35
recommended_target_sdk=36

# --- defaults ---------------------------------------------------------------
artifact=""
service_account_key="${GOOGLE_PLAY_SERVICE_ACCOUNT_JSON:-}"
package_name="com.yndronix"
track="internal"
release_status="draft"
release_name=""
force=0
preflight_only=0

usage() {
    sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//'
    exit "${1:-0}"
}

die() {
    printf 'upload-to-googl-play: %s\n' "$*" >&2
    exit 1
}

# --- arg parsing ------------------------------------------------------------
while [ "$#" -gt 0 ]; do
    case "$1" in
        --artifact)       artifact="${2:?--artifact needs a path}"; shift 2 ;;
        --key)            service_account_key="${2:?--key needs a path}"; shift 2 ;;
        --package)        package_name="${2:?--package needs a value}"; shift 2 ;;
        --track)          track="${2:?--track needs a value}"; shift 2 ;;
        --status)         release_status="${2:?--status needs a value}"; shift 2 ;;
        --release-name)   release_name="${2:?--release-name needs a value}"; shift 2 ;;
        --force)          force=1; shift ;;
        --preflight-only) preflight_only=1; shift ;;
        -h|--help)        usage 0 ;;
        *)                die "unknown option: $1 (try --help)" ;;
    esac
done

# --- locate the artifact ----------------------------------------------------
if [ -z "$artifact" ]; then
    for candidate in \
        "$repo_root/out/yndronix.aab" \
        "$repo_root/android/app/build/outputs/bundle/release/app-release.aab" \
        "$repo_root/android/app/build/outputs/apk/release/app-release.apk" \
        "$repo_root/out/yndronix.apk"
    do
        if [ -f "$candidate" ]; then artifact="$candidate"; break; fi
    done
fi

[ -n "$artifact" ] || die "no artifact given and none found; pass --artifact PATH"
[ -f "$artifact" ] || die "artifact not found: $artifact"

artifact_ext="${artifact##*.}"
case "$artifact_ext" in
    aab|apk) : ;;
    *) die "artifact must be .aab or .apk, got: $artifact" ;;
esac

# ===========================================================================
# PHASE 1 -- PREFLIGHT
# ===========================================================================
printf '\n== Google Play preflight ==\n'
printf '   artifact : %s (%s)\n' "$artifact" "$artifact_ext"
printf '   package  : %s\n' "$package_name"
printf '   track    : %s (status: %s)\n\n' "$track" "$release_status"

blockers=()
warnings=()

# 1. AAB vs APK. Apps created after Aug 2021 must ship an Android App Bundle;
#    the production/testing tracks of a fresh app will not accept a raw APK.
if [ "$artifact_ext" = "apk" ]; then
    blockers+=("Artifact is an APK. New Google Play apps must publish an Android App Bundle (.aab); a raw APK is rejected on a freshly-created app. Produce an .aab (e.g. 'gradle bundleRelease').")
fi

# 2. targetSdkVersion in the gradle project (the build that produced -- or will
#    produce -- the artifact). Below the Play minimum => hard reject.
gradle_file="$repo_root/android/app/build.gradle"
project_target_sdk=""
if [ -f "$gradle_file" ]; then
    project_target_sdk="$(grep -oE 'targetSdkVersion[[:space:]]+[0-9]+' "$gradle_file" \
        | grep -oE '[0-9]+' | head -n1 || true)"
fi
if [ -n "$project_target_sdk" ]; then
    if [ "$project_target_sdk" -lt "$required_target_sdk" ]; then
        blockers+=("targetSdkVersion is $project_target_sdk; Google Play requires >= $required_target_sdk (Android 15) for new apps and updates. NOTE: this app deliberately targets 28 to keep execve() of files in its writable data dir legal (the W^X rule that Android 10+/target>=29 enforces). Raising the target SDK to satisfy Play breaks the core relocated-store/exec model -- these requirements are in direct conflict.")
    elif [ "$project_target_sdk" -lt "$recommended_target_sdk" ]; then
        warnings+=("targetSdkVersion $project_target_sdk meets today's minimum but API $recommended_target_sdk (Android 16) becomes mandatory around 2026-08-31.")
    fi
fi

# 3. android:debuggable -- Play rejects any artifact built debuggable.
manifest="$repo_root/android/app/src/main/AndroidManifest.xml"
if [ -f "$manifest" ] && grep -q 'android:debuggable="true"' "$manifest"; then
    blockers+=("AndroidManifest.xml sets android:debuggable=\"true\". Google Play rejects debuggable uploads. Remove it (release builds default to false).")
fi

# 4. Signature -- the in-repo apk-build.sh signs with a throwaway debug key
#    (CN=yndronix, storepass 'android'). Play needs a real upload/release key.
if command -v keytool >/dev/null 2>&1 && [ "$artifact_ext" = "apk" ]; then
    signer_dn="$(keytool -printcert -jarfile "$artifact" 2>/dev/null \
        | grep -oE 'CN=[^,]*' | head -n1 || true)"
    if [ -n "$signer_dn" ]; then
        printf '   signer   : %s\n\n' "$signer_dn"
    fi
fi
if grep -q 'debug.ks' "$repo_root/build-tools/apk-build.sh" 2>/dev/null; then
    warnings+=("The repo's apk-build.sh debug-signs with a generated 'debug.ks' (pass 'android'). Google Play needs a release upload key -- enrol in Play App Signing and sign with a real upload keystore, not the debug key.")
fi

# 5. Policy surface (not detectable from the binary, but worth surfacing): this
#    app fetches/executes arbitrary binaries from its data dir and runs an SSH
#    server. That is the same shape that keeps Termux off current Play.
warnings+=("Policy review risk: the app unpacks a Nix store into its data dir and execs binaries from it (plus an SSH server / runit). This pattern routinely trips Google Play's Device-and-Network-Abuse / dynamic-code policies (it is why Termux left Play). Independent of any technical blocker above.")

# 6. Store-listing prerequisites that block the *release*, not the upload.
warnings+=("Before any track can go live you still need: app icon, store listing, privacy policy URL, Data safety form, content rating, and (for a new app) the first release created in the Console.")

# --- report -----------------------------------------------------------------
if [ "${#blockers[@]}" -gt 0 ]; then
    printf 'BLOCKERS (Google Play will reject this artifact):\n'
    for item in "${blockers[@]}"; do printf '  [x] %s\n\n' "$item"; done
fi
if [ "${#warnings[@]}" -gt 0 ]; then
    printf 'WARNINGS / prerequisites:\n'
    for item in "${warnings[@]}"; do printf '  [!] %s\n\n' "$item"; done
fi
if [ "${#blockers[@]}" -eq 0 ]; then
    printf 'Preflight found no hard upload blockers.\n\n'
fi

if [ "$preflight_only" -eq 1 ]; then
    [ "${#blockers[@]}" -gt 0 ] && exit 2
    exit 0
fi

# ===========================================================================
# PHASE 2 -- UPLOAD
# ===========================================================================
if [ -z "$service_account_key" ]; then
    printf 'No service-account key (--key / $GOOGLE_PLAY_SERVICE_ACCOUNT_JSON); stopping after preflight.\n'
    printf 'To enable upload: create a service account in Google Cloud, grant it access in\n'
    printf 'Play Console (Users & permissions), download its JSON key, and re-run with --key.\n\n'
    [ "${#blockers[@]}" -gt 0 ] && exit 2
    exit 0
fi
[ -f "$service_account_key" ] || die "service-account key not found: $service_account_key"

if [ "${#blockers[@]}" -gt 0 ] && [ "$force" -ne 1 ]; then
    die "preflight found $((${#blockers[@]})) hard blocker(s); refusing to upload. Re-run with --force to try anyway (Google will most likely reject it)."
fi

command -v uv >/dev/null 2>&1 || die "need 'uv' to run the uploader (https://docs.astral.sh/uv/)"

[ -n "$release_name" ] || release_name="yndronix upload"

printf 'Uploading %s to track "%s" (status %s)...\n\n' "$artifact" "$track" "$release_status"

GP_KEY="$service_account_key" \
GP_PACKAGE="$package_name" \
GP_ARTIFACT="$artifact" \
GP_ARTIFACT_KIND="$artifact_ext" \
GP_TRACK="$track" \
GP_STATUS="$release_status" \
GP_RELEASE_NAME="$release_name" \
uv run --quiet \
    --with 'google-api-python-client>=2.0' \
    --with 'google-auth>=2.0' \
    python - <<'PY'
import os
import sys

from google.oauth2 import service_account
from googleapiclient.discovery import build
from googleapiclient.errors import HttpError
from googleapiclient.http import MediaFileUpload

key = os.environ["GP_KEY"]
package = os.environ["GP_PACKAGE"]
artifact = os.environ["GP_ARTIFACT"]
kind = os.environ["GP_ARTIFACT_KIND"]
track = os.environ["GP_TRACK"]
status = os.environ["GP_STATUS"]
release_name = os.environ["GP_RELEASE_NAME"]

scopes = ["https://www.googleapis.com/auth/androidpublisher"]
credentials = service_account.Credentials.from_service_account_file(key, scopes=scopes)
service = build("androidpublisher", "v3", credentials=credentials, cache_discovery=False)
edits = service.edits()


def fail(message):
    print(f"upload-to-googl-play: {message}", file=sys.stderr)
    sys.exit(1)


try:
    edit_id = edits.insert(packageName=package, body={}).execute()["id"]
    print(f">> opened edit {edit_id}")

    media = MediaFileUpload(artifact, mimetype="application/octet-stream", resumable=True)
    if kind == "aab":
        uploaded = edits.bundles().upload(
            packageName=package, editId=edit_id, media_body=media
        ).execute()
    else:
        uploaded = edits.apks().upload(
            packageName=package, editId=edit_id, media_body=media
        ).execute()
    version_code = uploaded["versionCode"]
    print(f">> uploaded {kind}, versionCode={version_code}")

    release = {"name": release_name, "versionCodes": [str(version_code)], "status": status}
    edits.tracks().update(
        packageName=package,
        editId=edit_id,
        track=track,
        body={"track": track, "releases": [release]},
    ).execute()
    print(f">> assigned versionCode {version_code} to track '{track}' (status {status})")

    edits.commit(packageName=package, editId=edit_id).execute()
    print(f">> committed edit {edit_id} -- done")
except HttpError as error:
    # The first version of a brand-new app must be created in the Console UI;
    # the API returns a 4xx until the app exists as a draft. Surface the body.
    fail(f"Google Play API error: {error}")
except FileNotFoundError as error:
    fail(str(error))
PY

printf '\n>> upload finished.\n'

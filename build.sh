#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}"

APP_NAME="MacBridge"
BUNDLE="${APP_NAME}.app"
SRC_DIR="Sources/MacBridge"
# The file on disk is lowercase `info.plist`. That only works because
# macOS volumes are case-insensitive by default -- on a case-sensitive
# APFS volume (or in CI) the existence check below fails and the build
# stops with "Missing required path: Info.plist".
INFO_PLIST="info.plist"
ENTITLEMENTS="MacBridge.entitlements"

# A stable signing identity prevents each rebuild from appearing as a new app
# to macOS privacy controls. Override this through MACBRIDGE_SIGN_IDENTITY.
SIGN_IDENTITY="${MACBRIDGE_SIGN_IDENTITY:-MacBridge Local Signing}"

for required_path in "${SRC_DIR}" "${INFO_PLIST}" "${ENTITLEMENTS}"; do
    if [ ! -e "${required_path}" ]; then
        echo "❌ Missing required path: ${required_path}"
        exit 1
    fi
done

# Include sources in Modules/ and any deeper source directories as well.
# Bash arrays preserve paths with spaces and work with macOS's bundled Bash 3.2.
SWIFT_SOURCES=()
while IFS= read -r -d '' source_file; do
    SWIFT_SOURCES+=("${source_file}")
done < <(find "${SRC_DIR}" -type f -name '*.swift' -print0)

if [ "${#SWIFT_SOURCES[@]}" -eq 0 ]; then
    echo "❌ No Swift sources found under ${SRC_DIR}"
    exit 1
fi

# Report an incomplete PowerPack installation before stopping the existing app.
for module in AutomationSupport.swift Mouse.swift Accessibility.swift Screen.swift WhatsApp.swift PowerRouter.swift; do
    module_found=false
    for source_file in "${SWIFT_SOURCES[@]}"; do
        if [ "${source_file##*/}" = "${module}" ]; then
            module_found=true
            break
        fi
    done
    if [ "${module_found}" = false ]; then
        echo "❌ Missing PowerPack source: ${module}"
        echo "   Copy the PowerPack Swift files into ${SRC_DIR} (including its Modules folder)."
        exit 1
    fi
done

echo "🛑 Stopping old instance..."
pkill -x "${APP_NAME}" 2>/dev/null || true

echo "🧹 Cleaning..."
rm -rf -- "${BUNDLE}"

echo "📦 Creating app bundle..."
mkdir -p "${BUNDLE}/Contents/MacOS"

echo "🔨 Compiling..."
swiftc -swift-version 5 "${SWIFT_SOURCES[@]}" \
    -framework AppKit \
    -framework ApplicationServices \
    -framework CoreGraphics \
    -framework ScreenCaptureKit \
    -framework EventKit \
    -framework Contacts \
    -framework UserNotifications \
    -framework Vision \
    -framework PDFKit \
    -framework WebKit \
    -o "${BUNDLE}/Contents/MacOS/${APP_NAME}"

echo "📄 Copying Info.plist..."
cp "${INFO_PLIST}" "${BUNDLE}/Contents/Info.plist"

BUNDLE_ID="$(
    /usr/libexec/PlistBuddy \
        -c "Print :CFBundleIdentifier" \
        "${BUNDLE}/Contents/Info.plist"
)"

if [ -z "${BUNDLE_ID}" ]; then
    echo "❌ CFBundleIdentifier is missing from ${INFO_PLIST}"
    exit 1
fi

echo "🔏 Signing..."
if security find-identity -v -p codesigning 2>/dev/null |
    grep -Fq "\"${SIGN_IDENTITY}\""; then
    SIGNING_IDENTITY="${SIGN_IDENTITY}"
else
    echo "⚠️ '${SIGN_IDENTITY}' was not found; using ad-hoc signing."
    echo "   Permissions may need to be granted again after a rebuild."
    SIGNING_IDENTITY="-"
fi

codesign \
    --force \
    --options runtime \
    --entitlements "${ENTITLEMENTS}" \
    --identifier "${BUNDLE_ID}" \
    --sign "${SIGNING_IDENTITY}" \
    "${BUNDLE}"

echo "✅ Verifying bundle and embedded entitlements..."
codesign --verify --strict --verbose=2 "${BUNDLE}"

EMBEDDED_ENTITLEMENTS="$(codesign -d --entitlements :- "${BUNDLE}" 2>&1)"
if ! grep -q "com.apple.security.automation.apple-events" <<<"${EMBEDDED_ENTITLEMENTS}"; then
    echo "❌ Apple Events entitlement was not embedded"
    exit 1
fi

codesign -dv "${BUNDLE}" 2>&1 |
    grep -E "Authority|Identifier|Runtime" || true

echo "🚀 Launching..."
open "${BUNDLE}"

echo
echo "MacBridge launched."
echo "Test with: curl http://localhost:8765/health"


# ── Keep the Jugnu account's copy in step ─────────────────────────────────
# setup-agent-session.sh copies the bundle to /Users/Shared/Jugnu for the
# second login to run. Without this, every later rebuild only updated YOUR
# instance and the agent session silently kept running the old code.
# No sudo needed: the bundle directory there is owned by you. The running
# agent instance is asked to exit and its LaunchAgent (KeepAlive) restarts
# it from the new binary. Same signing identity, so its permissions carry over.
AGENT_COPY="/Users/Shared/Jugnu/${BUNDLE}"
AGENT_PORT="${JUGNU_AGENT_PORT:-8766}"
if [ -d "${AGENT_COPY}" ] && [ -w "${AGENT_COPY}" ]; then
    echo
    echo "🔁 Updating the Jugnu account's copy at ${AGENT_COPY}..."
    rsync -a --delete "${BUNDLE}/" "${AGENT_COPY}/"
    chmod -R a+rX "${AGENT_COPY}"
    if curl -s --max-time 2 "http://localhost:${AGENT_PORT}/health" >/dev/null 2>&1; then
        curl -s --max-time 5 -X POST "http://localhost:${AGENT_PORT}/shell/spawn" \
            -H 'Content-Type: application/json' \
            ${MACBRIDGE_TOKEN:+-H "Authorization: Bearer ${MACBRIDGE_TOKEN}"} \
            -d '{"args":{"command":"sleep 1; kill $PPID 2>/dev/null; pkill -x MacBridge"}}' >/dev/null || true
        # Wait for the old instance to go away first, or the check below
        # just sees it still answering and reports a restart that hasn't happened.
        for _ in $(seq 1 10); do
            curl -s --max-time 1 "http://localhost:${AGENT_PORT}/health" >/dev/null 2>&1 || break
            sleep 0.5
        done
        for _ in $(seq 1 30); do
            sleep 1
            if curl -s --max-time 2 "http://localhost:${AGENT_PORT}/health" >/dev/null 2>&1; then
                echo "   Agent session restarted on :${AGENT_PORT} with the new build."
                break
            fi
        done
    else
        echo "   Agent session isn't running; it will use the new build next time it starts."
    fi
fi

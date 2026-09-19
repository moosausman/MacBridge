#!/bin/bash
set -u

APP_NAME="MacBridge"
BUNDLE_ID="com.jarvis.macbridge"

pkill -x "${APP_NAME}" 2>/dev/null || true

echo "Resetting macOS permissions for ${BUNDLE_ID}..."

for service in \
    Calendar \
    Reminders \
    AddressBook \
    AppleEvents \
    Accessibility \
    ScreenCapture
do
    if tccutil reset "${service}" "${BUNDLE_ID}"; then
        echo "✅ Reset ${service}"
    else
        echo "⚠️ Could not reset ${service}; check it manually in System Settings"
    fi
done

echo
echo "Done. Run ./build.sh to launch MacBridge and request permissions again."
echo "Notification permission can be changed under System Settings → Notifications."
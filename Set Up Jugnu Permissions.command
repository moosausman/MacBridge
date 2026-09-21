#!/bin/bash
# Set Up Jugnu Permissions
#
# Double-click this WHILE LOGGED INTO THE JUGNU ACCOUNT. It gives the Jugnu
# account's MacBridge the macOS permissions it needs to control that account.
#
# Why this exists: Calendar, Reminders, Contacts and each app under
# Automation have no "+" button in System Settings. An app only appears there
# after it asks, and MacBridge asked while the Jugnu account was running in
# the background, where nobody could answer -- so those requests were denied
# or never shown. This clears those unanswered requests and asks again while
# you're looking.

BUNDLE_ID="com.jarvis.macbridge"
APP="/Users/Shared/Jugnu/MacBridge.app"
LABEL="ai.jugnu.macbridge.agent"
PORT="${JUGNU_AGENT_PORT:-8766}"
AGENT_USER="${JUGNU_AGENT_USER:-jugnu}"

pause() { echo; read -n 1 -s -r -p "Press any key to close."; echo; }

echo "═══ Jugnu account permissions ═══"
echo
if [ "$(id -un)" != "$AGENT_USER" ]; then
    echo "This is for the Jugnu account, but you're logged in as $(id -un)."
    echo "Switch to the Jugnu account (menu bar user icon › $AGENT_USER), then open"
    echo "this file again from /Users/Shared."
    pause; exit 1
fi
if ! curl -s --max-time 3 "http://127.0.0.1:$PORT/health" >/dev/null; then
    echo "MacBridge isn't running in this account yet. Starting it..."
    launchctl kickstart -k "gui/$(id -u)/$LABEL" 2>/dev/null
    sleep 3
fi

echo "1/3  Clearing MacBridge's earlier unanswered requests..."
for service in Calendar Reminders AddressBook AppleEvents; do
    tccutil reset "$service" "$BUNDLE_ID" >/dev/null 2>&1
done

echo "2/3  Asking for access. Click Allow / OK on each prompt that appears"
echo "     (Calendar, Reminders, Contacts, then one per app under Automation)."
RESULT="$(curl -s --max-time 900 -X POST "http://127.0.0.1:$PORT/permissions/request" \
    -H 'Content-Type: application/json' -d '{"args":{}}')"

MISSING="$(osascript -l JavaScript -e 'function run(argv) {
    try { return (JSON.parse(argv[0]).missing || []).join(" ") } catch (e) { return "?" }
}' "$RESULT")"

echo "3/3  Still missing: ${MISSING:-nothing}"
open_pane() { open "x-apple.systempreferences:com.apple.preference.security?$1"; }
for item in $MISSING; do
    case "$item" in
        accessibility)    open_pane Privacy_Accessibility ;;
        screen_recording) open_pane Privacy_ScreenCapture ;;
        calendar)         open_pane Privacy_Calendars ;;
        reminders)        open_pane Privacy_Reminders ;;
        contacts)         open_pane Privacy_Contacts ;;
    esac
done
if [ -n "$MISSING" ] && [ "$MISSING" != "?" ]; then
    echo
    echo "     In the System Settings window that opened, turn MacBridge on. If it"
    echo "     isn't listed, click + and choose $APP."
    echo "     macOS will ask for an administrator: enter YOUR main account's"
    echo "     name and password (the Jugnu account is a Standard user)."
    open -R "$APP"
fi

echo
echo "Optional, for complete control: System Settings › Privacy & Security ›"
echo "Full Disk Access › + › $APP"
echo
echo "Restarting MacBridge so new permissions take effect..."
launchctl kickstart -k "gui/$(id -u)/$LABEL" 2>/dev/null && echo "Done."
pause

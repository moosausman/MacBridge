#!/bin/bash
# install-launchagent.sh -- put the agent's LaunchAgent where launchd reads it.
#
# This exists because the plist is the one piece of the setup that lives
# outside the repository, in /Library/LaunchAgents, and so drifts out of
# step with the generator in setup-agent-session.sh without anyone noticing.
#
# The failure it fixes: a LaunchAgent in /Library/LaunchAgents loads into
# EVERY GUI session, not just the agent's, and LaunchAgents have no
# per-user key. Without a guard, whichever session logs in first wins the
# agent's port -- so "run this in the other account" quietly runs in your
# own, with your home directory and your permissions, and nothing reports
# an error. That is a worse failure than a crash, because everything
# appears to work.
#
# Run it after setup-agent-session.sh, or any time `lsof -nP -iTCP:8766`
# shows a user other than the agent.

set -euo pipefail

AGENT_USER="${JUGNU_AGENT_USER:-jugnu}"
AGENT_PORT="${JUGNU_AGENT_PORT:-8766}"
SHARED="${JUGNU_SHARED:-/Users/Shared/Jugnu}"
LABEL="ai.jugnu.macbridge.agent"
PLIST="/Library/LaunchAgents/${LABEL}.plist"

AGENT_UID="$(id -u "$AGENT_USER" 2>/dev/null || true)"
if [ -z "$AGENT_UID" ]; then
    echo "No such user '$AGENT_USER'. Run setup-agent-session.sh first." >&2
    exit 1
fi

echo "Installing $LABEL for $AGENT_USER (uid $AGENT_UID) on port $AGENT_PORT"

sudo tee "$PLIST" >/dev/null <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>${LABEL}</string>
    <key>ProgramArguments</key>
    <array>
        <!-- /Library/LaunchAgents loads in EVERY user's GUI session and
             there is no per-user key for an agent, so the program itself
             has to check. Without this, the first session to log in takes
             the agent's port and remote execution silently runs locally. -->
        <string>/bin/sh</string>
        <string>-c</string>
        <string>[ "\$(id -u)" = "${AGENT_UID}" ] || exit 0; exec "${SHARED}/MacBridge.app/Contents/MacOS/MacBridge"</string>
    </array>
    <key>EnvironmentVariables</key>
    <dict>
        <key>MACBRIDGE_PORT</key><string>${AGENT_PORT}</string>
    </dict>
    <key>RunAtLoad</key><true/>
    <!-- Restart it if it dies, but a clean exit means "not my session";
         respawning that forever is the loop this guard exists to stop. -->
    <key>KeepAlive</key>
    <dict><key>SuccessfulExit</key><false/></dict>
    <key>StandardOutPath</key><string>/tmp/jugnu-macbridge-agent.log</string>
    <key>StandardErrorPath</key><string>/tmp/jugnu-macbridge-agent.err</string>
</dict>
</plist>
EOF
sudo chown root:wheel "$PLIST"
sudo chmod 644 "$PLIST"
echo "  wrote $PLIST"

# Any instance started from the old, unguarded plist is holding the port in
# the wrong session. Stop it everywhere, then let launchd start it again
# where the guard allows.
echo "Reloading..."
for uid in $(ps -axo uid= | sort -u); do
    sudo launchctl bootout "gui/${uid}/${LABEL}" 2>/dev/null || true
done
pkill -x MacBridge 2>/dev/null || true
sleep 1
sudo launchctl bootstrap "gui/${AGENT_UID}" "$PLIST" 2>/dev/null || \
    echo "  (could not bootstrap into gui/${AGENT_UID}; it will start when $AGENT_USER next logs in)"

# The shared SQLite files get created by whichever account touches them
# first, at 0644, and then the other account cannot write. Both accounts
# run the same code against the same database, so both need write.
DATA="/Users/Shared/jugnu-trading/data"
if [ -d "$DATA" ]; then
    sudo chmod a+rw "$DATA"/*.db "$DATA"/*.db-wal "$DATA"/*.db-shm 2>/dev/null || true
    echo "  made $DATA writable by both accounts"
fi

echo
echo "Check it took:"
echo "  lsof -nP -iTCP:${AGENT_PORT} -sTCP:LISTEN     # should show $AGENT_USER"
echo "  curl -s -X POST http://127.0.0.1:${AGENT_PORT}/shell/run \\"
echo "       -H 'Content-Type: application/json' \\"
echo "       -d '{\"args\":{\"command\":\"id -un\"}}'   # should print $AGENT_USER"

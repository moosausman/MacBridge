#!/bin/bash
# Install MacBridge into a SECOND macOS login session, so Jugnu can work on
# a desktop that isn't yours.
#
# WHY A SECOND SESSION AT ALL
# ---------------------------
# macOS ties GUI automation to a login session. Apple Events, the
# accessibility tree, the keyboard, the mouse and the screen all belong to
# exactly one session, and a process in a different session cannot reach
# them -- there is no permission that grants it. Running "as another user"
# therefore means a whole second MacBridge living inside that user's login,
# which is what this installs.
#
# Modelled on second-self's setup/provision.sh, which solved this first:
# the key move is `launchctl bootstrap gui/<uid>`, which starts a service
# inside another user's GUI session rather than your own.
#
# WHAT THIS DOES NOT DO
# ---------------------
# It does not create the account -- that needs your password interactively,
# so do it yourself first (System Settings > Users & Groups, or
# second-self's provision.sh). A Standard account is fine and is safer than
# the admin account provision.sh creates by default.
#
# It also cannot grant TCC permissions. Accessibility, Automation and Screen
# Recording are per-user and per-app; the agent account has to grant its own,
# while logged in as itself. The script prints exactly what to do.

set -euo pipefail

AGENT_USER="${JUGNU_AGENT_USER:-secondself}"
AGENT_PORT="${JUGNU_AGENT_PORT:-8766}"
LABEL="ai.jugnu.macbridge.agent"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUNDLE="$SCRIPT_DIR/MacBridge.app"
PLIST="/Library/LaunchAgents/$LABEL.plist"

echo "=== Jugnu agent-session setup ==="
echo "    account: $AGENT_USER"
echo "    port:    $AGENT_PORT"
echo

# ── 1. The account has to exist already ──────────────────────────────────
if ! id "$AGENT_USER" &>/dev/null; then
    cat <<EOF
The account '$AGENT_USER' doesn't exist yet, and creating it needs your
password typed interactively, so this script won't do it behind your back.

Create it either way:

  System Settings > Users & Groups > Add User…
      New user:  Standard        (NOT Administrator -- see below)
      Full name: $AGENT_USER
      Account:   $AGENT_USER

  …or, from the second-self repo:
      ./setup/provision.sh

A note on that script: it grants the account ADMIN rights. That is more
than this needs. An agent account is precisely the one you would not want
able to install software or change system settings, so Standard is the
better default unless something specific requires otherwise.

Then run this script again.
EOF
    exit 1
fi

AGENT_UID="$(id -u "$AGENT_USER")"
echo "[1/4] Account '$AGENT_USER' exists (uid $AGENT_UID)."

# ── 2. MacBridge must be built ───────────────────────────────────────────
if [ ! -d "$BUNDLE" ]; then
    echo "MacBridge.app not found at $BUNDLE -- run ./build.sh first." >&2
    exit 1
fi

# It has to live somewhere the agent account can actually read. A bundle in
# your home directory is not readable by another user.
SHARED="/Users/Shared/Jugnu"
echo "[2/4] Copying MacBridge to $SHARED (readable by both accounts)..."
sudo mkdir -p "$SHARED"
sudo rsync -a --delete "$BUNDLE" "$SHARED/"
sudo chmod -R a+rX "$SHARED"
echo "      Done."

# ── 3. LaunchAgent, bootstrapped into the AGENT's session ────────────────
echo "[3/4] Installing LaunchAgent..."
sudo tee "$PLIST" >/dev/null <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>$LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>$SHARED/MacBridge.app/Contents/MacOS/MacBridge</string>
    </array>
    <key>EnvironmentVariables</key>
    <dict>
        <!-- The whole point: this instance answers on its own port so the
             two sessions never collide. -->
        <key>MACBRIDGE_PORT</key><string>$AGENT_PORT</string>
    </dict>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key><true/>
    <key>StandardOutPath</key><string>/tmp/jugnu-macbridge-agent.log</string>
    <key>StandardErrorPath</key><string>/tmp/jugnu-macbridge-agent.err</string>
</dict>
</plist>
EOF
sudo chown root:wheel "$PLIST"
sudo chmod 644 "$PLIST"
echo "      Installed $PLIST"

# ── 4. Start it, if that session is live ─────────────────────────────────
echo "[4/4] Starting in $AGENT_USER's session..."
sudo launchctl bootout "gui/$AGENT_UID/$LABEL" 2>/dev/null || true

if sudo launchctl bootstrap "gui/$AGENT_UID" "$PLIST" 2>/dev/null; then
    sleep 3
    if curl -s --max-time 3 "http://localhost:$AGENT_PORT/health" >/dev/null 2>&1; then
        echo "      Running: $(curl -s --max-time 3 http://localhost:$AGENT_PORT/health)"
    else
        echo "      Bootstrapped, but not answering yet -- see the permissions note below."
    fi
else
    cat <<EOF
      Could not bootstrap into gui/$AGENT_UID.

      That almost always means '$AGENT_USER' has no live login session.
      A GUI session only exists while the account is logged in -- it does
      not need to be the account you are LOOKING at, but it does need to
      be logged in:

        Click the user icon in the menu bar > $AGENT_USER > log in once.
        Then switch back to your own account. The session stays alive in
        the background, which is exactly what this needs.

      (Fast User Switching is already enabled on this Mac.)
EOF
fi

cat <<EOF

────────────────────────────────────────────────────────────────────────
PERMISSIONS -- this part cannot be scripted
────────────────────────────────────────────────────────────────────────
TCC grants are per-user AND per-app. The grants you gave MacBridge in your
own account do not carry over; '$AGENT_USER' has to grant its own.

While logged in AS $AGENT_USER, open System Settings > Privacy & Security
and add MacBridge to:

    Accessibility        keyboard, mouse, the accessibility tree
    Automation           AppleScript to Safari, Mail, Finder, Terminal, Spotify
    Screen Recording     screenshots

Until then the agent session will answer /health but most tools will fail
with permission errors.

────────────────────────────────────────────────────────────────────────
POINTING JUGNU AT IT
────────────────────────────────────────────────────────────────────────
    JUGNU_DEFAULT_SESSION=agent     work on the agent desktop by default
    JUGNU_DEFAULT_SESSION=primary   your own desktop (the current default)

Either way Jugnu can switch per request -- saying "on my account" moves
that request to your session. Nothing changes until you set this.
EOF

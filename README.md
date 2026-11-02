# MacBridge

A small HTTP server that gives a program permission to use a Mac.

It is the privileged half of [Jugnu](https://github.com/moosausman/Jugnu).
Jugnu itself holds no entitlements and asks for no permissions; it makes
JSON calls to this, and this does the work. Roughly 130 of Jugnu's 201 tools
are HTTP calls to the endpoints below.

Splitting it this way is deliberate. macOS grants Automation, Accessibility
and Screen Recording to a *binary*, so the component that holds those grants
should be small, readable, and separately auditable — about 7,600 lines of
Swift with no dependencies, rather than buried inside an app that also talks
to a language model.

---

## What it exposes

| Area | Endpoints |
|---|---|
| Files | read, write, move, copy, delete, zip, search, Finder reveal |
| Mail | list, read, search, send, mailboxes |
| Calendar & Reminders | list, create, update, delete |
| Contacts | list, search |
| Safari | tabs, open, close, page text, JavaScript |
| System | apps, windows, volume, battery, clipboard, notifications, sleep |
| Input | keyboard typing and key presses, mouse move, click, drag, scroll |
| Screen | capture, display list, and a live JPEG stream with long-polling |
| Shell | `/shell/run`, `/shell/spawn` |
| AppleScript | `/applescript/run`, classified by content before it runs |

Every endpoint takes `POST` with `{"args": {...}}` and answers with
`{"ok": true, ...}` or `{"ok": false, "error": "..."}`.

```bash
curl -s http://localhost:8765/health
curl -s -X POST http://localhost:8765/shell/run \
     -H 'Content-Type: application/json' \
     -d '{"args":{"command":"id -un"}}'
```

---

## Build

```bash
./build.sh
```

Compiles, signs, installs and launches. On first run macOS asks for
Automation, Accessibility, Screen Recording, Calendar, Reminders and
Contacts — grant them to **MacBridge**, not to Jugnu, because MacBridge is
the process making the calls. `contacts_list` needs *full* Contacts access;
`contacts_search` manages with limited.

---

## Running a second instance for an agent account

Jugnu can run heavy or long work in a separate macOS user account it
controls, so that work never touches the session you are typing in. That
account needs its own MacBridge, on its own port.

```bash
./setup-agent-session.sh      # creates the account and the shared copy
./install-launchagent.sh      # installs the LaunchAgent (needs sudo)
```

The second instance answers on **:8766**; yours stays on **:8765**.

**The detail worth knowing before you touch any of this.** A LaunchAgent in
`/Library/LaunchAgents` loads into *every* GUI session, and LaunchAgents have
no per-user key. Without a guard, whichever session logs in first wins the
agent's port — and then "run this in the other account" quietly runs in your
own, with your home directory and your permissions, reporting success. That
is a worse failure than a crash, because everything appears to work.

`install-launchagent.sh` writes a plist whose program checks `id -u` before
exec'ing anything, and whose `KeepAlive` only restarts on a non-zero exit, so
"not my session" stops instead of looping. Check it took:

```bash
curl -s -X POST http://localhost:8766/shell/run \
     -H 'Content-Type: application/json' \
     -d '{"args":{"command":"id -un"}}'      # must print the agent's name
```

`lsof` is not a good check here: without `sudo` it cannot see sockets owned
by another user's processes, so a working setup looks dead.

---

## Security

**It is unauthenticated by default.** It binds to loopback only, validates
`Host`, and rejects anything carrying `Origin` or `Sec-Fetch-Site`, so a web
page cannot reach it. What it does *not* do by default is distinguish between
local processes — the documented trust model is "anything running as you."
Since it exposes `/shell/run` and `/applescript/run`, that is a real
statement about what any local process can do.

Turn on bearer auth by setting the same token for both halves:

```bash
launchctl setenv MACBRIDGE_TOKEN "$(openssl rand -hex 32)"
```

`launchctl setenv` puts it in the GUI session environment, so both MacBridge
and anything Jugnu launches inherit it. Restart both;
`curl localhost:8765/health` will then report `"authRequired": true`.

**Listening sockets are close-on-exec.** They were not always, and the
consequence was instructive: a `caffeinate` started through `/shell/run`
inherited the listening socket, outlived the server, and held port 8765 for
fifteen hours while every relaunch crash-looped against it. A bind failure
now names the process holding the port and exits, instead of trapping.

**AppleScript is classified before it runs.** Read-only scripts execute;
anything that sends, deletes or touches security settings waits for the
user's approval.

---

## Layout

```
Sources/MacBridge/
  main.swift            startup, permissions, launch
  Server.swift          the HTTP server: sockets, parsing, auth, dispatch
  Router.swift          path → handler
  Files · Mail · Calendar · Contacts · Safari · System · Shell · Keyboard
  AppleScript.swift     + AppleScriptRunner.swift, with content classification
  Modules/
    ScreenStream.swift  one persistent SCStream, long-polled frames
    Mouse.swift         pointer control, with a corner-abort gesture
```

No third-party dependencies. Swift Package Manager, `./build.sh`, done.

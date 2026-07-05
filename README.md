<div align="center">

# pi-app

**You already have Pi. Now give it a proper macOS home.**

*A minimal native macOS app for running [Pi](https://github.com/earendil-works/pi) coding-agent sessions — locally on your Mac, or remotely through a [pi-appd](https://github.com/ent-ini/apple-pi) daemon.*

</div>

<p align="center">
  <img src="docs/assets/apple-pi-github-readme-banner-1280x640.png" alt="apple pi" width="100%">
</p>

<br>

<div align="center">

**Projects on the left. Sessions in the middle. The Pi conversation on the right.**

No fake IDE. No Electron wrapper. No unreadable terminal UI pretending to be a chat.

**Just Pi, organised.**

</div>

<p align="center">
  <img src="docs/assets/apple-pi-preview.png" alt="apple pi desktop preview" width="100%">
</p>

---

## What it is

Pi is powerful. The terminal chaos around it is not.

**pi-app** is the native macOS room you put Pi in. It keeps what is already great, the terminal, and gives it structure: a session browser, a project list, a workspace that stays oriented so you do not have to.

## What it does

Browse your Pi `.jsonl` sessions, resume them with one click, fork a session into a parallel path, open fresh sessions per project, or start ephemeral ones when you want a clean run.

The detail pane renders each open Pi conversation as a chat — message bubbles for user and assistant turns, compact disclosure rows for tool calls and tool results, and a composer that supports text, file attachments, and voice notes. You can keep multiple conversations open at once and switch between them from the sidebar.

Local sessions can send a macOS notification when Pi is ready for your input again. The app bundles the small helper this needs and loads it only for sessions it starts. Your existing Pi agent settings are left exactly as they are.

Run your local Pi with the configured `pi` executable, or talk to a remote machine through the lightweight `pi-appd` HTTP daemon. pi-app ships only the macOS client; `pi-appd` is a separate project that lives next to Pi on the remote host and exposes the same catalog, session, and turn APIs over a bearer-token-authenticated HTTP surface. No new password store on your Mac.

Remote API mode can browse, start, and resume sessions on the remote host. It intentionally does not delete remote session files from the app, and the Pi context panel stays limited because project trust and local file actions belong to the remote machine.

## Make it yours

Tune the opacity of the window, sidebars, and chat surface. Pick an accent color. Keep the titlebar transparent, or do not.

A clean translucent panel floating over your desktop is a legitimate aesthetic. The app will not fight you on it.

## Session discovery

**pi-app** looks where Pi already keeps sessions:

```sh
~/.pi/agent/sessions
```

If you changed Pi's session directory, the app follows that. Environment overrides, global settings, trusted project settings: all supported.

Pi owns the sessions. pi-app makes them easier to find, read, start, and resume.

## What it is not

pi-app is not a replacement for Pi, an IDE, an Electron dashboard, a cloud service, an account system, a model API key manager, or a generic terminal emulator host. (It is, by design, a chat-style session UI for Pi.)

## Install

Download the release zip, unzip it, move the app to `/Applications`:

```sh
shasum -a 256 "pi-app-<version>-<build>.zip"
ditto -x -k "pi-app-<version>-<build>.zip" /tmp/pi-app
rm -rf "/Applications/pi-app.app"
ditto "/tmp/pi-app/pi-app.app" "/Applications/pi-app.app"
```

macOS may warn that the app cannot be verified. That is expected: this is an open source project and I am not paying Apple $99/year to make that dialog disappear. Launch once, then go to **System Settings -> Privacy & Security -> Security** and click **Open Anyway**.

The trust model: inspect the source, verify the release hash, build it yourself if you want the strongest guarantee.

Full details are in [Install](docs/INSTALL.md) and [Verify An Install](docs/VERIFY_INSTALL.md).

## Build

```sh
swift test
swift run ApplePi          # development target
script/install_app.sh      # builds and installs /Applications/pi-app.app
```

`script/package_release.sh` creates the `.app`, ad-hoc signs it, verifies it, and writes a versioned zip into `dist/`. `script/install_app.sh` is the convenience path for a permanent local install. Release maintainers should follow [Release Checklist](RELEASE_CHECKLIST.md) and [Release Process](docs/RELEASE_PROCESS.md).

## Trust, but verify

No analytics. No account. No background auto-updater.

On launch, the app makes one anonymous GET to `api.github.com/repos/ent-ini/apple-pi/releases/latest` to check for newer releases, throttled to once every 24 hours, and shows a small in-app link if one exists. It never downloads or installs anything on its own.

No bundled browser runtime. No password store. No model API key manager. No hidden Pi installs.

```sh
codesign --verify --deep --strict --verbose=2 "pi-app.app"
codesign --display --verbose=4 "pi-app.app"
plutil -p "pi-app.app/Contents/Info.plist"
```

[Security](SECURITY.md), [Privacy](PRIVACY.md), and [Third-Party Notices](THIRD_PARTY_NOTICES.md) if you want to know exactly what you are installing.

Live macOS debugging is documented in [Diagnostics Gateway](docs/DIAGNOSTICS.md). It is opt-in, bearer-token-protected, and intended for Tailscale/private-network use.

## Requirements

- macOS 14 or newer
- Pi installed locally, **or** a remote host running [pi-appd](https://github.com/ent-ini/apple-pi) and Pi
- Swift 6.1 if building from source

Remote sessions only require whatever `pi-appd` itself requires on the remote host.

## License

MIT. See [LICENSE.md](LICENSE.md).

SwiftTerm is MIT licensed and vendored at [Vendor/SwiftTerm](Vendor/SwiftTerm). It is reserved for a future in-app terminal surface; the current release renders Pi conversations as chat, not as a SwiftTerm-backed terminal view.

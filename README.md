# Claude Desktop in a container

Run the Claude Desktop app in a rootless Podman container while its window shows up on your host's Wayland desktop. On SELinux systems (Fedora, RHEL), SELinux stays **enforcing** the whole time.

The app sees only two things from your machine:

- its own data folder, `claude-home/`
- the folder that contains this project, mounted at `/workspace/projects`

Everything else in your home folder stays out of reach.

```
┌──────────────── host (Fedora, SELinux enforcing) ────────────────┐
│                                                                  │
│  KWin / GNOME compositor  ◄── Wayland socket ──┐                 │
│  (unconfined_t)        /run/user/1000/wayland-1│                 │
│                                                │                 │
│  ┌──── container (claude_desktop.process) ─────┴─────────────┐   │
│  │  claude-desktop  (Electron, --ozone-platform=wayland)     │   │
│  │                                                           │   │
│  │  /home/claude         ◄── ./claude-home                   │   │
│  │  /workspace/projects  ◄── ../                             │   │
│  └───────────────────────────────────────────────────────────┘   │
└──────────────────────────────────────────────────────────────────┘
```

---

## Requirements

- A Linux desktop running a **Wayland** session
- `podman` and `podman compose`

Only if SELinux is enforcing (Fedora, RHEL, CentOS; check with `getenforce`):

- `udica`, for its policy templates: `sudo dnf install udica`
- `sudo`, once, to load the SELinux module

### Without SELinux

On a distro without SELinux (Ubuntu, Debian, Arch, …), skip `selinux/install.sh` entirely. `compose.yaml` works unchanged: Podman ignores the `label=type:…` option and the `:Z` volume suffixes when SELinux is off.

On Ubuntu and Debian, Podman applies its default AppArmor profile instead. That profile isn't known to block the Wayland socket, but this setup has only been tested on Fedora.

You do lose a layer of protection. Without SELinux, the container is held back only by namespaces, dropped capabilities and the volumes you mount, with no second barrier if the app escaped the container.

## Files

| Path | Purpose |
|---|---|
| `Dockerfile` | Debian 12 image with Claude Desktop from Anthropic's official APT repository |
| `compose.yaml` | Container definition: Wayland socket, volumes, SELinux label, dropped capabilities |
| `.env` | Your user ID/group ID and which Wayland socket to forward |
| `selinux/claude_desktop.cil` | The SELinux policy for the container |
| `selinux/install.sh` | Loads (or reloads) that policy |
| `start.sh` | Starts the container, or brings the window back if it's already running. `--stop` stops it. |
| `install-desktop-entry.sh` | Adds a "Claude (containerized)" launcher to your application menu |
| `migrate-code-sessions.sh` | Copies your host's Code tab sessions into the container, and re-syncs them later |
| `claude-home/` | The container's home folder: sign-in, settings, sessions. Its `.gitignore` keeps the folder in git but ignores everything inside, so your data is never committed. |

---

## Setup

### 1. Configure `.env`

```ini
PUID=1000
PGID=1000
WAYLAND_SOCKET=/run/user/1000/wayland-1
```

| Variable | What it is | How to find it |
|---|---|---|
| `PUID` | Your user ID. The container user gets the same ID, so files it creates in `claude-home/` and your projects belong to you. | `id -u` |
| `PGID` | Your group ID, for the same reason | `id -g` |
| `WAYLAND_SOCKET` | Full path of your desktop's Wayland socket on the host | `echo $XDG_RUNTIME_DIR/$WAYLAND_DISPLAY` |

Or generate the file from inside your Wayland session (not over SSH or from a TTY, where `WAYLAND_DISPLAY` isn't set):

```bash
printf 'PUID=%s\nPGID=%s\nWAYLAND_SOCKET=%s\n' "$(id -u)" "$(id -g)" "$XDG_RUNTIME_DIR/$WAYLAND_DISPLAY" > .env
```

Things to know:

- **Rebuild after changing `PUID` or `PGID`.** They're build arguments: the container user is created with them when the image is built. Editing `.env` alone isn't enough:

  ```bash
  podman compose up --build
  ```

  `WAYLAND_SOCKET` is only used at start, so changing it needs just a restart.
- **The socket name can differ from the host.** Whatever your host socket is called (KDE often uses `wayland-1`), `compose.yaml` mounts it as `wayland-0` inside the container and sets `WAYLAND_DISPLAY=wayland-0`. Don't change the `wayland-0` in `compose.yaml`.
- **The socket name can change between logins**, for example after a compositor crash or when a second session is running. If the window stops appearing, check the socket path again.

### 2. Load the SELinux policy (SELinux systems only)

```bash
./selinux/install.sh
```

Run it again whenever you edit `selinux/claude_desktop.cil`.

### 3. Build and start

```bash
podman compose up --build
```

The Claude window opens on your desktop. Stop it with `Ctrl+C`, or with:

```bash
podman compose down
```

### 4. Add a launcher to your desktop (optional)

```bash
./install-desktop-entry.sh
```

This adds **Claude (containerized)** to your application menu, with the official Claude icon taken from the image. To put it in your favorites:

- **KDE Plasma:** right-click it in the menu, then choose **Pin to Task Manager** or **Add to Favorites**.
- **GNOME:** right-click it, then choose **Pin to Dash**.

What a click does (it runs `start.sh`):

- **Container stopped:** starts it in the background (`podman compose up -d`).
- **Container already running:** asks the app to show its window again, for example after you closed it to the tray. The app allows only one instance, so this never opens a second copy.
- **Right-click → Stop container:** runs `podman compose down`.

Output goes to `~/.local/state/claude-desktop-container.log`. If something fails, you get a desktop notification pointing to that log.

The launcher stores this folder's absolute path, so run the script again if you move the folder. To remove the launcher:

```bash
./install-desktop-entry.sh --uninstall
```

**If you also have the regular Claude app installed on the host:** both report the same window ID (`com.anthropic.Claude`). Your taskbar may therefore show the container's window under the host app's icon. It still works; it's just labeled as the host app.

---

## How the SELinux part works

By default, a Podman container runs as `container_t`, and that type is not allowed to talk to your desktop's Wayland compositor. The two usual workarounds are both bad:

- `--security-opt label=disable` turns off SELinux protection for the container.
- `setenforce 0` turns SELinux off for the whole system.

Instead, `compose.yaml` runs the container under a custom type:

```yaml
security_opt:
  - label=type:claude_desktop.process
```

That type is defined in `selinux/claude_desktop.cil`. It starts from udica's `container` template, so it keeps everything a normal container has:

- MCS category separation, so it can't touch other containers' files
- no access to host files beyond its volumes

On top of that it adds only what the app needs:

| Rule | Why |
|---|---|
| `user_tmp_t` sock_file write | Open the Wayland socket in `/run/user/$UID` |
| `unconfined_t` unix_stream_socket connectto | Connect to the compositor process |
| `tmpfs_t` / `user_tmp_t` file open/read/write/map | Shared-memory buffers (window pixels, keymaps, cursors) and Chromium's memfd regions. Needed because the `domain_can_mmap_files` boolean is off. |
| `net_container` | The same network access a normal Podman container has (HTTPS, QUIC over UDP) |
| `dri_device_t` | GPU acceleration. Only used if you pass `/dev/dri` into the container. |
| `container_file_t` | Read/write the mounted volumes, which `:Z`/`:z` relabel |

For tighter network access (HTTP/HTTPS only), see the comment at the top of the `.cil` file. Be aware this breaks `git` over SSH and MCP servers on other ports.

### When something is denied

```bash
sudo ausearch -m avc -ts recent | grep claude_desktop
```

Each line names the permission (`{ open }`), the source type (`claude_desktop.process`) and the target type (`tcontext=…:tmpfs_t`). Add the narrowest matching `allow` rule to `selinux/claude_desktop.cil`, then rerun `./selinux/install.sh`.

### Launch flags

The image starts the app with these flags (the `CMD` in the `Dockerfile`):

| Flag | Why |
|---|---|
| `--ozone-platform=wayland` | Draw through Wayland directly, without needing XWayland |
| `--no-sandbox` | Chromium's own sandbox needs user namespaces and capabilities that a rootless, `cap_drop: ALL` container doesn't give it. The container and its SELinux domain take its place. |
| `--password-store=gnome-libsecret` | Keep your sign-in in the container's keyring. See [The keyring catch](#the-keyring-catch). |

`start.sh` repeats the same flags when it brings back the window of a running container. If you change them in the `Dockerfile`, change them there too.

---

## The keyring catch

Keeping you signed in across restarts hits two separate problems. Both come from the same thing: the container has no desktop session. The first is handled for you; the second needs one manual step.

### 1. Without a flag, the app doesn't use the keyring at all (handled)

**Symptom without the fix:** you have to sign in again every time the container starts. `claude-home/.config/Claude/logs/main.log` shows:

```
[safeStorage] isEncryptionAvailable=false on linux at startup (backend=basic_text) — session will not persist
[oauth-v2] safeStorage not available, tokens will not persist
```

**Why:** Electron chooses where to store secrets based on the `XDG_CURRENT_DESKTOP` variable (GNOME uses the keyring, KDE uses KWallet). That variable isn't set inside the container, so Electron falls back to `basic_text`: plaintext with a fixed, publicly known key. Claude refuses to store sign-ins that way, so it keeps you signed in only until the app closes.

**Fix:** the `Dockerfile` and `start.sh` launch the app with `--password-store=gnome-libsecret`, which tells Electron to use the container's GNOME keyring. Nothing to do, unless your image was built before this flag was added. Then rebuild it:

```bash
podman compose up -d --build
```

### 2. The keyring asks for its password on every start (one manual step)

**Symptom:** every time the container starts, a dialog asks for the password of your **keyring**. The Claude app on your host never asks.

**Why:**

- **On the host:** the app stores its sign-in token in your desktop's secret store (KWallet or GNOME Keyring). Your login password unlocks that store automatically when you log in.
- **In the container:** the Debian package pulls in `gnome-keyring`. The container's private D-Bus session starts it on demand. Nothing unlocks it, because there's no desktop login inside the container. So it asks you every time.

If you cancel the dialog, the keyring stays locked and the app can't read or save your sign-in.

**Fix:** give the container's keyring an **empty password**. gnome-keyring then unlocks it without asking.

1. Stop the container:

   ```bash
   podman compose down
   ```

2. Delete the existing keyring. You'll sign in to Claude once more afterwards.

   ```bash
   rm claude-home/.local/share/keyrings/*.keyring claude-home/.local/share/keyrings/default
   ```

3. Start the container, with the launcher or with:

   ```bash
   podman compose up -d
   ```

   Sign in to Claude. When it asks you to choose a password for the new keyring, leave both fields **empty** and confirm storing it unencrypted.

**What you give up:** the token is then stored unencrypted in `claude-home/.local/share/keyrings/`. It's protected by:

- the folder's `700` permissions (readable only by you)
- the container's SELinux label
- your disk encryption, if you have it

That's about the same protection the token has on your host: any program running as your user can already ask your unlocked KWallet for it.

**Alternatives that are worse:**

- **Forwarding your host's D-Bus session so the app uses your real KWallet.** This would also let the container read every other secret you've stored, which undoes the isolation.
- **Electron's `--password-store=basic` flag.** This is the `basic_text` fallback from problem 1. It only scrambles the token with a fixed, publicly known key, and Claude refuses to keep you signed in with it.

---

## Updating Claude Desktop

The app may say an update is available. **Don't use the in-app update button.** The package is installed by apt as root, and the app runs as an unprivileged user, so the update either fails or is lost the next time the container is recreated.

`stable` in the Dockerfile is a release channel, not a fixed version. The image contains whatever was newest when it was built. A plain rebuild reuses Podman's cached `apt-get` step, so rebuild without the cache:

```bash
podman compose build --no-cache
```

```bash
podman compose down && podman compose up -d
```

You stay signed in across the rebuild: your sign-in lives in `claude-home/`, not in the image.

To check which version the image contains:

```bash
podman run --rm --entrypoint dpkg-query claude-desktop-container-claude -W claude-desktop
```

---

## Your data

The container has its own data, completely separate from the host app's.

| | Host | Container (on disk) |
|---|---|---|
| Desktop app data, settings, MCP config | `~/.config/Claude/` | `claude-home/.config/Claude/` |
| Code tab session list | `~/.config/Claude/claude-code-sessions/` | `claude-home/.config/Claude/claude-code-sessions/` |
| Claude Code transcripts, settings, skills | `~/.claude/` | `claude-home/.claude/` |
| App logs | `~/.config/Claude/logs/` | `claude-home/.config/Claude/logs/` |

- **Chat tab conversations** live on Anthropic's servers. They appear in both apps as soon as you sign in with the same account.
- **Code tab sessions** are stored locally and are **not** synced. A fresh container starts with an empty Code tab. Use the migration script below to bring them over.

---

## Migrating Code tab sessions from the host

`migrate-code-sessions.sh` copies the Code tab sessions from your host app into the container, and brings existing copies up to date when you run it again.

```bash
podman compose down
```

```bash
./migrate-code-sessions.sh --dry-run
```

```bash
./migrate-code-sessions.sh
```

```bash
podman compose up -d
```

Or, in one line:

```bash
podman compose down && ./migrate-code-sessions.sh && podman compose up -d
```

**What it does:**

- **Copies the session list** (`claude-code-sessions/…/local_*.json`) and the full conversation transcripts (`~/.claude/projects/…`) into `claude-home/`.
- **Rewrites paths to the container's view,** so sessions open in the right folder:
  - `<parent of this project>` becomes `/workspace/projects`. For example, `~/projects/my-app` becomes `/workspace/projects/my-app`.
  - `~/.config/Claude` and `~/.claude` become `/home/claude/…`.
- **Is safe to run again** whenever you want to re-sync:
  - new host sessions are copied
  - sessions that continued on the host are updated
  - if a copy was also changed inside the container since the last sync (you continued that session there), the container's copy is kept and the script lists it
  - it never deletes anything. Sessions you created in the container are untouched.

  The time of the last sync is stored in `claude-home/.code-sessions-last-sync`.
- **Doesn't change** your host files.
- **Refuses to run** while the container is up, because the app might ignore or overwrite files changed under it.

**What it skips:**

- Sessions and transcripts whose folder isn't under the mounted directory (for example `~/other-projects/...`, when this project lives in `~/projects/`). The container can't open those folders anyway.
- Extra folders a session used outside the mount, such as something in `~/Downloads`. The session still opens; that folder just won't exist in the container.
- Undo snapshots (`~/.claude/file-history`). The conversations are complete, but you can't roll back file edits made in old sessions.

---

## Security notes

- **Volumes:** `claude-home` uses `:Z`, a label private to this container. `../` also uses `:Z`, which relabels your **whole projects folder** for this container only. If other containers mount anything from that folder, switch it to `:z` (lowercase, shared label).
- **Capabilities:** the container runs with `cap_drop: ALL` and `userns_mode: keep-id`. Inside it you are your own UID, never root.
- **Socket mount:** the Wayland socket is mounted read-only. Clients can still connect, but can't replace or remove the socket.

## Troubleshooting

| Problem | Check |
|---|---|
| The window never appears | `WAYLAND_SOCKET` in `.env` points at the right socket; `sudo ausearch -m avc -ts recent \| grep claude_desktop` |
| `Failed to connect to Wayland display` | The socket path is wrong, or the policy isn't loaded: `sudo semodule -l \| grep claude_desktop` |
| Can't sign in or reach claude.ai | Look for `name_connect` denials. Make sure `net_container` is in the policy and was installed. |
| Asks for the keyring password on every start | See [The keyring catch](#the-keyring-catch) |
| Signed out on every restart | Look for `backend=basic_text` in `claude-home/.config/Claude/logs/main.log`: the image lacks `--password-store=gnome-libsecret`, so rebuild it. See [The keyring catch](#the-keyring-catch). |
| "Update available" | Rebuild with `--no-cache` (see [Updating](#updating-claude-desktop)) |
| Clicking the launcher does nothing | Check `~/.local/state/claude-desktop-container.log`. On Wayland, the desktop may only highlight the window in the taskbar instead of bringing it to the front. |
| The launcher points to the wrong folder | You moved the project. Run `./install-desktop-entry.sh` again. |
| The window appears under the host Claude app's icon | Expected when the regular Claude app is also installed: both use the same window ID. |

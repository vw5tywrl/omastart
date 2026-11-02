# omastart

<p align="center">
  <img src="assets/omarchy-startup.svg" width="96" height="96" alt="omastart icon" />
</p>

<p align="center">
  <b>Dead-simple startup package and service manager for Omarchy & Arch Linux.</b><br>
  Organize, inspect, and manage your entire startup stack in one unified, blazing fast UI.
</p>

---

## Highlights

- **Designed for Omarchy & Hyprland**: Integrates natively with Omarchy's design language, Hyprland autostarts, and Quickshell.
- **Fast Startup Scan (< 0.05s)**: Pure-Python parser reads pacman's local database directly without shelling out, delivering instantaneous launch times.
- **Boot Time Breakdown**: Real-time measurement of total boot, userspace, and graphical target times using `systemd-analyze`.
- **Three Unified Views**:
  - **Packages**: See high-level packages (e.g. `fcitx5`, `bluez-tools`, `tailscale`) aggregating their background services, sockets, and timers into one clean card.
  - **Layers**: Grouped by execution layer (`System Services`, `User Services`, `Hyprland Autostart`, `Post-boot Hooks`).
  - **Disabled**: Dedicated view for inactive/disabled items to keep your system lean.
- **Single-Click Actions**:
  - Toggle enabled/disabled with instant persistence.
  - Inspect journal logs (`journalctl`) in real time.
  - Run units immediately on demand.
  - Reveal configuration files in your file manager.
- **+ ADD Modal**: Add autostart items seamlessly from installed packages, Hyprland commands, or custom post-boot hooks.
- **CLI Mode**: Run headlessly in scripts or the terminal (`omastart --list`, `omastart --json`).

---

## Requirements

- **OS**: Omarchy or Arch Linux
- **Compositor**: Hyprland
- **Dependencies**: `python`, `quickshell`, `pacman-contrib`, `systemd`

---

## Installation

### Option 1: Via AUR (Recommended)

```bash
yay -S omastart
# or with paru:
paru -S omastart
```

### Option 2: Quick Install (Git)

```bash
git clone https://github.com/loathe/omastart.git
cd omastart
./install.sh
```

To uninstall:
```bash
./uninstall.sh
```

---

## Usage

### GUI

Launch from your application launcher (`SUPER + SPACE` or `SUPER + D`) by searching for **Omastart**, or simply run:

```bash
omastart
```

#### Keybindings & Navigation:
- **Type anything**: Instantly searches packages, units, and descriptions.
- **`↑` / `↓`**: Navigate items.
- **`Space`**: Toggle enabled / disabled.
- **`Enter`**: Open inspector drawer for selected item.
- **`Escape`**: Close inspector or modals.

### CLI Mode

You can also use `omastart` directly in your terminal:

```bash
# List all active startup packages and boot times
omastart --list

# Include disabled units
omastart --list --all

# Export machine-readable startup state
omastart --json
```

---

## Architecture

`omastart` unifies several disjointed startup systems:
- **Pacman DB** (`/var/lib/pacman/local`): Maps raw systemd unit filenames back to official package metadata.
- **Systemd User & System Units**: Reads enablement state and queries `systemd-analyze blame`.
- **Hyprland** (`~/.config/hypr/autostart.conf`): Inspects and modifies `exec-once` entries.
- **Omarchy Hooks** (`~/.config/omarchy/hooks/post-boot.sh`): Manages custom desktop post-boot scripts.

---

## License

MIT © [andrea marano](LICENSE)

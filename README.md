# omastart

Startup manager for Omarchy and Arch Linux (Hyprland).

Aggregates systemd units, Hyprland autostart commands, and Omarchy post-boot hooks into a single interface.

## Requirements

- Arch Linux or Omarchy
- Hyprland
- Dependencies: `python`, `quickshell`, `pacman-contrib`, `systemd`

## Install

### From Git

```bash
git clone https://github.com/vw5tywrl/omastart.git
cd omastart
./install.sh
```

Or build as a native package:
```bash
makepkg -si
```

To uninstall:
```bash
./uninstall.sh
```

## Usage

### GUI

Run `omastart` from terminal or your application launcher.

- **Type to search**: filters by name, description, or package.
- **Up / Down**: navigate items.
- **Space**: toggle enabled / disabled.
- **Enter**: open logs and details drawer.
- **Escape**: close drawer or modal.

### CLI

```bash
# List active startup packages
omastart --list

# Include disabled units
omastart --list --all

# Output as JSON
omastart --json
```

## License

[MIT](LICENSE)

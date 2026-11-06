from __future__ import annotations

import configparser
from datetime import datetime
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import signal
import subprocess

from .collector import _extract_first_executable, detect_hyprland_user_target
from .models import SourceKind

HOME = Path.home()

PROTECTED_PROCESS_NAMES = {
    "Hyprland",
    "hyprland",
    "quickshell",
    "systemd",
    "dbus-daemon",
    "dbus-broker",
    "pipewire",
    "wireplumber",
    "sddm",
    "Xwayland",
    "bash",
    "zsh",
    "fish",
    "sh",
}


def _run_cmd(args: list[str], timeout: float = 15.0) -> tuple[int, str, str]:
    env = os.environ.copy()
    env["LC_ALL"] = "C"
    try:
        proc = subprocess.run(
            args,
            capture_output=True,
            text=True,
            timeout=timeout,
            env=env,
        )
        return proc.returncode, proc.stdout, proc.stderr
    except subprocess.TimeoutExpired:
        return 1, "", "Operation timed out."
    except Exception as exc:
        return 1, "", str(exc)


def _spawn_detached(args: list[str]) -> bool:
    """Spawn a detached GUI/session process, using uwsm-app only when available."""
    cmd = (["uwsm-app", "--"] + args) if shutil.which("uwsm-app") else list(args)
    try:
        subprocess.Popen(
            cmd,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            start_new_session=True,
            close_fds=True,
        )
        return True
    except Exception:
        return False


def _spawn_bg_cmd(args: list[str]) -> None:
    """Run a background maintenance command without blocking the UI action."""
    try:
        subprocess.Popen(
            args,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            start_new_session=True,
            close_fds=True,
        )
    except Exception:
        pass


def _stop_user_process_safely(pid: int, command: str) -> bool:
    """Safely send SIGTERM to a user-owned process matching command's executable."""
    if pid <= 1 or pid == os.getpid():
        return False
    exe_base = os.path.basename(_extract_first_executable(command))
    if not exe_base or exe_base in PROTECTED_PROCESS_NAMES:
        return False
    proc_dir = Path(f"/proc/{pid}")
    try:
        if not proc_dir.is_dir():
            return False
        if proc_dir.stat().st_uid != os.getuid():
            return False
        comm = (proc_dir / "comm").read_text(encoding="utf-8", errors="ignore").strip()
        cmdline = (
            (proc_dir / "cmdline")
            .read_bytes()
            .replace(b"\x00", b" ")
            .decode("utf-8", errors="ignore")
        )
        if comm != exe_base and exe_base not in cmdline:
            return False
        os.kill(pid, signal.SIGTERM)
        return True
    except OSError:
        return False


def _validate_hyprland_or_rollback(target_path: Path, backup_path: Path) -> tuple[bool, str]:
    if not shutil.which("hyprctl"):
        return True, ""
    _run_cmd(["hyprctl", "reload"], timeout=4.0)
    rc, out, _ = _run_cmd(["hyprctl", "configerrors"], timeout=4.0)
    err_lines = [ln.strip() for ln in out.splitlines() if ln.strip()]
    if rc == 0 and err_lines:
        if backup_path.is_file():
            shutil.copy2(backup_path, target_path)
            _run_cmd(["hyprctl", "reload"], timeout=4.0)
        return False, "Hyprland config error (restored backup): " + "; ".join(err_lines)
    return True, ""


def _lua_quote(value: str) -> str:
    escaped = value.replace("\\", "\\\\").replace('"', '\\"')
    return f'"{escaped}"'


def _write_autostart_desktop_entry(
    usr_path: Path, name: str, comment: str, command: str, icon: str = ""
) -> None:
    usr_path.parent.mkdir(parents=True, exist_ok=True)
    lines = [
        "[Desktop Entry]",
        "Type=Application",
        f"Name={name}",
    ]
    if comment and comment != "Installed desktop application":
        lines.append(f"Comment={comment}")
    lines.append(f"Exec={command}")
    if icon:
        lines.append(f"Icon={icon}")
    lines.append("Terminal=false")
    lines.append("X-Omastart-Managed=true")
    usr_path.write_text("\n".join(lines) + "\n", encoding="utf-8")


def set_item_enabled_raw(payload: dict, enable: bool) -> tuple[bool, str]:
    source = SourceKind(payload["source"])
    config_path = payload.get("configPath", "")
    name = payload.get("name", "")
    command = payload.get("command", "")
    unit_name = payload.get("unitName", "")
    pid = int(payload.get("pid") or 0)
    line_number = int(payload.get("lineNumber") or 0)
    is_masked = bool(payload.get("isMasked"))
    triggered_by = str(payload.get("triggeredBy") or "").strip()
    extra_meta = payload.get("extraMeta") or {}

    if payload.get("readOnly") or config_path.startswith("/usr/share/omarchy"):
        return False, "Core Omarchy startup entries are read-only."

    if source == SourceKind.HYPRLAND_USER:
        target_file = Path(config_path) if config_path else (HOME / ".config" / "hypr" / "autostart.lua")
        if not str(target_file).startswith(str(HOME) + "/") or not target_file.is_file():
            return False, f"File not found: {target_file}"
        backup = target_file.with_name(target_file.name + ".bak")
        shutil.copy2(target_file, backup)

        lines = target_file.read_text(encoding="utf-8").splitlines()
        idx = line_number - 1
        if idx < 0 or idx >= len(lines):
            return False, "Line changed on disk — reload first."

        hypr_fmt = extra_meta.get("hypr_format") or ("lua" if target_file.suffix == ".lua" else "conf")
        current = lines[idx].strip()
        if hypr_fmt == "lua":
            clean = re.sub(r"^--\s*(?:\[disabled\]\s*)?", "", current)
            updated = clean if enable else f"-- [disabled] {clean}"
        else:
            clean = re.sub(r"^#\s*(?:\[disabled\]\s*)?", "", current)
            updated = clean if enable else f"# [disabled] {clean}"

        lines[idx] = updated
        target_file.write_text("\n".join(lines) + "\n", encoding="utf-8")
        ok, err = _validate_hyprland_or_rollback(target_file, backup)
        if not ok:
            return False, err

        if enable and pid == 0 and command:
            _spawn_detached(["bash", "-lc", command])
            return True, f"{name}: enabled & started"
        if not enable and pid > 0:
            stopped = _stop_user_process_safely(pid, command)
            if stopped:
                return True, f"{name}: disabled & stopped"
        return True, f"{name}: {'enabled' if enable else 'disabled'}"

    if source == SourceKind.HOOK_POST_BOOT:
        p = Path(config_path)
        if not p.is_file():
            return False, f"Hook script not found: {p}"
        is_stock_sample = extra_meta.get("is_stock_sample") == "1"
        if enable:
            if p.name.endswith(".disabled.sample"):
                target = p.with_name(p.name[: -len(".disabled.sample")])
                p.rename(target)
                target.chmod(target.stat().st_mode | 0o111)
            elif p.name.endswith(".sample") and is_stock_sample:
                target = p.with_name(p.name[: -len(".sample")])
                shutil.copy2(p, target)
                target.chmod(target.stat().st_mode | 0o111)
            return True, f"{name}: hook enabled"
        else:
            if not p.name.endswith(".sample"):
                target = p.with_name(p.name + ".disabled.sample")
                p.rename(target)
            return True, f"{name}: hook disabled"

    if source == SourceKind.DESKTOP_APP:
        desktop_id = extra_meta.get("desktop_id") or unit_name
        if not desktop_id:
            return False, "Missing desktop entry ID."
        if not desktop_id.endswith(".desktop"):
            desktop_id += ".desktop"
        usr_path = HOME / ".config" / "autostart" / desktop_id
        if enable:
            if not command:
                return False, "Application has no launch command."
            desc = str(payload.get("description") or "").strip()
            icon = str(extra_meta.get("icon") or "").strip()
            _write_autostart_desktop_entry(usr_path, name or desktop_id, desc, command, icon)
            _spawn_bg_cmd(["systemctl", "--user", "daemon-reload"])
            return True, f"{name}: enabled at login"
        else:
            usr_path.unlink(missing_ok=True)
            _spawn_bg_cmd(["systemctl", "--user", "daemon-reload"])
            return True, f"{name}: disabled at login"

    if source == SourceKind.XDG_AUTOSTART:
        desktop_id = extra_meta.get("desktop_id") or unit_name
        has_sys = extra_meta.get("has_sys") == "1"
        omastart_managed = extra_meta.get("omastart_managed") == "1"
        app_desktop_path = str(extra_meta.get("app_desktop_path") or "")
        user_dir = HOME / ".config" / "autostart"
        user_dir.mkdir(parents=True, exist_ok=True)
        usr_path = user_dir / desktop_id

        if enable:
            if not usr_path.is_file() and not has_sys and command:
                desc = str(payload.get("description") or "").strip()
                icon = str(extra_meta.get("icon") or "").strip()
                _write_autostart_desktop_entry(usr_path, name or desktop_id, desc, command, icon)
                _spawn_bg_cmd(["systemctl", "--user", "daemon-reload"])
                return True, f"{name}: enabled at login"

            if usr_path.is_file():
                cp = configparser.ConfigParser(interpolation=None, strict=False)
                cp.optionxform = str
                cp.read(usr_path, encoding="utf-8")
                keys = (
                    set(cp["Desktop Entry"].keys())
                    if "Desktop Entry" in cp
                    else set()
                )
                if has_sys and keys <= {"Hidden", "X-GNOME-Autostart-enabled"}:
                    usr_path.unlink(missing_ok=True)
                elif "Desktop Entry" in cp:
                    cp["Desktop Entry"].pop("Hidden", None)
                    cp["Desktop Entry"].pop("X-GNOME-Autostart-enabled", None)
                    with open(usr_path, "w", encoding="utf-8") as fh:
                        cp.write(fh, space_around_delimiters=False)
            _spawn_bg_cmd(["systemctl", "--user", "daemon-reload"])
            if omastart_managed:
                return True, f"{name}: enabled at login"
            if pid == 0 and command:
                _spawn_detached(["bash", "-lc", command])
                return True, f"{name}: enabled & started"
            return True, f"{name}: enabled"
        else:
            if not has_sys and omastart_managed and app_desktop_path and Path(app_desktop_path).is_file():
                usr_path.unlink(missing_ok=True)
                _spawn_bg_cmd(["systemctl", "--user", "daemon-reload"])
                return True, f"{name}: disabled at login"

            if usr_path.is_file():
                cp = configparser.ConfigParser(interpolation=None, strict=False)
                cp.optionxform = str
                cp.read(usr_path, encoding="utf-8")
                if "Desktop Entry" not in cp:
                    cp["Desktop Entry"] = {}
                cp["Desktop Entry"]["Hidden"] = "true"
                with open(usr_path, "w", encoding="utf-8") as fh:
                    cp.write(fh, space_around_delimiters=False)
            else:
                usr_path.write_text("[Desktop Entry]\nHidden=true\n", encoding="utf-8")
            _spawn_bg_cmd(["systemctl", "--user", "daemon-reload"])
            if pid > 0 and _stop_user_process_safely(pid, command):
                return True, f"{name}: disabled & stopped"
            return True, f"{name}: disabled"

    if source == SourceKind.SYSTEMD_USER:
        if enable:
            if is_masked:
                _run_cmd(["systemctl", "--user", "unmask", unit_name], timeout=6.0)
            rc, _, err = _run_cmd(
                ["systemctl", "--user", "enable", "--now", unit_name], timeout=8.0
            )
            if rc != 0:
                return False, err.strip() or "systemctl --user enable failed"
            return True, f"{unit_name}: {'unmasked & enabled' if is_masked else 'enabled'}"
        else:
            companions = [u for u in triggered_by.split() if u and u != unit_name]
            targets = [unit_name] + companions
            rc, _, err = _run_cmd(
                ["systemctl", "--user", "disable", "--now"] + targets, timeout=8.0
            )
            if rc != 0:
                return False, err.strip() or "systemctl --user disable failed"
            label = " + ".join(targets)
            return True, f"{label}: disabled"

    if source == SourceKind.SYSTEMD_SYSTEM:
        if enable:
            if is_masked:
                rc, _, err = _run_cmd(
                    [
                        "pkexec",
                        "sh",
                        "-c",
                        'systemctl unmask "$1" && systemctl enable --now "$1"',
                        "--",
                        unit_name,
                    ],
                    timeout=45.0,
                )
            else:
                rc, _, err = _run_cmd(
                    ["pkexec", "systemctl", "enable", "--now", unit_name], timeout=45.0
                )
            if rc != 0:
                return False, err.strip() or "Authorization canceled"
            return True, f"{unit_name}: {'unmasked & enabled' if is_masked else 'enabled'}"
        else:
            companions = [u for u in triggered_by.split() if u and u != unit_name]
            targets = [unit_name] + companions
            rc, _, err = _run_cmd(
                ["pkexec", "systemctl", "disable", "--now"] + targets, timeout=45.0
            )
            if rc != 0:
                return False, err.strip() or "Authorization canceled"
            label = " + ".join(targets)
            return True, f"{label}: disabled"

    return False, "Unsupported startup source."


def add_hyprland_startup_entry(command: str) -> tuple[bool, str]:
    cmd = command.strip()
    if not cmd:
        return False, "Command cannot be empty."

    target_file, fmt = detect_hyprland_user_target()
    target_file.parent.mkdir(parents=True, exist_ok=True)
    backup = target_file.with_name(target_file.name + ".bak")

    if target_file.is_file():
        shutil.copy2(target_file, backup)
        existing = target_file.read_text(encoding="utf-8")
    else:
        existing = (
            "-- Extra autostart processes.\n"
            if fmt == "lua"
            else "# Autostart processes\n"
        )

    if fmt == "lua":
        new_line = f"o.launch_on_start({_lua_quote(cmd)})"
    else:
        new_line = f"exec-once = {cmd}"

    for ln in existing.splitlines():
        if ln.strip() == new_line:
            return False, f"Already present in {target_file.name}"

    if existing and not existing.endswith("\n"):
        existing += "\n"
    target_file.write_text(existing + new_line + "\n", encoding="utf-8")

    ok, err = _validate_hyprland_or_rollback(target_file, backup)
    if not ok:
        return False, err
    return True, f"Added '{cmd}' to {target_file.name}"


def add_post_boot_hook(name: str, description: str, script_body: str) -> tuple[bool, str]:
    slug = re.sub(r"[^a-zA-Z0-9_-]+", "-", name.strip().lower()).strip("-")
    if not slug:
        return False, "Hook name is required."
    body = script_body.strip()
    if not body:
        return False, "Command is required."

    hook_dir = HOME / ".config" / "omarchy" / "hooks" / "post-boot.d"
    hook_dir.mkdir(parents=True, exist_ok=True)
    target = hook_dir / slug
    if target.exists():
        return False, f"Hook '{slug}' already exists."

    desc_line = f"# {description.strip()}\n" if description.strip() else ""
    content = f"#!/bin/bash\n{desc_line}\n{body}\n"
    target.write_text(content, encoding="utf-8")
    target.chmod(0o755)
    return True, f"Created post-boot hook '{slug}'"


def delete_user_item_raw(payload: dict) -> tuple[bool, str]:
    if not payload.get("canDelete") or payload.get("readOnly"):
        return False, "System entries cannot be deleted (disable instead)."

    source = SourceKind(payload["source"])
    name = payload.get("name", "")
    command = payload.get("command", "")
    pid = int(payload.get("pid") or 0)
    config_path = payload.get("configPath", "")
    line_number = int(payload.get("lineNumber") or 0)

    if source == SourceKind.HYPRLAND_USER:
        target_file = Path(config_path) if config_path else (HOME / ".config" / "hypr" / "autostart.lua")
        if not str(target_file).startswith(str(HOME) + "/") or not target_file.is_file():
            return False, f"{target_file.name} not found."
        backup = target_file.with_name(target_file.name + ".bak")
        shutil.copy2(target_file, backup)
        lines = target_file.read_text(encoding="utf-8").splitlines()
        idx = line_number - 1
        if idx < 0 or idx >= len(lines):
            return False, "Line changed on disk — reload first."
        del lines[idx]
        target_file.write_text("\n".join(lines) + "\n", encoding="utf-8")
        ok, err = _validate_hyprland_or_rollback(target_file, backup)
        if not ok:
            return False, err
        if pid > 0:
            _stop_user_process_safely(pid, command)
        return True, f"Removed '{name}' from {target_file.name}"

    if source in (SourceKind.HOOK_POST_BOOT, SourceKind.XDG_AUTOSTART):
        p = Path(config_path)
        if str(p).startswith(str(HOME) + "/") and p.is_file():
            p.unlink()
            if source == SourceKind.XDG_AUTOSTART:
                _run_cmd(["systemctl", "--user", "daemon-reload"], timeout=4.0)
                if pid > 0:
                    _stop_user_process_safely(pid, command)
            return True, f"Removed '{name}'"
    return False, "Cannot delete this entry."


def run_item_now_raw(payload: dict) -> tuple[bool, str]:
    source = SourceKind(payload["source"])
    unit_name = payload.get("unitName", "")
    name = payload.get("name", "")
    command = payload.get("command", "")

    if source == SourceKind.SYSTEMD_USER:
        rc, _, err = _run_cmd(["systemctl", "--user", "restart", unit_name], timeout=8.0)
        return (rc == 0, f"Restarted {unit_name}" if rc == 0 else err.strip())
    if source == SourceKind.SYSTEMD_SYSTEM:
        rc, _, err = _run_cmd(["pkexec", "systemctl", "restart", unit_name], timeout=45.0)
        return (rc == 0, f"Restarted {unit_name}" if rc == 0 else (err.strip() or "Canceled"))
    if command:
        if _spawn_detached(["bash", "-lc", command]):
            return True, f"Launched {name}"
        return False, f"Failed to launch {name}"
    return False, "No runnable command."


def _resolve_preferred_editor() -> str:
    omarchy_ed_file = HOME / ".local" / "state" / "omarchy" / "defaults" / "editor"
    if omarchy_ed_file.is_file():
        try:
            ed = omarchy_ed_file.read_text(encoding="utf-8").splitlines()[0].strip()
            if ed and shutil.which(ed):
                return ed
        except OSError:
            pass

    for env_key in ("VISUAL", "EDITOR"):
        val = os.environ.get(env_key, "").strip()
        if not val or "omarchy-launch-editor" in val:
            continue
        try:
            tok = shlex.split(val)[0]
        except ValueError:
            tok = val.split()[0]
        if shutil.which(tok):
            return tok

    for candidate in ("nvim", "vim", "hx", "helix", "micro", "nano", "code", "zed"):
        if shutil.which(candidate):
            return candidate
    return ""


def _launch_tui_command(cmd_args: list[str]) -> bool:
    if shutil.which("omarchy-launch-tui"):
        return _spawn_detached(["omarchy-launch-tui"] + cmd_args)
    if shutil.which("xdg-terminal-exec"):
        return _spawn_detached(["xdg-terminal-exec", "-e"] + cmd_args)
    term_env = os.environ.get("TERMINAL", "").strip()
    if term_env and shutil.which(term_env):
        return _spawn_detached([term_env, "-e"] + cmd_args)
    for term in ("kitty", "alacritty", "foot", "ghostty", "wezterm"):
        if shutil.which(term):
            return _spawn_detached([term, "-e"] + cmd_args)
    return False


def open_in_editor_raw(payload: dict) -> tuple[bool, str]:
    config_path = str(payload.get("configPath") or "").strip()
    unit_name = str(payload.get("unitName") or "").strip()
    source_val = str(payload.get("source") or "")
    line_num = int(payload.get("lineNumber") or 0)

    target = Path(config_path) if config_path else None
    if (not target or not target.is_file() or str(target) == "/dev/null") and unit_name:
        sub = "user" if source_val == SourceKind.SYSTEMD_USER.value else "system"
        fallback = Path(f"/usr/lib/systemd/{sub}/{unit_name}")
        if fallback.is_file():
            target = fallback

    if not target or not target.is_file():
        return False, "Configuration file not found on disk."

    editor = _resolve_preferred_editor()
    ed_base = os.path.basename(editor) if editor else ""
    tui_editors = {"nvim", "vim", "vi", "nano", "micro", "hx", "helix", "fresh"}

    if ed_base in tui_editors:
        if ed_base in ("hx", "helix"):
            arg = f"{target}:{line_num}" if line_num > 0 else str(target)
            cmd = [editor, arg]
        elif line_num > 0 and ed_base in ("nvim", "vim", "vi", "nano", "micro"):
            cmd = [editor, f"+{line_num}", str(target)]
        else:
            cmd = [editor, str(target)]
        if _launch_tui_command(cmd):
            return True, f"Opened {target.name} in {ed_base}"

    if ed_base in ("code", "codium"):
        loc = f"{target}:{line_num}" if line_num > 0 else str(target)
        if _spawn_detached([editor, "--goto", loc]):
            return True, f"Opened {target.name} in {ed_base}"
    elif ed_base in ("zed", "zeditor", "subl"):
        loc = f"{target}:{line_num}" if line_num > 0 else str(target)
        if _spawn_detached([editor, loc]):
            return True, f"Opened {target.name} in {ed_base}"
    elif editor:
        if _spawn_detached([editor, str(target)]):
            return True, f"Opened {target.name} in {ed_base}"

    if shutil.which("omarchy-launch-editor"):
        if _spawn_detached(["omarchy-launch-editor", str(target)]):
            return True, f"Opened {target.name}"

    if shutil.which("xdg-open") and _spawn_detached(["xdg-open", str(target)]):
        return True, f"Opened {target.name}"

    return False, "No suitable editor found."


def open_dir_raw(path_str: str) -> tuple[bool, str]:
    p = Path(path_str) if path_str else None
    if not p:
        return False, "No path available."
    folder = p.parent if (p.is_file() or p.is_symlink() or not p.is_dir()) else p
    if folder.is_dir():
        if _spawn_detached(["xdg-open", str(folder)]):
            return False, f"Opened {folder}"
    return False, "Directory not found."


def fetch_unit_logs_raw(payload: dict, lines: int = 60) -> str:
    source = SourceKind(payload["source"])
    unit_name = payload.get("unitName", "")
    extra_meta = payload.get("extraMeta") or {}

    if source == SourceKind.SYSTEMD_USER:
        _, out, err = _run_cmd(
            ["journalctl", "--user", "-u", unit_name, "-n", str(lines), "--no-pager"],
            timeout=4.0,
        )
        return out.strip() or err.strip() or "No journal entries."
    if source == SourceKind.SYSTEMD_SYSTEM:
        _, out, err = _run_cmd(
            ["journalctl", "-u", unit_name, "-n", str(lines), "--no-pager"],
            timeout=4.0,
        )
        return out.strip() or err.strip() or "No journal entries."
    if source == SourceKind.XDG_AUTOSTART:
        desktop_id = extra_meta.get("desktop_id") or unit_name
        stem = desktop_id.removesuffix(".desktop").replace("-", r"\x2d")
        gen_unit = f"app-{stem}@autostart.service"
        _, out, _ = _run_cmd(
            ["journalctl", "--user", "-u", gen_unit, "-n", str(lines), "--no-pager"],
            timeout=4.0,
        )
        return out.strip() or "No systemd journal entries for this XDG entry."
    return ""


def mask_item_raw(payload: dict) -> tuple[bool, str]:
    source = SourceKind(payload["source"])
    unit_name = payload.get("unitName", "")
    if not unit_name:
        return False, "Not a systemd unit."
    if source == SourceKind.SYSTEMD_USER:
        rc, _, err = _run_cmd(["systemctl", "--user", "mask", unit_name], timeout=8.0)
        if rc != 0:
            return False, err.strip() or "systemctl --user mask failed"
        return True, f"{unit_name}: masked"
    elif source == SourceKind.SYSTEMD_SYSTEM:
        rc, _, err = _run_cmd(["pkexec", "systemctl", "mask", unit_name], timeout=45.0)
        if rc != 0:
            return False, err.strip() or "Authorization canceled"
        return True, f"{unit_name}: masked"
    return False, "Only systemd units can be masked."


def _omarchy_agent_env() -> dict[str, str]:
    env = os.environ.copy()
    extra_dirs = [
        str(HOME / ".local" / "bin"),
        str(HOME / ".local" / "share" / "mise" / "command-wrappers" / "bin"),
        str(HOME / ".local" / "share" / "mise" / "shims"),
        "/usr/share/omarchy/bin",
    ]
    parts = [p for p in env.get("PATH", "").split(":") if p]
    for d in reversed(extra_dirs):
        if d not in parts and os.path.isdir(d):
            parts.insert(0, d)
    env["PATH"] = ":".join(parts)
    return env


def _read_default_omarchy_agent(env: dict[str, str]) -> str:
    agent_file = HOME / ".config" / "omarchy" / "defaults" / "agent"
    if agent_file.is_file():
        try:
            for ln in agent_file.read_text(encoding="utf-8", errors="ignore").splitlines():
                if ln.strip():
                    return ln.strip()
        except OSError:
            pass
    default_bin = shutil.which("omarchy-default-agent", path=env.get("PATH"))
    if default_bin:
        try:
            proc = subprocess.run(
                [default_bin],
                capture_output=True,
                text=True,
                timeout=3.0,
                env=env,
            )
            if proc.returncode == 0 and proc.stdout.strip():
                return proc.stdout.strip().splitlines()[0].strip()
        except Exception:
            pass
    return ""


def _build_failed_units_ai_prompt(items: list[dict]) -> str:
    sections: list[str] = []
    for idx, it in enumerate(items[:6], start=1):
        name = str(it.get("name") or it.get("unitName") or "unknown").strip()
        unit_name = str(it.get("unitName") or "").strip()
        src_val = str(it.get("source") or "").strip()
        src_label = str(it.get("sourceLabel") or src_val).strip()
        pkg_name = str(it.get("pkgName") or "").strip()
        pkg_ver = str(it.get("pkgVersion") or "").strip()
        cfg_path = str(it.get("configPath") or "").strip()
        cmd_str = str(it.get("command") or "").strip()
        trig = str(it.get("triggeredBy") or "").strip()

        pkg_txt = f"{pkg_name} {pkg_ver}".strip() if pkg_name else "local / unowned"
        header = f"[{idx}] {unit_name or name} ({src_label})"
        meta_lines = [
            header,
            f"  Name:    {name}",
            f"  Package: {pkg_txt}",
        ]
        if cfg_path:
            meta_lines.append(f"  Config:  {cfg_path}")
        if cmd_str:
            meta_lines.append(f"  Command: {cmd_str}")
        if trig:
            meta_lines.append(f"  Trigger: {trig}")

        status_out = ""
        if unit_name and src_val in (SourceKind.SYSTEMD_USER.value, SourceKind.SYSTEMD_SYSTEM.value):
            scmd = (
                ["systemctl", "--user", "status", unit_name, "--no-pager", "-n", "12"]
                if src_val == SourceKind.SYSTEMD_USER.value
                else ["systemctl", "status", unit_name, "--no-pager", "-n", "12"]
            )
            _, st_stdout, st_stderr = _run_cmd(scmd, timeout=3.0)
            status_out = (st_stdout or st_stderr).strip()
            if len(status_out) > 1200:
                status_out = status_out[-1200:]

        logs_out = ""
        try:
            if unit_name and src_val == SourceKind.SYSTEMD_USER.value:
                _, l_out, l_err = _run_cmd(
                    ["journalctl", "--user", "-u", unit_name, "-b", "-n", "30", "--no-pager"],
                    timeout=3.0,
                )
                logs_out = (l_out or l_err).strip()
            elif unit_name and src_val == SourceKind.SYSTEMD_SYSTEM.value:
                _, l_out, l_err = _run_cmd(
                    ["journalctl", "-u", unit_name, "-b", "-n", "30", "--no-pager"],
                    timeout=3.0,
                )
                logs_out = (l_out or l_err).strip()
            else:
                logs_out = fetch_unit_logs_raw(it, lines=30).strip()
        except Exception:
            logs_out = ""
        if len(logs_out) > 1800:
            logs_out = logs_out[-1800:]

        if status_out:
            meta_lines.append("  systemctl status:")
            meta_lines.extend(f"    {ln}" for ln in status_out.splitlines())
        if logs_out:
            meta_lines.append("  Recent journal logs (current boot):")
            meta_lines.extend(f"    {ln}" for ln in logs_out.splitlines())

        sections.append("\n".join(meta_lines))

    extra_note = ""
    if len(items) > 6:
        extra_note = f"\n(Plus {len(items) - 6} additional failed startup unit(s); check `systemctl --failed` and `systemctl --user --failed`.)\n"

    body = "\n\n---\n\n".join(sections)
    return (
        "The following startup process(es) / systemd unit(s) failed on this Omarchy Linux machine "
        "(detected in omastart).\n"
        "Please analyze the error output and unit configuration for each failed process, explain the "
        "exact root cause clearly, and suggest the cleanest fix (ask before making system-level or "
        "destructive changes):\n\n"
        f"{body}{extra_note}"
    )


def inspect_failed_with_ai_raw(items: list[dict]) -> tuple[bool, str]:
    target_items = [it for it in (items or []) if isinstance(it, dict)]
    if not target_items:
        from .collector import collect_all_startup_data

        summary = collect_all_startup_data()
        target_items = [
            it.to_ui_dict() for it in summary.items if it.running_state == "failed"
        ]

    if not target_items:
        return False, "No failed startup processes to inspect."

    prompt = _build_failed_units_ai_prompt(target_items)
    env = _omarchy_agent_env()
    work_dir = str(HOME / "Work") if (HOME / "Work").is_dir() else str(HOME)

    omarchy_agent_bin = shutil.which("omarchy-agent", path=env.get("PATH"))
    default_agent = _read_default_omarchy_agent(env)

    if omarchy_agent_bin:
        if not default_agent:
            wl_copy = shutil.which("wl-copy", path=env.get("PATH"))
            if wl_copy:
                try:
                    subprocess.run(
                        [wl_copy],
                        input=prompt,
                        text=True,
                        timeout=2.0,
                        env=env,
                    )
                except Exception:
                    pass
            try:
                subprocess.Popen(
                    [omarchy_agent_bin, "--pick"],
                    cwd=work_dir,
                    env=env,
                    stdin=subprocess.DEVNULL,
                    stdout=subprocess.DEVNULL,
                    stderr=subprocess.DEVNULL,
                    start_new_session=True,
                    close_fds=True,
                )
                return True, "Select a default Omarchy agent first (error details copied)"
            except Exception as exc:
                return False, f"Failed to open Omarchy agent picker: {exc}"

        try:
            subprocess.Popen(
                [omarchy_agent_bin, "--prompt", prompt],
                cwd=work_dir,
                env=env,
                stdin=subprocess.DEVNULL,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                start_new_session=True,
                close_fds=True,
            )
            cnt = len(target_items)
            noun = "failed process" if cnt == 1 else "failed processes"
            return True, f"Opened {default_agent} to analyze {cnt} {noun}"
        except Exception as exc:
            return False, f"Failed to launch {default_agent}: {exc}"

    # Fallback on non-Omarchy systems if a known CLI coding agent is installed
    for cand, args in (
        ("agy", ["agy", "--prompt-interactive", prompt]),
        ("claude", ["claude", "--", prompt]),
        ("codex", ["codex", "--", prompt]),
        ("opencode", ["opencode", "--prompt", prompt]),
    ):
        cbin = shutil.which(cand, path=env.get("PATH"))
        if cbin:
            args[0] = cbin
            if _launch_tui_command(args):
                return True, f"Opened {cand} to analyze failed startup units"

    return False, "No default Omarchy AI agent configured (`omarchy default agent`)."


SETTINGS_FILE = HOME / ".config" / "omastart" / "settings.json"


def get_settings_raw() -> dict:
    if SETTINGS_FILE.is_file():
        try:
            return json.loads(SETTINGS_FILE.read_text(encoding="utf-8"))
        except Exception:
            pass
    return {"rememberMode": False, "mode": "apps"}


def save_settings_raw(settings: dict) -> tuple[bool, str]:
    SETTINGS_FILE.parent.mkdir(parents=True, exist_ok=True)
    try:
        curr = get_settings_raw()
        curr.update(settings)
        SETTINGS_FILE.write_text(json.dumps(curr, indent=2), encoding="utf-8")
        return True, "Settings saved"
    except Exception as e:
        return False, str(e)


SNAPSHOT_DIR = HOME / ".config" / "omastart" / "snapshots"


def save_snapshot_raw(name: str = "") -> tuple[bool, str]:
    from .collector import collect_all_startup_data

    SNAPSHOT_DIR.mkdir(parents=True, exist_ok=True)
    now_str = datetime.now().strftime("%Y%m%d_%H%M%S")
    snap_id = f"snap_{now_str}"
    label = name.strip() or now_str
    summary = collect_all_startup_data()
    data = {
        "id": snap_id,
        "label": label,
        "timestamp": now_str,
        "items": [
            {
                "id": it.id,
                "name": it.name,
                "source": it.source.value,
                "enabled": it.enabled,
                "unitName": it.unit_name,
                "configPath": it.config_path,
                "command": it.command,
                "lineNumber": it.line_number or 0,
            }
            for it in summary.items
            if it.source != SourceKind.DESKTOP_APP
        ],
    }
    file_path = SNAPSHOT_DIR / f"{snap_id}.json"
    try:
        file_path.write_text(json.dumps(data, indent=2), encoding="utf-8")
        return True, f"Saved snapshot '{label}' ({len(data['items'])} items)"
    except Exception as e:
        return False, str(e)


def list_snapshots_raw() -> list[dict]:
    if not SNAPSHOT_DIR.is_dir():
        return []
    out = []
    for p in sorted(SNAPSHOT_DIR.glob("snap_*.json"), reverse=True):
        try:
            d = json.loads(p.read_text(encoding="utf-8"))
            out.append(
                {
                    "id": d.get("id", p.stem),
                    "label": d.get("label", p.stem),
                    "timestamp": d.get("timestamp", ""),
                    "itemCount": len(d.get("items", [])),
                    "file": str(p),
                }
            )
        except Exception:
            pass
    return out


def restore_snapshot_raw(snap_id: str) -> tuple[bool, str]:
    file_path = SNAPSHOT_DIR / f"{snap_id}.json"
    if not file_path.is_file():
        matches = list(SNAPSHOT_DIR.glob(f"*{snap_id}*.json"))
        if matches:
            file_path = matches[0]
        else:
            return False, f"Snapshot not found: {snap_id}"
    try:
        data = json.loads(file_path.read_text(encoding="utf-8"))
    except Exception as e:
        return False, f"Failed to read snapshot: {e}"

    from .collector import collect_all_startup_data

    summary = collect_all_startup_data()
    curr_map = {it.id: it for it in summary.items}
    restored_cnt = 0

    snap_ids: set[str] = set()
    for rec in data.get("items", []):
        rec_id = rec.get("id")
        if rec_id:
            snap_ids.add(rec_id)
        rec_enabled = rec.get("enabled", True)
        if rec_id in curr_map:
            curr_item = curr_map[rec_id]
            if curr_item.enabled != rec_enabled and not curr_item.read_only:
                ok, _ = set_item_enabled_raw(curr_item.to_ui_dict(), rec_enabled)
                if ok:
                    restored_cnt += 1

    # Also disable any omastart-managed desktop autostart added after the snapshot
    for it in summary.items:
        if (
            it.source == SourceKind.XDG_AUTOSTART
            and it.enabled
            and it.extra_meta.get("omastart_managed") == "1"
            and it.id not in snap_ids
        ):
            ok, _ = set_item_enabled_raw(it.to_ui_dict(), False)
            if ok:
                restored_cnt += 1

    return True, f"Restored snapshot '{data.get('label', snap_id)}' ({restored_cnt} changes applied)"


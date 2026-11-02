from __future__ import annotations

import configparser
import os
from pathlib import Path
import re
import shutil
import subprocess

from .models import SourceKind, StartupItem

HOME = Path.home()


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


def _validate_hyprland_or_rollback(user_lua: Path, backup_path: Path) -> tuple[bool, str]:
    _run_cmd(["hyprctl", "reload"], timeout=4.0)
    rc, out, _ = _run_cmd(["hyprctl", "configerrors"], timeout=4.0)
    err_lines = [ln.strip() for ln in out.splitlines() if ln.strip()]
    if rc == 0 and err_lines:
        if backup_path.is_file():
            shutil.copy2(backup_path, user_lua)
            _run_cmd(["hyprctl", "reload"], timeout=4.0)
        return False, "Hyprland config error (restored backup): " + "; ".join(err_lines)
    return True, ""


def _lua_quote(value: str) -> str:
    escaped = value.replace("\\", "\\\\").replace('"', '\\"')
    return f'"{escaped}"'


def set_item_enabled_raw(payload: dict, enable: bool) -> tuple[bool, str]:
    source = SourceKind(payload["source"])
    config_path = payload.get("configPath", "")
    name = payload.get("name", "")
    unit_name = payload.get("unitName", "")
    line_number = int(payload.get("lineNumber") or 0)
    extra_meta = payload.get("extraMeta") or {}

    if payload.get("readOnly") or config_path.startswith("/usr/share/omarchy"):
        return False, "Core Omarchy startup entries are read-only."

    if source == SourceKind.HYPRLAND_USER:
        user_lua = HOME / ".config" / "hypr" / "autostart.lua"
        if not user_lua.is_file():
            return False, f"File not found: {user_lua}"
        backup = user_lua.with_suffix(".lua.bak")
        shutil.copy2(user_lua, backup)

        lines = user_lua.read_text(encoding="utf-8").splitlines()
        idx = line_number - 1
        if idx < 0 or idx >= len(lines):
            return False, "Line changed on disk — reload first."

        current = lines[idx].strip()
        if enable:
            updated = re.sub(r"^--\s*(?:\[disabled\]\s*)?", "", current)
        else:
            clean = re.sub(r"^--\s*(?:\[disabled\]\s*)?", "", current)
            updated = f"-- [disabled] {clean}"

        lines[idx] = updated
        user_lua.write_text("\n".join(lines) + "\n", encoding="utf-8")
        ok, err = _validate_hyprland_or_rollback(user_lua, backup)
        if not ok:
            return False, err
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

    if source == SourceKind.XDG_AUTOSTART:
        desktop_id = extra_meta.get("desktop_id") or unit_name
        has_sys = extra_meta.get("has_sys") == "1"
        user_dir = HOME / ".config" / "autostart"
        user_dir.mkdir(parents=True, exist_ok=True)
        usr_path = user_dir / desktop_id

        if enable:
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
            _run_cmd(["systemctl", "--user", "daemon-reload"], timeout=4.0)
            return True, f"{name}: enabled"
        else:
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
            _run_cmd(["systemctl", "--user", "daemon-reload"], timeout=4.0)
            return True, f"{name}: disabled"

    if source == SourceKind.SYSTEMD_USER:
        action = "enable" if enable else "disable"
        rc, _, err = _run_cmd(
            ["systemctl", "--user", action, "--now", unit_name], timeout=8.0
        )
        if rc != 0:
            return False, err.strip() or "systemctl --user failed"
        return True, f"{unit_name}: {'enabled' if enable else 'disabled'}"

    if source == SourceKind.SYSTEMD_SYSTEM:
        action = "enable" if enable else "disable"
        rc, _, err = _run_cmd(
            ["pkexec", "systemctl", action, "--now", unit_name], timeout=45.0
        )
        if rc != 0:
            return False, err.strip() or "Authorization canceled"
        return True, f"{unit_name}: {'enabled' if enable else 'disabled'}"

    return False, "Unsupported startup source."


def add_hyprland_startup_entry(command: str) -> tuple[bool, str]:
    cmd = command.strip()
    if not cmd:
        return False, "Command cannot be empty."
    user_lua = HOME / ".config" / "hypr" / "autostart.lua"
    user_lua.parent.mkdir(parents=True, exist_ok=True)
    backup = user_lua.with_suffix(".lua.bak")
    if user_lua.is_file():
        shutil.copy2(user_lua, backup)
        existing = user_lua.read_text(encoding="utf-8")
    else:
        existing = "-- Extra autostart processes.\n"

    new_line = f"o.launch_on_start({_lua_quote(cmd)})"
    if new_line in existing.splitlines():
        return False, "Already present in ~/.config/hypr/autostart.lua"

    if existing and not existing.endswith("\n"):
        existing += "\n"
    user_lua.write_text(existing + new_line + "\n", encoding="utf-8")

    ok, err = _validate_hyprland_or_rollback(user_lua, backup)
    if not ok:
        return False, err
    return True, f"Added '{cmd}' to autostart.lua"


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
    config_path = payload.get("configPath", "")
    line_number = int(payload.get("lineNumber") or 0)

    if source == SourceKind.HYPRLAND_USER:
        user_lua = HOME / ".config" / "hypr" / "autostart.lua"
        if not user_lua.is_file():
            return False, "autostart.lua not found."
        backup = user_lua.with_suffix(".lua.bak")
        shutil.copy2(user_lua, backup)
        lines = user_lua.read_text(encoding="utf-8").splitlines()
        idx = line_number - 1
        if idx < 0 or idx >= len(lines):
            return False, "Line changed on disk — reload first."
        del lines[idx]
        user_lua.write_text("\n".join(lines) + "\n", encoding="utf-8")
        ok, err = _validate_hyprland_or_rollback(user_lua, backup)
        if not ok:
            return False, err
        return True, f"Removed '{name}' from autostart.lua"

    if source in (SourceKind.HOOK_POST_BOOT, SourceKind.XDG_AUTOSTART):
        p = Path(config_path)
        if str(p).startswith(str(HOME) + "/") and p.is_file():
            p.unlink()
            if source == SourceKind.XDG_AUTOSTART:
                _run_cmd(["systemctl", "--user", "daemon-reload"], timeout=4.0)
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
        try:
            subprocess.Popen(
                ["uwsm-app", "--", "bash", "-lc", command],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                start_new_session=True,
            )
            return True, f"Launched {name}"
        except Exception as exc:
            return False, str(exc)
    return False, "No runnable command."


def fetch_unit_logs_raw(payload: dict, lines: int = 40) -> str:
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

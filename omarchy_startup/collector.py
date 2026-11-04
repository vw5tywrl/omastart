from __future__ import annotations

from concurrent.futures import ThreadPoolExecutor
import configparser
import glob as glob_mod
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import subprocess
from typing import Optional

from .models import BootSummary, PackageInfo, SourceKind, StartupItem

HOME = Path.home()
OMARCHY_PATH = Path(os.environ.get("OMARCHY_PATH", "/usr/share/omarchy"))

CRITICAL_UNITS = {
    "sddm.service",
    "NetworkManager.service",
    "systemd-resolved.service",
    "systemd-timesyncd.service",
    "ufw.service",
    "pipewire.service",
    "pipewire.socket",
    "pipewire-pulse.service",
    "pipewire-pulse.socket",
    "wireplumber.service",
    "dbus-broker.service",
}

FRIENDLY_HYPR_NAMES = {
    "omarchy-launch-shell": (
        "omarchy-shell",
        "Status bar, notifications, menu, OSD, and Polkit agent",
    ),
    "omarchy-provision-first-run": (
        "omarchy-provision-first-run",
        "First-boot user session provisioning",
    ),
    "omarchy-powerprofiles-init": (
        "omarchy-powerprofiles-init",
        "Initialize AC/battery power profile",
    ),
    "omarchy-hyprland-monitor-watch": (
        "omarchy-hyprland-monitor-watch",
        "External display hotplug & scaling watcher",
    ),
    "omarchy-hook": (
        "omarchy-hook post-boot",
        "Run user scripts in ~/.config/omarchy/hooks/post-boot.d/",
    ),
    "udiskie": (
        "udiskie",
        "Removable USB/disk automounter",
    ),
}


def _run_cmd(args: list[str], timeout: float = 5.0) -> tuple[int, str, str]:
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
    except Exception as exc:
        return 1, "", str(exc)


def _parse_systemd_duration_ms(text: str) -> float:
    """Parse systemd duration strings like '1min 2.345s', '821ms', '21.792s' into ms."""
    s = text.strip()
    if not s:
        return 0.0
    total_ms = 0.0
    for m in re.finditer(r"([0-9]+(?:\.[0-9]+)?)\s*(min|ms|us|µs|s|h)", s):
        val = float(m.group(1))
        unit = m.group(2)
        if unit == "h":
            total_ms += val * 3_600_000.0
        elif unit == "min":
            total_ms += val * 60_000.0
        elif unit == "s":
            total_ms += val * 1000.0
        elif unit == "ms":
            total_ms += val
        elif unit in ("us", "µs"):
            total_ms += val / 1000.0
    return total_ms


def _compute_monotonic_ms(info: dict[str, str]) -> Optional[float]:
    try:
        t_start = int(info.get("InactiveExitTimestampMonotonic", "0") or "0")
        t_end = int(info.get("ActiveEnterTimestampMonotonic", "0") or "0")
        if t_start > 0 and t_end >= t_start:
            ms = (t_end - t_start) / 1000.0
            if ms >= 0.5:
                return ms
        # Oneshot units without RemainAfterExit never enter 'active'; measure ExecMain
        ex_start = int(info.get("ExecMainStartTimestampMonotonic", "0") or "0")
        ex_end = int(info.get("ExecMainExitTimestampMonotonic", "0") or "0")
        if ex_start > 0 and ex_end >= ex_start:
            ms = (ex_end - ex_start) / 1000.0
            if ms >= 0.5:
                return ms
    except ValueError:
        pass
    return None


def _collect_boot_summary() -> BootSummary:
    summary = BootSummary()
    rc, out, _ = _run_cmd(["systemd-analyze", "time", "--no-pager"], timeout=3.0)
    if rc != 0 or not out.strip():
        return summary
    lines = [ln.strip() for ln in out.strip().splitlines() if ln.strip()]
    summary.raw_breakdown = "\n".join(lines)
    stages: list[dict[str, object]] = []
    if lines:
        first = lines[0]
        m_total = re.search(r"=\s*([0-9a-zA-Z.\s]+)$", first)
        if m_total:
            summary.total_time = m_total.group(1).strip()
        m_user = re.search(r"([0-9a-zA-Z.\s]+?)\s*\(userspace\)", first)
        if m_user:
            summary.userspace_time = m_user.group(1).strip()

        # Extract each 'X.XXXs (stage)' segment
        body = re.sub(r"^Startup finished in\s+", "", first)
        body = re.sub(r"\s*=\s*[^=]+$", "", body)
        for part in body.split("+"):
            pm = re.match(r"^\s*([0-9a-zA-Z.\s]+?)\s*\(([^)]+)\)\s*$", part)
            if pm:
                dur_txt = pm.group(1).strip()
                stg_name = pm.group(2).strip()
                stages.append(
                    {
                        "name": stg_name,
                        "label": stg_name.capitalize(),
                        "time": dur_txt,
                        "text": dur_txt,
                        "ms": round(_parse_systemd_duration_ms(dur_txt), 1),
                    }
                )
        tot_ms = sum(float(s["ms"]) for s in stages) or 1.0
        for s in stages:
            s["percent"] = round((float(s["ms"]) / tot_ms) * 100, 1)
    if len(lines) > 1:
        m_graph = re.search(r"after\s+([0-9a-zA-Z.\s]+?)\s+in userspace", lines[1])
        if m_graph:
            summary.graphical_time = m_graph.group(1).strip()
    summary.stages = stages
    return summary


def _collect_critical_chain() -> list[dict[str, object]]:
    rc, out, _ = _run_cmd(["systemd-analyze", "critical-chain", "--no-pager"], timeout=4.0)
    if rc != 0 or not out.strip():
        return []
    tree: list[dict[str, object]] = []
    for line in out.strip().splitlines():
        if "@" not in line:
            continue
        cleaned = re.sub(r"^\s*(?:└─|├─|│|`[-─]|\+[-─]|[-─]{1,2})\s*", "", line)
        m = re.match(r"^([a-zA-Z0-9_.\-@]+)\s+@([0-9a-zA-Z.]+)(?:\s+\+([0-9a-zA-Z.]+))?", cleaned)
        if m:
            unit = m.group(1)
            active_at = m.group(2)
            dur = m.group(3) or ""
            prefix = line[:line.find(unit)] if unit in line else ""
            indent = len(prefix.replace("└─", "  ").replace("├─", "  ").replace("│ ", "  "))
            tree.append({
                "unit": unit,
                "activeAt": active_at,
                "duration": dur,
                "indent": indent,
                "raw": line.strip(),
            })
    return tree


def _collect_running_processes() -> list[tuple[int, str, str]]:
    rc, out, _ = _run_cmd(["ps", "-eo", "pid=,comm=,args="], timeout=3.0)
    procs: list[tuple[int, str, str]] = []
    if rc != 0:
        return procs
    for line in out.splitlines():
        line = line.strip()
        if not line:
            continue
        parts = line.split(None, 2)
        if len(parts) < 2:
            continue
        try:
            pid = int(parts[0])
        except ValueError:
            continue
        comm = parts[1]
        args = parts[2] if len(parts) > 2 else comm
        procs.append((pid, comm, args))
    return procs


def _strip_hypr_exec_rules(command: str) -> str:
    """Strip Hyprland dispatch rules prefix such as '[workspace 2 silent] firefox'."""
    return re.sub(r"^\s*\[[^\]]*\]\s*", "", command.strip())


def _extract_first_executable(command: str) -> str:
    cmd = _strip_hypr_exec_rules(command)
    if not cmd:
        return ""
    cmd = re.sub(r"^[-@:+!]+\s*", "", cmd)
    if "&&" in cmd:
        segments = [s.strip() for s in cmd.split("&&") if s.strip()]
        for seg in segments:
            if not seg.startswith("sleep "):
                cmd = seg
                break
    try:
        tokens = shlex.split(cmd)
    except ValueError:
        tokens = cmd.split()
    skip_wrappers = {
        "uwsm-app",
        "uwsm",
        "app",
        "--",
        "env",
        "nohup",
        "setsid",
        "sh",
        "bash",
        "-c",
        "-lc",
    }
    idx = 0
    while idx < len(tokens):
        tok = tokens[idx]
        if "=" in tok and not tok.startswith("/"):
            idx += 1
            continue
        if tok in skip_wrappers:
            idx += 1
            continue
        return os.path.expanduser(tok)
    return os.path.expanduser(tokens[0]) if tokens else ""


def _resolve_binary_path(command: str) -> str:
    exe = _extract_first_executable(command)
    if not exe:
        return ""
    if exe.startswith("/"):
        return exe if os.path.exists(exe) else ""
    return shutil.which(exe) or ""


def _is_executable_uninstalled(command: str, bin_path: str) -> bool:
    exe = _extract_first_executable(command)
    if not exe:
        return False
    if bin_path and os.path.exists(bin_path):
        return False
    if exe in {"sh", "bash", "zsh", "systemctl", "exec", "source", "."}:
        return False
    if "/" in exe:
        return not os.path.exists(os.path.expanduser(exe))
    return shutil.which(exe) is None


def _read_omarchy_script_summary(binary_path: str) -> str:
    if not binary_path or not os.path.isfile(binary_path):
        return ""
    try:
        with open(binary_path, "r", encoding="utf-8", errors="ignore") as fh:
            for _ in range(15):
                line = fh.readline()
                if not line:
                    break
                if line.startswith("# omarchy:summary="):
                    return line.split("=", 1)[1].strip()
    except OSError:
        pass
    return ""


def _match_process(
    exe_name: str, command: str, procs: list[tuple[int, str, str]]
) -> Optional[int]:
    if not exe_name:
        return None
    base = os.path.basename(exe_name)
    if base == "omarchy-launch-shell":
        for pid, comm, args in procs:
            if "quickshell" in comm and "omarchy-startup" not in args:
                return pid
    for pid, comm, args in procs:
        if "omarchy-startup" in args:
            continue
        if comm == base:
            return pid
        if base in args and re.search(rf"(?:^|[/\s]){re.escape(base)}(?:\s|$)", args):
            return pid
    return None


def detect_hyprland_user_target() -> tuple[Path, str]:
    """Return (target_file, format) where format is 'lua' or 'conf'."""
    hypr_dir = HOME / ".config" / "hypr"
    if (hypr_dir / "hyprland.lua").is_file() or (hypr_dir / "autostart.lua").is_file():
        return hypr_dir / "autostart.lua", "lua"
    if (hypr_dir / "autostart.conf").is_file():
        return hypr_dir / "autostart.conf", "conf"
    if (hypr_dir / "hyprland.conf").is_file():
        return hypr_dir / "hyprland.conf", "conf"
    if (OMARCHY_PATH / "default" / "hypr" / "autostart.lua").is_file():
        return hypr_dir / "autostart.lua", "lua"
    return hypr_dir / "hyprland.conf", "conf"


def _discover_hypr_conf_files() -> list[Path]:
    """Find user Hyprland .conf files (hyprland.conf, autostart.conf, and sourced files)."""
    hypr_dir = HOME / ".config" / "hypr"
    if not hypr_dir.is_dir():
        return []

    seen: set[Path] = set()
    ordered: list[Path] = []

    def _add(p: Path) -> None:
        try:
            rp = p.resolve()
        except OSError:
            rp = p
        if rp not in seen and p.is_file():
            seen.add(rp)
            ordered.append(p)

    main_conf = hypr_dir / "hyprland.conf"
    auto_conf = hypr_dir / "autostart.conf"
    _add(auto_conf)
    _add(main_conf)

    # Follow top-level `source = ...` directives inside hyprland.conf
    if main_conf.is_file():
        try:
            for raw in main_conf.read_text(encoding="utf-8", errors="ignore").splitlines():
                s = raw.strip()
                if not s or s.startswith("#"):
                    continue
                m = re.match(r"^source\s*=\s*(.+)$", s)
                if not m:
                    continue
                src_expr = m.group(1).split("#", 1)[0].strip()
                src_expr = src_expr.replace("$HOME", str(HOME))
                src_expr = os.path.expanduser(src_expr)
                if not src_expr.startswith("/"):
                    src_expr = str(hypr_dir / src_expr)
                for matched in sorted(glob_mod.glob(src_expr)):
                    mp = Path(matched)
                    if mp.suffix == ".conf":
                        _add(mp)
        except OSError:
            pass

    return ordered


def _collect_hyprland_items(procs: list[tuple[int, str, str]]) -> list[StartupItem]:
    items: list[StartupItem] = []

    # 1. Omarchy default read-only Lua autostarts (if running on Omarchy)
    default_lua = OMARCHY_PATH / "default" / "hypr" / "autostart.lua"
    if default_lua.is_file():
        try:
            lines = default_lua.read_text(encoding="utf-8", errors="ignore").splitlines()
        except OSError:
            lines = []
        for idx, line in enumerate(lines, start=1):
            stripped = line.strip()
            if not stripped or stripped.startswith("--"):
                continue
            m_launch = re.search(
                r'hl\.exec_cmd\(\s*o\.launch\(\s*(["\'])(.+?)\1\s*\)\s*\)', stripped
            )
            m_exec = re.search(r'hl\.exec_cmd\(\s*(["\'])(.+?)\1\s*\)', stripped)
            cmd = m_launch.group(2) if m_launch else (m_exec.group(2) if m_exec else "")
            if not cmd:
                continue
            if cmd.startswith("systemctl --user import-environment") or cmd.startswith(
                "dbus-update-activation-environment"
            ):
                continue

            bin_path = _resolve_binary_path(cmd)
            exe_base = os.path.basename(_extract_first_executable(cmd))
            friendly = FRIENDLY_HYPR_NAMES.get(exe_base)
            if friendly:
                title, desc = friendly
            else:
                title = exe_base or cmd
                desc = _read_omarchy_script_summary(bin_path) or "Hyprland session startup"

            pid = _match_process(exe_base, cmd, procs)
            oneshot_cmds = {
                "omarchy-provision-first-run",
                "omarchy-powerprofiles-init",
                "omarchy-hook",
            }
            if pid is not None:
                r_state, r_label = "running", "active"
            elif exe_base in oneshot_cmds:
                r_state, r_label = "oneshot_done", "done"
            else:
                r_state, r_label = "inactive", "stopped"

            items.append(
                StartupItem(
                    id=f"hypr-default:{idx}:{exe_base}",
                    name=title,
                    description=desc,
                    command=cmd,
                    source=SourceKind.HYPRLAND_DEFAULT,
                    enabled=True,
                    running_state=r_state,
                    running_label=r_label,
                    config_path=str(default_lua),
                    binary_path=bin_path,
                    pid=pid,
                    read_only=True,
                    read_only_reason="Managed by Omarchy (/usr/share/omarchy/ is read-only across updates).",
                    is_uninstalled=_is_executable_uninstalled(cmd, bin_path),
                    trigger_type="login",
                    line_number=idx,
                    raw_line=line,
                    extra_meta={"hypr_format": "lua"},
                )
            )

    # 2. User ~/.config/hypr/autostart.lua (Omarchy Lua style)
    user_lua = HOME / ".config" / "hypr" / "autostart.lua"
    if user_lua.is_file():
        try:
            lines = user_lua.read_text(encoding="utf-8", errors="ignore").splitlines()
        except OSError:
            lines = []
        pattern = re.compile(
            r'^(?P<comment>--\s*(?:\[disabled\]\s*)?)?'
            r'(?P<func>o\.launch_on_start|o\.exec_on_start|hl\.exec_cmd)\s*\(\s*'
            r'(?:o\.launch\(\s*)?(?P<quote>["\'])(?P<cmd>.+?)(?P=quote)\s*\)?\s*\)'
        )
        for idx, line in enumerate(lines, start=1):
            stripped = line.strip()
            if not stripped:
                continue
            m = pattern.match(stripped)
            if not m:
                continue
            cmd = m.group("cmd").strip()
            is_commented = bool(m.group("comment"))
            if is_commented and cmd == "my-service" and "[disabled]" not in stripped:
                continue

            enabled = not is_commented
            bin_path = _resolve_binary_path(cmd)
            exe_base = os.path.basename(_extract_first_executable(cmd))
            pid = _match_process(exe_base, cmd, procs) if enabled else None
            if not enabled:
                r_state, r_label = "inactive", "disabled"
            elif pid is not None:
                r_state, r_label = "running", "active"
            else:
                r_state, r_label = "inactive", "stopped"

            desc = (
                _read_omarchy_script_summary(bin_path)
                or f"User autostart ({m.group('func')})"
            )
            items.append(
                StartupItem(
                    id=f"hypr-user:{user_lua}:{idx}:{cmd}",
                    name=exe_base or cmd,
                    description=desc,
                    command=cmd,
                    source=SourceKind.HYPRLAND_USER,
                    enabled=enabled,
                    running_state=r_state,
                    running_label=r_label,
                    config_path=str(user_lua),
                    binary_path=bin_path,
                    pid=pid,
                    read_only=False,
                    can_delete=True,
                    is_uninstalled=_is_executable_uninstalled(cmd, bin_path),
                    trigger_type="login",
                    line_number=idx,
                    raw_line=line,
                    extra_meta={"hypr_format": "lua"},
                )
            )

    # 3. Standard Hyprland .conf files (exec-once = ...) for vanilla Arch + Hyprland users
    conf_files = _discover_hypr_conf_files()
    if conf_files:
        hypr_vars: dict[str, str] = {}
        for cf in conf_files:
            try:
                for raw in cf.read_text(encoding="utf-8", errors="ignore").splitlines():
                    vm = re.match(r"^\s*\$([A-Za-z0-9_]+)\s*=\s*(.+?)\s*$", raw)
                    if vm:
                        hypr_vars["$" + vm.group(1)] = vm.group(2).strip()
            except OSError:
                pass

        exec_pattern = re.compile(
            r"^(?P<comment>#\s*(?:\[disabled\]\s*)?)?"
            r"exec-once\s*=\s*(?P<cmd>.+?)\s*$"
        )

        for cf in conf_files:
            is_dedicated_autostart = "autostart" in cf.name.lower()
            try:
                lines = cf.read_text(encoding="utf-8", errors="ignore").splitlines()
            except OSError:
                continue

            for idx, line in enumerate(lines, start=1):
                stripped = line.strip()
                if not stripped:
                    continue
                m = exec_pattern.match(stripped)
                if not m:
                    continue

                comment_prefix = m.group("comment") or ""
                is_commented = bool(comment_prefix)
                raw_cmd = m.group("cmd").strip()
                if not raw_cmd:
                    continue

                # Avoid picking up stock hyprland.conf commented examples like `# exec-once = $terminal`
                if is_commented and "[disabled]" not in comment_prefix:
                    if not is_dedicated_autostart or "$" in raw_cmd:
                        continue

                # Expand Hyprland $vars for binary/process resolution
                expanded_cmd = raw_cmd
                for k, v in hypr_vars.items():
                    if k in expanded_cmd:
                        expanded_cmd = expanded_cmd.replace(k, v)

                if expanded_cmd.startswith(
                    "systemctl --user import-environment"
                ) or expanded_cmd.startswith("dbus-update-activation-environment"):
                    continue

                is_sys_read_only = not str(cf).startswith(str(HOME) + "/")
                enabled = not is_commented
                clean_exec_cmd = _strip_hypr_exec_rules(expanded_cmd)
                bin_path = _resolve_binary_path(clean_exec_cmd)
                exe_base = os.path.basename(_extract_first_executable(clean_exec_cmd))
                pid = _match_process(exe_base, clean_exec_cmd, procs) if enabled else None

                if not enabled:
                    r_state, r_label = "inactive", "disabled"
                elif pid is not None:
                    r_state, r_label = "running", "active"
                else:
                    r_state, r_label = "inactive", "stopped"

                desc = (
                    _read_omarchy_script_summary(bin_path)
                    or f"Hyprland exec-once ({cf.name})"
                )
                items.append(
                    StartupItem(
                        id=f"hypr-conf:{cf}:{idx}:{raw_cmd}",
                        name=exe_base or raw_cmd,
                        description=desc,
                        command=clean_exec_cmd,
                        source=(
                            SourceKind.HYPRLAND_DEFAULT
                            if is_sys_read_only
                            else SourceKind.HYPRLAND_USER
                        ),
                        enabled=enabled,
                        running_state=r_state,
                        running_label=r_label,
                        config_path=str(cf),
                        binary_path=bin_path,
                        pid=pid,
                        read_only=is_sys_read_only,
                        can_delete=not is_sys_read_only,
                        is_uninstalled=_is_executable_uninstalled(clean_exec_cmd, bin_path),
                        trigger_type="login",
                        line_number=idx,
                        raw_line=line,
                        extra_meta={"hypr_format": "conf"},
                    )
                )

    return items


def _collect_hook_items() -> list[StartupItem]:
    items: list[StartupItem] = []
    hooks_root = HOME / ".config" / "omarchy" / "hooks"
    flat_hook = hooks_root / "post-boot"
    hook_dir = hooks_root / "post-boot.d"

    candidates: list[Path] = []
    if flat_hook.is_file():
        candidates.append(flat_hook)
    if hook_dir.is_dir():
        candidates.extend(sorted(p for p in hook_dir.iterdir() if p.is_file()))

    for path in candidates:
        fname = path.name
        if fname.endswith(".disabled.sample"):
            enabled = False
            clean_name = fname[: -len(".disabled.sample")]
            is_stock_sample = False
        elif fname.endswith(".sample"):
            enabled = False
            clean_name = fname[: -len(".sample")]
            is_stock_sample = True
        else:
            enabled = True
            clean_name = fname
            is_stock_sample = False

        desc = "Post-boot hook script"
        try:
            for ln in path.read_text(encoding="utf-8", errors="ignore").splitlines()[:8]:
                s = ln.strip()
                if s.startswith("#") and not s.startswith("#!"):
                    comment_txt = s.lstrip("#").strip()
                    if comment_txt:
                        desc = comment_txt
                        break
        except OSError:
            pass

        if is_stock_sample:
            desc = f"[sample] {desc}"

        items.append(
            StartupItem(
                id=f"hook:{path}",
                name=clean_name,
                description=desc,
                command=f"bash {path}",
                source=SourceKind.HOOK_POST_BOOT,
                enabled=enabled,
                running_state="oneshot_done" if enabled else "inactive",
                running_label="done" if enabled else "disabled",
                config_path=str(path),
                binary_path="",
                read_only=False,
                can_delete=not is_stock_sample,
                is_vendor_default=is_stock_sample,
                is_uninstalled=not path.is_file(),
                trigger_type="hook",
                extra_meta={"is_stock_sample": "1" if is_stock_sample else "0"},
            )
        )

    return items


def _parse_desktop_file(path: Path) -> dict[str, str]:
    cp = configparser.ConfigParser(interpolation=None, strict=False)
    try:
        cp.read(path, encoding="utf-8")
    except Exception:
        return {}
    if "Desktop Entry" not in cp:
        return {}
    return dict(cp["Desktop Entry"])


def _desktop_app_dirs() -> list[Path]:
    return [
        HOME / ".local" / "share" / "applications",
        HOME / ".local" / "share" / "flatpak" / "exports" / "share" / "applications",
        Path("/var/lib/flatpak/exports/share/applications"),
        Path("/usr/local/share/applications"),
        Path("/usr/share/applications"),
    ]


def _find_app_desktop_path(desktop_id: str) -> str:
    for d in _desktop_app_dirs():
        cand = d / desktop_id
        if cand.is_file():
            return str(cand)
    return ""


def _clean_desktop_exec(exec_raw: str, terminal: bool = False) -> str:
    cmd = re.sub(r"\s+%[fFuUdDnNickvm]\b", "", exec_raw).strip()
    cmd = re.sub(r"\s+--\s*$", "", cmd).strip()
    if terminal and cmd and shutil.which("xdg-terminal-exec"):
        first = os.path.basename(_extract_first_executable(cmd))
        if first not in ("xdg-terminal-exec", "omarchy-launch-tui"):
            cmd = f"xdg-terminal-exec -e {cmd}"
    return cmd


def _collect_xdg_items(procs: list[tuple[int, str, str]]) -> list[StartupItem]:
    sys_dir = Path("/etc/xdg/autostart")
    user_dir = HOME / ".config" / "autostart"

    desktop_ids: set[str] = set()
    if sys_dir.is_dir():
        desktop_ids.update(p.name for p in sys_dir.glob("*.desktop"))
    if user_dir.is_dir():
        desktop_ids.update(p.name for p in user_dir.glob("*.desktop"))

    current_desktops = set(
        d.strip()
        for d in os.environ.get("XDG_CURRENT_DESKTOP", "Hyprland").split(":")
        if d.strip()
    )

    items: list[StartupItem] = []
    gen_units_to_query: dict[str, StartupItem] = {}

    for desktop_id in sorted(desktop_ids):
        sys_path = sys_dir / desktop_id
        usr_path = user_dir / desktop_id
        has_sys = sys_path.is_file()
        has_usr = usr_path.is_file()

        merged: dict[str, str] = {}
        if has_sys:
            merged.update(_parse_desktop_file(sys_path))
        if has_usr:
            merged.update(_parse_desktop_file(usr_path))
        if not merged:
            continue

        if merged.get("x-systemd-skip", "").lower() == "true":
            continue

        only_show = [
            x.strip() for x in merged.get("onlyshowin", "").split(";") if x.strip()
        ]
        not_show = [
            x.strip() for x in merged.get("notshowin", "").split(";") if x.strip()
        ]
        if only_show and not (current_desktops & set(only_show)):
            continue
        if not_show and (current_desktops & set(not_show)):
            continue

        hidden = merged.get("hidden", "").lower() == "true"
        gnome_enabled = merged.get("x-gnome-autostart-enabled", "true").lower() != "false"
        enabled = (not hidden) and gnome_enabled

        name = merged.get("name") or desktop_id.removesuffix(".desktop")
        comment = merged.get("comment") or "XDG autostart entry"
        exec_raw = merged.get("exec", "")
        is_term = merged.get("terminal", "").lower() == "true"
        exec_cmd = _clean_desktop_exec(exec_raw, terminal=is_term)
        omastart_managed = merged.get("x-omastart-managed", "").lower() == "true"
        app_desktop_path = _find_app_desktop_path(desktop_id)

        bin_path = _resolve_binary_path(exec_cmd)
        exe_base = os.path.basename(_extract_first_executable(exec_cmd))
        pid = _match_process(exe_base, exec_cmd, procs) if enabled else None

        if not enabled:
            r_state, r_label = "inactive", "disabled"
        elif pid is not None:
            r_state, r_label = "running", "active"
        elif omastart_managed:
            r_state, r_label = "inactive", "on login"
        else:
            r_state, r_label = "oneshot_done", "done"

        cfg_path = str(usr_path if has_usr else sys_path)
        item = StartupItem(
            id=f"xdg:{desktop_id}",
            name=name,
            description=comment,
            command=exec_cmd,
            source=SourceKind.XDG_AUTOSTART,
            enabled=enabled,
            running_state=r_state,
            running_label=r_label,
            config_path=cfg_path,
            binary_path=bin_path,
            unit_name=desktop_id,
            pid=pid,
            read_only=False,
            can_delete=(has_usr and not has_sys),
            is_vendor_default=(not enabled and not has_usr),
            is_uninstalled=_is_executable_uninstalled(exec_cmd, bin_path),
            trigger_type="login",
            extra_meta={
                "desktop_id": desktop_id,
                "has_sys": "1" if has_sys else "0",
                "has_usr": "1" if has_usr else "0",
                "sys_path": str(sys_path) if has_sys else "",
                "app_desktop_path": app_desktop_path,
                "omastart_managed": "1" if omastart_managed else "0",
                "icon": merged.get("icon", "").strip(),
            },
        )
        items.append(item)
        if enabled:
            stem = desktop_id.removesuffix(".desktop").replace("-", r"\x2d")
            gen_units_to_query[f"app-{stem}@autostart.service"] = item

    if gen_units_to_query:
        rc, out, _ = _run_cmd(
            [
                "systemctl",
                "--user",
                "show",
                "--property=Id,InactiveExitTimestampMonotonic,ActiveEnterTimestampMonotonic,ExecMainStartTimestampMonotonic,ExecMainExitTimestampMonotonic",
                "--no-pager",
            ]
            + list(gen_units_to_query.keys()),
            timeout=2.0,
        )
        if rc == 0:
            for block in out.strip().split("\n\n"):
                info = dict(
                    ln.split("=", 1) for ln in block.splitlines() if "=" in ln
                )
                uid = info.get("Id", "")
                if uid in gen_units_to_query:
                    gen_units_to_query[uid].boot_time_ms = _compute_monotonic_ms(info)

    return items


def _find_unit_file_on_disk(unit_name: str, user: bool) -> str:
    search_dirs = (
        [
            HOME / ".config" / "systemd" / "user",
            Path("/etc/systemd/user"),
            Path("/usr/lib/systemd/user"),
        ]
        if user
        else [
            Path("/etc/systemd/system"),
            Path("/usr/lib/systemd/system"),
        ]
    )
    for d in search_dirs:
        p = d / unit_name
        if p.is_file() or p.is_symlink():
            return str(p)
    return ""


def _has_user_or_etc_override(unit_name: str, user: bool) -> bool:
    """Return True if unit has any file/symlink in ~/.config/systemd or /etc/systemd."""
    dirs = (
        [HOME / ".config" / "systemd" / "user", Path("/etc/systemd/user")]
        if user
        else [Path("/etc/systemd/system")]
    )
    for d in dirs:
        if (d / unit_name).exists() or (d / unit_name).is_symlink():
            return True
    return False


def _read_unit_file_fast(unit_path: str, unit_name: str) -> tuple[str, str, str]:
    if not unit_path or not os.path.isfile(unit_path):
        return unit_name, unit_name, ""
    desc = unit_name
    exec_cmd = unit_name
    try:
        with open(unit_path, "r", encoding="utf-8", errors="ignore") as fh:
            for line in fh:
                s = line.strip()
                if s.startswith("Description=") and desc == unit_name:
                    desc = s.split("=", 1)[1].strip() or unit_name
                elif s.startswith("ExecStart=") and exec_cmd == unit_name:
                    val = s.split("=", 1)[1].strip()
                    val = re.sub(r"^[-@:+!]+\s*", "", val)
                    if val:
                        exec_cmd = val
    except OSError:
        pass
    return desc, exec_cmd, _resolve_binary_path(exec_cmd)


def _collect_systemd_items(user: bool) -> list[StartupItem]:
    base_cmd = ["systemctl", "--user"] if user else ["systemctl"]
    types = "service,socket,timer"

    rc, out, _ = _run_cmd(
        base_cmd
        + [
            "list-unit-files",
            f"--type={types}",
            "--state=enabled,enabled-runtime,disabled,masked,masked-runtime",
            "--output=json",
            "--no-pager",
        ],
        timeout=4.0,
    )
    if rc != 0 or not out.strip():
        return []

    try:
        unit_files = json.loads(out)
    except json.JSONDecodeError:
        return []

    unit_states: dict[str, str] = {}
    for entry in unit_files:
        ufile = entry.get("unit_file", "")
        state = entry.get("state", "")
        if not ufile or "@." in ufile:
            continue
        unit_states[ufile] = state

    if not unit_states:
        return []

    loaded_active: dict[str, dict[str, str]] = {}
    rc_l, out_l, _ = _run_cmd(
        base_cmd + ["list-units", f"--type={types}", "--all", "--output=json", "--no-pager"],
        timeout=3.0,
    )
    if rc_l == 0 and out_l.strip():
        try:
            for u in json.loads(out_l):
                uid = u.get("unit", "")
                if uid:
                    loaded_active[uid] = u
        except json.JSONDecodeError:
            pass

    units_to_inspect = [
        u
        for u, st in unit_states.items()
        if st in ("enabled", "enabled-runtime")
        or loaded_active.get(u, {}).get("active") in ("active", "failed", "activating")
    ]
    props = (
        "Id,Description,FragmentPath,UnitFileState,ActiveState,SubState,"
        "MainPID,ExecStart,Type,Result,TriggeredBy,"
        "InactiveExitTimestampMonotonic,ActiveEnterTimestampMonotonic,"
        "ExecMainStartTimestampMonotonic,ExecMainExitTimestampMonotonic"
    )
    details_by_id: dict[str, dict[str, str]] = {}
    if units_to_inspect:
        rc_s, out_s, _ = _run_cmd(
            base_cmd + ["show", f"--property={props}", "--no-pager"] + units_to_inspect,
            timeout=4.0,
        )
        if rc_s == 0:
            for block in out_s.strip().split("\n\n"):
                info: dict[str, str] = {}
                for line in block.splitlines():
                    if "=" in line:
                        k, v = line.split("=", 1)
                        info[k] = v
                uid = info.get("Id")
                if uid:
                    details_by_id[uid] = info

    items: list[StartupItem] = []
    source = SourceKind.SYSTEMD_USER if user else SourceKind.SYSTEMD_SYSTEM

    for unit_name in sorted(unit_states.keys()):
        u_state = unit_states[unit_name]
        is_masked = u_state in ("masked", "masked-runtime")
        enabled = u_state in ("enabled", "enabled-runtime")
        info = details_by_id.get(unit_name)

        triggered_by = ""
        if info:
            desc = (
                info.get("Description")
                if not is_masked
                else ""
            ) or unit_name
            frag_path = info.get("FragmentPath", "") or _find_unit_file_on_disk(
                unit_name, user
            )
            active_state = info.get("ActiveState", "inactive")
            sub_state = info.get("SubState", "")
            service_type = info.get("Type", "")
            result = info.get("Result", "")
            triggered_by = info.get("TriggeredBy", "").strip()
            main_pid_str = info.get("MainPID", "0")
            pid = (
                int(main_pid_str)
                if main_pid_str.isdigit() and int(main_pid_str) > 0
                else None
            )
            raw_exec = info.get("ExecStart", "")
            exec_cmd = unit_name
            m_argv = re.search(r"argv\[\]=([^;]+)", raw_exec)
            m_path = re.search(r"path=([^;]+)", raw_exec)
            if m_argv:
                exec_cmd = m_argv.group(1).strip()
            elif m_path:
                exec_cmd = m_path.group(1).strip()
            bin_path = (
                m_path.group(1).strip() if m_path else _resolve_binary_path(exec_cmd)
            )
            boot_ms = _compute_monotonic_ms(info) if (enabled or active_state == "active") else None
        else:
            # For masked units, FragmentPath may be /dev/null; check underlying vendor unit for description
            vendor_dir = Path("/usr/lib/systemd/user" if user else "/usr/lib/systemd/system")
            vendor_unit = str(vendor_dir / unit_name) if (vendor_dir / unit_name).is_file() else ""
            frag_path = _find_unit_file_on_disk(unit_name, user) or vendor_unit
            desc, exec_cmd, bin_path = _read_unit_file_fast(vendor_unit or frag_path, unit_name)
            active_state = "inactive"
            sub_state = "dead"
            service_type = ""
            result = ""
            pid = None
            boot_ms = None

        # Detect companion socket/timer trigger even when service isn't currently loaded
        if not triggered_by and unit_name.endswith(".service"):
            stem = unit_name[:-8]
            companions = [
                f"{stem}.{ext}"
                for ext in ("socket", "timer")
                if unit_states.get(f"{stem}.{ext}") in ("enabled", "enabled-runtime")
            ]
            if companions:
                triggered_by = " ".join(companions)

        if is_masked:
            r_state = "inactive"
            r_label = "masked"
        elif active_state == "failed" or (
            result and result not in ("success", "done", "")
        ):
            r_state = "failed"
            r_label = "failed"
        elif active_state == "active" and sub_state in (
            "running",
            "listening",
            "waiting",
        ):
            r_state = "running"
            if sub_state == "listening":
                r_label = "listening"
            elif sub_state == "waiting":
                r_label = "timer"
            else:
                r_label = "active"
        elif active_state == "active" and sub_state == "exited":
            r_state = "oneshot_done"
            r_label = "exited"
        elif not enabled:
            # Socket-activated services can be disabled as a unit file yet actively running right now!
            if active_state == "active":
                r_state = "running"
                r_label = "active (socket)"
            else:
                r_state = "inactive"
                r_label = "disabled"
        elif service_type == "oneshot" and result == "success":
            r_state = "oneshot_done"
            r_label = "done"
        else:
            r_state = "inactive"
            r_label = "inactive"

        pretty_name = unit_name.removesuffix(".service")
        is_vendor_default = (
            not enabled
            and not is_masked
            and r_state != "running"
            and r_state != "failed"
            and not _has_user_or_etc_override(unit_name, user)
        )

        if unit_name.endswith(".socket") or bool(triggered_by):
            t_type = "on-demand"
        elif unit_name.endswith(".timer"):
            t_type = "scheduled"
        else:
            t_type = "boot"

        items.append(
            StartupItem(
                id=f"{source.value}:{unit_name}",
                name=pretty_name,
                description=desc,
                command=exec_cmd,
                source=source,
                enabled=enabled,
                running_state=r_state,
                running_label=r_label,
                config_path=frag_path or unit_name,
                binary_path=bin_path,
                unit_name=unit_name,
                boot_time_ms=boot_ms,
                pid=pid,
                read_only=False,
                is_critical=(unit_name in CRITICAL_UNITS),
                is_masked=is_masked,
                is_vendor_default=is_vendor_default,
                is_uninstalled=False,
                trigger_type=t_type,
                triggered_by=triggered_by,
                extra_meta={
                    "unit_state": u_state,
                    "active_state": active_state,
                    "sub_state": sub_state,
                    "result": result,
                },
            )
        )

    return items


def _format_bytes(size_str: str) -> str:
    try:
        n = int(size_str)
    except ValueError:
        return size_str
    if n >= 1024 * 1024:
        return f"{n / (1024 * 1024):.2f} MiB"
    if n >= 1024:
        return f"{n / 1024:.1f} KiB"
    return f"{n} B"


def _parse_pacman_desc(pkg_dir: Path) -> Optional[PackageInfo]:
    desc_file = pkg_dir / "desc"
    if not desc_file.is_file():
        return None
    sections: dict[str, list[str]] = {}
    current_key = ""
    try:
        for raw in desc_file.read_text(encoding="utf-8", errors="ignore").splitlines():
            s = raw.strip()
            if not s:
                current_key = ""
                continue
            if s.startswith("%") and s.endswith("%"):
                current_key = s
                sections[current_key] = []
            elif current_key:
                sections[current_key].append(s)
    except OSError:
        return None

    name = (sections.get("%NAME%") or [""])[0]
    if not name:
        return None
    reason_code = (sections.get("%REASON%") or ["0"])[0]
    reason = "dependency" if reason_code == "1" else "explicit"
    desc_text = "" if name == "omarchy" else (sections.get("%DESC%") or [""])[0]
    return PackageInfo(
        name=name,
        version=(sections.get("%VERSION%") or [""])[0],
        description=desc_text,
        installed_size=_format_bytes((sections.get("%SIZE%") or [""])[0]),
        url=(sections.get("%URL%") or [""])[0],
        install_reason=reason,
    )


def _enrich_packages(items: list[StartupItem]) -> None:
    target_rel_paths: set[str] = set()
    item_probes: list[tuple[StartupItem, list[str]]] = []

    for item in items:
        candidates: list[str] = []
        raw_probes = [
            item.extra_meta.get("sys_path", ""),
            item.extra_meta.get("app_desktop_path", ""),
            item.binary_path,
            item.config_path,
        ]
        # For masked units where config_path points to /dev/null, also check /usr/lib/systemd/...
        if item.unit_name and item.source in (SourceKind.SYSTEMD_USER, SourceKind.SYSTEMD_SYSTEM):
            sub = "user" if item.source == SourceKind.SYSTEMD_USER else "system"
            raw_probes.append(f"/usr/lib/systemd/{sub}/{item.unit_name}")

        for p in raw_probes:
            if p and p.startswith("/") and os.path.exists(p):
                if p == "/dev/null" or p.startswith(str(HOME) + "/"):
                    continue
                if p not in candidates:
                    candidates.append(p)
                real_p = os.path.realpath(p)
                if (
                    real_p != p
                    and real_p != "/dev/null"
                    and not real_p.startswith(str(HOME) + "/")
                    and real_p not in candidates
                ):
                    candidates.append(real_p)
        for c in candidates:
            target_rel_paths.add(c.lstrip("/"))
        item_probes.append((item, candidates))

    if not target_rel_paths:
        return

    local_db = Path("/var/lib/pacman/local")
    rel_to_pkg_dir: dict[str, Path] = {}
    if local_db.is_dir():
        remaining = set(target_rel_paths)
        for entry in local_db.iterdir():
            if not remaining:
                break
            files_path = entry / "files"
            if not files_path.is_file():
                continue
            try:
                content = files_path.read_text(encoding="utf-8", errors="ignore")
            except OSError:
                continue
            for ln in content.splitlines():
                if ln in remaining:
                    rel_to_pkg_dir[ln] = entry
                    remaining.discard(ln)

    pkg_cache: dict[Path, Optional[PackageInfo]] = {}
    for item, candidates in item_probes:
        for cand in candidates:
            rel = cand.lstrip("/")
            pkg_dir = rel_to_pkg_dir.get(rel)
            if pkg_dir is not None:
                if pkg_dir not in pkg_cache:
                    pkg_cache[pkg_dir] = _parse_pacman_desc(pkg_dir)
                item.package = pkg_cache[pkg_dir]
                if item.package:
                    break


def _load_launcher_hidden_stems() -> set[str]:
    hides_file = OMARCHY_PATH / "default" / "omarchy" / "launcher.hides"
    hidden_ids: set[str] = {"omastart", "io.omarchy.startup"}
    if hides_file.is_file():
        try:
            for ln in hides_file.read_text(encoding="utf-8", errors="ignore").splitlines():
                stem = ln.strip().removesuffix(".desktop")
                if stem:
                    hidden_ids.add(stem)
        except OSError:
            pass
    return hidden_ids


_MULTI_APP_WRAPPERS = {
    "libreoffice",
    "soffice",
    "xdg-terminal-exec",
    "omarchy-launch-webapp",
    "omarchy-launch-or-focus-webapp",
    "omarchy-launch-tui",
    "omarchy-launch-or-focus",
    "omarchy-shell",
    "bash",
    "sh",
    "zsh",
    "fish",
    "env",
    "flatpak",
    "python",
    "python3",
}


def _collect_desktop_app_items(
    procs: list[tuple[int, str, str]],
    existing_items: list[StartupItem],
) -> list[StartupItem]:
    """Collect installed desktop applications not yet registered as startup entries."""
    hidden_ids = _load_launcher_hidden_stems()
    current_desktops = set(
        d.strip()
        for d in os.environ.get("XDG_CURRENT_DESKTOP", "Hyprland").split(":")
        if d.strip()
    )

    existing_xdg_ids: set[str] = set()
    existing_cmds: set[str] = set()
    existing_exes: set[str] = set()

    for it in existing_items:
        if it.source == SourceKind.XDG_AUTOSTART:
            if it.unit_name:
                existing_xdg_ids.add(it.unit_name)
            did = it.extra_meta.get("desktop_id", "")
            if did:
                existing_xdg_ids.add(did)
        if it.source in (
            SourceKind.HYPRLAND_DEFAULT,
            SourceKind.HYPRLAND_USER,
            SourceKind.XDG_AUTOSTART,
        ):
            cmd_norm = it.command.strip().lower()
            if cmd_norm:
                existing_cmds.add(cmd_norm)
            exe = os.path.basename(_extract_first_executable(it.command)).lower()
            if exe and exe not in _MULTI_APP_WRAPPERS:
                existing_exes.add(exe)

    items: list[StartupItem] = []
    seen_ids: set[str] = set()
    seen_names: set[str] = set()

    for d in _desktop_app_dirs():
        if not d.is_dir():
            continue
        for p in sorted(d.glob("*.desktop")):
            stem = p.stem
            if p.name in seen_ids or stem in hidden_ids:
                continue
            seen_ids.add(p.name)
            if p.name in existing_xdg_ids:
                continue

            entry = _parse_desktop_file(p)
            if not entry:
                continue
            if entry.get("nodisplay", "").lower() == "true":
                continue
            if entry.get("hidden", "").lower() == "true":
                continue

            only_show = [
                x.strip() for x in entry.get("onlyshowin", "").split(";") if x.strip()
            ]
            not_show = [
                x.strip() for x in entry.get("notshowin", "").split(";") if x.strip()
            ]
            if only_show and not (current_desktops & set(only_show)):
                continue
            if not_show and (current_desktops & set(not_show)):
                continue

            name = entry.get("name", "").strip()
            exec_raw = entry.get("exec", "").strip()
            if not name or not exec_raw:
                continue

            is_term = entry.get("terminal", "").lower() == "true"
            clean_cmd = _clean_desktop_exec(exec_raw, terminal=is_term)
            if not clean_cmd or name.lower() in seen_names:
                continue

            exe_base = os.path.basename(_extract_first_executable(clean_cmd))
            if clean_cmd.lower() in existing_cmds:
                continue
            if exe_base and exe_base.lower() not in _MULTI_APP_WRAPPERS and exe_base.lower() in existing_exes:
                continue

            seen_names.add(name.lower())
            bin_path = _resolve_binary_path(clean_cmd)
            if _is_executable_uninstalled(clean_cmd, bin_path):
                continue

            pid = _match_process(exe_base, clean_cmd, procs)
            comment = entry.get("comment", "").strip() or "Installed desktop application"

            items.append(
                StartupItem(
                    id=f"xdg:{p.name}",
                    name=name,
                    description=comment,
                    command=clean_cmd,
                    source=SourceKind.DESKTOP_APP,
                    enabled=False,
                    running_state="inactive",
                    running_label="off",
                    config_path=str(p),
                    binary_path=bin_path,
                    unit_name=p.name,
                    pid=pid,
                    read_only=False,
                    can_delete=False,
                    is_uninstalled=False,
                    trigger_type="login",
                    extra_meta={
                        "desktop_id": p.name,
                        "app_desktop_path": str(p),
                        "icon": entry.get("icon", "").strip(),
                    },
                )
            )

    return items


def collect_all_startup_data() -> BootSummary:
    with ThreadPoolExecutor(max_workers=4) as pool:
        f_summary = pool.submit(_collect_boot_summary)
        f_procs = pool.submit(_collect_running_processes)
        f_usr_sysd = pool.submit(_collect_systemd_items, True)
        f_sys_sysd = pool.submit(_collect_systemd_items, False)

        procs = f_procs.result()
        f_hypr = pool.submit(_collect_hyprland_items, procs)
        f_hooks = pool.submit(_collect_hook_items)
        f_xdg = pool.submit(_collect_xdg_items, procs)

        summary = f_summary.result()
        items: list[StartupItem] = []
        items.extend(f_hypr.result())
        items.extend(f_hooks.result())
        items.extend(f_xdg.result())
        items.extend(f_usr_sysd.result())
        items.extend(f_sys_sysd.result())

    items.extend(_collect_desktop_app_items(procs, items))
    _enrich_packages(items)
    summary.items = items

    # Compute top slowest units on this boot for the Boot Breakdown modal
    timed = [it for it in items if it.boot_time_ms is not None and it.boot_time_ms >= 10.0]
    timed.sort(key=lambda x: x.boot_time_ms or 0.0, reverse=True)
    summary.slowest_units = [
        {
            "id": it.id,
            "name": it.name,
            "description": it.description or it.command,
            "sourceLabel": it.source.label,
            "pkgName": it.package.name if it.package else "",
            "bootTimeMs": it.boot_time_ms,
            "bootTimeText": it.boot_time_formatted,
        }
        for it in timed[:8]
    ]
    summary.critical_chain = _collect_critical_chain()
    return summary


def list_installed_desktop_apps() -> list[dict[str, str]]:
    """Pure-Python scan of launchable installed packages (.desktop + pacman owner)."""
    hidden_ids = _load_launcher_hidden_stems()
    app_dirs = _desktop_app_dirs()
    raw_entries: list[tuple[Path, dict[str, str]]] = []
    seen_ids: set[str] = set()
    seen_names: set[str] = set()
    rel_lookup_paths: set[str] = set()

    for d in app_dirs:
        if not d.is_dir():
            continue
        for p in sorted(d.glob("*.desktop")):
            stem = p.stem
            if p.name in seen_ids or stem in hidden_ids:
                continue
            seen_ids.add(p.name)
            entry = _parse_desktop_file(p)
            if not entry:
                continue
            if entry.get("nodisplay", "").lower() == "true":
                continue
            if entry.get("hidden", "").lower() == "true":
                continue
            name = entry.get("name", "").strip()
            exec_raw = entry.get("exec", "").strip()
            if not name or not exec_raw:
                continue
            is_term = entry.get("terminal", "").lower() == "true"
            clean_cmd = _clean_desktop_exec(exec_raw, terminal=is_term)
            if not clean_cmd or name.lower() in seen_names:
                continue
            seen_names.add(name.lower())
            exe_base = os.path.basename(_extract_first_executable(clean_cmd))
            raw_entries.append((p, {
                "id": p.name,
                "name": name,
                "description": entry.get("comment", "").strip(),
                "command": clean_cmd,
                "exeBase": exe_base,
            }))
            if not str(p).startswith(str(HOME) + "/"):
                rel_lookup_paths.add(str(p).lstrip("/"))
            sys_desktop = Path("/usr/share/applications") / p.name
            if sys_desktop.is_file():
                rel_lookup_paths.add(str(sys_desktop).lstrip("/"))

    rel_to_pkg: dict[str, str] = {}
    local_db = Path("/var/lib/pacman/local")
    if rel_lookup_paths and local_db.is_dir():
        remaining = set(rel_lookup_paths)
        for pkg_dir in local_db.iterdir():
            if not remaining:
                break
            files_path = pkg_dir / "files"
            if not files_path.is_file():
                continue
            try:
                content = files_path.read_text(encoding="utf-8", errors="ignore")
            except OSError:
                continue
            for ln in content.splitlines():
                if ln in remaining:
                    info = _parse_pacman_desc(pkg_dir)
                    if info:
                        rel_to_pkg[ln] = info.name
                    remaining.discard(ln)

    apps: list[dict[str, str]] = []
    for p, item in raw_entries:
        pkg_name = (
            rel_to_pkg.get(str(p).lstrip("/"))
            or rel_to_pkg.get(f"usr/share/applications/{p.name}")
            or ""
        )
        item["pkgName"] = pkg_name
        apps.append(item)

    apps.sort(key=lambda a: (a["pkgName"] or a["name"]).lower())
    return apps

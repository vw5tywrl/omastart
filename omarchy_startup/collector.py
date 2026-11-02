from __future__ import annotations

from concurrent.futures import ThreadPoolExecutor
import configparser
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


def _compute_monotonic_ms(info: dict[str, str]) -> Optional[float]:
    try:
        t_start = int(info.get("InactiveExitTimestampMonotonic", "0") or "0")
        t_end = int(info.get("ActiveEnterTimestampMonotonic", "0") or "0")
        if t_start > 0 and t_end >= t_start:
            ms = (t_end - t_start) / 1000.0
            return ms if ms >= 0.5 else None
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
    if lines:
        first = lines[0]
        m_total = re.search(r"=\s*([0-9a-zA-Z.\s]+)$", first)
        if m_total:
            summary.total_time = m_total.group(1).strip()
        m_user = re.search(r"([0-9a-zA-Z.\s]+?)\s*\(userspace\)", first)
        if m_user:
            summary.userspace_time = m_user.group(1).strip()
    if len(lines) > 1:
        m_graph = re.search(r"after\s+([0-9a-zA-Z.\s]+?)\s+in userspace", lines[1])
        if m_graph:
            summary.graphical_time = m_graph.group(1).strip()
    return summary


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


def _extract_first_executable(command: str) -> str:
    cmd = command.strip()
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
    skip_wrappers = {"uwsm-app", "--", "env", "nohup", "setsid", "sh", "bash", "-c"}
    idx = 0
    while idx < len(tokens):
        tok = tokens[idx]
        if "=" in tok and not tok.startswith("/"):
            idx += 1
            continue
        if tok in skip_wrappers:
            idx += 1
            continue
        return tok
    return tokens[0] if tokens else ""


def _resolve_binary_path(command: str) -> str:
    exe = _extract_first_executable(command)
    if not exe:
        return ""
    if exe.startswith("/"):
        return exe if os.path.exists(exe) else ""
    return shutil.which(exe) or ""


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


def _collect_hyprland_items(procs: list[tuple[int, str, str]]) -> list[StartupItem]:
    items: list[StartupItem] = []

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
                r_state, r_label = "running", f"active · {pid}"
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
                    line_number=idx,
                    raw_line=line,
                )
            )

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
                r_state, r_label = "running", f"active · {pid}"
            else:
                r_state, r_label = "inactive", "stopped"

            desc = (
                _read_omarchy_script_summary(bin_path)
                or f"User autostart ({m.group('func')})"
            )
            items.append(
                StartupItem(
                    id=f"hypr-user:{idx}:{cmd}",
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
                    line_number=idx,
                    raw_line=line,
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
        exec_cmd = merged.get("exec", "")

        bin_path = _resolve_binary_path(exec_cmd)
        exe_base = os.path.basename(_extract_first_executable(exec_cmd))
        pid = _match_process(exe_base, exec_cmd, procs) if enabled else None

        if not enabled:
            r_state, r_label = "inactive", "disabled"
        elif pid is not None:
            r_state, r_label = "running", f"active · {pid}"
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
            extra_meta={
                "desktop_id": desktop_id,
                "has_sys": "1" if has_sys else "0",
                "has_usr": "1" if has_usr else "0",
                "sys_path": str(sys_path) if has_sys else "",
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
                "--property=Id,InactiveExitTimestampMonotonic,ActiveEnterTimestampMonotonic",
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
        if p.is_file():
            return str(p)
    return ""


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
    types = "service,socket,timer" if user else "service,timer"

    rc, out, _ = _run_cmd(
        base_cmd
        + [
            "list-unit-files",
            f"--type={types}",
            "--state=enabled,enabled-runtime,disabled",
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
        "MainPID,ExecStart,Type,Result,InactiveExitTimestampMonotonic,ActiveEnterTimestampMonotonic"
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
        enabled = u_state in ("enabled", "enabled-runtime")
        info = details_by_id.get(unit_name)

        if info:
            desc = info.get("Description") or unit_name
            frag_path = info.get("FragmentPath", "") or _find_unit_file_on_disk(
                unit_name, user
            )
            active_state = info.get("ActiveState", "inactive")
            sub_state = info.get("SubState", "")
            service_type = info.get("Type", "")
            result = info.get("Result", "")
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
            boot_ms = _compute_monotonic_ms(info) if enabled else None
        else:
            frag_path = _find_unit_file_on_disk(unit_name, user)
            desc, exec_cmd, bin_path = _read_unit_file_fast(frag_path, unit_name)
            active_state = "inactive"
            sub_state = "dead"
            service_type = ""
            result = ""
            pid = None
            boot_ms = None

        if active_state == "failed" or (
            result and result not in ("success", "done", "")
        ):
            r_state = "failed"
            r_label = f"failed · {sub_state or result}"
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
            elif pid:
                r_label = f"active · {pid}"
            else:
                r_label = "active"
        elif active_state == "active" and sub_state == "exited":
            r_state = "oneshot_done"
            r_label = "exited"
        elif not enabled:
            r_state = "inactive"
            r_label = "disabled"
        elif service_type == "oneshot" and result == "success":
            r_state = "oneshot_done"
            r_label = "done"
        else:
            r_state = "inactive"
            r_label = "inactive"

        pretty_name = unit_name.removesuffix(".service")

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
                extra_meta={
                    "unit_state": u_state,
                    "active_state": active_state,
                    "sub_state": sub_state,
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
            item.binary_path,
            item.extra_meta.get("sys_path", ""),
            item.config_path,
        ]
        for p in raw_probes:
            if p and p.startswith("/") and os.path.exists(p):
                if not p.startswith(str(HOME) + "/"):
                    if p not in candidates:
                        candidates.append(p)
                    real_p = os.path.realpath(p)
                    if (
                        real_p != p
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

    _enrich_packages(items)
    summary.items = items
    return summary


def list_installed_desktop_apps() -> list[dict[str, str]]:
    """Pure-Python scan of launchable installed packages (.desktop + pacman owner)."""
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

    app_dirs = [
        HOME / ".local" / "share" / "applications",
        Path("/usr/local/share/applications"),
        Path("/usr/share/applications"),
    ]
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
            clean_cmd = re.sub(r"\s+%[fFuUdDnNickvm]\b", "", exec_raw).strip()
            if not clean_cmd or name.lower() in seen_names:
                continue
            seen_names.add(name.lower())
            raw_entries.append((p, {
                "id": p.name,
                "name": name,
                "description": entry.get("comment", "").strip(),
                "command": clean_cmd,
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

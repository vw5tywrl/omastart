from __future__ import annotations

from dataclasses import dataclass, field
from enum import Enum
from typing import Optional


class SourceKind(str, Enum):
    HYPRLAND_DEFAULT = "hyprland-default"
    HYPRLAND_USER = "hyprland-user"
    HOOK_POST_BOOT = "hook-post-boot"
    XDG_AUTOSTART = "xdg-autostart"
    SYSTEMD_USER = "systemd-user"
    SYSTEMD_SYSTEM = "systemd-system"
    DESKTOP_APP = "desktop-app"

    @property
    def label(self) -> str:
        return {
            SourceKind.HYPRLAND_DEFAULT: "Hyprland · Core",
            SourceKind.HYPRLAND_USER: "Hyprland · User",
            SourceKind.HOOK_POST_BOOT: "Post-Boot Hook",
            SourceKind.XDG_AUTOSTART: "XDG Autostart",
            SourceKind.SYSTEMD_USER: "Systemd · User",
            SourceKind.SYSTEMD_SYSTEM: "Systemd · System",
            SourceKind.DESKTOP_APP: "Desktop Application",
        }[self]

    @property
    def short_tag(self) -> str:
        return {
            SourceKind.HYPRLAND_DEFAULT: "hypr",
            SourceKind.HYPRLAND_USER: "hypr",
            SourceKind.HOOK_POST_BOOT: "hook",
            SourceKind.XDG_AUTOSTART: "xdg",
            SourceKind.SYSTEMD_USER: "user",
            SourceKind.SYSTEMD_SYSTEM: "sys",
            SourceKind.DESKTOP_APP: "app",
        }[self]

    @property
    def category_group(self) -> str:
        if self in (
            SourceKind.HYPRLAND_DEFAULT,
            SourceKind.HYPRLAND_USER,
            SourceKind.HOOK_POST_BOOT,
        ):
            return "hyprland"
        if self in (SourceKind.XDG_AUTOSTART, SourceKind.DESKTOP_APP):
            return "xdg"
        if self == SourceKind.SYSTEMD_USER:
            return "systemd-user"
        return "systemd-system"

    @property
    def sort_rank(self) -> int:
        return {
            SourceKind.HYPRLAND_USER: 0,
            SourceKind.HYPRLAND_DEFAULT: 1,
            SourceKind.HOOK_POST_BOOT: 2,
            SourceKind.XDG_AUTOSTART: 3,
            SourceKind.SYSTEMD_USER: 4,
            SourceKind.SYSTEMD_SYSTEM: 5,
            SourceKind.DESKTOP_APP: 6,
        }[self]


@dataclass
class PackageInfo:
    name: str
    version: str = ""
    description: str = ""
    installed_size: str = ""
    url: str = ""
    install_reason: str = ""


@dataclass
class StartupItem:
    id: str
    name: str
    description: str
    command: str
    source: SourceKind
    enabled: bool
    running_state: str  # "running" | "oneshot_done" | "inactive" | "failed"
    running_label: str
    config_path: str
    binary_path: str = ""
    unit_name: str = ""
    package: Optional[PackageInfo] = None
    boot_time_ms: Optional[float] = None
    pid: Optional[int] = None
    read_only: bool = False
    read_only_reason: str = ""
    can_delete: bool = False
    is_critical: bool = False
    is_masked: bool = False
    is_vendor_default: bool = False
    is_uninstalled: bool = False
    trigger_type: str = "boot"
    triggered_by: str = ""
    line_number: Optional[int] = None
    raw_line: str = ""
    extra_meta: dict[str, str] = field(default_factory=dict)

    @property
    def package_key(self) -> str:
        if self.package and self.package.name:
            return self.package.name
        if self.source in (SourceKind.HYPRLAND_USER, SourceKind.HOOK_POST_BOOT):
            return "user-custom"
        return "local"

    @property
    def boot_time_formatted(self) -> str:
        if self.boot_time_ms is None:
            return ""
        if self.boot_time_ms >= 1000.0:
            return f"{self.boot_time_ms / 1000.0:.2f}s"
        return f"{int(round(self.boot_time_ms))}ms"

    def to_ui_dict(self) -> dict:
        return {
            "id": self.id,
            "name": self.name,
            "description": self.description,
            "command": self.command,
            "source": self.source.value,
            "sourceLabel": self.source.label,
            "sourceTag": self.source.short_tag,
            "category": self.source.category_group,
            "sortRank": self.source.sort_rank,
            "enabled": self.enabled,
            "runningState": self.running_state,
            "runningLabel": self.running_label,
            "configPath": self.config_path,
            "binaryPath": self.binary_path,
            "unitName": self.unit_name,
            "pkgKey": self.package_key,
            "pkgName": self.package.name if self.package else "",
            "pkgVersion": self.package.version if self.package else "",
            "pkgDesc": self.package.description if self.package else "",
            "pkgSize": self.package.installed_size if self.package else "",
            "pkgUrl": self.package.url if self.package else "",
            "pkgReason": self.package.install_reason if self.package else "",
            "bootTimeMs": self.boot_time_ms if self.boot_time_ms is not None else -1,
            "bootTimeText": self.boot_time_formatted,
            "pid": self.pid or 0,
            "readOnly": self.read_only,
            "readOnlyReason": self.read_only_reason,
            "canDelete": self.can_delete,
            "isCritical": self.is_critical,
            "isMasked": self.is_masked,
            "isVendorDefault": self.is_vendor_default,
            "isUninstalled": self.is_uninstalled,
            "triggerType": self.trigger_type,
            "triggeredBy": self.triggered_by,
            "lineNumber": self.line_number or 0,
            "extraMeta": self.extra_meta,
        }


@dataclass
class BootSummary:
    total_time: str = "—"
    userspace_time: str = "—"
    graphical_time: str = "—"
    raw_breakdown: str = ""
    stages: list[dict[str, object]] = field(default_factory=list)
    slowest_units: list[dict[str, object]] = field(default_factory=list)
    critical_chain: list[dict[str, object]] = field(default_factory=list)
    items: list[StartupItem] = field(default_factory=list)

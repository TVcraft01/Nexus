"""System Info — RAM, CPU, disk, battery, uptime. No AI, no network."""
import re
import platform
import subprocess

NAME = "System Info"
DESCRIPTION = "Check RAM, CPU, disk space, battery, device name, uptime."
CAPABILITIES = ["system_info"]
PATTERNS = [
    r"(how (much|many|mut\S*))\s.{0,20}(ram|memory|storage|disk|space)",
    r"^(ram|memory|cpu|battery|disk|uptime|ip)\b",
    r"(ram|memory|cpu|battery|disk|ip address|uptime).{0,20}(usage|info|level|left|status)?",
    r"(battery|charge).{0,20}(level|percent|left|remaining)?",
    r"(cpu|processor).{0,20}(usage|speed|load|info)?",
    r"(disk|storage|drive).{0,20}(space|free|used|full)?",
    r"(system|device|computer|pc|machine).{0,20}(info|name|specs?|status)",
    r"(uptime|how long.{0,10}running|since when)",
    r"(ip address|local ip|my ip|what.?s my ip)",
    r"(os|operating system|platform|what (os|system))",
]


def handle(text, lower, language, memory=None):
    fr = language.startswith("fr")

    if any(w in lower for w in ["battery", "charge", "batterie"]):
        return {"response": _battery(fr), "intent": "system_info"}
    if any(w in lower for w in ["cpu", "processor", "processeur", "usage"]):
        return {"response": _cpu(fr), "intent": "system_info"}
    if any(w in lower for w in ["disk", "storage", "drive", "space", "disque", "stockage"]):
        return {"response": _disk(fr), "intent": "system_info"}
    if any(w in lower for w in ["ram", "memory", "mémoire"]):
        return {"response": _ram(fr), "intent": "system_info"}
    if any(w in lower for w in ["uptime", "running", "démarré"]):
        return {"response": _uptime(fr), "intent": "system_info"}
    if any(w in lower for w in ["ip", "address", "adresse"]):
        return {"response": _ip(fr), "intent": "system_info"}
    if any(w in lower for w in ["os", "platform", "operating", "système"]):
        return {"response": _os_info(fr), "intent": "system_info"}

    # Full summary
    parts = [_os_info(fr), _ram(fr), _cpu(fr), _disk(fr)]
    return {"response": "\n".join(parts), "intent": "system_info"}


def _ram(fr):
    try:
        import psutil
        vm = psutil.virtual_memory()
        total = vm.total / (1024**3)
        used  = vm.used  / (1024**3)
        pct   = vm.percent
        return (f"RAM : {used:.1f} Go utilisés / {total:.1f} Go ({pct:.0f}%)" if fr
                else f"RAM: {used:.1f} GB used / {total:.1f} GB total ({pct:.0f}%)")
    except ImportError:
        return _proc_meminfo(fr)


def _proc_meminfo(fr):
    try:
        data = {}
        with open("/proc/meminfo") as f:
            for line in f:
                k, v = line.split(":")
                data[k.strip()] = int(v.strip().split()[0])
        total = data.get("MemTotal", 0) // 1024
        avail = data.get("MemAvailable", 0) // 1024
        used  = total - avail
        return (f"RAM : {used} Mo utilisés / {total} Mo" if fr
                else f"RAM: {used} MB used / {total} MB total")
    except Exception:
        return "RAM: unavailable" if not fr else "RAM : indisponible"


def _cpu(fr):
    try:
        import psutil
        pct = psutil.cpu_percent(interval=0.5)
        count = psutil.cpu_count()
        return (f"CPU : {pct:.0f}% ({count} cœurs)" if fr
                else f"CPU: {pct:.0f}% ({count} cores)")
    except ImportError:
        name = platform.processor() or "Unknown"
        return (f"Processeur : {name}" if fr else f"CPU: {name}")


def _disk(fr):
    try:
        import psutil
        d = psutil.disk_usage("/")
        total = d.total / (1024**3)
        used  = d.used  / (1024**3)
        free  = d.free  / (1024**3)
        pct   = d.percent
        return (f"Disque : {used:.1f} Go utilisés / {total:.1f} Go ({free:.1f} Go libres)" if fr
                else f"Disk: {used:.1f} GB used / {total:.1f} GB total ({free:.1f} GB free)")
    except Exception:
        return "Disk: unavailable" if not fr else "Disque : indisponible"


def _battery(fr):
    try:
        import psutil
        b = psutil.sensors_battery()
        if b is None:
            return ("Pas de batterie détectée." if fr else "No battery detected.")
        status = ""
        if b.power_plugged:
            status = " (en charge)" if fr else " (charging)"
        return (f"Batterie : {b.percent:.0f}%{status}" if fr
                else f"Battery: {b.percent:.0f}%{status}")
    except Exception:
        return "Battery: unavailable" if not fr else "Batterie : indisponible"


def _uptime(fr):
    try:
        import psutil, time
        boot = psutil.boot_time()
        seconds = int(time.time() - boot)
        h, r = divmod(seconds, 3600)
        m, s = divmod(r, 60)
        return (f"Uptime : {h}h {m}min" if fr else f"Uptime: {h}h {m}min")
    except Exception:
        try:
            with open("/proc/uptime") as f:
                seconds = int(float(f.read().split()[0]))
            h, r = divmod(seconds, 3600)
            m, _ = divmod(r, 60)
            return (f"Uptime : {h}h {m}min" if fr else f"Uptime: {h}h {m}min")
        except Exception:
            return "Uptime: unavailable"


def _ip(fr):
    import socket
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.connect(("8.8.8.8", 80))
        ip = s.getsockname()[0]
        s.close()
        return (f"IP locale : {ip}" if fr else f"Local IP: {ip}")
    except Exception:
        return "IP: unavailable" if not fr else "IP : indisponible"


def _os_info(fr):
    name = platform.system()
    version = platform.version()
    machine = platform.machine()
    return (f"Système : {name} {machine}" if fr
            else f"OS: {name} {machine}")

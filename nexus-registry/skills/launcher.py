"""Launcher — open apps, websites, folders. No AI, no network requests."""
import re
import subprocess
import platform
import webbrowser
import os

NAME = "Launcher"
DESCRIPTION = "Open apps, websites, folders, and files by name."
CAPABILITIES = ["files_read"]
PATTERNS = [
    r"(open|launch|start|ouvrir?|lance[rz]?|démarre[rz]?).{0,30}",
    r"(go to|navigate to|ouvre le site).{0,40}",
    r"(search|cherche[rz]?).{0,10}(on|sur|with|avec|google|youtube|wikipedia|duckduckgo)",
    r"(show|ouvre[rz]?).{0,20}(folder|directory|dossier|downloads?|desktop|documents?)",
]

SYSTEM = platform.system().lower()

# Common app aliases → command
APP_ALIASES = {
    # Browsers
    "firefox":   ["firefox"],
    "chrome":    ["google-chrome", "chromium", "chromium-browser"],
    "safari":    ["open", "-a", "Safari"],
    "edge":      ["microsoft-edge"],
    # Media
    "spotify":   ["spotify"],
    "vlc":       ["vlc"],
    "mpv":       ["mpv"],
    # Utils
    "terminal":  ["gnome-terminal", "xterm", "konsole"],
    "calculator":["gnome-calculator", "kcalc", "xcalc"],
    "files":     ["nautilus", "dolphin", "thunar", "nemo"],
    "settings":  ["gnome-control-center", "systemsettings5"],
    "notes":     ["gedit", "mousepad", "kate", "xed"],
    "calendar":  ["gnome-calendar", "korganizer"],
    # Code
    "vscode":    ["code"],
    "code":      ["code"],
    "cursor":    ["cursor"],
}

SEARCH_ENGINES = {
    "google":     "https://www.google.com/search?q=",
    "youtube":    "https://www.youtube.com/results?search_query=",
    "wikipedia":  "https://en.wikipedia.org/wiki/Special:Search?search=",
    "duckduckgo": "https://duckduckgo.com/?q=",
    "ddg":        "https://duckduckgo.com/?q=",
}

FOLDER_PATHS = {
    "downloads": os.path.expanduser("~/Downloads"),
    "desktop":   os.path.expanduser("~/Desktop"),
    "documents": os.path.expanduser("~/Documents"),
    "pictures":  os.path.expanduser("~/Pictures"),
    "music":     os.path.expanduser("~/Music"),
    "home":      os.path.expanduser("~"),
    "téléchargements": os.path.expanduser("~/Downloads"),
    "bureau":    os.path.expanduser("~/Desktop"),
}


def handle(text, lower, language, memory=None):
    fr = language.startswith("fr")

    # Web search
    search_match = re.search(
        r"(search|cherche[rz]?).{0,10}(for|pour)?\s+(.+?)\s+(?:on|sur|with|avec)\s+(\w+)",
        lower
    )
    if search_match:
        query   = search_match.group(3).strip()
        engine  = search_match.group(4).strip()
        base    = SEARCH_ENGINES.get(engine, SEARCH_ENGINES["google"])
        url     = base + query.replace(" ", "+")
        webbrowser.open(url)
        return {"response": (f"Searching '{query}' on {engine.capitalize()}." if not fr
                              else f"Recherche '{query}' sur {engine.capitalize()}."),
                "intent": "launcher"}

    # Open URL
    url_match = re.search(r"(open|go to|navigate to|ouvrir?|ouvre[rz]?).{0,10}(https?://\S+|www\.\S+)", lower)
    if url_match:
        url = url_match.group(2)
        if not url.startswith("http"):
            url = "https://" + url
        webbrowser.open(url)
        return {"response": (f"Opening {url}." if not fr else f"Ouverture de {url}."), "intent": "launcher"}

    # Open folder
    for name, path in FOLDER_PATHS.items():
        if name in lower and re.search(r"(open|show|ouvrir?|ouvre[rz]?|show me)", lower):
            if os.path.exists(path):
                _open_path(path)
                return {"response": (f"Opening {name}." if not fr else f"Ouverture de {name}."),
                        "intent": "launcher"}

    # Open app by name
    open_match = re.search(
        r"(open|launch|start|ouvrir?|lance[rz]?|démarre[rz]?)\s+(.+)",
        lower
    )
    if open_match:
        app_name = open_match.group(2).strip().rstrip(".,!")
        result = _launch_app(app_name)
        if result:
            return {"response": (f"Opening {app_name}." if not fr else f"Ouverture de {app_name}."),
                    "intent": "launcher"}
        return {"response": (f"Couldn't find '{app_name}'." if not fr
                              else f"Impossible de trouver '{app_name}'."),
                "intent": "launcher"}

    return None


def _launch_app(name: str) -> bool:
    """Try to launch an app. Returns True if launched."""
    name_lower = name.lower().strip()

    # Check aliases first
    for alias, cmds in APP_ALIASES.items():
        if alias in name_lower:
            for cmd in cmds:
                if _try_run([cmd]):
                    return True

    # Try the name directly (various forms)
    candidates = [
        name_lower,
        name_lower.replace(" ", "-"),
        name_lower.replace(" ", ""),
        name_lower.replace(" ", "_"),
    ]
    for c in candidates:
        if _try_run([c]):
            return True

    # macOS: open -a "AppName"
    if SYSTEM == "darwin":
        if _try_run(["open", "-a", name]):
            return True

    # Linux: try gtk-launch (works with .desktop files)
    if SYSTEM == "linux":
        if _try_run(["gtk-launch", name_lower]):
            return True
        if _try_run(["gtk-launch", name_lower.replace(" ", "-")]):
            return True

    return False


def _try_run(cmd: list) -> bool:
    try:
        subprocess.Popen(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        return True
    except (FileNotFoundError, PermissionError, OSError):
        return False


def _open_path(path: str):
    if SYSTEM == "darwin":
        subprocess.Popen(["open", path])
    elif SYSTEM == "windows":
        os.startfile(path)
    else:
        for cmd in ["xdg-open", "nautilus", "dolphin", "thunar"]:
            if _try_run([cmd, path]):
                break

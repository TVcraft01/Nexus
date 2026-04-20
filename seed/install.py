"""
Nexus Seed Installer
====================
Detects hardware, picks model, sets up core memory.
"""
import os, json, platform
from datetime import date

CORE_FILE = os.path.join(os.path.dirname(__file__), "..", "core", "data", "core_memory.json")

def detect_hardware():
    import psutil
    ram_mb = psutil.virtual_memory().total // (1024 * 1024)
    return {"ram_mb": ram_mb, "os": platform.system().lower()}

def pick_model(ram_mb):
    if ram_mb < 2000:  return "tinyllama"
    elif ram_mb < 4000: return "phi3:mini"
    elif ram_mb < 8000: return "phi3:medium"
    else:               return "llama3.2:latest"

def first_launch():
    print("\n🌱 Welcome to Nexus\n")
    name = input("What's your name? ").strip()
    lang = input("Preferred language? (e.g. en, fr, es) ").strip()
    hw   = detect_hardware()
    model = pick_model(hw["ram_mb"])
    core = {
        "name": name,
        "language": lang,
        "hardware": hw,
        "model": model,
        "install_date": date.today().isoformat()
    }
    os.makedirs(os.path.dirname(CORE_FILE), exist_ok=True)
    with open(CORE_FILE, "w") as f:
        json.dump(core, f, indent=2)
    print(f"\nHi {name}. Model selected: {model}")
    print("Nexus is ready. Run core/main.py to start.\n")

if __name__ == "__main__":
    if not os.path.exists(CORE_FILE):
        first_launch()
    else:
        print("Nexus already installed. Run core/main.py to start.")

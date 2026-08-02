#!/usr/bin/env python3
# Quick-install script for Nexus
import os, subprocess, sys

def main():
    print("Nexus Quick Install")
    print("=" * 40)
    os.chdir(os.path.dirname(os.path.abspath(__file__)))
    os.chdir("..")
    os.chdir("server")
    subprocess.check_call([sys.executable, "-m", "pip", "install", "-e", ".[gui,voice]"])
    print("\nNexus installed! Run 'nexus' to start.")
    print("Or 'nexus --headless' for headless mode.")

if __name__ == "__main__":
    main()

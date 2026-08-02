#!/usr/bin/env python3
"""Graphical packager for the Nexus desktop .deb.

Run from the project virtual environment:
    cd desktop
    source venv/bin/activate
    python package_nexus.py
"""

from __future__ import annotations

import os
import re
import shutil
import subprocess
import sys
import threading
import tkinter as tk
from pathlib import Path
from tkinter import messagebox


def _find_deb() -> Path | None:
    desktop_dir = Path(__file__).resolve().parent
    dist_dir = desktop_dir / "dist"
    if not dist_dir.exists():
        return None
    candidates = sorted(dist_dir.glob("nexus-desktop_*.deb"), key=lambda p: p.stat().st_mtime, reverse=True)
    return candidates[0] if candidates else None


class NexusPackager(tk.Tk):
    def __init__(self) -> None:
        super().__init__()
        self.title("Nexus Packager")
        self.geometry("720x540")
        self.configure(bg="#1e1e28")
        self.minsize(640, 460)

        self._setup_icon()
        self._build_ui()
        self._update_status()

    def _setup_icon(self) -> None:
        try:
            from PIL import Image, ImageTk
            icon = Image.open(Path(__file__).resolve().parent / "assets" / "nexus-icon.png")
            icon_16 = icon.resize((16, 16))
            self._window_icon = ImageTk.PhotoImage(icon_16)
            self.iconphoto(True, self._window_icon)
        except Exception:
            self._window_icon = None

    def _build_ui(self) -> None:
        # Header
        header = tk.Frame(self, bg="#1e1e28", padx=24, pady=20)
        header.pack(fill="x")

        try:
            from PIL import Image, ImageTk
            icon_img = Image.open(Path(__file__).resolve().parent / "assets" / "nexus-icon.png")
            icon_img = icon_img.resize((64, 64))
            self._header_icon = ImageTk.PhotoImage(icon_img)
            tk.Label(header, image=self._header_icon, bg="#1e1e28").pack(side="left")
        except Exception:
            self._header_icon = None

        title_frame = tk.Frame(header, bg="#1e1e28")
        title_frame.pack(side="left", padx=(16, 0))
        tk.Label(
            title_frame,
            text="Nexus Packager",
            bg="#1e1e28",
            fg="#ffffff",
            font=("Inter", 24, "bold"),
        ).pack(anchor="w")
        tk.Label(
            title_frame,
            text="Build, install and remove the Nexus desktop .deb",
            bg="#1e1e28",
            fg="#a0a4b8",
            font=("Inter", 12),
        ).pack(anchor="w")

        # Content area
        content = tk.Frame(self, bg="#1e1e28", padx=24, pady=8)
        content.pack(fill="both", expand=True)

        # Status card
        status_card = tk.Frame(content, bg="#252532", bd=0, padx=16, pady=12, relief="flat")
        status_card.pack(fill="x", pady=(0, 12))
        self.status_label = tk.Label(
            status_card,
            text="Ready",
            bg="#252532",
            fg="#ffffff",
            font=("Inter", 12),
            justify="left",
        )
        self.status_label.pack(anchor="w")

        # Version + Buttons
        version_frame = tk.Frame(content, bg="#1e1e28")
        version_frame.pack(fill="x", pady=(0, 8))
        tk.Label(version_frame, text="Version:", bg="#1e1e28", fg="#a0a4b8", font=("Inter", 10)).pack(side="left")
        self.version_var = tk.StringVar(value="0.1.0")
        self.version_entry = tk.Entry(
            version_frame,
            textvariable=self.version_var,
            width=10,
            bg="#111116",
            fg="#ffffff",
            insertbackground="#ffffff",
            relief="flat",
            highlightthickness=1,
            highlightbackground="#3d4252",
            highlightcolor="#4682ff",
            font=("Inter", 10),
        )
        self.version_entry.pack(side="left", padx=(8, 0))

        button_frame = tk.Frame(content, bg="#1e1e28")
        button_frame.pack(fill="x", pady=(0, 12))

        self.btn_build = self._make_button(button_frame, "Build .deb", self._on_build, accent=True)
        self.btn_build.pack(side="left", padx=(0, 10))

        self.btn_open = self._make_button(button_frame, "Open in Software Center", self._on_open)
        self.btn_open.pack(side="left", padx=(0, 10))

        self.btn_uninstall = self._make_button(button_frame, "Uninstall", self._on_uninstall)
        self.btn_uninstall.pack(side="left")

        # Log area
        log_frame = tk.Frame(content, bg="#1e1e28")
        log_frame.pack(fill="both", expand=True)
        tk.Label(log_frame, text="Build log", bg="#1e1e28", fg="#a0a4b8", font=("Inter", 10)).pack(anchor="w")

        self.log_text = tk.Text(
            log_frame,
            bg="#111116",
            fg="#c5c8d4",
            insertbackground="#ffffff",
            font=("JetBrains Mono", 9),
            relief="flat",
            state="disabled",
            wrap="word",
            padx=8,
            pady=8,
        )
        self.log_text.pack(fill="both", expand=True, pady=(4, 0))

        # Footer
        footer = tk.Frame(self, bg="#1e1e28", padx=24, pady=12)
        footer.pack(fill="x")
        tk.Label(
            footer,
            text="Need help? Run this from the desktop virtual environment.",
            bg="#1e1e28",
            fg="#686c7a",
            font=("Inter", 9),
        ).pack(anchor="w")

    def _make_button(self, parent: tk.Widget, text: str, command, accent: bool = False) -> tk.Button:
        bg = "#4682ff" if accent else "#2f3341"
        fg = "#ffffff"
        hover = "#5a91ff" if accent else "#3d4252"
        btn = tk.Button(
            parent,
            text=text,
            command=command,
            bg=bg,
            fg=fg,
            activebackground=hover,
            activeforeground=fg,
            font=("Inter", 11, "bold"),
            relief="flat",
            cursor="hand2",
            padx=16,
            pady=8,
            borderwidth=0,
            highlightthickness=0,
        )
        return btn

    def _log(self, message: str, tag: str | None = None) -> None:
        self.log_text.configure(state="normal")
        self.log_text.insert("end", message + "\n", tag or "")
        self.log_text.see("end")
        self.log_text.configure(state="disabled")

    def _set_status(self, text: str, color: str = "#ffffff") -> None:
        self.status_label.config(text=text, fg=color)

    def _update_status(self) -> None:
        deb = _find_deb()
        if deb:
            self._set_status(f"Found package: {deb.name}  ({deb.stat().st_size / 1024 / 1024:.1f} MiB)", "#6efaa3")
        else:
            self._set_status("No package yet. Click 'Build .deb' to create one.", "#a0a4b8")

    def _run_in_thread(self, target, args=()):  # type: ignore[no-untyped-def]
        self._set_buttons_state("disabled")
        thread = threading.Thread(target=target, args=args, daemon=True)
        thread.start()

    def _set_buttons_state(self, state: str) -> None:
        for btn in (self.btn_build, self.btn_open, self.btn_uninstall):
            btn.config(state=state)

    def _stream_command(self, cmd: list[str], cwd: Path, env: dict | None = None) -> int:
        self._log(f"$ {' '.join(cmd)}")
        try:
            proc = subprocess.Popen(cmd, cwd=cwd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, env=env)
            if proc.stdout is None:
                return 1
            for line in proc.stdout:
                self.after(0, self._log, line.rstrip())
            proc.wait()
            return proc.returncode
        except FileNotFoundError as exc:
            self.after(0, self._log, f"Error: {exc}")
            return 1

    def _on_build(self) -> None:
        version = self.version_var.get().strip() or "0.1.0"

        if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]*", version):
            messagebox.showerror(
                "Invalid version",
                f"Version '{version}' is not valid. Use letters, numbers, dots, dashes and underscores (e.g. 0.1.0).",
            )
            return

        desktop_dir = Path(__file__).resolve().parent

        if os.environ.get("VIRTUAL_ENV") is None:
            messagebox.showwarning(
                "Virtual environment recommended",
                "It looks like the Nexus virtual environment is not active.\n"
                "Activate it first with:\n  source venv/bin/activate",
            )
            # Continue anyway; the user may still have pip available.

        def _build() -> None:
            try:
                code = self._stream_command([sys.executable, "build_deb.py", "--version", version], cwd=desktop_dir)
            except Exception as exc:  # pragma: no cover - GUI safety net
                self.after(0, self._log, f"Unexpected error: {exc}")
                code = 1
            finally:
                self.after(0, self._build_finished, code)

        self._log("Starting build...\n")
        self._set_status("Building .deb...", "#ffd166")
        self._run_in_thread(_build)

    def _build_finished(self, code: int) -> None:
        self._set_buttons_state("normal")
        if code == 0:
            self._set_status("Build succeeded.", "#6efaa3")
            self._update_status()
            deb = _find_deb()
            if deb:
                self._log(f"\nBuilt: {deb}")
        else:
            self._set_status(f"Build failed (exit {code}).", "#ff6b6b")

    def _on_open(self) -> None:
        deb = _find_deb()
        if not deb:
            messagebox.showwarning("No package", "No .deb package found. Build one first.")
            return
        self._log(f"Opening {deb} with the default application...")
        try:
            subprocess.run(["xdg-open", str(deb)], check=False)
        except FileNotFoundError:
            messagebox.showerror("xdg-open not found", "Could not open the package with xdg-open.")

    def _on_uninstall(self) -> None:
        if not messagebox.askyesno("Uninstall Nexus?", "This will remove the system-wide Nexus package."):
            return

        def _uninstall() -> None:
            desktop_dir = Path(__file__).resolve().parent
            env = os.environ.copy()
            env["DEBIAN_FRONTEND"] = "noninteractive"
            # Prefer pkexec; fall back to a terminal so the user can type a password.
            if shutil.which("pkexec"):
                code = self._stream_command(
                    ["pkexec", "env", "DEBIAN_FRONTEND=noninteractive", "apt", "remove", "-y", "nexus-desktop"],
                    cwd=desktop_dir,
                    env=env,
                )
            elif shutil.which("x-terminal-emulator"):
                self.after(0, self._log, "Opening terminal for password...")
                code = subprocess.run(
                    ["x-terminal-emulator", "-e", "sudo apt remove -y nexus-desktop"],
                    cwd=desktop_dir,
                    env=env,
                ).returncode
            else:
                self.after(0, self._log, "Error: no privilege escalation tool found (pkexec or x-terminal-emulator)")
                code = 1
            self.after(0, self._uninstall_finished, code)

        self._log("Uninstalling Nexus...\n")
        self._set_status("Uninstalling...", "#ffd166")
        self._run_in_thread(_uninstall)

    def _uninstall_finished(self, code: int) -> None:
        self._set_buttons_state("normal")
        if code == 0:
            self._set_status("Nexus uninstalled.", "#6efaa3")
        else:
            self._set_status(f"Uninstall finished with exit code {code}.", "#ff6b6b")
        self._update_status()


def main() -> None:
    app = NexusPackager()
    app.mainloop()


if __name__ == "__main__":
    main()

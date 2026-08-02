# GUI Integration Module
#
# Wraps the desktop GUI (customtkinter) for integration with the
# new orchestrator. Optional — only loaded when GUI dependencies are available.

from __future__ import annotations

import logging

logger = logging.getLogger("nexus.gui")


def launch_gui(orchestrator, start_hidden: bool = False) -> None:
    """Launch the Nexus desktop GUI using customtkinter.

    Falls back gracefully if GUI dependencies are not installed.
    """
    try:
        import customtkinter as ctk
        import tkinter as tk
    except ImportError:
        logger.warning(
            "GUI dependencies not installed. Install with: pip install customtkinter pystray"
        )
        logger.info("Nexus is running in headless mode. Use 'nexus --headless' next time.")
        return

    try:
        # Try to import the legacy desktop app
        import sys
        import os

        # Add client/desktop to path
        client_path = os.path.join(os.path.dirname(__file__), "..", "..", "client", "desktop")
        sys.path.insert(0, client_path)

        # Run a simplified GUI
        _run_simple_gui(orchestrator, start_hidden)
    except Exception as e:
        logger.error(f"Failed to launch GUI: {e}")
        logger.info("Falling back to headless mode.")


def _run_simple_gui(orchestrator, start_hidden: bool = False) -> None:
    """Launch a minimal GUI wrapper around the orchestrator."""
    import customtkinter as ctk
    import tkinter as tk
    import threading

    ctk.set_appearance_mode("dark")

    root = ctk.CTk()
    root.title("Nexus v0.3.0")
    root.geometry("800x600")
    root.configure(fg_color="#0A0A0A")

    ctk.CTkLabel(
        root, text="◉  Nexus", font=("Inter", 24, "bold"), text_color="#5B8CFF"
    ).pack(pady=(24, 4))

    ctk.CTkLabel(
        root,
        text=f"Node: {orchestrator.node_id}",
        font=("Inter", 12),
        text_color="#AEAEB2",
    ).pack(pady=(0, 8))

    status_label = ctk.CTkLabel(
        root,
        text=orchestrator.chat_status(),
        text_color="#34C759",
        font=("Inter", 12),
    )
    status_label.pack()

    # Command input
    input_frame = ctk.CTkFrame(root, fg_color="#1C1C1E", corner_radius=24)
    input_frame.pack(fill=tk.X, padx=24, pady=16)
    input_frame.grid_columnconfigure(0, weight=1)

    cmd_entry = ctk.CTkEntry(
        input_frame,
        placeholder_text="Type a command...",
        height=44,
        corner_radius=24,
        border_width=0,
        fg_color="#1C1C1E",
        text_color="#FFFFFF",
        font=("Inter", 13),
    )
    cmd_entry.grid(row=0, column=0, sticky="ew", padx=(16, 8), pady=4)

    def on_submit():
        cmd = cmd_entry.get().strip()
        if not cmd:
            return
        cmd_entry.delete(0, tk.END)
        result = orchestrator.execute_command(cmd)
        result_text.configure(
            text=f"{'OK' if result.success else 'FAIL'}: {result.message}",
            text_color="#34C759" if result.success else "#FF4433",
        )

    cmd_entry.bind("<Return>", lambda e: on_submit())

    ctk.CTkButton(
        input_frame,
        text="➤",
        width=40,
        height=40,
        corner_radius=20,
        fg_color="#5B8CFF",
        command=on_submit,
    ).grid(row=0, column=1, padx=(0, 8), pady=4)

    result_text = ctk.CTkLabel(
        root,
        text="Type a command above to get started.",
        wraplength=700,
        justify="left",
        text_color="#AEAEB2",
        font=("Inter", 13),
    )
    result_text.pack(pady=16)

    # Quick actions
    actions_frame = ctk.CTkFrame(root, fg_color="transparent")
    actions_frame.pack(fill=tk.X, padx=24)

    quick_actions = [
        ("What time is it", "GET_TIME_DATE"),
        ("Roll a dice", "ROLL_DICE"),
        ("Tell me a joke", "GET_JOKE"),
        ("Search cats", "WEB_SEARCH"),
    ]

    for label, _ in quick_actions:
        ctk.CTkButton(
            actions_frame,
            text=label,
            width=140,
            height=32,
            corner_radius=16,
            fg_color="#1C1C1E",
            text_color="#FFFFFF",
            font=("Inter", 11),
            command=lambda c=label: [cmd_entry.delete(0, tk.END), cmd_entry.insert(0, c), on_submit()],
        ).pack(side=tk.LEFT, padx=(0, 8))

    if start_hidden:
        root.withdraw()

    root.mainloop()

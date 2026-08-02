"""Modern, unified Nexus desktop UI (customtkinter)."""

from __future__ import annotations

import json
import logging
import queue
import threading
import tkinter as tk
from tkinter import messagebox, simpledialog
from typing import Callable, Dict, List, Optional

import customtkinter as ctk

# Optional QR / camera imports (gracefully degrade if missing)
try:
    import qrcode
    from PIL import Image, ImageTk
    _QR_AVAILABLE = True
except Exception:
    _QR_AVAILABLE = False

try:
    import cv2
    from pyzbar import pyzbar
    _CAMERA_AVAILABLE = True
except Exception:
    _CAMERA_AVAILABLE = False

from .autostart import disable as autostart_disable, enable as autostart_enable, is_enabled as autostart_is_enabled
from .brain import BrainResponse
from .models import CommandResult, MeshNode
from .service import NexusService
from .tray import TrayManager
from . import voice as voice_module


logger = logging.getLogger(__name__)

# Unified dark colour palette shared with the Android app.
Palette = Dict[str, str]
PALETTE: Palette = {
    "bg": "#0A0A0A",
    "surface": "#121212",
    "card": "#1C1C1E",
    "card_hover": "#2C2C2E",
    "text": "#FFFFFF",
    "text_secondary": "#AEAEB2",
    "primary": "#5B8CFF",
    "success": "#34C759",
    "warning": "#FF9500",
    "error": "#FF4433",
}

# Navigation layout matches the Android bottom bar: Chat, Home, Devices, Logs, Settings.
NAV_ITEMS = [
    ("Chat", "💬"),
    ("Home", "🏠"),
    ("Devices", "🌐"),
    ("Logs", "📜"),
    ("Settings", "⚙️"),
]

QUICK_ACTIONS = [
    ("Find devices", "__find_devices__"),
    ("Timer", "Set a timer for 5 minutes"),
    ("Weather", "What's the weather"),
    ("Schedule", "My schedule today"),
    ("Navigate", "Navigate to home"),
    ("Music", "Play chill tunes"),
    ("Roll dice", "Roll a dice"),
    ("Joke", "Tell me a joke"),
    ("Info", "What time is it"),
]


class NexusDesktopApp:
    def __init__(self, root: ctk.CTk, service: NexusService, *, start_hidden: bool = False, use_tray: bool = True) -> None:
        self.root = root
        self.service = service
        self.root.title("Nexus")
        self.root.geometry("960x720")
        self.root.minsize(800, 600)
        if isinstance(self.root, ctk.CTk):
            self.root.configure(fg_color=PALETTE["bg"])
        else:
            self.root.configure(bg=PALETTE["bg"])
        self.root.protocol("WM_DELETE_WINDOW", self._on_close_button)

        ctk.set_appearance_mode("dark")

        self._tray: Optional[TrayManager] = None
        if use_tray:
            self._tray = TrayManager(
                on_show=self.show_window,
                on_hide=self.hide_window,
                on_quit=self._quit_from_tray,
                on_toggle_autostart=self._on_toggle_autostart,
                autostart_enabled=autostart_is_enabled(),
            )
            self._tray.start()

        self._nav_buttons: Dict[str, ctk.CTkButton] = {}
        self._content_frames: Dict[str, ctk.CTkFrame] = {}
        self._current_tab = "Home"
        self._is_listening = False
        self._cancel_voice = False
        self._chat_messages: List[ctk.CTkFrame] = []

        self._build_ui()
        self._select_tab("Home")

        self.service.on_command(self._on_remote_command)
        self._nodes: List[MeshNode] = []
        self._node_widgets: List[ctk.CTkFrame] = []

        # Thread-safe UI update queue. Background threads must schedule UI work
        # through this queue; the main loop drains it every 50 ms.
        self._ui_queue: queue.Queue[Callable[[], None]] = queue.Queue()
        self._process_ui_queue()

        self._poll_nodes()
        self._animate_visualizer()
        self._bind_keyboard_shortcuts()

        if start_hidden:
            self.hide_window()

    # ------------------------------------------------------------------ UI scheduler
    def _schedule_ui_callback(self, callback: Callable[..., None], *args, **kwargs) -> None:
        """Schedule a callback to run on the main Tk thread."""
        self._ui_queue.put(lambda: callback(*args, **kwargs))

    def _process_ui_queue(self) -> None:
        if not self.root.winfo_exists():
            return
        while True:
            try:
                callback = self._ui_queue.get_nowait()
            except queue.Empty:
                break
            try:
                callback()
            except Exception as exc:
                logger.error("UI queue callback failed: %s", exc)
        self.root.after(50, self._process_ui_queue)

    # ------------------------------------------------------------------ UI layout
    def _build_ui(self) -> None:
        self._build_sidebar()
        self._build_content_area()

    def _build_sidebar(self) -> None:
        sidebar = ctk.CTkFrame(self.root, width=200, corner_radius=0, fg_color=PALETTE["surface"])
        sidebar.pack(side=tk.LEFT, fill=tk.Y)
        sidebar.pack_propagate(False)

        # App brand
        brand = ctk.CTkFrame(sidebar, fg_color="transparent")
        brand.pack(fill=tk.X, padx=20, pady=24)
        ctk.CTkLabel(
            brand,
            text="◉",
            font=("Inter", 36, "bold"),
            text_color=PALETTE["primary"],
        ).pack(side=tk.LEFT)
        ctk.CTkLabel(
            brand,
            text="Nexus",
            font=("Inter", 22, "bold"),
            text_color=PALETTE["text"],
        ).pack(side=tk.LEFT, padx=(10, 0))

        # Nav buttons
        for name, icon in NAV_ITEMS:
            btn = ctk.CTkButton(
                sidebar,
                text=f"{icon}  {name}",
                font=("Inter", 14),
                height=44,
                corner_radius=12,
                border_width=0,
                fg_color="transparent",
                text_color=PALETTE["text_secondary"],
                hover_color=PALETTE["card_hover"],
                command=lambda n=name: self._select_tab(n),
            )
            btn.pack(fill=tk.X, padx=12, pady=4)
            self._nav_buttons[name] = btn

    def _build_content_area(self) -> None:
        self.content_container = ctk.CTkFrame(self.root, fg_color=PALETTE["bg"], corner_radius=0)
        self.content_container.pack(side=tk.LEFT, fill=tk.BOTH, expand=True)

        self._content_frames["Chat"] = self._build_chat_frame()
        self._content_frames["Home"] = self._build_home_frame()
        self._content_frames["Devices"] = self._build_mesh_frame()
        self._content_frames["Logs"] = self._build_logs_frame()
        self._content_frames["Settings"] = self._build_settings_frame()

    def _select_tab(self, name: str) -> None:
        self._current_tab = name
        for frame in self._content_frames.values():
            frame.pack_forget()
        for n, btn in self._nav_buttons.items():
            if n == name:
                btn.configure(fg_color=PALETTE["card"], text_color=PALETTE["text"])
            else:
                btn.configure(fg_color="transparent", text_color=PALETTE["text_secondary"])
        frame = self._content_frames[name]
        frame.pack(fill=tk.BOTH, expand=True, padx=24, pady=24)
        if name == "Home":
            self.cmd_entry.focus_set()

    def _bind_keyboard_shortcuts(self) -> None:
        # Mnemonic shortcuts: Chat, Home, Devices, Logs, Settings.
        self.root.bind("<Control-Shift-c>", lambda e: self._select_tab("Chat"))
        self.root.bind("<Control-Shift-h>", lambda e: self._select_tab("Home"))
        self.root.bind("<Control-Shift-d>", lambda e: self._select_tab("Devices"))
        self.root.bind("<Control-Shift-l>", lambda e: self._select_tab("Logs"))
        self.root.bind("<Control-Shift-s>", lambda e: self._select_tab("Settings"))

    # ------------------------------------------------------------------ Chat tab
    def _build_chat_frame(self) -> ctk.CTkFrame:
        frame = ctk.CTkFrame(self.content_container, fg_color=PALETTE["bg"])

        header = ctk.CTkFrame(frame, fg_color="transparent")
        header.pack(fill=tk.X, pady=(0, 12))
        ctk.CTkLabel(header, text="Talk to Nexus", font=("Inter", 18, "bold"), text_color=PALETTE["text"]).pack(side=tk.LEFT)
        self._chat_status_label = ctk.CTkLabel(header, text="Checking local LLM…", text_color=PALETTE["text_secondary"], font=("Inter", 11))
        self._chat_status_label.pack(side=tk.RIGHT)

        self._chat_container = ctk.CTkScrollableFrame(frame, fg_color=PALETTE["card"], corner_radius=16)
        self._chat_container.pack(fill=tk.BOTH, expand=True, pady=(0, 12))

        self._pending_confirm_frame: Optional[ctk.CTkFrame] = None

        # Empty state / LLM setup card (must exist before _refresh_chat_status runs)
        self._empty_state_card: Optional[ctk.CTkFrame] = None
        self._build_empty_state_card(frame)

        self._refresh_chat_status()

        input_frame = ctk.CTkFrame(frame, fg_color=PALETTE["card"], corner_radius=24)
        input_frame.pack(fill=tk.X, pady=(0, 0))
        input_frame.grid_columnconfigure(0, weight=1)

        self._chat_entry = ctk.CTkEntry(
            input_frame,
            placeholder_text="Ask Nexus anything…",
            height=48,
            corner_radius=24,
            border_width=0,
            fg_color=PALETTE["card"],
            text_color=PALETTE["text"],
            font=("Inter", 14),
        )
        self._chat_entry.grid(row=0, column=0, sticky="ew", padx=(8, 8), pady=4)
        self._chat_entry.bind("<Return>", lambda e: self._on_send_chat())

        self._mic_button = ctk.CTkButton(
            input_frame,
            text="🎙",
            width=40,
            height=40,
            corner_radius=20,
            fg_color=PALETTE["primary"],
            text_color=PALETTE["text"],
            command=self._start_voice_chat,
        )
        self._mic_button.grid(row=0, column=1, padx=(0, 8), pady=4)

        ctk.CTkButton(
            input_frame,
            text="➤",
            width=40,
            height=40,
            corner_radius=20,
            fg_color=PALETTE["primary"],
            text_color=PALETTE["text"],
            command=self._on_send_chat,
        ).grid(row=0, column=2, padx=(0, 8), pady=4)

        return frame

    def _build_empty_state_card(self, parent: ctk.CTkFrame) -> None:
        self._empty_state_card = ctk.CTkFrame(parent, fg_color=PALETTE["card"], corner_radius=16)
        self._empty_state_label = ctk.CTkLabel(
            self._empty_state_card,
            text="Tap the mic or type below to start talking with Nexus.",
            font=("Inter", 13),
            text_color=PALETTE["text_secondary"],
            wraplength=700,
            justify="left",
        )
        self._empty_state_label.pack(padx=16, pady=(16, 8))
        self._empty_state_refresh = ctk.CTkButton(
            self._empty_state_card,
            text="Refresh LLM check",
            fg_color=PALETTE["card_hover"],
            command=self._refresh_chat_status,
        )
        self._empty_state_refresh.pack(padx=16, pady=(0, 16))

    def _update_empty_state(self) -> None:
        has_messages = bool(self._chat_messages)
        if not has_messages:
            if self.service.backend is None:
                self._empty_state_label.configure(
                    text="Nexus needs a local AI brain to chat.\n\n"
                         "1. Install Ollama:  curl -fsSL https://ollama.com/install.sh | sh\n"
                         "2. Pull a model:    ollama pull llama3.2\n"
                         "3. Start Ollama:    ollama serve\n"
                         "4. Tap Refresh below."
                )
            else:
                self._empty_state_label.configure(
                    text="Tap the mic or type below to start talking with Nexus."
                )
            self._empty_state_card.pack(fill=tk.BOTH, expand=True, pady=(0, 12))
        else:
            self._empty_state_card.pack_forget()

    def _refresh_chat_status(self) -> None:
        self.service.refresh_backend()
        status = self.service.chat_status()
        self._chat_status_label.configure(text=status)
        self._update_empty_state()

    def _on_send_chat(self) -> None:
        text = self._chat_entry.get().strip()
        if not text:
            return
        self._chat_entry.delete(0, tk.END)
        self._add_chat_bubble(text, "user")
        self._refresh_chat_status()
        threading.Thread(target=self._run_chat, args=(text,), daemon=True).start()

    def _run_chat(self, text: str) -> None:
        response = self.service.chat(text)
        self._schedule_ui_callback(self._add_chat_bubble, response.text, "assistant", response)
        self._schedule_ui_callback(self._refresh_chat_status)

    def _add_chat_bubble(self, text: str, sender: str, response: Optional[BrainResponse] = None) -> None:
        self._empty_state_card.pack_forget()
        bubble = ctk.CTkFrame(self._chat_container, fg_color="transparent")
        bubble.pack(fill=tk.X, pady=4, padx=12, anchor="e" if sender == "user" else "w")
        self._chat_messages.append(bubble)

        inner = ctk.CTkFrame(
            bubble,
            fg_color=PALETTE["primary"] if sender == "user" else PALETTE["card_hover"],
            corner_radius=16,
        )
        inner.pack(anchor="e" if sender == "user" else "w")

        ctk.CTkLabel(
            inner,
            text=text,
            wraplength=700,
            justify="left",
            text_color=PALETTE["text"],
            font=("Inter", 13),
        ).pack(anchor="w", padx=12, pady=8)

        # Scroll to the newest message.
        try:
            self._chat_container._parent_canvas.yview_moveto(1.0)
        except Exception:
            pass

        if response and response.requires_confirmation and response.action:
            self._show_chat_confirmation(response)

    def _show_chat_confirmation(self, response: BrainResponse) -> None:
        if self._pending_confirm_frame:
            self._pending_confirm_frame.destroy()

        self._pending_confirm_frame = ctk.CTkFrame(self._chat_container, fg_color="transparent")
        self._pending_confirm_frame.pack(fill=tk.X, pady=4, padx=12, anchor="w")

        card = ctk.CTkFrame(self._pending_confirm_frame, fg_color=PALETTE["warning"], corner_radius=12)
        card.pack(anchor="w")
        ctk.CTkLabel(
            card,
            text=f"Nexus wants to run: {response.action.name}. Approve?",
            text_color="#000000",
            font=("Inter", 12),
        ).pack(side=tk.LEFT, padx=(12, 8), pady=8)

        def _approve() -> None:
            card.destroy()
            threading.Thread(target=self._confirm_chat_command, daemon=True).start()

        def _cancel() -> None:
            card.destroy()

        ctk.CTkButton(card, text="Approve", width=80, fg_color="#FFFFFF", text_color="#000000", command=_approve).pack(side=tk.LEFT, padx=(0, 8), pady=8)
        ctk.CTkButton(card, text="Cancel", width=80, fg_color=PALETTE["card_hover"], command=_cancel).pack(side=tk.LEFT, pady=8)

    def _confirm_chat_command(self) -> None:
        response = self.service.confirm_pending_command()
        self._schedule_ui_callback(self._add_chat_bubble, response.text, "assistant", response)

    # ------------------------------------------------------------------ Voice chat
    def _start_voice_chat(self) -> None:
        if self._is_listening:
            return
        if not voice_module.is_available():
            messagebox.showinfo(
                "Voice input",
                "Offline voice recognition is available after installing Vosk.\n"
                "Run: pip install vosk\n\n"
                "You can still type your message below.",
            )
            self._select_tab("Chat")
            self._chat_entry.focus_set()
            return
        if self._is_listening:
            self._cancel_voice = True
            return
        self._is_listening = True
        self._cancel_voice = False
        self._visualizer_active = True
        if hasattr(self, "_call_button"):
            self._call_button.configure(text="Listening…")
        if hasattr(self, "_mic_button"):
            self._mic_button.configure(text="⏹")
        self._select_tab("Chat")
        threading.Thread(target=self._listen_and_send, daemon=True).start()

    def _listen_and_send(self) -> None:
        try:
            text = voice_module.listen_for_speech(
                self.service.storage_dir,
                duration_s=5,
                should_stop=lambda: self._cancel_voice,
            )
        finally:
            self._schedule_ui_callback(self._stop_voice_chat)
        if self._cancel_voice:
            return
        if text:
            self._schedule_ui_callback(self._chat_entry.delete, 0, tk.END)
            self._schedule_ui_callback(self._chat_entry.insert, 0, text)
            self._schedule_ui_callback(self._on_send_chat)
        else:
            self._schedule_ui_callback(
                self._add_chat_bubble,
                "I didn't catch that. Try speaking closer to the mic.",
                "assistant",
            )

    def _stop_voice_chat(self) -> None:
        self._is_listening = False
        self._visualizer_active = False
        if hasattr(self, "_call_button"):
            self._call_button.configure(text="🎙  Call Nexus")
        if hasattr(self, "_mic_button"):
            self._mic_button.configure(text="🎙")

    # ------------------------------------------------------------------ Home tab
    def _build_home_frame(self) -> ctk.CTkFrame:
        frame = ctk.CTkFrame(self.content_container, fg_color=PALETTE["bg"])

        # Visualizer
        self._visualizer_canvas = ctk.CTkCanvas(
            frame,
            width=220,
            height=220,
            bg=PALETTE["bg"],
            highlightthickness=0,
        )
        self._visualizer_canvas.pack(pady=(0, 24))
        self._visualizer_dots: List[int] = []
        self._visualizer_active = False
        self._visualizer_amplitude = 0.35
        self._init_visualizer()

        # Call Nexus
        self._call_button = ctk.CTkButton(
            frame,
            text="🎙  Call Nexus",
            font=("Inter", 16, "bold"),
            height=56,
            corner_radius=16,
            fg_color=PALETTE["primary"],
            text_color=PALETTE["text"],
            hover_color=PALETTE["card_hover"],
            command=self._start_voice_chat,
        )
        self._call_button.pack(fill=tk.X, pady=(0, 20))

        # Quick actions (horizontal scroll to match Android)
        self._build_section_header(frame, "Quick actions")
        actions_frame = ctk.CTkScrollableFrame(frame, fg_color="transparent", orientation="horizontal", height=80)
        actions_frame.pack(fill=tk.X, pady=(0, 20))
        for label, command in QUICK_ACTIONS:
            btn = ctk.CTkButton(
                actions_frame,
                text=label,
                width=140,
                height=32,
                corner_radius=16,
                fg_color=PALETTE["card"],
                text_color=PALETTE["text"],
                hover_color=PALETTE["card_hover"],
                font=("Inter", 12),
                command=lambda c=command: self._on_quick_action(c),
            )
            btn.pack(side=tk.LEFT, padx=(0, 8), pady=2)

        # Command input
        self._build_section_header(frame, "Command")
        input_frame = ctk.CTkFrame(frame, fg_color=PALETTE["card"], corner_radius=24)
        input_frame.pack(fill=tk.X, pady=(0, 20))
        input_frame.grid_columnconfigure(0, weight=1)

        self.cmd_entry = ctk.CTkEntry(
            input_frame,
            placeholder_text="Say or type a command…",
            height=48,
            corner_radius=24,
            border_width=0,
            fg_color=PALETTE["card"],
            text_color=PALETTE["text"],
            font=("Inter", 14),
        )
        self.cmd_entry.grid(row=0, column=0, sticky="ew", padx=(16, 8), pady=4)
        self.cmd_entry.bind("<Return>", lambda e: self._on_send_local())

        ctk.CTkButton(
            input_frame,
            text="➤",
            width=40,
            height=40,
            corner_radius=20,
            fg_color=PALETTE["primary"],
            text_color=PALETTE["text"],
            command=self._on_send_local,
        ).grid(row=0, column=1, padx=(0, 8), pady=4)

        # Last result card
        self._result_card = ctk.CTkFrame(frame, fg_color=PALETTE["card"], corner_radius=16)
        self._result_card.pack(fill=tk.X, pady=(0, 20))
        self._result_title = ctk.CTkLabel(
            self._result_card,
            text="Result",
            font=("Inter", 12, "bold"),
            text_color=PALETTE["text"],
        )
        self._result_title.pack(anchor="w", padx=16, pady=(12, 0))
        self._last_result_label = ctk.CTkLabel(
            self._result_card,
            text="Tap a quick action or type a command to get started.",
            wraplength=700,
            justify="left",
            height=60,
            text_color=PALETTE["text_secondary"],
            font=("Inter", 13),
        )
        self._last_result_label.pack(fill=tk.X, padx=16, pady=(4, 12))

        return frame

    def _init_visualizer(self) -> None:
        canvas = self._visualizer_canvas
        rows, cols = 9, 9
        spacing = 20
        offset = 30
        for row in range(rows):
            for col in range(cols):
                x = offset + col * spacing
                y = offset + row * spacing
                dot = canvas.create_oval(
                    x - 3, y - 3, x + 3, y + 3,
                    fill=PALETTE["text_secondary"], outline="",
                )
                self._visualizer_dots.append((dot, x, y))

    def _animate_visualizer(self) -> None:
        active = self._visualizer_active
        target = 0.9 if active else 0.35
        self._visualizer_amplitude += (target - self._visualizer_amplitude) * 0.1

        cx, cy = 110, 110
        for dot, x, y in self._visualizer_dots:
            distance = ((x - cx) ** 2 + (y - cy) ** 2) ** 0.5
            max_dist = 110
            wave = (1 - distance / max_dist) * self._visualizer_amplitude
            alpha = int((0.2 + wave * 0.8) * 255)
            color = self._alpha_blend(PALETTE["primary"], alpha)
            radius = max(2, 4 + wave * 4)
            self._visualizer_canvas.itemconfig(dot, fill=color)
            self._visualizer_canvas.coords(
                dot,
                x - radius, y - radius,
                x + radius, y + radius,
            )

        if self.root.winfo_exists():
            self.root.after(60, self._animate_visualizer)

    def _alpha_blend(self, color: str, alpha: int) -> str:
        # Simple dark-overlay alpha against background
        alpha = max(0, min(255, alpha))
        bg = self._hex_to_rgb(PALETTE["bg"])
        fg = self._hex_to_rgb(color)
        r = (fg[0] * alpha + bg[0] * (255 - alpha)) // 255
        g = (fg[1] * alpha + bg[1] * (255 - alpha)) // 255
        b = (fg[2] * alpha + bg[2] * (255 - alpha)) // 255
        return f"#{r:02x}{g:02x}{b:02x}"

    @staticmethod
    def _hex_to_rgb(value: str) -> tuple:
        value = value.lstrip("#")
        return int(value[0:2], 16), int(value[2:4], 16), int(value[4:6], 16)

    # ------------------------------------------------------------------ Mesh / Devices tab
    def _build_mesh_frame(self) -> ctk.CTkFrame:
        frame = ctk.CTkFrame(self.content_container, fg_color=PALETTE["bg"])

        # Pair device button
        self._pair_device_btn = ctk.CTkButton(
            frame,
            text="Pair device",
            font=("Inter", 14, "bold"),
            height=48,
            corner_radius=12,
            fg_color=PALETTE["primary"],
            text_color=PALETTE["text"],
            command=self._open_pairing_options,
        )
        self._pair_device_btn.pack(fill=tk.X, pady=(0, 16))

        # Connected devices list
        self._build_section_header(frame, "Connected devices")
        self.nodes_container = ctk.CTkScrollableFrame(frame, fg_color=PALETTE["bg"])
        self.nodes_container.pack(fill=tk.BOTH, expand=True)

        # Manual pair (advanced fallback, hidden by default)
        self._manual_pair_visible = False
        self._manual_pair_visible = False
        self._manual_pair_card = ctk.CTkFrame(frame, fg_color=PALETTE["card"], corner_radius=16)
        self._manual_pair_card.pack(fill=tk.X, pady=(0, 20))
        self._manual_pair_card.pack_forget()  # start collapsed

        ctk.CTkLabel(
            self._manual_pair_card,
            text="Manual pair",
            font=("Inter", 16, "bold"),
            text_color=PALETTE["text"],
        ).pack(anchor="w", padx=16, pady=(16, 8))

        form = ctk.CTkFrame(self._manual_pair_card, fg_color="transparent")
        form.pack(fill=tk.X, padx=16, pady=(0, 16))
        form.grid_columnconfigure(1, weight=1)
        form.grid_columnconfigure(3, weight=1)

        ctk.CTkLabel(form, text="Peer ID", text_color=PALETTE["text_secondary"], font=("Inter", 12)).grid(row=0, column=0, padx=(0, 8), pady=4, sticky="w")
        self.peer_id_entry = ctk.CTkEntry(form, fg_color=PALETTE["bg"], border_width=0, text_color=PALETTE["text"])
        self.peer_id_entry.grid(row=0, column=1, sticky="ew", padx=(0, 16), pady=4)

        ctk.CTkLabel(form, text="PIN", text_color=PALETTE["text_secondary"], font=("Inter", 12)).grid(row=0, column=2, padx=(0, 8), pady=4, sticky="w")
        self.pin_entry = ctk.CTkEntry(form, fg_color=PALETTE["bg"], border_width=0, show="*", text_color=PALETTE["text"])
        self.pin_entry.grid(row=0, column=3, sticky="ew", pady=4)

        actions = ctk.CTkFrame(self._manual_pair_card, fg_color="transparent")
        actions.pack(fill=tk.X, padx=16, pady=(0, 16))
        ctk.CTkButton(
            actions,
            text="Pair",
            width=100,
            fg_color=PALETTE["primary"],
            command=self._on_pair,
        ).pack(side=tk.LEFT, padx=(0, 8))
        ctk.CTkButton(
            actions,
            text=" Play PIN",
            width=120,
            fg_color=PALETTE["card_hover"],
            command=self._on_play_pin,
        ).pack(side=tk.LEFT, padx=(0, 8))
        ctk.CTkButton(
            actions,
            text="🎙 Listen",
            width=120,
            fg_color=PALETTE["card_hover"],
            command=self._on_listen_pin,
        ).pack(side=tk.LEFT)
        self._listen_label = ctk.CTkLabel(actions, text="", text_color=PALETTE["text_secondary"])
        self._listen_label.pack(side=tk.LEFT, padx=(12, 0))

        self._manual_pair_toggle = ctk.CTkButton(
            frame,
            text="Show advanced pairing options",
            fg_color="transparent",
            text_color=PALETTE["text_secondary"],
            hover_color=PALETTE["card_hover"],
            command=self._toggle_manual_pair_card,
        )
        self._manual_pair_toggle.pack(fill=tk.X, pady=(0, 12))

        # Nodes list
        self._build_section_header(frame, "Discovered nodes")
        self.nodes_container = ctk.CTkScrollableFrame(frame, fg_color=PALETTE["bg"])
        self.nodes_container.pack(fill=tk.BOTH, expand=True)

        return frame

    # ------------------------------------------------------------------ Logs tab
    def _build_logs_frame(self) -> ctk.CTkFrame:
        frame = ctk.CTkFrame(self.content_container, fg_color=PALETTE["bg"])
        header = ctk.CTkFrame(frame, fg_color="transparent")
        header.pack(fill=tk.X, pady=(0, 12))
        ctk.CTkLabel(header, text="System Log", font=("Inter", 18, "bold"), text_color=PALETTE["text"]).pack(side=tk.LEFT)
        ctk.CTkButton(
            header,
            text="Clear",
            width=80,
            fg_color=PALETTE["card"],
            command=self._clear_log,
        ).pack(side=tk.RIGHT)

        self.log_area = ctk.CTkTextbox(
            frame,
            fg_color=PALETTE["card"],
            text_color=PALETTE["text_secondary"],
            font=("SF Mono", 12),
            wrap="word",
        )
        self.log_area.pack(fill=tk.BOTH, expand=True)
        self.log_area.configure(state="disabled")
        return frame

    # ------------------------------------------------------------------ Settings tab
    def _build_settings_frame(self) -> ctk.CTkFrame:
        frame = ctk.CTkFrame(self.content_container, fg_color=PALETTE["bg"])

        ctk.CTkLabel(
            frame,
            text="Settings",
            font=("Inter", 24, "bold"),
            text_color=PALETTE["text"],
        ).pack(anchor="w", pady=(0, 16))

        # Autostart
        self._autostart_var = tk.IntVar(value=1 if autostart_is_enabled() else 0)
        self._llm_setup_frame: Optional[ctk.CTkFrame] = None
        autostart_card = ctk.CTkFrame(frame, fg_color=PALETTE["card"], corner_radius=16)
        autostart_card.pack(fill=tk.X, pady=(0, 16))
        row = ctk.CTkFrame(autostart_card, fg_color="transparent")
        row.pack(fill=tk.X, padx=16, pady=16)
        ctk.CTkLabel(
            row,
            text="Start on login",
            font=("Inter", 14, "bold"),
            text_color=PALETTE["text"],
        ).pack(side=tk.LEFT)
        ctk.CTkSwitch(
            row,
            text="",
            variable=self._autostart_var,
            command=self._on_autostart_checkbox,
            progress_color=PALETTE["success"],
        ).pack(side=tk.RIGHT)
        ctk.CTkLabel(
            autostart_card,
            text="Launch Nexus automatically when you log in to this computer.",
            text_color=PALETTE["text_secondary"],
            font=("Inter", 12),
            wraplength=700,
            justify="left",
        ).pack(anchor="w", padx=16, pady=(0, 16))

        # Node info
        info_card = ctk.CTkFrame(frame, fg_color=PALETTE["card"], corner_radius=16)
        info_card.pack(fill=tk.X, pady=(0, 16))
        ctk.CTkLabel(info_card, text="Node identity", font=("Inter", 14, "bold"), text_color=PALETTE["text"]).pack(anchor="w", padx=16, pady=(16, 4))
        ctk.CTkLabel(
            info_card,
            text=f"ID: {self.service.node_id}",
            text_color=PALETTE["text_secondary"],
            font=("SF Mono", 12),
        ).pack(anchor="w", padx=16, pady=(0, 16))

        return frame

    # ------------------------------------------------------------------ helpers
    def _build_section_header(self, parent: ctk.CTkFrame, text: str) -> None:
        ctk.CTkLabel(
            parent,
            text=text,
            font=("Inter", 14, "bold"),
            text_color=PALETTE["text"],
        ).pack(anchor="w", pady=(0, 8))

    # ------------------------------------------------------------------ actions
    def _on_quick_action(self, command: str) -> None:
        if command == "__find_devices__":
            self._select_tab("Devices")
            return
        self.cmd_entry.delete(0, tk.END)
        self.cmd_entry.insert(0, command)
        self._on_send_local()

    def _on_send_local(self) -> None:
        command = self.cmd_entry.get().strip()
        if not command:
            return
        threading.Thread(target=self._run_local, args=(command,), daemon=True).start()

    def _run_local(self, command: str) -> None:
        result = self.service.execute_local_command(command)
        self._schedule_ui_callback(self._show_result, result)

    def _open_pairing_options(self) -> None:
        dialog = ctk.CTkToplevel(self.root)
        dialog.title("Pair a device")
        dialog.geometry("420x280")
        dialog.configure(fg_color=PALETTE["bg"])
        dialog.transient(self.root)
        dialog.grab_set()

        ctk.CTkLabel(
            dialog,
            text="Pair a device",
            font=("Inter", 18, "bold"),
            text_color=PALETTE["text"],
        ).pack(pady=(20, 4))
        ctk.CTkLabel(
            dialog,
            text="Choose how you want to pair. Both devices must be on the same Wi-Fi or close via Bluetooth.",
            font=("Inter", 12),
            text_color=PALETTE["text_secondary"],
            wraplength=380,
            justify="left",
        ).pack(padx=20)

        actions = ctk.CTkFrame(dialog, fg_color="transparent")
        actions.pack(pady=20)
        ctk.CTkButton(
            actions,
            text="Scan QR code",
            width=160,
            height=44,
            fg_color=PALETTE["primary"],
            command=lambda: [dialog.destroy(), self._scan_qr_code()],
        ).pack(side=tk.LEFT, padx=(0, 8))
        ctk.CTkButton(
            actions,
            text="Show QR code",
            width=160,
            height=44,
            fg_color=PALETTE["primary"],
            command=lambda: [dialog.destroy(), self._show_qr_code()],
        ).pack(side=tk.LEFT)

    def _show_qr_code(self) -> None:
        from .sound_pairing import generate_pin

        pin = generate_pin(6)
        self.service.set_qr_pairing_pin(pin)

        dialog = ctk.CTkToplevel(self.root)
        dialog.title("Show this QR code")
        dialog.geometry("420x500")
        dialog.configure(fg_color=PALETTE["bg"])
        dialog.transient(self.root)
        dialog.grab_set()

        ctk.CTkLabel(
            dialog,
            text="Have the other device tap Scan QR code and point its camera at this code.",
            font=("Inter", 12),
            text_color=PALETTE["text_secondary"],
            wraplength=380,
            justify="left",
        ).pack(padx=20, pady=(12, 8))

        qr_image = self._generate_qr_image(pin)
        if qr_image:
            label = ctk.CTkLabel(dialog, text="", image=qr_image)
            label.pack(pady=8)
        else:
            ctk.CTkLabel(dialog, text="QR code unavailable (install qrcode and Pillow)", text_color=PALETTE["error"]).pack(pady=8)

        ctk.CTkLabel(
            dialog,
            text=f"PIN: {pin}",
            font=("SF Mono", 16, "bold"),
            text_color=PALETTE["text"],
        ).pack(pady=4)

        def _on_close() -> None:
            self.service.set_qr_pairing_pin(None)
            dialog.destroy()

        ctk.CTkButton(dialog, text="Done", command=_on_close).pack(pady=12)

    def _generate_qr_image(self, pin: str) -> Optional[ImageTk.PhotoImage]:
        if not _QR_AVAILABLE:
            return None
        try:
            payload = json.dumps({"nodeId": self.service.node_id, "nodeName": self.service.node_name, "pin": pin})
            qr = qrcode.QRCode(box_size=8, border=2)
            qr.add_data(payload)
            qr.make(fit=True)
            img = qr.make_image(fill_color="black", back_color="white")
            self._qr_photo = ImageTk.PhotoImage(img)
            return self._qr_photo
        except Exception as exc:
            logger.warning("Failed to generate QR image: %s", exc)
            return None

    def _scan_qr_code(self) -> None:
        if not _CAMERA_AVAILABLE:
            raw = simpledialog.askstring("Scan QR code", "Paste the text inside the QR code:", parent=self.root)
            if raw:
                self._handle_scanned_qr(raw)
            return

        dialog = ctk.CTkToplevel(self.root)
        dialog.title("Scan QR code")
        dialog.geometry("640x480")
        dialog.configure(fg_color=PALETTE["bg"])
        dialog.transient(self.root)
        dialog.grab_set()

        video_label = ctk.CTkLabel(dialog, text="")
        video_label.pack(fill=tk.BOTH, expand=True, padx=8, pady=8)

        cap = cv2.VideoCapture(0)
        self._qr_capture_active = True

        def _update_frame() -> None:
            if not self._qr_capture_active or not cap.isOpened():
                return
            ret, frame = cap.read()
            if not ret:
                dialog.after(30, _update_frame)
                return
            decoded = pyzbar.decode(frame)
            for d in decoded:
                self._qr_capture_active = False
                cap.release()
                dialog.destroy()
                self._handle_scanned_qr(d.data.decode("utf-8"))
                return
            frame = cv2.cvtColor(frame, cv2.COLOR_BGR2RGB)
            image = Image.fromarray(frame)
            photo = ImageTk.PhotoImage(image=image)
            video_label.configure(image=photo)
            video_label.image = photo  # type: ignore[attr-defined]
            dialog.after(30, _update_frame)

        def _on_close() -> None:
            self._qr_capture_active = False
            cap.release()
            dialog.destroy()

        dialog.protocol("WM_DESTROY_WINDOW", _on_close)
        dialog.after(30, _update_frame)

    def _handle_scanned_qr(self, contents: str) -> None:
        try:
            data = json.loads(contents)
            peer_id = data.get("nodeId")
            pin = data.get("pin")
            if not peer_id or not pin:
                raise ValueError("Missing fields")
            if self.service.pair_with_node(peer_id, pin):
                self.log(f"Paired with {peer_id}")
            else:
                messagebox.showerror("Pairing failed", f"Could not pair with {peer_id}")
        except Exception as exc:
            messagebox.showerror("Invalid QR code", f"Could not parse pairing data: {exc}")

    def _on_pair(self) -> None:
        peer_id = self.peer_id_entry.get().strip()
        pin = self.pin_entry.get().strip()
        if not peer_id or not pin:
            messagebox.showwarning("Missing info", "Please enter peer node ID and PIN.")
            return
        if self.service.pair_with_node(peer_id, pin):
            self.log(f"Paired with {peer_id}")
        else:
            messagebox.showerror("Pairing failed", "Could not pair with the given node.")

    def _on_play_pin(self) -> None:
        pin = self.pin_entry.get().strip()
        if not pin or not pin.isdigit():
            messagebox.showwarning("Invalid PIN", "Please enter a numeric PIN first.")
            return
        self.log(f"Playing pairing chime for PIN: {pin}")
        threading.Thread(target=self._play_pin, args=(pin,), daemon=True).start()

    def _play_pin(self, pin: str) -> None:
        try:
            from .sound_pairing import play_pairing_sequence
            play_pairing_sequence(pin)
            self._schedule_ui_callback(self.log, f"Played pairing chime for PIN: {pin}")
        except Exception as exc:
            self._schedule_ui_callback(self.log, f"Failed to play PIN: {exc}")

    def _on_listen_pin(self) -> None:
        self._listen_label.configure(text="Listening…")
        self.log("Listening for pairing chime...")
        threading.Thread(target=self._listen_pin, daemon=True).start()

    def _listen_pin(self) -> None:
        try:
            from .sound_pairing import listen_for_pairing_sequence
            pin = listen_for_pairing_sequence(duration_s=8, min_length=4)
            if pin:
                self._schedule_ui_callback(self._pin_entry_set, pin)
                self._schedule_ui_callback(self.log, f"Heard pairing chime PIN: {pin}")
            else:
                self._schedule_ui_callback(self.log, "No pairing chime detected")
        except Exception as exc:
            self._schedule_ui_callback(self.log, f"Failed to listen: {exc}")
        finally:
            self._schedule_ui_callback(self._listen_label.configure, text="")

    def _pin_entry_set(self, pin: str) -> None:
        self.pin_entry.delete(0, tk.END)
        self.pin_entry.insert(0, pin)

    def _on_remote_command(self, peer_id: str, result: CommandResult) -> None:
        self._schedule_ui_callback(self.log, f"[remote:{peer_id}] {result.message}")

    def _poll_nodes(self) -> None:
        try:
            nodes = self.service.discovered_nodes
            if not hasattr(self, "_nodes") or self._nodes != nodes:
                self._nodes = nodes
                self._refresh_node_list(nodes)
        except Exception:
            pass
        if self.root.winfo_exists():
            self.root.after(2000, self._poll_nodes)

    def _refresh_node_list(self, nodes: List[MeshNode]) -> None:
        for widget in self._node_widgets:
            widget.destroy()
        self._node_widgets.clear()

        if not nodes:
            label = ctk.CTkLabel(
                self.nodes_container,
                text="No nearby Nexus nodes discovered yet.",
                text_color=PALETTE["text_secondary"],
            )
            label.pack(pady=12)
            self._node_widgets.append(label)
            return

        for node in sorted(nodes, key=lambda n: n.name):
            card = ctk.CTkFrame(self.nodes_container, fg_color=PALETTE["card"], corner_radius=12)
            card.pack(fill=tk.X, pady=4)

            top = ctk.CTkFrame(card, fg_color="transparent")
            top.pack(fill=tk.X, padx=12, pady=(12, 4))
            ctk.CTkLabel(
                top,
                text=node.name,
                font=("Inter", 14, "bold"),
                text_color=PALETTE["text"],
            ).pack(side=tk.LEFT)
            ctk.CTkLabel(
                top,
                text=f"{'Paired' if node.is_paired else 'Discovered'} • {node.address}:{node.port}",
                text_color=PALETTE["text_secondary"],
                font=("Inter", 11),
            ).pack(side=tk.RIGHT)

            cmd = self.cmd_entry.get().strip() if hasattr(self, "cmd_entry") else ""
            btns = ctk.CTkFrame(card, fg_color="transparent")
            btns.pack(fill=tk.X, padx=12, pady=(0, 12))
            ctk.CTkButton(
                btns,
                text="Relay",
                width=80,
                fg_color=PALETTE["card_hover"],
                command=lambda n=node, c=cmd: self._relay_to(n, c),
            ).pack(side=tk.LEFT, padx=(0, 8))
            ctk.CTkButton(
                btns,
                text="Unpair" if node.is_paired else "Pair",
                width=80,
                fg_color=PALETTE["card_hover"],
                command=lambda n=node: self._toggle_pair(n),
            ).pack(side=tk.LEFT)
            self._node_widgets.append(card)

    def _relay_to(self, node: MeshNode, command: str) -> None:
        if not command:
            command = simpledialog.askstring("Relay command", "Enter command to relay:", parent=self.root) or "hello"
        threading.Thread(target=self._run_remote, args=(node, command), daemon=True).start()

    def _toggle_pair(self, node: MeshNode) -> None:
        if node.is_paired:
            self.service.unpair_node(node.id)
            self.log(f"Unpaired {node.name}")
        else:
            self._start_pairing_with_node(node)

    def _start_pairing_with_node(self, node: MeshNode) -> None:
        """Open an intuitive pairing dialog with an auto-generated PIN."""
        from .sound_pairing import generate_pin, play_pairing_sequence

        pin_var = {"pin": generate_pin(6)}

        dialog = ctk.CTkToplevel(self.root)
        dialog.title(f"Pair with {node.name}")
        dialog.geometry("420x360")
        dialog.configure(fg_color=PALETTE["bg"])
        dialog.transient(self.root)
        dialog.grab_set()

        ctk.CTkLabel(
            dialog,
            text=f"Pair with {node.name}",
            font=("Inter", 18, "bold"),
            text_color=PALETTE["text"],
        ).pack(pady=(20, 4))

        ctk.CTkLabel(
            dialog,
            text="Pairing steps:\n"
                 "1. Make sure both devices are on the same Wi-Fi or close via Bluetooth.\n"
                 "2. On the other device, go to Devices and tap this node.\n"
                 "3. Both devices must show the same PIN. Copy it, play it as a chime, or enter it manually.",
            font=("Inter", 12),
            text_color=PALETTE["text_secondary"],
            wraplength=380,
            justify="left",
        ).pack()

        pin_label = ctk.CTkLabel(
            dialog,
            text=pin_var["pin"],
            font=("SF Mono", 42, "bold"),
            text_color=PALETTE["primary"],
        )
        pin_label.pack(pady=8)

        visual_canvas = tk.Canvas(dialog, width=220, height=40, bg=PALETTE["bg"], highlightthickness=0)
        visual_canvas.pack()

        def _update_visual(pin: str) -> None:
            visual_canvas.delete("all")
            colors = ["#5B8CFF", "#34C759", "#FF9500", "#FF4433", "#AEAEB2", "#FFFFFF"]
            width = 28
            gap = 6
            for idx, digit in enumerate(pin):
                color = colors[int(digit) % len(colors)]
                x = 10 + idx * (width + gap)
                visual_canvas.create_rectangle(x, 5, x + width, 35, fill=color, outline="")

        _update_visual(pin_var["pin"])

        def _regenerate_pin() -> None:
            pin_var["pin"] = generate_pin(6)
            pin_label.configure(text=pin_var["pin"])
            _update_visual(pin_var["pin"])

        def _copy_pin() -> None:
            self.root.clipboard_clear()
            self.root.clipboard_append(pin_var["pin"])
            self.log(f"PIN copied to clipboard for {node.name}")

        def _play_chime() -> None:
            def _play() -> None:
                try:
                    play_pairing_sequence(pin_var["pin"])
                except Exception as exc:
                    self._schedule_ui_callback(self.log, f"Failed to play pairing chime: {exc}")
            threading.Thread(target=_play, daemon=True).start()

        actions = ctk.CTkFrame(dialog, fg_color="transparent")
        actions.pack(pady=4)
        ctk.CTkButton(
            actions,
            text="🔊 Play pairing chime",
            width=160,
            fg_color=PALETTE["card_hover"],
            command=_play_chime,
        ).pack(side=tk.LEFT, padx=(0, 8))
        ctk.CTkButton(
            actions,
            text="📋 Copy PIN",
            width=120,
            fg_color=PALETTE["card_hover"],
            command=_copy_pin,
        ).pack(side=tk.LEFT)

        ctk.CTkButton(
            dialog,
            text=" New PIN",
            width=120,
            fg_color="transparent",
            text_color=PALETTE["text_secondary"],
            hover_color=PALETTE["card_hover"],
            command=_regenerate_pin,
        ).pack(pady=4)

        ctk.CTkLabel(
            dialog,
            text="Or enter the PIN manually on the other device.",
            font=("Inter", 11),
            text_color=PALETTE["text_secondary"],
        ).pack(pady=(8, 0))

        confirm = ctk.CTkFrame(dialog, fg_color="transparent")
        confirm.pack(pady=12)
        ctk.CTkButton(
            confirm,
            text="Pair",
            width=100,
            fg_color=PALETTE["success"],
            command=lambda: self._confirm_pair(dialog, node, pin_var["pin"]),
        ).pack(side=tk.LEFT, padx=(0, 12))
        ctk.CTkButton(
            confirm,
            text="Cancel",
            width=100,
            fg_color=PALETTE["card"],
            command=dialog.destroy,
        ).pack(side=tk.LEFT)

    def _confirm_pair(self, dialog: ctk.CTkToplevel, node: MeshNode, pin: str) -> None:
        if self.service.pair_with_node(node.id, pin):
            self.log(f"Paired with {node.name}")
        else:
            messagebox.showerror("Pairing failed", f"Could not pair with {node.name}")
        dialog.destroy()

    def _toggle_manual_pair_card(self) -> None:
        self._manual_pair_visible = not self._manual_pair_visible
        if self._manual_pair_visible:
            self._manual_pair_card.pack(fill=tk.X, pady=(0, 20), before=self._manual_pair_toggle)
            self._manual_pair_toggle.configure(text="Hide advanced pairing options")
        else:
            self._manual_pair_card.pack_forget()
            self._manual_pair_toggle.configure(text="Show advanced pairing options")

    def _run_remote(self, node: MeshNode, command: str) -> None:
        result = self.service.relay_command(node, command)
        if result:
            self._schedule_ui_callback(self._show_result, result)
        else:
            self._schedule_ui_callback(self.log, f"Failed to send command to {node.id}")

    def _show_result(self, result: CommandResult) -> None:
        status = "OK" if result.success else "FAIL"
        self.log(f"[{status}] {result.message}")

        if result.requires_intern_choice and result.action.name == "UNKNOWN":
            self._schedule_ui_callback(
                self._ask_what_they_meant,
                result.original_input or result.action.args.get("raw", ""),
            )

        text = f"{result.message}"
        color = PALETTE["success"] if result.success else PALETTE["error"]
        self._result_title.configure(text=result.action.name)
        self._last_result_label.configure(text=text, text_color=color)

    _VALID_ACTION_NAMES = {
        "OPEN_APP", "OPEN_WEBSITE", "WEB_SEARCH", "TOGGLE_WIFI", "TOGGLE_BLUETOOTH",
        "SET_BRIGHTNESS", "SET_VOLUME", "ADJUST_VOLUME", "MUTE_VOLUME", "PLAY_MEDIA",
        "PLAY_MEDIA_APP", "PAUSE_MEDIA", "MEDIA_CONTROL", "TOGGLE_FLASHLIGHT",
        "SET_TIMER", "SET_ALARM", "TAKE_NOTE", "ROLL_DICE", "FLIP_COIN",
        "TOGGLE_DND", "NAVIGATE", "OPEN_CALENDAR", "CALCULATE", "SMART_HOME",
        "LIST_ACTION", "SET_REMINDER", "SEARCH_INFO", "OPEN_CAMERA", "RECORD_VIDEO",
        "CALL_CONTACT", "SEND_TEXT", "SEND_EMAIL", "CANCEL_ALARM_TIMER",
        "GET_TIME_DATE", "GET_BATTERY_STATUS", "GET_NEXT_ALARM", "GET_JOKE",
        "GET_WEATHER", "GET_TODAY_SCHEDULE",
    }

    def _ask_what_they_meant(self, original_input: str) -> None:
        if not original_input:
            return
        action_name = simpledialog.askstring(
            "Teach Nexus",
            f"I don't understand:\n{original_input}\n\nWhat should Nexus do?\n"
            "Enter an action like: open_app, set_volume, set_timer, navigate, etc.",
            parent=self.root,
        )
        if not action_name:
            return
        action_name = action_name.strip().upper()
        if action_name not in self._VALID_ACTION_NAMES:
            messagebox.showerror("Invalid action", f"'{action_name}' is not a known action.")
            self.log(f"[error] Invalid action name: {action_name}")
            return
        payload = simpledialog.askstring(
            "Teach Nexus",
            f"Enter the details for {action_name} (or leave empty):",
            parent=self.root,
        ) or ""
        if self.service.teach_rule(original_input, action_name, payload):
            self.log(f"[learned] '{original_input}' -> {action_name}({payload})")
        else:
            self.log("[error] Could not learn rule.")

    # ------------------------------------------------------------------ logging
    def log(self, message: str) -> None:
        self.log_area.configure(state="normal")
        self.log_area.insert(tk.END, f"{message}\n")
        self.log_area.see(tk.END)
        self.log_area.configure(state="disabled")

    def _clear_log(self) -> None:
        self.log_area.configure(state="normal")
        self.log_area.delete("1.0", tk.END)
        self.log_area.configure(state="disabled")

    # ------------------------------------------------------------------ window / tray
    def show_window(self) -> None:
        self._schedule_ui_callback(self._show_impl)

    def _show_impl(self) -> None:
        self.root.deiconify()
        self.root.lift()
        self.root.focus_force()

    def hide_window(self) -> None:
        self._schedule_ui_callback(self._hide_impl)

    def _hide_impl(self) -> None:
        self.root.withdraw()

    def _on_close_button(self) -> None:
        self.hide_window()

    def _quit_from_tray(self) -> None:
        if self._tray is not None:
            self._tray.stop()
        self.service.stop()
        self._schedule_ui_callback(self.root.destroy)

    def _on_toggle_autostart(self) -> None:
        self._schedule_ui_callback(self._toggle_autostart_impl)

    def _toggle_autostart_impl(self) -> None:
        if autostart_is_enabled():
            success = autostart_disable()
        else:
            success = autostart_enable()
        if self._tray:
            self._tray.update_autostart(autostart_is_enabled())
        self._autostart_var.set(1 if autostart_is_enabled() else 0)
        if not success:
            logger.error("Failed to toggle autostart")

    def _on_autostart_checkbox(self) -> None:
        if self._autostart_var.get():
            success = autostart_enable()
        else:
            success = autostart_disable()
        if self._tray:
            self._tray.update_autostart(autostart_is_enabled())
        self._autostart_var.set(1 if autostart_is_enabled() else 0)
        if not success:
            logger.error("Failed to toggle autostart from checkbox")

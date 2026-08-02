"""System tray integration for the Nexus Linux desktop node."""

from __future__ import annotations

import logging
import threading
from typing import Callable, Optional

import pystray
from PIL import Image, ImageDraw

logger = logging.getLogger(__name__)


class TrayManager:
    """Manages a system tray icon with Show and Quit actions."""

    def __init__(
        self,
        *,
        on_show: Callable[[], None],
        on_hide: Callable[[], None],
        on_quit: Callable[[], None],
        on_toggle_autostart: Optional[Callable[[], None]] = None,
        autostart_enabled: bool = False,
    ) -> None:
        self.on_show = on_show
        self.on_hide = on_hide
        self.on_quit = on_quit
        self.on_toggle_autostart = on_toggle_autostart
        self.autostart_enabled = autostart_enabled
        self._icon: Optional[pystray.Icon] = None
        self._thread: Optional[threading.Thread] = None

    @staticmethod
    def _create_icon() -> Image.Image:
        """Generate a small in-memory tray icon."""
        width, height = 64, 64
        image = Image.new("RGBA", (width, height), (18, 18, 18, 255))
        draw = ImageDraw.Draw(image)
        # Draw a blue "N" on a dark rounded-square background.
        draw.rounded_rectangle((4, 4, width - 4, height - 4), radius=12, fill=(30, 30, 35, 255), outline=(70, 130, 255, 255), width=3)
        draw.line([(22, 18), (22, 46)], fill=(70, 130, 255, 255), width=5)
        draw.line([(22, 18), (42, 46)], fill=(70, 130, 255, 255), width=5)
        draw.line([(42, 18), (42, 46)], fill=(70, 130, 255, 255), width=5)
        return image

    def _build_menu(self) -> pystray.Menu:
        def make_menu(autostart: bool) -> pystray.Menu:
            items = [
                pystray.MenuItem("Show Nexus", self._show),
                pystray.MenuItem("Hide Nexus", self._hide),
                pystray.MenuItem(
                    f"Start on login {'✓' if autostart else ''}",
                    self._toggle_autostart,
                ),
                pystray.Menu.SEPARATOR,
                pystray.MenuItem("Quit", self._quit),
            ]
            return pystray.Menu(*items)

        return make_menu(self.autostart_enabled)

    def _show(self, icon: Optional[pystray.Icon] = None, item: Optional[pystray.MenuItem] = None) -> None:
        logger.debug("Tray: show requested")
        self.on_show()

    def _hide(self, icon: Optional[pystray.Icon] = None, item: Optional[pystray.MenuItem] = None) -> None:
        logger.debug("Tray: hide requested")
        self.on_hide()

    def _toggle_autostart(self, icon: Optional[pystray.Icon] = None, item: Optional[pystray.MenuItem] = None) -> None:
        if self.on_toggle_autostart:
            self.on_toggle_autostart()

    def _quit(self, icon: Optional[pystray.Icon] = None, item: Optional[pystray.MenuItem] = None) -> None:
        logger.debug("Tray: quit requested")
        self.on_quit()

    def update_autostart(self, enabled: bool) -> None:
        self.autostart_enabled = enabled
        if self._icon:
            self._icon.menu = self._build_menu()

    def start(self) -> None:
        if self._icon is not None:
            return

        self._icon = pystray.Icon(
            "nexus-node",
            icon=self._create_icon(),
            title="Nexus Node",
            menu=self._build_menu(),
        )

        def _run() -> None:
            try:
                if self._icon is not None:
                    self._icon.run()
            except Exception:
                logger.exception("Tray icon loop failed")

        self._thread = threading.Thread(target=_run, daemon=True)
        self._thread.start()
        logger.info("System tray icon started")

    def stop(self) -> None:
        if self._icon:
            try:
                self._icon.stop()
            except Exception:
                logger.exception("Error stopping tray icon")
            self._icon = None
        self._thread = None

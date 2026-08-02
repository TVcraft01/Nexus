#!/usr/bin/env python3
"""Build a Debian (.deb) package for the Nexus desktop node.

Usage:
    cd desktop
    source venv/bin/activate
    python build_deb.py [--version 0.1.0]

The resulting .deb installs:
    /opt/nexus/          application source + offline wheels
    /opt/nexus/venv/     virtualenv created at install time
    /usr/bin/nexus       launcher wrapper
    /usr/share/applications/com.nexus.Nexus.desktop  menu entry
    /usr/share/icons/hicolor/256x256/apps/nexus.png  icon
    /usr/share/metainfo/com.nexus.Nexus.metainfo.xml  AppStream metadata
"""

from __future__ import annotations

import argparse
import shutil
import subprocess
import sys
from pathlib import Path


PACKAGE_NAME = "nexus-desktop"
DEFAULT_VERSION = "0.1.0"
ICON_SIZE = 256


def _build_python_version() -> str:
    return f"{sys.version_info.major}.{sys.version_info.minor}"


def _run(cmd: list[str], cwd: Path | None = None, check: bool = True) -> None:
    print(f"$ {' '.join(cmd)}")
    subprocess.run(cmd, cwd=cwd, check=check)


def _write_text(path: Path, content: str) -> None:
    path.write_text(content, encoding="utf-8")


def _generate_icon(desktop_dir: Path, icon_dest: Path) -> None:
    # Reuse the existing icon generator; it writes to desktop/assets by default.
    _run([sys.executable, "-m", "generate_icon"], cwd=desktop_dir)
    icon_source = desktop_dir / "assets" / "nexus-icon.png"
    if not icon_source.exists():
        raise FileNotFoundError(f"Icon was not generated at {icon_source}")
    shutil.copy2(icon_source, icon_dest)


def _copy_application_source(desktop_dir: Path, app_dest: Path) -> None:
    shutil.copytree(
        desktop_dir / "nexus",
        app_dest / "nexus",
        ignore=shutil.ignore_patterns("__pycache__", "*.pyc", "*.pyo", ".*", "tests"),
    )
    shutil.copy2(desktop_dir / "requirements.txt", app_dest / "requirements.txt")


def _download_wheels(desktop_dir: Path, wheels_dir: Path, requirements: Path) -> None:
    wheels_dir.mkdir(parents=True, exist_ok=True)
    _run(
        [
            sys.executable,
            "-m",
            "pip",
            "wheel",
            "-r",
            str(requirements),
            "--wheel-dir",
            str(wheels_dir),
        ],
        cwd=desktop_dir,
    )


def _write_debian_metadata(debian_dir: Path, version: str, arch: str) -> None:
    control = debian_dir / "control"
    _write_text(
        control,
        f"""Package: {PACKAGE_NAME}
Version: {version}
Section: utils
Priority: optional
Architecture: {arch}
Depends: python3 (>= 3.10), python3-venv, python3-pip, python3-tk, libportaudio2, gir1.2-appindicator3-0.1
Maintainer: Nexus Team <nexus@example.com>
Description: Privacy-first local voice assistant
 Nexus is a privacy-first, offline-first voice assistant that runs on
 your Linux desktop and meshes with your Android phone.
""",
    )

    # postinst creates the venv from bundled wheels and refreshes menus.
    postinst = debian_dir / "postinst"
    _write_text(
        postinst,
        r"""#!/bin/sh
set -e

NEXUS_DIR=/opt/nexus
VENV_DIR=$NEXUS_DIR/venv

# Verify that the system Python matches the one used to build the bundled wheels.
BUILD_PY="$(cat "$NEXUS_DIR/.build-python-version")"
SYSTEM_PY="$(python3 -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")')"
if [ "$BUILD_PY" != "$SYSTEM_PY" ]; then
    echo "Error: $BUILD_PY was used to build this package, but this system is using Python $SYSTEM_PY." >&2
    echo "Please install the .deb on a system with the same Python 3 minor version, or rebuild from source." >&2
    exit 1
fi

# Create a fresh virtual environment if it doesn't exist.
if [ ! -d "$VENV_DIR" ]; then
    python3 -m venv "$VENV_DIR"
fi

# Install/upgrade dependencies from bundled wheels (offline install).
"$VENV_DIR/bin/pip" install --no-index --find-links="$NEXUS_DIR/wheels" -r "$NEXUS_DIR/requirements.txt"

# Refresh desktop integration.
if command -v update-desktop-database >/dev/null 2>&1; then
    update-desktop-database /usr/share/applications
fi

if command -v gtk-update-icon-cache >/dev/null 2>&1; then
    gtk-update-icon-cache -f /usr/share/icons/hicolor >/dev/null 2>&1 || true
fi

exit 0
""",
    )
    postinst.chmod(0o755)

    # postrm removes the venv created by postinst.
    postrm = debian_dir / "postrm"
    _write_text(
        postrm,
        r"""#!/bin/sh
set -e

if [ "$1" = "remove" ] || [ "$1" = "purge" ]; then
    rm -rf /opt/nexus/venv
    # Remove /opt/nexus if it's now empty.
    rmdir /opt/nexus 2>/dev/null || true
fi

exit 0
""",
    )
    postrm.chmod(0o755)


def _write_system_files(desktop_dir: Path, package_dir: Path) -> None:
    # /usr/bin/nexus wrapper
    bin_dir = package_dir / "usr" / "bin"
    bin_dir.mkdir(parents=True, exist_ok=True)
    wrapper = bin_dir / "nexus"
    _write_text(
        wrapper,
        r"""#!/bin/sh
# Start the system-installed Nexus desktop node.
cd "$HOME" || true
export PYTHONPATH=/opt/nexus:$PYTHONPATH
exec /opt/nexus/venv/bin/python3 -m nexus "$@"
""",
    )
    wrapper.chmod(0o755)

    # /usr/share/applications/com.nexus.Nexus.desktop
    applications_dir = package_dir / "usr" / "share" / "applications"
    applications_dir.mkdir(parents=True, exist_ok=True)
    desktop_file = applications_dir / "com.nexus.Nexus.desktop"
    _write_text(
        desktop_file,
        """[Desktop Entry]
Type=Application
Name=Nexus
Comment=Privacy-first local voice assistant
Exec=/usr/bin/nexus
Icon=nexus
Terminal=false
Categories=Utility;Audio;Network;
StartupNotify=true
""",
    )

    # AppStream / metainfo
    metainfo_dir = package_dir / "usr" / "share" / "metainfo"
    metainfo_dir.mkdir(parents=True, exist_ok=True)
    metainfo_source = desktop_dir / "packaging" / "com.nexus.Nexus.metainfo.xml"
    shutil.copy2(metainfo_source, metainfo_dir / "com.nexus.Nexus.metainfo.xml")

    # Minimal copyright file
    doc_dir = package_dir / "usr" / "share" / "doc" / "nexus"
    doc_dir.mkdir(parents=True, exist_ok=True)
    _write_text(
        doc_dir / "copyright",
        "Nexus - Privacy-first local voice assistant\n\nLicense: MIT\n",
    )


def build_deb(version: str = DEFAULT_VERSION, output_dir: Path | None = None) -> Path:
    desktop_dir = Path(__file__).resolve().parent
    project_root = desktop_dir.parent
    dist_dir = desktop_dir / "dist"
    build_root = dist_dir / "nexus_deb_build"
    package_dir = build_root / "package"

    # Clean any previous build.
    if build_root.exists():
        shutil.rmtree(build_root)

    package_dir.mkdir(parents=True)

    arch = subprocess.run(
        ["dpkg", "--print-architecture"],
        capture_output=True,
        text=True,
        check=True,
    ).stdout.strip()

    # Application source
    app_dest = package_dir / "opt" / "nexus"
    _copy_application_source(desktop_dir, app_dest)

    # Icon
    icon_dest_dir = (
        package_dir / "usr" / "share" / "icons" / "hicolor" / f"{ICON_SIZE}x{ICON_SIZE}" / "apps"
    )
    icon_dest_dir.mkdir(parents=True, exist_ok=True)
    icon_dest = icon_dest_dir / "nexus.png"
    _generate_icon(desktop_dir, icon_dest)

    # Offline wheels
    wheels_dir = app_dest / "wheels"
    _download_wheels(desktop_dir, wheels_dir, app_dest / "requirements.txt")

    # Record the Python version used to build the wheels so postinst can verify compatibility.
    (app_dest / ".build-python-version").write_text(_build_python_version(), encoding="utf-8")

    # Debian metadata
    debian_dir = package_dir / "DEBIAN"
    debian_dir.mkdir(parents=True, exist_ok=True)
    _write_debian_metadata(debian_dir, version, arch)
    _write_system_files(desktop_dir, package_dir)

    # Build the .deb
    if output_dir is None:
        output_dir = dist_dir
    output_dir.mkdir(parents=True, exist_ok=True)
    deb_name = f"{PACKAGE_NAME}_{version}_{arch}.deb"
    deb_path = output_dir / deb_name

    _run(
        ["dpkg-deb", "--build", "--root-owner-group", str(package_dir), str(deb_path)],
        check=True,
    )

    return deb_path


def main() -> None:
    parser = argparse.ArgumentParser(description="Build a Debian package for Nexus")
    parser.add_argument("--version", default=DEFAULT_VERSION, help="Package version")
    parser.add_argument("--output-dir", type=Path, help="Directory for the .deb output")
    args = parser.parse_args()

    deb_path = build_deb(version=args.version, output_dir=args.output_dir)
    print(f"\nBuilt: {deb_path}")
    print(f"  size: {deb_path.stat().st_size / 1024 / 1024:.1f} MiB")
    print("\nInstall with:")
    print(f"  sudo dpkg -i {deb_path}")


if __name__ == "__main__":
    main()

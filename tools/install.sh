#!/usr/bin/env bash
set -euo pipefail

# Nexus — cross-platform installer
# Detects your OS and installs the latest release from GitHub.
#
# Usage (Linux / macOS shell that has bash — Linux x86_64 only today):
#   curl -fsSL https://raw.githubusercontent.com/TVcraft01/Nexus/main/tools/install.sh | bash
#
# Windows users: run the PowerShell installer instead (no bash needed):
#   irm https://raw.githubusercontent.com/TVcraft01/Nexus/main/tools/install.ps1 | iex
#
# Or download and run:
#   bash install.sh
#
# Already installed and the app will not start? The same check the install runs:
#   bash install.sh --check-deps [install-dir]

REPO="TVcraft01/Nexus"
INSTALL_DIR="${NEXUS_INSTALL_DIR:-$HOME/.nexus}"

# Sonames check_system_libraries found missing (empty when the app can load).
MISSING_LIBS=""

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

info()  { echo -e "${CYAN}▸${NC} $*"; }
ok()    { echo -e "${GREEN}✓${NC} $*"; }
warn()  { echo -e "${YELLOW}!${NC} $*"; }
fail()  { echo -e "${RED}✗${NC} $*" >&2; exit 1; }

# Detect platform
detect_platform() {
    local os arch
    case "$(uname -s)" in
        Linux*)  os="linux" ;;
        Darwin*) os="macos" ;;
        MINGW*|MSYS*|CYGWIN*) os="windows" ;;
        *) fail "Unsupported OS: $(uname -s)" ;;
    esac
    case "$(uname -m)" in
        x86_64|amd64) arch="x64" ;;
        aarch64|arm64) arch="arm64" ;;
        *) fail "Unsupported architecture: $(uname -m) — only x86_64 (x64) builds are published." ;;
    esac
    echo "${os}-${arch}"
}

# Get latest release tag from GitHub
get_latest_release() {
    local url="https://api.github.com/repos/${REPO}/releases/latest"
    if command -v curl &>/dev/null; then
        curl -fsSL "$url" | grep '"tag_name"' | sed -E 's/.*"tag_name": *"([^"]+)".*/\1/'
    elif command -v wget &>/dev/null; then
        wget -qO- "$url" | grep '"tag_name"' | sed -E 's/.*"tag_name": *"([^"]+)".*/\1/'
    else
        fail "Neither curl nor wget found. Please install one."
    fi
}

# Download a release asset
download() {
    local url="$1" dest="$2"
    if command -v curl &>/dev/null; then
        curl -fsSL -o "$dest" "$url"
    elif command -v wget &>/dev/null; then
        wget -qO "$dest" "$url"
    fi
}

# --- System library check ----------------------------------------------------
#
# The archive carries Flutter's own libraries and Nexus's bundled plugins, but
# not the desktop libraries those plugins link against — the tray icon needs
# libayatana-appindicator, and no archive can ship it. When one is missing the
# dynamic loader refuses to start the app with
#
#   error while loading shared libraries: libayatana-indicator3.so.7: cannot
#   open shared object file
#
# a message that names a file and no package. This check makes the same load
# happen ahead of time, in a terminal, and names the package instead.
#
# It installs nothing: printing the command is help; running sudo for somebody
# is not this script's to do.

# The package that provides one missing soname, ordered apt|dnf|pacman.
soname_package() {
    case "$1" in
        libayatana-indicator3.so.*|libayatana-ido3-0.4.so.*|libayatana-appindicator3.so.*)
            echo 'libayatana-appindicator3-1|libayatana-appindicator-gtk3|libayatana-appindicator'
            ;;
        libappindicator3.so.1|libappindicator1)
            echo 'libappindicator3-1|libappindicator-gtk3|libappindicator'
            ;;
        *)
            echo ''
            ;;
    esac
}

# The command that installs one package here, or an empty string when this is
# not a package manager we can name a command for (then say so, honestly).
install_command_for() {
    local apt dnf pacman
    IFS='|' read -r apt dnf pacman <<<"$1"
    if command -v apt-get &>/dev/null; then
        echo "sudo apt install ${apt}"
    elif command -v dnf &>/dev/null; then
        echo "sudo dnf install ${dnf}"
    elif command -v pacman &>/dev/null; then
        echo "sudo pacman -S ${pacman}"
    else
        echo ''
    fi
}

# Fills MISSING_LIBS and, when it is not empty, explains what to install.
#
# Always returns 0: a missing library is something to tell the user, not a
# failed download — the files are worth installing either way, and the only
# thing this script may not do is install system packages.
check_system_libraries() {
    local dir="${1:-$INSTALL_DIR}"
    local lib_dir="$dir/lib"
    local f line soname missing=""

    [ -d "$lib_dir" ] || return 0
    command -v ldd &>/dev/null || return 0

    # The launcher *and* the Flutter plugins. This build links its plugins into
    # the launcher, so the launcher's chain already covers them; another build
    # dlopens them, which is why each one is checked as well. The rest of the
    # bundle is deliberately out of scope: the JNI bridge and the llama runtime
    # (with its GPU backend) are loaded only when something asks for them, so a
    # machine with no JVM and no Vulkan still runs Nexus — on the CPU.
    for f in "$dir/nexus" "$lib_dir"/*_plugin.so "$lib_dir"/*_plugin.dll; do
        [ -f "$f" ] || continue
        while IFS= read -r line; do
            soname="${line%% *}"
            # A library the archive already ships resolves at runtime; only a
            # soname that is nowhere in the bundle is this machine's to add.
            [ -e "$lib_dir/$(basename "$soname")" ] && continue
            case "$missing" in
                *"$soname"*) ;;
                *) missing="${missing}${soname}"$'\n' ;;
            esac
        done < <(LD_LIBRARY_PATH="$lib_dir${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" \
            ldd "$f" 2>/dev/null \
            | sed -n 's/^[[:space:]]*\([^[:space:]]*\) => not found.*/\1/p')
    done

    MISSING_LIBS="$missing"
    [ -n "$missing" ] || return 0

    echo ""
    warn "Nexus is installed, but it will not start yet — this system is missing:"
    echo ""
    while IFS= read -r soname; do
        local pkg cmd
        [ -n "$soname" ] || continue
        pkg=$(soname_package "$soname")
        echo -e "    ${CYAN}${soname}${NC}"
        if [ -z "$pkg" ]; then
            echo "      install the package that provides it on your distribution"
            continue
        fi
        cmd=$(install_command_for "$pkg")
        if [ -n "$cmd" ]; then
            echo -e "      install it with:  ${YELLOW}${cmd}${NC}"
        else
            echo "      install the package that provides it — Debian/Ubuntu:"
            echo "      ${pkg%%|*}; Fedora: $(echo "$pkg" | cut -d'|' -f2); Arch: $(echo "$pkg" | cut -d'|' -f3)"
        fi
    done <<<"$missing"
    echo ""
    info "Nothing was installed for you — run the command above, then start Nexus again."
    return 0
}

# Main install
main() {
    echo ""
    echo -e "${CYAN}  Nexus — your devices, one system.${NC}"
    echo ""

    local platform
    platform=$(detect_platform)
    local os="${platform%%-*}"
    local arch="${platform##*-}"
    info "Detected platform: ${platform}"

    # Only builds that are actually published may install. Anything else
    # stops with a clear message instead of failing mid-download with a 404.
    case "$platform" in
        linux-x64)
            ;;
        linux-arm64)
            fail "Linux on ARM isn't published yet — only x86_64 Linux builds exist today. Run this on an x86_64 machine, or build from source."
            ;;
        windows-x64)
            info "Windows via Git Bash detected. Tip: native Windows users can skip bash entirely:"
            info "  irm https://raw.githubusercontent.com/TVcraft01/Nexus/main/tools/install.ps1 | iex"
            ;;
        windows-arm64)
            fail "Windows on ARM isn't published yet — only x86_64 Windows builds exist today. In PowerShell, run: irm https://raw.githubusercontent.com/TVcraft01/Nexus/main/tools/install.ps1 | iex"
            ;;
        macos-*)
            fail "macOS isn't published yet — Nexus runs on Linux (x86_64), Windows (x86_64), and Android today. Windows users can install from PowerShell: irm https://raw.githubusercontent.com/TVcraft01/Nexus/main/tools/install.ps1 | iex"
            ;;
        *)
            fail "No build is published for ${os}-${arch}. Published today: Linux x86_64, Windows x86_64, and Android."
            ;;
    esac

    # Make install dir
    mkdir -p "$INSTALL_DIR"

    # Get latest version
    info "Checking latest release..."
    local version
    version=$(get_latest_release)
    if [ -z "$version" ]; then
        fail "Could not fetch latest release. Check your internet connection."
    fi
    info "Latest version: ${version}"

    case "$os" in
        linux)
            local url="https://github.com/${REPO}/releases/download/${version}/nexus-linux-x64.tar.gz"
            local archive="/tmp/nexus-linux.tar.gz"
            info "Downloading Linux build..."
            download "$url" "$archive"
            info "Extracting..."
            tar -xzf "$archive" -C "$INSTALL_DIR" --strip-components=1
            rm -f "$archive"
            chmod +x "$INSTALL_DIR/nexus"
            ;;

        windows)
            command -v unzip >/dev/null 2>&1 \
                || fail "unzip is missing — install it (Git Bash usually bundles it), or use the PowerShell installer instead: irm https://raw.githubusercontent.com/TVcraft01/Nexus/main/tools/install.ps1 | iex"
            local url="https://github.com/${REPO}/releases/download/${version}/nexus-windows-x64.zip"
            local archive="/tmp/nexus-windows.zip"
            info "Downloading Windows build..."
            download "$url" "$archive"
            info "Extracting..."
            unzip -qo "$archive" -C "$INSTALL_DIR"
            rm -f "$archive"
            ;;
    esac

    # Unpacked: check that this machine provides the libraries the app links
    # against and the archive cannot carry, before anything says it is ready.
    check_system_libraries "$INSTALL_DIR"

    # Add to PATH if not already there
    local shell_profile=""
    if [ -f "$HOME/.bashrc" ]; then
        shell_profile="$HOME/.bashrc"
    elif [ -f "$HOME/.zshrc" ]; then
        shell_profile="$HOME/.zshrc"
    fi

    if [ -n "$shell_profile" ]; then
        if ! grep -q "$INSTALL_DIR" "$shell_profile" 2>/dev/null; then
            echo "export PATH=\"\$PATH:$INSTALL_DIR\"" >> "$shell_profile"
            info "Added $INSTALL_DIR to PATH in $shell_profile"
        fi
    fi

    # Create .desktop file so the app shows in the app menu
    if [ "$os" = "linux" ]; then
        local desktop_dir="$HOME/.local/share/applications"
        mkdir -p "$desktop_dir"
        cat > "$desktop_dir/nexus.desktop" <<DESKTOP
[Desktop Entry]
Name=Nexus
Comment=Your devices, one system
Exec=$INSTALL_DIR/nexus
Icon=$INSTALL_DIR/data/flutter_assets/assets/tray_icon.png
Terminal=false
Type=Application
Categories=Utility;Network;
StartupNotify=false
DESKTOP
        chmod +x "$desktop_dir/nexus.desktop"
        ok "Added Nexus to your app menu"
    fi

    ok "Installed to $INSTALL_DIR/nexus"
    echo ""
    if [ -n "$MISSING_LIBS" ]; then
        # The warning above named the package and the command; following it
        # with "To run now" would contradict it — the app cannot start yet.
        echo -e "  ${YELLOW}Install the library above, then start Nexus:${NC}"
        echo -e "    ${CYAN}$INSTALL_DIR/nexus${NC}"
        echo ""
        return 0
    fi
    echo -e "  ${GREEN}To run now:${NC}"
    echo -e "    ${CYAN}$INSTALL_DIR/nexus${NC}"
    echo ""
    if [ -n "$shell_profile" ]; then
        echo -e "  ${YELLOW}After restarting your terminal (or running source $shell_profile):${NC}"
        echo -e "    ${CYAN}nexus${NC}"
    fi
    echo ""
    echo -e "  On Linux: look for ${CYAN}Nexus${NC} in your app menu."
    echo -e "  The app runs in the system tray — close the window and it keeps running."
    echo ""
}

# The check on its own: no download, no writes. Run it on a machine where
# Nexus is already installed to see exactly what the app will find at startup.
case "${1:-}" in
    --check-deps)
        check_system_libraries "${2:-$INSTALL_DIR}"
        exit 0
        ;;
esac

main "$@"

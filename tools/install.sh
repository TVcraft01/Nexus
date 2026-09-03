#!/usr/bin/env bash
set -euo pipefail

# Nexus — cross-platform installer
# Detects your OS and installs the latest release from GitHub.
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/TVcraft01/Nexus/main/tools/install.sh | bash
#
# Or download and run:
#   bash install.sh

REPO="TVcraft01/Nexus"
INSTALL_DIR="${NEXUS_INSTALL_DIR:-$HOME/.nexus}"
BINARY_NAME="nexus"

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
        *) fail "Unsupported architecture: $(uname -m)" ;;
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

# Main install
main() {
    echo ""
    echo -e "${CYAN}  Nexus — your devices, one system.${NC}"
    echo ""

    local platform
    platform=$(detect_platform)
    info "Detected platform: ${platform}"

    local os="${platform%%-*}"

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

        macos)
            local url="https://github.com/${REPO}/releases/download/${version}/nexus-macos-universal.zip"
            local archive="/tmp/nexus-macos.zip"
            info "Downloading macOS build..."
            download "$url" "$archive"
            info "Extracting..."
            unzip -qo "$archive" -C "$INSTALL_DIR"
            rm -f "$archive"
            chmod +x "$INSTALL_DIR/nexus" 2>/dev/null || true
            ;;

        windows)
            local url="https://github.com/${REPO}/releases/download/${version}/nexus-windows-x64.zip"
            local archive="/tmp/nexus-windows.zip"
            info "Downloading Windows build..."
            download "$url" "$archive"
            info "Extracting..."
            unzip -qo "$archive" -C "$INSTALL_DIR"
            rm -f "$archive"
            ;;
    esac

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

main "$@"

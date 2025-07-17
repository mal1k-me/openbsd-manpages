#!/usr/bin/env bash

# OpenBSD Manpages + Mandoc Installer Script
# Installs OpenBSD 7.7 manpages and mandoc suite to ~/.local/

set -euo pipefail # Exit on error, undefined vars, pipe failures

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
OPENBSD_VERSION="7.7"
MANDOC_VERSION="1.14.6"
MAN_URL="https://cdn.openbsd.org/pub/OpenBSD/${OPENBSD_VERSION}/amd64/man${OPENBSD_VERSION//./}.tgz"
COMP_URL="https://cdn.openbsd.org/pub/OpenBSD/${OPENBSD_VERSION}/amd64/comp${OPENBSD_VERSION//./}.tgz"
MANDOC_URL="https://mandoc.bsd.lv/snapshots/mandoc-${MANDOC_VERSION}.tar.gz"
MANDOC_ST_URL="https://raw.githubusercontent.com/openbsd/src/refs/heads/master/usr.bin/mandoc/st.c"
MANDOC_CONFIG_URL="https://gitlab.archlinux.org/archlinux/packaging/packages/mandoc/-/raw/main/configure.local"

DOCS_DIR="$HOME/.local/share/openbsd"
BIN_DIR="$HOME/.local/bin"
TEMP_DIR="/tmp/openbsd-man-$$"

# Functions
print_status() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

cleanup() {
    if [[ -d "$TEMP_DIR" ]]; then
        rm -rf "$TEMP_DIR"
        print_status "Cleaned up temporary directory"
    fi
}

# Trap to cleanup on exit
trap cleanup EXIT

check_dependencies() {
    print_status "Checking dependencies..."

    local missing_deps=()

    command -v wget >/dev/null 2>&1 || missing_deps+=("wget")
    command -v tar >/dev/null 2>&1 || missing_deps+=("tar")
    command -v make >/dev/null 2>&1 || missing_deps+=("make")
    (command -v gcc >/dev/null 2>&1 || command -v clang >/dev/null 2>&1) || missing_deps+=("gcc or clang")

    if [[ ${#missing_deps[@]} -gt 0 ]]; then
        print_error "Missing dependencies: ${missing_deps[*]}"
        print_error "Install with: sudo pacman -S base-devel (or individual packages: ${missing_deps[*]})"
        exit 1
    fi

    print_success "All dependencies found"
}

extract_makepkg_var() {
    local var_name="$1"
    if [[ -f /etc/makepkg.conf ]]; then
        sed -n "/^${var_name}=/{
            # If the line ends with a quote, it's single-line
            /\"$/{ p; b }
            # Otherwise, it's multi-line - print from here to closing quote
            :a
            p
            n
            /^[^#]*\"$/{ p; b }
            ba
        }" /etc/makepkg.conf
    fi
}

get_makepkg_flags() {
    # Extract CFLAGS and check exit code and output
    CFLAGS_LINES=$(extract_makepkg_var "CFLAGS")
    cflags_status=$?
    if [[ $cflags_status -ne 0 || -z "$CFLAGS_LINES" ]]; then
        print_warning "Falling back to default CFLAGS"
        CFLAGS_LINES='CFLAGS="-march=x86-64 -mtune=generic -O2 -pipe -fno-plt -fexceptions \
        -Wp,-D_FORTIFY_SOURCE=3 -Wformat -Werror=format-security \
        -fstack-clash-protection -fcf-protection \
        -fno-omit-frame-pointer -mno-omit-leaf-frame-pointer"'
    fi

    # Extract LDFLAGS and check exit code and output
    LDFLAGS_LINES=$(extract_makepkg_var "LDFLAGS")
    ldflags_status=$?
    if [[ $ldflags_status -ne 0 || -z "$LDFLAGS_LINES" ]]; then
        print_warning "Falling back to default LDFLAGS"
        LDFLAGS_LINES='LDFLAGS="-Wl,-O1 -Wl,--sort-common -Wl,--as-needed -Wl,-z,relro -Wl,-z,now \
        -Wl,-z,pack-relative-relocs"'
    fi
}

create_directories() {
    print_status "Creating directories..."

    if [[ -d "$DOCS_DIR" ]]; then
        rm -rf "$DOCS_DIR"
        print_status "Deleted existing $DOCS_DIR for clean install"
    fi

    mkdir -p "$DOCS_DIR"
    mkdir -p "$BIN_DIR"
    mkdir -p "$TEMP_DIR"

    print_success "Directories created"
}

download_files() {
    print_status "Downloading OpenBSD ${OPENBSD_VERSION} manpages and mandoc..."

    cd "$TEMP_DIR"

    # Download base manpages
    print_status "Downloading man${OPENBSD_VERSION//./}.tgz..."
    wget -q --show-progress "$MAN_URL" -O "man${OPENBSD_VERSION//./}.tgz"

    # Download compiler/development manpages
    print_status "Downloading comp${OPENBSD_VERSION//./}.tgz..."
    wget -q --show-progress "$COMP_URL" -O "comp${OPENBSD_VERSION//./}.tgz"

    # Download mandoc
    print_status "Downloading mandoc-${MANDOC_VERSION}..."
    wget -q --show-progress "$MANDOC_URL" -O "mandoc-${MANDOC_VERSION}.tar.gz"

    print_success "Downloads completed"
}

build_mandoc() {
    print_status "Building mandoc from source..."

    cd "$TEMP_DIR"

    # Extract mandoc
    tar -xzf "mandoc-${MANDOC_VERSION}.tar.gz"
    cd "mandoc-${MANDOC_VERSION}"

    # Download and replace st.c with upstream
    print_status "Patching st.c with upstream version..."
    wget -q "$MANDOC_ST_URL" -O "st.c"

    # Download and replace configure.local
    print_status "Downloading Arch Linux configure.local..."
    wget -q "$MANDOC_CONFIG_URL" -O "configure.local"

    # Get Arch build flags
    get_makepkg_flags

    # Append CFLAGS and LDFLAGS to configure.local
    print_status "Appending build flags to configure.local..."
    echo "" >>configure.local
    echo "# Arch Linux build flags" >>configure.local
    echo "$CFLAGS_LINES" >>configure.local
    echo "$LDFLAGS_LINES" >>configure.local

    # Configure and build
    print_status "Configuring mandoc..."
    ./configure

    print_status "Compiling mandoc..."
    make -j"$(nproc)"

    # Copy binaries to ~/.local/bin
    print_status "Installing mandoc binaries to $BIN_DIR..."
    local binaries=(soelim mandocd mandoc man demandoc catman)

    for binary in "${binaries[@]}"; do
        if [[ -f "$binary" ]]; then
            cp "$binary" "$BIN_DIR/"
            print_success "Installed $binary"
        else
            print_warning "$binary not found after build"
        fi
    done

    print_success "Mandoc build and installation completed"
}

extract_manpages() {
    print_status "Extracting manpages to $DOCS_DIR..."

    cd "$TEMP_DIR"

    # Create a temporary extraction directory
    local extract_temp="$TEMP_DIR/extract"
    mkdir -p "$extract_temp"

    # Extract base manpages
    print_status "Extracting base system manpages..."
    tar -xzf "man${OPENBSD_VERSION//./}.tgz" -C "$extract_temp"

    # Extract development manpages and info pages
    print_status "Extracting development manpages and info pages..."
    tar -xzf "comp${OPENBSD_VERSION//./}.tgz" -C "$extract_temp" \
        './usr/share/man/' './usr/share/info/' './usr/share/doc/' 2>/dev/null || true

    # Move extracted content to the final destination (flatten structure)
    if [[ -d "$extract_temp/usr/share" ]]; then
        print_status "Moving extracted files to final location..."
        cp -r "$extract_temp/usr/share/"* "$DOCS_DIR/"
    fi

    print_success "Extraction completed"

    # Verify extraction and show stats
    if [[ -d "$DOCS_DIR/man" ]]; then
        local manpage_count=$(find "$DOCS_DIR/man" -name "*.[0-9]*" | wc -l)
        print_status "Installed $manpage_count manpages total"

        # Build manpage database using our custom mandoc
        print_status "Building manpage database with mandoc..."
        if [[ -f "$BIN_DIR/mandoc" ]]; then
            "makewhatis" "$DOCS_DIR/man" 2>/dev/null ||
                print_warning "Failed to build manpage database (non-critical)"
        fi
    else
        print_error "Extraction verification failed - man directory not found"
        exit 1
    fi
}

create_wrapper_scripts() {
    print_status "Creating wrapper scripts in $BIN_DIR..."

    # Create obsdman wrapper using our custom mandoc
    cat >"$BIN_DIR/obsdman" <<EOF
#!/usr/bin/env bash
# OpenBSD manpages wrapper with custom mandoc
# Usage: obsdman [section] command

export MANPATH="$DOCS_DIR/man"
"$BIN_DIR/man" -I os="OpenBSD ${OPENBSD_VERSION}" "\$@"
EOF

    chmod +x "$BIN_DIR/obsdman"
    print_success "Created obsdman wrapper"

    # Create obsdinfo wrapper
    cat >"$BIN_DIR/obsdinfo" <<EOF
#!/usr/bin/env bash
# OpenBSD info pages wrapper
export INFOPATH="$DOCS_DIR/info"
info "\$@"
EOF

    chmod +x "$BIN_DIR/obsdinfo"
    print_success "Created obsdinfo wrapper"

    # Create obsdapropos wrapper
    cat >"$BIN_DIR/obsdapropos" <<EOF
#!/usr/bin/env bash
# OpenBSD apropos wrapper using custom mandoc
export MANPATH="$DOCS_DIR/man"
"$BIN_DIR/man" -k "\$@"
EOF

    chmod +x "$BIN_DIR/obsdapropos"
    print_success "Created obsdapropos wrapper"
}

check_path() {
    if [[ ":$PATH:" != *":$BIN_DIR:"* ]]; then
        print_warning "$BIN_DIR is not in your PATH"
        print_warning "Add this to your ~/.config/fish/config.fish:"
        echo ""
        echo "fish_add_path $BIN_DIR"
        echo ""
        print_warning "Or for bash/zsh, add to ~/.bashrc:"
        echo "export PATH=\"\$HOME/.local/bin:\$PATH\""
    else
        print_success "$BIN_DIR is in your PATH"
    fi
}

show_usage() {
    print_success "Installation completed successfully!"
    echo ""
    print_status "Installed mandoc binaries:"
    echo "  mandoc, man, soelim, mandocd, demandoc, catman"
    echo ""

    print_status "Usage examples:"
    echo "  obsdman ls          # OpenBSD ls manpage"
    echo "  obsdman 3 printf    # OpenBSD printf from section 3"
    echo "  obsdman 8 mount     # OpenBSD mount from section 8"
    echo "  obsdman pf          # OpenBSD Packet Filter"
    echo "  obsdman pledge      # OpenBSD pledge system call"
    echo "  obsdapropos network # Search OpenBSD manpages"
    echo "  obsdinfo cvs        # OpenBSD CVS info page"

    echo ""
    print_status "Direct mandoc usage:"
    echo "  ~/.local/bin/mandoc -T html /path/to/manpage  # Convert to HTML"
    echo "  ~/.local/bin/man 1 ls                         # Using custom man"
}

main() {
    echo "OpenBSD ${OPENBSD_VERSION} Manpages + Mandoc Snapshot v${MANDOC_VERSION} Installer"
    echo "========================================================"
    echo ""

    check_dependencies
    create_directories
    download_files
    build_mandoc
    extract_manpages
    create_wrapper_scripts

    check_path
    show_usage
}

case "${1:-}" in
-h | --help)
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "Options:"
    echo "  -h, --help      Show this help message"
    echo "  -u, --uninstall Remove installed manpages, mandoc, and wrappers"
    echo ""
    echo "Installs OpenBSD's ${OPENBSD_VERSION} manpages and mandoc v${MANDOC_VERSION} suite to ~/.local/"
    exit 0
    ;;
-u | --uninstall)
    print_status "Uninstalling OpenBSD manpages and mandoc..."
    rm -rf "$DOCS_DIR"
    rm -f "$BIN_DIR/obsdman" "$BIN_DIR/obsdinfo" "$BIN_DIR/obsdapropos"
    rm -f "$BIN_DIR/soelim" "$BIN_DIR/mandocd" "$BIN_DIR/mandoc"
    rm -f "$BIN_DIR/man" "$BIN_DIR/demandoc" "$BIN_DIR/catman"

    print_success "Uninstallation completed"
    exit 0
    ;;
"")
    main
    ;;
*)
    print_error "Unknown option: $1"
    print_error "Use -h or --help for usage information"
    exit 1
    ;;
esac

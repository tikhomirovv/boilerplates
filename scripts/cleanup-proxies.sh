#!/bin/sh

# Check if terminal supports colors
if [ -t 1 ] && command -v tput > /dev/null 2>&1; then
    RED=$(tput setaf 1)
    GREEN=$(tput setaf 2)
    YELLOW=$(tput setaf 3)
    NC=$(tput sgr0)
else
    RED=""
    GREEN=""
    YELLOW=""
    NC=""
fi

print_info() {
    printf "%s[INFO]%s %s\n" "${GREEN}" "${NC}" "$1"
}

print_error() {
    printf "%s[ERROR]%s %s\n" "${RED}" "${NC}" "$1"
}

print_warning() {
    printf "%s[WARNING]%s %s\n" "${YELLOW}" "${NC}" "$1"
}

# Function to check if running as root
check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        print_error "Please run as root (use sudo)"
        exit 1
    fi
}

# Main cleanup function
cleanup_all() {
    print_info "Starting cleanup of proxy servers..."
    echo ""

    # Stop and disable services
    print_info "Stopping services..."

    # Dante service
    if systemctl is-active --quiet danted 2>/dev/null; then
        print_info "Stopping danted service..."
        systemctl stop danted
        systemctl disable danted
    fi

    # Shadowsocks-libev service
    if systemctl is-active --quiet shadowsocks-libev 2>/dev/null; then
        print_info "Stopping shadowsocks-libev service..."
        systemctl stop shadowsocks-libev
        systemctl disable shadowsocks-libev
    fi

    echo ""

    # Remove packages
    print_info "Removing packages..."

    if dpkg -l | grep -q "^ii.*dante-server"; then
        print_info "Removing dante-server..."
        apt-get remove --purge -y dante-server
    fi

    if dpkg -l | grep -q "^ii.*shadowsocks-libev"; then
        print_info "Removing shadowsocks-libev..."
        apt-get remove --purge -y shadowsocks-libev
    fi

    echo ""

    # Remove configuration files
    print_info "Removing configuration files..."

    if [ -f "/etc/danted.conf" ]; then
        print_info "Removing /etc/danted.conf..."
        rm -f /etc/danted.conf
        # Also remove backups
        rm -f /etc/danted.conf.bak.* 2>/dev/null
    fi

    if [ -d "/etc/shadowsocks-libev" ]; then
        print_info "Removing /etc/shadowsocks-libev/..."
        rm -rf /etc/shadowsocks-libev
    fi

    echo ""

    # Remove proxy users (if they exist)
    print_info "Removing proxy users..."

    # Dante proxy user (default from script)
    if id "socks5proxy" > /dev/null 2>&1; then
        print_info "Removing user socks5proxy..."
        userdel -r socks5proxy 2>/dev/null || userdel socks5proxy 2>/dev/null
    fi

    # Check for other possible proxy users
    # Note: shadowsocks doesn't create system users, so we only check for dante users

    echo ""

    # Clean up autoremove
    print_info "Cleaning up unused packages..."
    apt-get autoremove -y > /dev/null 2>&1
    apt-get autoclean -y > /dev/null 2>&1

    echo ""
    print_info "Cleanup completed!"
    echo ""
    print_warning "Note: Firewall rules were not removed automatically."
    print_info "If you want to remove firewall rules, check:"
    print_info "  - UFW: sudo ufw status"
    print_info "  - iptables: sudo iptables -L -n"
}

# Main
check_root

print_warning "This will remove Dante SOCKS5 and Shadowsocks-libev from your system."
print_warning "This includes:"
echo "  - Stopping and disabling services"
echo "  - Removing packages"
echo "  - Removing configuration files"
echo "  - Removing proxy users"
echo ""
printf "Are you sure you want to continue? (yes/no): "
read REPLY

case "$REPLY" in
    yes|YES|y|Y)
        cleanup_all
        ;;
    *)
        print_info "Cleanup cancelled"
        exit 0
        ;;
esac

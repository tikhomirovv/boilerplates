#!/bin/sh

# Check if terminal supports colors
if [ -t 1 ] && command -v tput > /dev/null 2>&1; then
    # Terminal supports colors
    RED=$(tput setaf 1)
    GREEN=$(tput setaf 2)
    YELLOW=$(tput setaf 3)
    NC=$(tput sgr0) # No Color
else
    # Terminal doesn't support colors or not interactive
    RED=""
    GREEN=""
    YELLOW=""
    NC=""
fi

# Configuration paths for Dante SOCKS5 proxy
CONFIG_FILE="/etc/danted.conf"
SERVICE_NAME="danted"
PROXY_USER="socks5proxy"

# Function to print colored messages
# Using printf instead of echo -e for POSIX sh compatibility
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

# Function to check if Dante is installed
check_dante_installed() {
    # Check if service exists and package is installed
    if systemctl list-unit-files | grep -q "^${SERVICE_NAME}.service" || \
       dpkg -l | grep -q "^ii.*dante-server"; then
        return 0
    fi
    return 1
}

# Function to get default network interface
get_default_interface() {
    # Try to get default route interface
    if command -v ip > /dev/null 2>&1; then
        ip route | awk '/default/ {print $5}' | head -1
    elif command -v route > /dev/null 2>&1; then
        route -n | awk '/^0.0.0.0/ {print $8}' | head -1
    else
        # Fallback to eth0
        echo "eth0"
    fi
}

# Function to install Dante
install_dante() {
    print_info "Installing Dante SOCKS5 proxy server..."

    # Update package list
    print_info "Updating package list..."
    if ! apt-get update -qq; then
        print_error "Failed to update package list"
        return 1
    fi

    # Install dante-server from Debian/Ubuntu repository
    print_info "Installing dante-server package..."
    if ! apt-get install -y dante-server; then
        print_error "Failed to install dante-server"
        return 1
    fi

    # Verify installation
    if systemctl list-unit-files | grep -q "^${SERVICE_NAME}.service" || \
       dpkg -l | grep -q "^ii.*dante-server"; then
        print_info "Dante installed successfully"
        return 0
    else
        print_error "Installation completed but service not found"
        return 1
    fi
}

# Function to get user input with default value
get_input() {
    local prompt="$1"
    local default="$2"
    local var_name="$3"
    local input

    if [ -n "$default" ]; then
        read -p "$prompt [$default]: " input
        eval "$var_name=\"\${input:-$default}\""
    else
        read -p "$prompt: " input
        eval "$var_name=\"$input\""
    fi
}

# Function to validate port
validate_port() {
    local port=$1
    # Check if port is numeric using case statement (POSIX compatible)
    case "$port" in
        ''|*[!0-9]*) return 1 ;;
    esac
    # Check if port is in valid range
    if [ "$port" -lt 1 ] || [ "$port" -gt 65535 ]; then
        return 1
    fi
    return 0
}

# Function to setup configuration
setup_config() {
    print_info "Starting SOCKS5 proxy setup..."

    # Get server port
    SERVER_PORT=""
    if [ -f "$CONFIG_FILE" ]; then
        print_warning "Configuration file already exists. It will be updated."
        # Try to extract existing port from config
        if [ -f "$CONFIG_FILE" ]; then
            EXISTING_PORT=$(grep -o "internal:.*port[[:space:]]*=[[:space:]]*[0-9]*" "$CONFIG_FILE" 2>/dev/null | grep -o '[0-9]*' | head -1)
        fi
    fi

    while true; do
        get_input "Enter server port" "${EXISTING_PORT:-1080}" "SERVER_PORT"
        if validate_port "$SERVER_PORT"; then
            break
        else
            print_error "Invalid port. Please enter a number between 1 and 65535"
        fi
    done

    # Get username
    get_input "Enter proxy username" "$PROXY_USER" "PROXY_USER"
    if [ -z "$PROXY_USER" ]; then
        print_error "Username cannot be empty"
        exit 1
    fi

    # Get password
    get_input "Enter proxy password" "" "PROXY_PASSWORD"
    if [ -z "$PROXY_PASSWORD" ]; then
        print_error "Password cannot be empty"
        exit 1
    fi

    # Get network interface
    DEFAULT_INTERFACE=$(get_default_interface)
    get_input "Enter network interface for external connections" "$DEFAULT_INTERFACE" "NETWORK_INTERFACE"

    # Create or update proxy user
    print_info "Creating proxy user..."
    if id "$PROXY_USER" > /dev/null 2>&1; then
        print_warning "User $PROXY_USER already exists. Updating password..."
        echo "$PROXY_USER:$PROXY_PASSWORD" | chpasswd
    else
        useradd --system --shell /usr/sbin/nologin --home-dir /dev/null --no-create-home "$PROXY_USER"
        echo "$PROXY_USER:$PROXY_PASSWORD" | chpasswd
        print_info "User $PROXY_USER created"
    fi

    # Backup existing config if it exists
    if [ -f "$CONFIG_FILE" ]; then
        cp "$CONFIG_FILE" "${CONFIG_FILE}.bak.$(date +%Y%m%d_%H%M%S)"
        print_info "Backup of existing config created"
    fi

    # Create configuration file for Dante
    print_info "Creating configuration file..."
    cat > "$CONFIG_FILE" << EOF
# Dante SOCKS5 proxy server configuration
# Generated by socks5.sh setup script

# Logging
logoutput: syslog

# Internal interface (where proxy listens)
internal: 0.0.0.0 port = $SERVER_PORT

# External interface (for outgoing connections)
external: $NETWORK_INTERFACE

# Authentication method: username/password
socksmethod: username

# User privileges
user.privileged: root
user.unprivileged: nobody

# Client rules - allow connections from anywhere
client pass {
    from: 0.0.0.0/0 to: 0.0.0.0/0
    log: error connect disconnect
}

# SOCKS rules - allow connections to anywhere
socks pass {
    from: 0.0.0.0/0 to: 0.0.0.0/0
    log: error connect disconnect
}
EOF

    print_info "Configuration file created at $CONFIG_FILE"

    # Setup firewall
    setup_firewall "$SERVER_PORT"

    # Restart service
    print_info "Restarting Dante service..."
    systemctl restart "$SERVICE_NAME"

    # Check status
    sleep 2
    if systemctl is-active --quiet "$SERVICE_NAME"; then
        print_info "SOCKS5 proxy service started successfully!"
        print_info "Server is listening on port $SERVER_PORT"
        echo ""
        print_info "Your connection details:"
        echo "  Server: $(hostname -I | awk '{print $1}')"
        echo "  Port: $SERVER_PORT"
        echo "  Username: $PROXY_USER"
        echo "  Password: $PROXY_PASSWORD"
        echo ""
        print_info "For iOS: Settings > Wi-Fi > (i) > Configure Proxy > Manual"
        print_info "  Server: $(hostname -I | awk '{print $1}')"
        print_info "  Port: $SERVER_PORT"
        print_info "  Authentication: ON"
        print_info "  Username: $PROXY_USER"
        print_info "  Password: $PROXY_PASSWORD"
    else
        print_error "Failed to start SOCKS5 proxy service"
        print_info "Check logs with: sudo journalctl -u $SERVICE_NAME -n 50"
        exit 1
    fi
}

# Function to setup firewall
setup_firewall() {
    local port=$1
    print_info "Configuring firewall for port $port..."

    # Check if ufw is installed and active
    if command -v ufw > /dev/null 2>&1; then
        if ufw status | grep -q "Status: active"; then
            ufw allow "$port/tcp" > /dev/null 2>&1
            print_info "Firewall rule added (UFW) for TCP"
        fi
    fi

    # Also try iptables (if ufw is not used)
    if command -v iptables > /dev/null 2>&1; then
        # Check if TCP rule already exists
        if ! iptables -C INPUT -p tcp --dport "$port" -j ACCEPT 2>/dev/null; then
            iptables -A INPUT -p tcp --dport "$port" -j ACCEPT
            print_info "Firewall rule added (iptables) for TCP"
        fi
    fi
}

# Function to show help
show_help() {
    cat << EOF
SOCKS5 Proxy Server Management Script (Dante)

Usage:
    $0 [command]

Commands:
    help           Show this help message
    setup          Interactive setup/configuration
    start          Start SOCKS5 proxy service
    stop           Stop SOCKS5 proxy service
    restart        Restart SOCKS5 proxy service
    status         Show service status
    logs           Show service logs (last 50 lines)
    logs-follow    Follow service logs (real-time)
    config         Show current configuration
    test           Test if server is listening on port

Examples:
    $0              # Show help (default)
    $0 help         # Show help
    $0 setup        # Run interactive setup
    $0 status       # Check service status
    $0 logs         # View recent logs
    $0 restart      # Restart service

Setup Process:
    When you run '$0 setup', the script will:
    1. Check and install Dante if needed
    2. Ask for configuration (port, username, password, network interface)
    3. Create proxy user for authentication
    4. Create/update configuration file
    5. Configure firewall
    6. Start and enable the service

Configuration File:
    Location: $CONFIG_FILE

Service Management:
    Uses systemd service: '$SERVICE_NAME'
    You can also use standard systemctl commands:
    - sudo systemctl start $SERVICE_NAME
    - sudo systemctl stop $SERVICE_NAME
    - sudo systemctl restart $SERVICE_NAME
    - sudo systemctl status $SERVICE_NAME

iOS Configuration:
    Settings > Wi-Fi > (i) > Configure Proxy > Manual
    - Server: your server IP
    - Port: configured port (default 1080)
    - Authentication: ON
    - Username: configured username
    - Password: configured password

EOF
}

# Function to show status
show_status() {
    if systemctl is-active --quiet "$SERVICE_NAME"; then
        print_info "Service is running"
    else
        print_error "Service is stopped"
    fi

    echo ""
    systemctl status "$SERVICE_NAME" --no-pager -l
}

# Function to show logs
show_logs() {
    print_info "Showing last 50 lines of logs..."
    journalctl -u "$SERVICE_NAME" -n 50 --no-pager
}

# Function to follow logs
follow_logs() {
    print_info "Following logs (Ctrl+C to exit)..."
    journalctl -u "$SERVICE_NAME" -f
}

# Function to show config
show_config() {
    if [ -f "$CONFIG_FILE" ]; then
        print_info "Current configuration:"
        echo ""
        cat "$CONFIG_FILE"
    else
        print_error "Configuration file not found. Run 'setup' first."
        exit 1
    fi
}

# Function to test server
test_server() {
    if [ ! -f "$CONFIG_FILE" ]; then
        print_error "Configuration file not found"
        exit 1
    fi

    # Try to extract port from config
    PORT=$(grep -o "internal:.*port[[:space:]]*=[[:space:]]*[0-9]*" "$CONFIG_FILE" 2>/dev/null | grep -o '[0-9]*' | head -1)

    if [ -z "$PORT" ]; then
        print_error "Could not read port from configuration"
        exit 1
    fi

    print_info "Testing if server is listening on port $PORT..."

    if command -v netstat > /dev/null 2>&1; then
        if netstat -tlnp 2>/dev/null | grep -q ":$PORT "; then
            print_info "Server is listening on port $PORT"
        else
            print_error "Server is NOT listening on port $PORT"
        fi
    elif command -v ss > /dev/null 2>&1; then
        if ss -tlnp 2>/dev/null | grep -q ":$PORT "; then
            print_info "Server is listening on port $PORT"
        else
            print_error "Server is NOT listening on port $PORT"
        fi
    else
        print_warning "Could not test (netstat/ss not available)"
    fi
}

# Main script logic
main() {
    # Check root privileges
    check_root

    # Parse command
    COMMAND="${1:-help}"

    case "$COMMAND" in
        help)
            show_help
            ;;
        setup)
            # Check if Dante is installed
            if ! check_dante_installed; then
                print_warning "Dante is not installed"
                printf "Do you want to install it now? (y/n): "
                read REPLY
                case "$REPLY" in
                    [Yy]*)
                        install_dante
                        if [ $? -ne 0 ]; then
                            exit 1
                        fi
                        ;;
                    *)
                        print_error "Installation cancelled"
                        exit 1
                        ;;
                esac
            fi
            setup_config
            ;;
        start)
            print_info "Starting service..."
            systemctl start "$SERVICE_NAME"
            show_status
            ;;
        stop)
            print_info "Stopping service..."
            systemctl stop "$SERVICE_NAME"
            show_status
            ;;
        restart)
            print_info "Restarting service..."
            systemctl restart "$SERVICE_NAME"
            sleep 1
            show_status
            ;;
        status)
            show_status
            ;;
        logs)
            show_logs
            ;;
        logs-follow)
            follow_logs
            ;;
        config)
            show_config
            ;;
        test)
            test_server
            ;;
        *)
            print_error "Unknown command: $COMMAND"
            echo ""
            show_help
            exit 1
            ;;
    esac
}

# Run main function
main "$@"

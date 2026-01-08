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

# Configuration paths
CONFIG_DIR="/etc/shadowsocks"
CONFIG_FILE="$CONFIG_DIR/config.json"
SERVICE_FILE="/etc/systemd/system/shadowsocks.service"
SERVICE_NAME="shadowsocks"

# Function to print colored messages
print_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

# Function to check if running as root
check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        print_error "Please run as root (use sudo)"
        exit 1
    fi
}

# Function to check if shadowsocks is installed
check_shadowsocks_installed() {
    if ! command -v ssserver > /dev/null 2>&1; then
        return 1
    fi
    return 0
}

# Function to install shadowsocks
install_shadowsocks() {
    print_info "Installing Shadowsocks..."

    # Update package list
    apt-get update -qq

    # Install Python and pip if not present
    if ! command -v python3 > /dev/null 2>&1; then
        print_info "Installing Python3..."
        apt-get install -y python3 python3-pip > /dev/null 2>&1
    fi

    # Install shadowsocks
    print_info "Installing Shadowsocks via pip..."
    pip3 install shadowsocks > /dev/null 2>&1

    if [ $? -eq 0 ]; then
        print_info "Shadowsocks installed successfully"
        return 0
    else
        print_error "Failed to install Shadowsocks"
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
    print_info "Starting Shadowsocks setup..."

    # Check if config exists
    if [ -f "$CONFIG_FILE" ]; then
        print_warning "Configuration file already exists. It will be updated."

        # Try to read existing values
        if command -v jq > /dev/null 2>&1; then
            EXISTING_PORT=$(jq -r '.server_port' "$CONFIG_FILE" 2>/dev/null)
            EXISTING_METHOD=$(jq -r '.method' "$CONFIG_FILE" 2>/dev/null)
        fi
    fi

    # Get server port
    while true; do
        get_input "Enter server port" "${EXISTING_PORT:-8388}" "SERVER_PORT"
        if validate_port "$SERVER_PORT"; then
            break
        else
            print_error "Invalid port. Please enter a number between 1 and 65535"
        fi
    done

    # Get password
    get_input "Enter password" "" "PASSWORD"
    if [ -z "$PASSWORD" ]; then
        print_error "Password cannot be empty"
        exit 1
    fi

    # Get encryption method
    print_info "Available encryption methods:"
    echo "  1) aes-256-cfb (recommended)"
    echo "  2) aes-128-cfb"
    echo "  3) chacha20-ietf-poly1305"
    echo "  4) aes-256-gcm"
    echo "  5) aes-128-gcm"
    get_input "Select encryption method (1-5) or enter custom" "${EXISTING_METHOD:-aes-256-cfb}" "METHOD_CHOICE"

    case "$METHOD_CHOICE" in
        1) ENCRYPTION_METHOD="aes-256-cfb" ;;
        2) ENCRYPTION_METHOD="aes-128-cfb" ;;
        3) ENCRYPTION_METHOD="chacha20-ietf-poly1305" ;;
        4) ENCRYPTION_METHOD="aes-256-gcm" ;;
        5) ENCRYPTION_METHOD="aes-128-gcm" ;;
        *) ENCRYPTION_METHOD="$METHOD_CHOICE" ;;
    esac

    # Create config directory
    mkdir -p "$CONFIG_DIR"

    # Create configuration file
    print_info "Creating configuration file..."
    cat > "$CONFIG_FILE" << EOF
{
    "server": "0.0.0.0",
    "server_port": $SERVER_PORT,
    "local_address": "127.0.0.1",
    "local_port": 1080,
    "password": "$PASSWORD",
    "timeout": 300,
    "method": "$ENCRYPTION_METHOD",
    "fast_open": false
}
EOF

    print_info "Configuration file created at $CONFIG_FILE"

    # Setup firewall
    setup_firewall "$SERVER_PORT"

    # Create systemd service
    create_systemd_service

    # Reload systemd and start service
    print_info "Starting Shadowsocks service..."
    systemctl daemon-reload
    systemctl enable "$SERVICE_NAME"
    systemctl restart "$SERVICE_NAME"

    # Check status
    sleep 2
    if systemctl is-active --quiet "$SERVICE_NAME"; then
        print_info "Shadowsocks service started successfully!"
        print_info "Server is listening on port $SERVER_PORT"
        echo ""
        print_info "Your connection details:"
        echo "  Server: $(hostname -I | awk '{print $1}')"
        echo "  Port: $SERVER_PORT"
        echo "  Password: $PASSWORD"
        echo "  Method: $ENCRYPTION_METHOD"
    else
        print_error "Failed to start Shadowsocks service"
        print_info "Check logs with: sudo journalctl -u $SERVICE_NAME -n 50"
        exit 1
    fi
}

# Function to setup firewall
setup_firewall() {
    local port=$1
    print_info "Configuring firewall for port $port..."

    # Check if ufw is installed and active
    if command -v ufw &> /dev/null; then
        if ufw status | grep -q "Status: active"; then
            ufw allow "$port/tcp" > /dev/null 2>&1
            print_info "Firewall rule added (UFW)"
        fi
    fi

    # Also try iptables (if ufw is not used)
    if command -v iptables &> /dev/null; then
        # Check if rule already exists
        if ! iptables -C INPUT -p tcp --dport "$port" -j ACCEPT 2>/dev/null; then
            iptables -A INPUT -p tcp --dport "$port" -j ACCEPT
            print_info "Firewall rule added (iptables)"
        fi
    fi
}

# Function to create systemd service
create_systemd_service() {
    print_info "Creating systemd service..."

    # Find ssserver path
    SSERVER_PATH=$(command -v ssserver)
    if [ -z "$SSERVER_PATH" ]; then
        SSERVER_PATH="/usr/local/bin/ssserver"
    fi

    cat > "$SERVICE_FILE" << EOF
[Unit]
Description=Shadowsocks Server
After=network.target

[Service]
Type=simple
User=root
ExecStart=$SSERVER_PATH -c $CONFIG_FILE
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

    print_info "Systemd service file created at $SERVICE_FILE"
}

# Function to show help
show_help() {
    cat << EOF
Shadowsocks Server Management Script

Usage:
    $0 [command]

Commands:
    help           Show this help message
    setup          Interactive setup/configuration
    start          Start Shadowsocks service
    stop           Stop Shadowsocks service
    restart        Restart Shadowsocks service
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
    1. Check and install Shadowsocks if needed
    2. Ask for configuration (port, password, encryption method)
    3. Create/update configuration file
    4. Configure firewall
    5. Create systemd service
    6. Start and enable the service

Configuration File:
    Location: $CONFIG_FILE

Service Management:
    The script creates a systemd service named '$SERVICE_NAME'
    You can also use standard systemctl commands:
    - sudo systemctl start $SERVICE_NAME
    - sudo systemctl stop $SERVICE_NAME
    - sudo systemctl restart $SERVICE_NAME
    - sudo systemctl status $SERVICE_NAME

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
        cat "$CONFIG_FILE" | python3 -m json.tool 2>/dev/null || cat "$CONFIG_FILE"
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

    PORT=$(python3 -c "import json; print(json.load(open('$CONFIG_FILE'))['server_port'])" 2>/dev/null)

    if [ -z "$PORT" ]; then
        print_error "Could not read port from configuration"
        exit 1
    fi

    print_info "Testing if server is listening on port $PORT..."

    if command -v netstat &> /dev/null; then
        if netstat -tlnp 2>/dev/null | grep -q ":$PORT "; then
            print_info "Server is listening on port $PORT"
        else
            print_error "Server is NOT listening on port $PORT"
        fi
    elif command -v ss &> /dev/null; then
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
            # Check if shadowsocks is installed
            if ! check_shadowsocks_installed; then
                print_warning "Shadowsocks is not installed"
                printf "Do you want to install it now? (y/n): "
                read REPLY
                case "$REPLY" in
                    [Yy]*)
                        install_shadowsocks
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

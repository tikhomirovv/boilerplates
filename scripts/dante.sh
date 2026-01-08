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
USERS_FILE="/etc/danted.users"
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

    # Add user to users list file
    if [ ! -f "$USERS_FILE" ]; then
        touch "$USERS_FILE"
        chmod 600 "$USERS_FILE"
    fi
    if ! grep -q "^${PROXY_USER}$" "$USERS_FILE" 2>/dev/null; then
        echo "$PROXY_USER" >> "$USERS_FILE"
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
    user-add       Add a new proxy user
    user-del       Delete a proxy user
    user-list      List all proxy users
    user-passwd    Change user password
    user-stats     Show usage statistics for a user

Examples:
    $0              # Show help (default)
    $0 help         # Show help
    $0 setup        # Run interactive setup
    $0 status       # Check service status
    $0 logs         # View recent logs
    $0 restart      # Restart service
    $0 user-add john    # Add new user 'john'
    $0 user-del john    # Delete user 'john'
    $0 user-list        # List all users
    $0 user-passwd john # Change password for user 'john'
    $0 user-stats john  # Show statistics for user 'john'

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
    Users File: $USERS_FILE

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

# Function to add a new user
add_user() {
    if [ ! -f "$CONFIG_FILE" ]; then
        print_error "Configuration file not found. Run 'setup' first."
        exit 1
    fi

    if [ -z "$2" ]; then
        print_error "Usage: $0 user-add <username>"
        exit 1
    fi

    local username="$2"

    # Check if user already exists
    if id "$username" > /dev/null 2>&1; then
        print_error "User $username already exists"
        exit 1
    fi

    # Get password
    printf "Enter password for user $username: "
    stty -echo
    read password
    stty echo
    echo ""

    if [ -z "$password" ]; then
        print_error "Password cannot be empty"
        exit 1
    fi

    # Create system user
    useradd --system --shell /usr/sbin/nologin --home-dir /dev/null --no-create-home "$username"
    echo "$username:$password" | chpasswd
    print_info "System user $username created"

    # Add user to users list file
    if [ ! -f "$USERS_FILE" ]; then
        touch "$USERS_FILE"
        chmod 600 "$USERS_FILE"
    fi
    if ! grep -q "^${username}$" "$USERS_FILE" 2>/dev/null; then
        echo "$username" >> "$USERS_FILE"
    fi

    print_info "User $username added successfully to proxy"
}

# Function to delete a user
delete_user() {
    if [ ! -f "$CONFIG_FILE" ]; then
        print_error "Configuration file not found. Run 'setup' first."
        exit 1
    fi

    if [ -z "$2" ]; then
        print_error "Usage: $0 user-del <username>"
        exit 1
    fi

    local username="$2"

    # Check if user exists
    if ! id "$username" > /dev/null 2>&1; then
        print_error "User $username not found"
        exit 1
    fi

    # Check if user is in users list
    if [ -f "$USERS_FILE" ] && ! grep -q "^${username}$" "$USERS_FILE" 2>/dev/null; then
        print_warning "User $username exists but is not in proxy users list"
    fi

    # Delete user from users list
    if [ -f "$USERS_FILE" ]; then
        grep -v "^${username}$" "$USERS_FILE" > "${USERS_FILE}.tmp" 2>/dev/null
        mv "${USERS_FILE}.tmp" "$USERS_FILE" 2>/dev/null
    fi

    # Delete system user
    userdel "$username" 2>/dev/null
    print_info "User $username deleted successfully"
}

# Function to list all users
list_users() {
    if [ ! -f "$USERS_FILE" ]; then
        print_error "Users file not found. Run 'setup' first."
        exit 1
    fi

    local user_count=$(wc -l < "$USERS_FILE" 2>/dev/null | tr -d ' ')

    if [ "$user_count" -eq 0 ]; then
        print_warning "No users found"
        exit 0
    fi

    print_info "Proxy users ($user_count total):"
    echo ""
    # Read file and filter out empty lines
    grep -v '^[[:space:]]*$' "$USERS_FILE" 2>/dev/null | while read username; do
        if [ -n "$username" ]; then
            if id "$username" > /dev/null 2>&1; then
                printf "  %s\n" "$username"
            else
                printf "  %s (user deleted but still in list)\n" "$username"
            fi
        fi
    done
}

# Function to change user password
change_password() {
    if [ ! -f "$CONFIG_FILE" ]; then
        print_error "Configuration file not found. Run 'setup' first."
        exit 1
    fi

    if [ -z "$2" ]; then
        print_error "Usage: $0 user-passwd <username>"
        exit 1
    fi

    local username="$2"

    # Check if user exists
    if ! id "$username" > /dev/null 2>&1; then
        print_error "User $username not found"
        exit 1
    fi

    # Check if user is in users list
    if [ ! -f "$USERS_FILE" ] || ! grep -q "^${username}$" "$USERS_FILE" 2>/dev/null; then
        print_warning "User $username exists but is not in proxy users list"
    fi

    # Get new password
    printf "Enter new password for user $username: "
    stty -echo
    read password
    stty echo
    echo ""

    if [ -z "$password" ]; then
        print_error "Password cannot be empty"
        exit 1
    fi

    # Update password
    echo "$username:$password" | chpasswd
    print_info "Password for user $username updated successfully"
}

# Function to show user statistics
show_user_stats() {
    local username="$2"

    if [ -z "$username" ]; then
        print_error "Usage: $0 user-stats <username>"
        exit 1
    fi

    # Check if user exists
    if ! id "$username" > /dev/null 2>&1; then
        print_error "User $username not found"
        exit 1
    fi

    # Check if user is in users list
    if [ ! -f "$USERS_FILE" ] || ! grep -q "^${username}$" "$USERS_FILE" 2>/dev/null; then
        print_warning "User $username exists but is not in proxy users list"
    fi

    print_info "Statistics for user: $username"
    echo ""

    # Get logs from journalctl (Dante logs to syslog)
    local log_output=$(journalctl -u "$SERVICE_NAME" --no-pager 2>/dev/null | grep -i "$username" || true)

    if [ -z "$log_output" ]; then
        print_warning "No activity found for user $username"
        print_info "Make sure the user has used the proxy and logging is enabled"
        exit 0
    fi

    # Count total connections (filter out empty lines)
    local total_connections=$(echo "$log_output" | grep -v '^[[:space:]]*$' | wc -l | tr -d ' ')
    if [ -z "$total_connections" ]; then
        total_connections="0"
    fi

    if [ "$total_connections" -eq 0 ] || [ -z "$total_connections" ]; then
        print_warning "No activity found for user $username"
        exit 0
    fi

    echo "Total connections: $total_connections"
    echo ""

    # Show last activity
    print_info "Last activity:"
    local last_line=$(echo "$log_output" | tail -1)
    if [ -n "$last_line" ]; then
        # Extract date from journalctl output (format: YYYY-MM-DD HH:MM:SS)
        local last_date=$(echo "$last_line" | awk '{print $1, $2, $3}' | head -1)
        if [ -n "$last_date" ]; then
            echo "  $last_date"
        else
            echo "  (unable to parse date)"
        fi
    else
        echo "  (no data)"
    fi
    echo ""

    # Show recent activity (last 10 lines)
    print_info "Recent activity (last 10 connections):"
    echo "$log_output" | tail -10 | while read line; do
        if [ -n "$line" ]; then
            # Extract date and message
            local date_part=$(echo "$line" | awk '{print $1, $2, $3}' | head -1)
            local message=$(echo "$line" | cut -d' ' -f5-)
            if [ -n "$date_part" ] && [ -n "$message" ]; then
                printf "  %s - %s\n" "$date_part" "$message"
            fi
        fi
    done
    echo ""

    # Show activity summary by date
    print_info "Activity by date:"
    echo "$log_output" | awk '{print $1, $2, $3}' | sort | uniq -c | tail -10 | \
        awk '{printf "  %-6s %s %s %s\n", $1, $2, $3, $4}'
    echo ""
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
            if systemctl is-active --quiet "$SERVICE_NAME"; then
                print_info "Stopping service..."
                systemctl stop "$SERVICE_NAME"
                sleep 1
                if systemctl is-active --quiet "$SERVICE_NAME"; then
                    print_error "Failed to stop service"
                    exit 1
                else
                    print_info "Service stopped successfully"
                fi
            else
                print_warning "Service is already stopped"
            fi
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
        user-add)
            add_user "$@"
            ;;
        user-del)
            delete_user "$@"
            ;;
        user-list)
            list_users
            ;;
        user-passwd)
            change_password "$@"
            ;;
        user-stats)
            show_user_stats "$@"
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

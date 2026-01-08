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

# Configuration paths for Squid HTTP proxy
CONFIG_FILE="/etc/squid/squid.conf"
PASSWD_FILE="/etc/squid/passwords"
SERVICE_NAME="squid"
PROXY_USER="httpproxy"

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

# Function to check if Squid is installed
check_squid_installed() {
    # Check if service exists and package is installed
    if systemctl list-unit-files | grep -q "^${SERVICE_NAME}.service" || \
       dpkg -l | grep -q "^ii.*squid"; then
        return 0
    fi
    return 1
}

# Function to install Squid
install_squid() {
    print_info "Installing Squid HTTP proxy server..."

    # Update package list
    print_info "Updating package list..."
    if ! apt-get update -qq; then
        print_error "Failed to update package list"
        return 1
    fi

    # Install squid and apache2-utils (for htpasswd)
    print_info "Installing squid and apache2-utils packages..."
    if ! apt-get install -y squid apache2-utils; then
        print_error "Failed to install squid"
        return 1
    fi

    # Verify installation
    if systemctl list-unit-files | grep -q "^${SERVICE_NAME}.service" || \
       dpkg -l | grep -q "^ii.*squid"; then
        print_info "Squid installed successfully"
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
    print_info "Starting HTTP proxy setup..."

    # Get server port
    SERVER_PORT=""
    if [ -f "$CONFIG_FILE" ]; then
        print_warning "Configuration file already exists. It will be updated."
        # Try to extract existing port from config
        if [ -f "$CONFIG_FILE" ]; then
            EXISTING_PORT=$(grep -o "http_port[[:space:]]*[0-9]*" "$CONFIG_FILE" 2>/dev/null | grep -o '[0-9]*' | head -1)
        fi
    fi

    while true; do
        get_input "Enter server port" "${EXISTING_PORT:-3128}" "SERVER_PORT"
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

    # Create password file
    print_info "Creating password file..."
    if [ ! -f "$PASSWD_FILE" ]; then
        touch "$PASSWD_FILE"
        chown proxy:proxy "$PASSWD_FILE"
        chmod 640 "$PASSWD_FILE"
    fi

    # Add or update user password
    print_info "Setting up authentication..."
    if command -v htpasswd > /dev/null 2>&1; then
        # Check if password file exists
        if [ ! -f "$PASSWD_FILE" ]; then
            touch "$PASSWD_FILE"
            chown proxy:proxy "$PASSWD_FILE"
            chmod 640 "$PASSWD_FILE"
        fi

        # Check if user already exists
        if grep -q "^${PROXY_USER}:" "$PASSWD_FILE" 2>/dev/null; then
            print_warning "User $PROXY_USER already exists. Updating password..."
            htpasswd -b "$PASSWD_FILE" "$PROXY_USER" "$PROXY_PASSWORD"
        else
            htpasswd -b "$PASSWD_FILE" "$PROXY_USER" "$PROXY_PASSWORD"
        fi
        chown proxy:proxy "$PASSWD_FILE"
        chmod 640 "$PASSWD_FILE"
    else
        print_error "htpasswd not found. Please install apache2-utils"
        exit 1
    fi

    # Backup existing config if it exists
    if [ -f "$CONFIG_FILE" ]; then
        cp "$CONFIG_FILE" "${CONFIG_FILE}.bak.$(date +%Y%m%d_%H%M%S)"
        print_info "Backup of existing config created"
    fi

    # Create configuration file for Squid
    print_info "Creating configuration file..."
    cat > "$CONFIG_FILE" << EOF
# Squid HTTP proxy server configuration
# Generated by http-proxy.sh setup script

# HTTP port
http_port $SERVER_PORT

# Authentication using basic_ncsa_auth
auth_param basic program /usr/lib/squid/basic_ncsa_auth $PASSWD_FILE
auth_param basic realm Proxy
auth_param basic children 5
auth_param basic credentialsttl 2 hours

# ACL for authenticated users
acl authenticated proxy_auth REQUIRED

# Allow authenticated users
http_access allow authenticated

# Deny all other requests
http_access deny all

# DNS settings
dns_nameservers 8.8.8.8 8.8.4.4

# Cache settings (minimal for proxy)
cache_dir ufs /var/spool/squid 100 16 256
cache_mem 64 MB
maximum_object_size_in_memory 512 KB

# Logging
access_log /var/log/squid/access.log squid
cache_log /var/log/squid/cache.log

# Visibility
visible_hostname $(hostname)

# Error pages
error_directory /usr/share/squid/errors/en
EOF

    print_info "Configuration file created at $CONFIG_FILE"

    # Create cache directory
    print_info "Initializing cache directory..."
    if [ ! -d /var/spool/squid ]; then
        mkdir -p /var/spool/squid
    fi
    chown -R proxy:proxy /var/spool/squid

    # Setup firewall
    setup_firewall "$SERVER_PORT"

    # Initialize cache
    print_info "Initializing Squid cache..."
    squid -z 2>/dev/null || true

    # Restart service
    print_info "Restarting Squid service..."
    systemctl restart "$SERVICE_NAME"

    # Check status
    sleep 2
    if systemctl is-active --quiet "$SERVICE_NAME"; then
        print_info "HTTP proxy service started successfully!"
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
        print_error "Failed to start HTTP proxy service"
        print_info "Check logs with: sudo journalctl -u $SERVICE_NAME -n 50"
        print_info "Or check Squid logs: sudo tail -f /var/log/squid/cache.log"
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
HTTP Proxy Server Management Script (Squid)

Usage:
    $0 [command]

Commands:
    help           Show this help message
    setup          Interactive setup/configuration
    start          Start HTTP proxy service
    stop           Stop HTTP proxy service
    restart        Restart HTTP proxy service
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
    1. Check and install Squid if needed
    2. Ask for configuration (port, username, password)
    3. Create password file for authentication
    4. Create/update configuration file
    5. Configure firewall
    6. Initialize cache and start the service

Configuration File:
    Location: $CONFIG_FILE
    Password File: $PASSWD_FILE

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
    - Port: configured port (default 3128)
    - Authentication: ON
    - Username: configured username
    - Password: configured password

Note: This HTTP proxy works with standard iOS settings without additional apps.

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
    PORT=$(grep -o "http_port[[:space:]]*[0-9]*" "$CONFIG_FILE" 2>/dev/null | grep -o '[0-9]*' | head -1)

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
    if [ ! -f "$PASSWD_FILE" ]; then
        print_error "Password file not found. Run 'setup' first."
        exit 1
    fi

    if [ -z "$2" ]; then
        print_error "Usage: $0 user-add <username>"
        exit 1
    fi

    local username="$2"

    # Check if user already exists
    if grep -q "^${username}:" "$PASSWD_FILE" 2>/dev/null; then
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

    # Add user
    if command -v htpasswd > /dev/null 2>&1; then
        htpasswd -b "$PASSWD_FILE" "$username" "$password"
        chown proxy:proxy "$PASSWD_FILE"
        chmod 640 "$PASSWD_FILE"
        print_info "User $username added successfully"
    else
        print_error "htpasswd not found. Please install apache2-utils"
        exit 1
    fi
}

# Function to delete a user
delete_user() {
    if [ ! -f "$PASSWD_FILE" ]; then
        print_error "Password file not found. Run 'setup' first."
        exit 1
    fi

    if [ -z "$2" ]; then
        print_error "Usage: $0 user-del <username>"
        exit 1
    fi

    local username="$2"

    # Check if user exists
    if ! grep -q "^${username}:" "$PASSWD_FILE" 2>/dev/null; then
        print_error "User $username not found"
        exit 1
    fi

    # Delete user
    htpasswd -D "$PASSWD_FILE" "$username"
    chown proxy:proxy "$PASSWD_FILE"
    chmod 640 "$PASSWD_FILE"
    print_info "User $username deleted successfully"
}

# Function to list all users
list_users() {
    if [ ! -f "$PASSWD_FILE" ]; then
        print_error "Password file not found. Run 'setup' first."
        exit 1
    fi

    local user_count=$(wc -l < "$PASSWD_FILE" 2>/dev/null | tr -d ' ')

    if [ "$user_count" -eq 0 ]; then
        print_warning "No users found"
        exit 0
    fi

    print_info "Proxy users ($user_count total):"
    echo ""
    awk -F: '{printf "  %s\n", $1}' "$PASSWD_FILE"
}

# Function to change user password
change_password() {
    if [ ! -f "$PASSWD_FILE" ]; then
        print_error "Password file not found. Run 'setup' first."
        exit 1
    fi

    if [ -z "$2" ]; then
        print_error "Usage: $0 user-passwd <username>"
        exit 1
    fi

    local username="$2"

    # Check if user exists
    if ! grep -q "^${username}:" "$PASSWD_FILE" 2>/dev/null; then
        print_error "User $username not found"
        exit 1
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
    if command -v htpasswd > /dev/null 2>&1; then
        htpasswd -b "$PASSWD_FILE" "$username" "$password"
        chown proxy:proxy "$PASSWD_FILE"
        chmod 640 "$PASSWD_FILE"
        print_info "Password for user $username updated successfully"
    else
        print_error "htpasswd not found. Please install apache2-utils"
        exit 1
    fi
}

# Function to show user statistics
show_user_stats() {
    local username="$2"
    local log_file="/var/log/squid/access.log"

    if [ -z "$username" ]; then
        print_error "Usage: $0 user-stats <username>"
        exit 1
    fi

    # Check if user exists
    if [ ! -f "$PASSWD_FILE" ] || ! grep -q "^${username}:" "$PASSWD_FILE" 2>/dev/null; then
        print_error "User $username not found"
        exit 1
    fi

    # Check if log file exists
    if [ ! -f "$log_file" ]; then
        print_error "Log file not found: $log_file"
        print_info "User may not have used the proxy yet, or logging is not configured"
        exit 1
    fi

    print_info "Statistics for user: $username"
    echo ""

    # Count total requests
    local total_requests=$(grep " ${username} " "$log_file" 2>/dev/null | wc -l | tr -d ' ')

    if [ "$total_requests" -eq 0 ]; then
        print_warning "No activity found for user $username"
        exit 0
    fi

    echo "Total requests: $total_requests"
    echo ""

    # Calculate total data transferred (bytes)
    # Squid log format: timestamp elapsed client action/code size method URL ...
    # Size is usually in 6th or 7th field depending on log format
    local total_bytes=$(grep " ${username} " "$log_file" 2>/dev/null | awk '{sum += $5} END {print sum}')

    if [ -z "$total_bytes" ] || [ "$total_bytes" = "0" ]; then
        # Try alternative format
        total_bytes=$(grep " ${username} " "$log_file" 2>/dev/null | awk '{sum += $4} END {print sum}')
    fi

    # Convert bytes to human readable format
    local total_mb="0"
    if [ -n "$total_bytes" ] && [ "$total_bytes" -gt 0 ]; then
        total_mb=$(echo "scale=2; $total_bytes / 1024 / 1024" | bc 2>/dev/null || echo "0")
        if [ -z "$total_mb" ] || [ "$total_mb" = "0" ]; then
            total_mb=$(awk "BEGIN {printf \"%.2f\", $total_bytes / 1024 / 1024}")
        fi
    fi

    echo "Total data transferred: ${total_mb} MB (${total_bytes} bytes)"
    echo ""

    # Show last activity
    print_info "Last activity:"
    local last_line=$(grep " ${username} " "$log_file" 2>/dev/null | tail -1)
    if [ -n "$last_line" ]; then
        # Extract timestamp (first field in epoch time)
        local last_timestamp=$(echo "$last_line" | awk '{print $1}')
        if [ -n "$last_timestamp" ]; then
            # Convert epoch to readable date if date command supports it
            if date -d "@$last_timestamp" > /dev/null 2>&1; then
                echo "  $(date -d "@$last_timestamp" '+%Y-%m-%d %H:%M:%S')"
            elif date -r "$last_timestamp" > /dev/null 2>&1; then
                echo "  $(date -r "$last_timestamp" '+%Y-%m-%d %H:%M:%S')"
            else
                echo "  Timestamp: $last_timestamp"
            fi
        fi
    fi
    echo ""

    # Show top 10 most accessed domains
    print_info "Top 10 most accessed domains:"
    grep " ${username} " "$log_file" 2>/dev/null | \
        awk '{print $7}' | \
        sed 's|http://||g; s|https://||g' | \
        sed 's|/.*||g' | \
        sort | uniq -c | sort -rn | head -10 | \
        awk '{printf "  %-6s %s\n", $1, $2}'
    echo ""

    # Show requests by hour (last 24 hours if possible)
    print_info "Activity by hour (last 24 hours):"
    local current_time=$(date +%s)
    local day_ago=$((current_time - 86400))

    grep " ${username} " "$log_file" 2>/dev/null | \
        awk -v day_ago="$day_ago" '$1 >= day_ago {print $1}' | \
        while read timestamp; do
            if date -d "@$timestamp" > /dev/null 2>&1; then
                date -d "@$timestamp" '+%Y-%m-%d %H:00'
            elif date -r "$timestamp" > /dev/null 2>&1; then
                date -r "$timestamp" '+%Y-%m-%d %H:00'
            fi
        done | sort | uniq -c | tail -24 | \
        awk '{printf "  %-6s %s\n", $1, $2}'
    echo ""

    # Show HTTP status codes
    print_info "HTTP status codes:"
    grep " ${username} " "$log_file" 2>/dev/null | \
        awk '{print $3}' | \
        sed 's|/.*||g' | \
        sort | uniq -c | sort -rn | \
        awk '{printf "  %-6s %s\n", $1, $2}'
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
            # Check if Squid is installed
            if ! check_squid_installed; then
                print_warning "Squid is not installed"
                printf "Do you want to install it now? (y/n): "
                read REPLY
                case "$REPLY" in
                    [Yy]*)
                        install_squid
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

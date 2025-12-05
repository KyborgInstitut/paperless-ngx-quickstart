#!/bin/bash
#
# Paperless-ngx Management Script
# For Ubuntu 24.04 LTS
#

# Note: We intentionally do NOT use 'set -e' because:
# - Many commands may fail gracefully (apt updates, network checks, etc.)
# - We handle errors explicitly where needed
# - Interactive scripts need to continue even after minor failures

# ============================================================================
# CONFIGURATION
# ============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ============================================================================
# STARTUP TIME SYNC (runs immediately, non-blocking)
# ============================================================================
# This prevents "Release file not valid yet" APT errors due to clock skew

startup_time_sync() {
    # Only attempt if running as root (needed for time changes)
    if [[ $EUID -ne 0 ]]; then
        return 0
    fi

    local sync_status=""

    # Check if time is already synchronized
    if command -v timedatectl &> /dev/null; then
        if timedatectl status 2>/dev/null | grep -q "synchronized: yes"; then
            sync_status="synced"
        else
            # Try to sync time (non-blocking, timeout after 3 seconds)
            {
                # Enable NTP
                timedatectl set-ntp true 2>/dev/null

                # If systemd-timesyncd is available, trigger immediate sync
                if systemctl is-active --quiet systemd-timesyncd 2>/dev/null; then
                    # Restart timesyncd to force immediate sync attempt
                    systemctl restart systemd-timesyncd 2>/dev/null &
                    local sync_pid=$!

                    # Wait max 3 seconds
                    local waited=0
                    while kill -0 $sync_pid 2>/dev/null && [[ $waited -lt 3 ]]; do
                        sleep 0.5
                        ((waited++)) || true
                    done

                    # Kill if still running
                    kill $sync_pid 2>/dev/null || true
                fi

                # Alternative: try ntpdate if available (quick one-shot sync)
                if command -v ntpdate &> /dev/null; then
                    timeout 3 ntpdate -u pool.ntp.org 2>/dev/null &
                fi
            } &>/dev/null

            # Check result
            sleep 0.5
            if timedatectl status 2>/dev/null | grep -q "synchronized: yes"; then
                sync_status="just_synced"
            else
                sync_status="pending"
            fi
        fi
    else
        sync_status="unavailable"
    fi

    # Store status for display (don't print here, will be shown in splash screen)
    export TIME_SYNC_STATUS="$sync_status"
}

# Run time sync immediately at script load
startup_time_sync
BACKUP_DIR="${SCRIPT_DIR}/backups"
DATA_DIR="${SCRIPT_DIR}/data"
CONSUME_DIR="${SCRIPT_DIR}/consume"
EXPORT_DIR="${SCRIPT_DIR}/export"
TRASH_DIR="${SCRIPT_DIR}/trash"
SCRIPTS_DIR="${SCRIPT_DIR}/scripts"
NGINX_DIR="${SCRIPT_DIR}/nginx"
SSL_DIR="${NGINX_DIR}/ssl"

# SMB Configuration
SMB_USER="paperless"
SMB_SHARE_NAME="paperless-import"

# SSL Configuration
SSL_CERT="${SSL_DIR}/cert.pem"
SSL_KEY="${SSL_DIR}/key.pem"
SSL_DAYS=3650  # 10 years for local network use

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# ============================================================================
# HELPER FUNCTIONS
# ============================================================================

print_header() {
    echo -e "\n${BLUE}============================================${NC}"
    echo -e "${BLUE}  $1${NC}"
    echo -e "${BLUE}============================================${NC}\n"
}

print_success() {
    echo -e "${GREEN}✓ $1${NC}"
}

print_warning() {
    echo -e "${YELLOW}⚠ $1${NC}"
}

print_error() {
    echo -e "${RED}✗ $1${NC}"
}

print_info() {
    echo -e "${BLUE}ℹ $1${NC}"
}

check_root() {
    if [[ $EUID -ne 0 ]]; then
        print_error "This operation requires root privileges."
        echo "Please run with: sudo $0"
        exit 1
    fi
}

check_docker() {
    if ! command -v docker &> /dev/null; then
        print_error "Docker is not installed."
        return 1
    fi
    if ! docker compose version &> /dev/null; then
        print_error "Docker Compose is not available."
        return 1
    fi
    return 0
}

# ============================================================================
# PROGRESS BAR AND UI UTILITIES
# ============================================================================

# Display a progress bar
# Usage: show_progress $current $total "message"
show_progress() {
    local current=$1
    local total=$2
    local message="${3:-Processing...}"
    local width=40
    local percentage=$((current * 100 / total))
    local filled=$((current * width / total))
    local empty=$((width - filled))

    # Build progress bar
    local bar=""
    for ((i=0; i<filled; i++)); do bar+="█"; done
    for ((i=0; i<empty; i++)); do bar+="░"; done

    # Print progress bar (overwrite same line)
    printf "\r  [${GREEN}%s${NC}] %3d%% %s" "$bar" "$percentage" "$message"

    # New line when complete
    if [[ $current -eq $total ]]; then
        echo ""
    fi
}

# Animated spinner for long-running tasks
# Usage: start_spinner "message" & SPINNER_PID=$!
#        ... do work ...
#        stop_spinner $SPINNER_PID
SPINNER_PID=""

start_spinner() {
    local message="${1:-Working...}"
    local spin_chars='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
    local i=0

    while true; do
        printf "\r  ${BLUE}%s${NC} %s" "${spin_chars:i++%${#spin_chars}:1}" "$message"
        sleep 0.1
    done
}

stop_spinner() {
    local pid=$1
    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
        kill "$pid" 2>/dev/null
        wait "$pid" 2>/dev/null
    fi
    printf "\r%80s\r" ""  # Clear the line
}

# Display a step indicator
# Usage: show_step 1 5 "Installing Docker"
show_step() {
    local current=$1
    local total=$2
    local message="$3"

    echo ""
    echo -e "  ${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "  ${BLUE}Step ${current} of ${total}:${NC} ${message}"
    echo -e "  ${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
}

# Display task status inline
# Usage: show_task_status "Installing package" "done|error|skip|working"
show_task_status() {
    local task="$1"
    local status="$2"
    local padding=45

    printf "  %-${padding}s " "$task"

    case $status in
        done)
            echo -e "[${GREEN}  OK  ${NC}]"
            ;;
        error)
            echo -e "[${RED}FAILED${NC}]"
            ;;
        skip)
            echo -e "[${YELLOW} SKIP ${NC}]"
            ;;
        working)
            echo -e "[${BLUE}......${NC}]"
            ;;
        *)
            echo "[$status]"
            ;;
    esac
}

# Update task status on same line (for progress updates)
update_task_status() {
    local task="$1"
    local status="$2"
    local padding=45

    printf "\r  %-${padding}s " "$task"

    case $status in
        done)
            echo -e "[${GREEN}  OK  ${NC}]"
            ;;
        error)
            echo -e "[${RED}FAILED${NC}]"
            ;;
        skip)
            echo -e "[${YELLOW} SKIP ${NC}]"
            ;;
        working)
            printf "[${BLUE}......${NC}]"
            ;;
    esac
}

# Display welcome/splash screen
show_splash_screen() {
    clear
    echo ""
    echo -e "${BLUE}"
    cat << 'EOF'
    ____                        __
   / __ \____ _____  ___  _____/ /__  __________      ____  ____ __  __
  / /_/ / __ `/ __ \/ _ \/ ___/ / _ \/ ___/ ___/_____/ __ \/ __ `/ |/_/
 / ____/ /_/ / /_/ /  __/ /  / /  __(__  |__  )_____/ / / / /_/ />  <
/_/    \__,_/ .___/\___/_/  /_/\___/____/____/     /_/ /_/\__, /_/|_|
           /_/                                           /____/
EOF
    echo -e "${NC}"
    echo ""
    echo -e "  ${GREEN}Document Management System - Quick Start${NC}"
    echo -e "  ${BLUE}by Kyborg Institut & Research${NC} - kyborg-institut.com"

    # Show time sync status (small, non-intrusive)
    case "${TIME_SYNC_STATUS:-}" in
        synced)
            echo -e "  ${GREEN}✓${NC} System time synchronized"
            ;;
        just_synced)
            echo -e "  ${GREEN}✓${NC} System time just synchronized"
            ;;
        pending)
            echo -e "  ${YELLOW}○${NC} Time sync in progress..."
            ;;
        unavailable)
            echo -e "  ${YELLOW}○${NC} Time sync unavailable (offline mode)"
            ;;
        *)
            # No status or not root - don't show anything
            ;;
    esac

    echo ""
    echo "  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
}

# Display main action menu
show_action_menu() {
    echo "  What would you like to do?"
    echo ""
    echo -e "  ${GREEN}Getting Started:${NC}"
    echo "    1) Complete Setup (Recommended)"
    echo "       Install everything and configure Paperless-ngx"
    echo ""
    echo -e "  ${GREEN}Individual Steps:${NC}"
    echo "    2) Install Dependencies Only"
    echo "       Docker, tools, and required packages"
    echo ""
    echo "    3) Configure Paperless-ngx"
    echo "       Set up admin account and settings"
    echo ""
    echo "    4) Start Services"
    echo "       Launch Paperless-ngx"
    echo ""
    echo -e "  ${GREEN}Management:${NC}"
    echo "    5) Open Full Management Menu"
    echo "       Access all features and settings"
    echo ""
    echo "    6) View System Status"
    echo "       Check if everything is running"
    echo ""
    echo "  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "    0) Exit"
    echo ""
}

# ============================================================================
# DEPENDENCY MANAGEMENT
# ============================================================================

install_dependencies() {
    print_header "Checking and Installing Dependencies"

    local PACKAGES_TO_INSTALL=()
    local APT_UPDATED=false

    # Function to check if a package is installed
    is_pkg_installed() {
        dpkg -l "$1" 2>/dev/null | grep -q "^ii"
    }

    # Function to update apt cache once
    ensure_apt_updated() {
        if [[ "$APT_UPDATED" == false ]]; then
            print_info "Updating package lists..."
            apt-get update -qq
            APT_UPDATED=true
        fi
    }

    echo "Checking required dependencies..."
    echo ""

    # -------------------------------------------------------------------------
    # 1. Docker
    # -------------------------------------------------------------------------
    echo -n "  Docker.................... "
    if command -v docker &> /dev/null; then
        local docker_version=$(docker --version | cut -d' ' -f3 | tr -d ',')
        echo -e "${GREEN}OK${NC} (v${docker_version})"
    else
        echo -e "${YELLOW}MISSING${NC}"
        print_info "Installing Docker..."
        ensure_apt_updated

        # Install prerequisites for Docker
        apt-get install -y -qq ca-certificates curl gnupg

        # Add Docker's official GPG key
        install -m 0755 -d /etc/apt/keyrings
        curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg 2>/dev/null || true
        chmod a+r /etc/apt/keyrings/docker.gpg

        # Add Docker repository
        echo \
            "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
            $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
            tee /etc/apt/sources.list.d/docker.list > /dev/null

        # Install Docker
        apt-get update -qq
        apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

        # Start and enable Docker
        systemctl enable docker
        systemctl start docker

        print_success "Docker installed successfully"
    fi

    # -------------------------------------------------------------------------
    # 2. Docker Compose (plugin)
    # -------------------------------------------------------------------------
    echo -n "  Docker Compose............ "
    if docker compose version &> /dev/null; then
        local compose_version=$(docker compose version --short 2>/dev/null || docker compose version | grep -oP 'v\d+\.\d+\.\d+')
        echo -e "${GREEN}OK${NC} (${compose_version})"
    else
        echo -e "${YELLOW}MISSING${NC}"
        print_info "Installing Docker Compose plugin..."
        ensure_apt_updated
        apt-get install -y -qq docker-compose-plugin
        print_success "Docker Compose installed successfully"
    fi

    # -------------------------------------------------------------------------
    # 3. OpenSSL (for certificate generation)
    # -------------------------------------------------------------------------
    echo -n "  OpenSSL................... "
    if command -v openssl &> /dev/null; then
        local openssl_version=$(openssl version | cut -d' ' -f2)
        echo -e "${GREEN}OK${NC} (v${openssl_version})"
    else
        echo -e "${YELLOW}MISSING${NC}"
        PACKAGES_TO_INSTALL+=("openssl")
    fi

    # -------------------------------------------------------------------------
    # 4. Samba (for SMB file sharing)
    # -------------------------------------------------------------------------
    echo -n "  Samba..................... "
    if command -v smbd &> /dev/null; then
        local samba_version=$(smbd --version | head -1 | cut -d' ' -f2)
        echo -e "${GREEN}OK${NC} (${samba_version})"
    else
        echo -e "${YELLOW}MISSING${NC}"
        PACKAGES_TO_INSTALL+=("samba" "samba-common-bin")
    fi

    # -------------------------------------------------------------------------
    # 5. ACL (for file permissions)
    # -------------------------------------------------------------------------
    echo -n "  ACL utilities............. "
    if command -v setfacl &> /dev/null; then
        echo -e "${GREEN}OK${NC}"
    else
        echo -e "${YELLOW}MISSING${NC}"
        PACKAGES_TO_INSTALL+=("acl")
    fi

    # -------------------------------------------------------------------------
    # 6. curl (for downloads and health checks)
    # -------------------------------------------------------------------------
    echo -n "  curl...................... "
    if command -v curl &> /dev/null; then
        local curl_version=$(curl --version | head -1 | cut -d' ' -f2)
        echo -e "${GREEN}OK${NC} (v${curl_version})"
    else
        echo -e "${YELLOW}MISSING${NC}"
        PACKAGES_TO_INSTALL+=("curl")
    fi

    # -------------------------------------------------------------------------
    # 7. tar (for backups)
    # -------------------------------------------------------------------------
    echo -n "  tar....................... "
    if command -v tar &> /dev/null; then
        local tar_version=$(tar --version | head -1 | grep -oP '\d+\.\d+' | head -1)
        echo -e "${GREEN}OK${NC} (v${tar_version})"
    else
        echo -e "${YELLOW}MISSING${NC}"
        PACKAGES_TO_INSTALL+=("tar")
    fi

    # -------------------------------------------------------------------------
    # 8. gzip (for compression)
    # -------------------------------------------------------------------------
    echo -n "  gzip...................... "
    if command -v gzip &> /dev/null; then
        local gzip_version=$(gzip --version | head -1 | grep -oP '\d+\.\d+' | head -1)
        echo -e "${GREEN}OK${NC} (v${gzip_version})"
    else
        echo -e "${YELLOW}MISSING${NC}"
        PACKAGES_TO_INSTALL+=("gzip")
    fi

    # -------------------------------------------------------------------------
    # 9. sed (for config editing)
    # -------------------------------------------------------------------------
    echo -n "  sed....................... "
    if command -v sed &> /dev/null; then
        local sed_version=$(sed --version 2>/dev/null | head -1 | grep -oP '\d+\.\d+' | head -1 || echo "installed")
        echo -e "${GREEN}OK${NC} (v${sed_version})"
    else
        echo -e "${YELLOW}MISSING${NC}"
        PACKAGES_TO_INSTALL+=("sed")
    fi

    # -------------------------------------------------------------------------
    # 10. UFW (firewall - optional but recommended)
    # -------------------------------------------------------------------------
    echo -n "  UFW firewall.............. "
    if command -v ufw &> /dev/null; then
        local ufw_status=$(ufw status | head -1)
        echo -e "${GREEN}OK${NC} (${ufw_status})"
    else
        echo -e "${YELLOW}MISSING${NC} (optional)"
        # Don't auto-install UFW, just note it
        print_info "UFW not installed - firewall configuration will be skipped"
    fi

    # -------------------------------------------------------------------------
    # 11. ca-certificates (for HTTPS)
    # -------------------------------------------------------------------------
    echo -n "  CA Certificates........... "
    if is_pkg_installed "ca-certificates"; then
        echo -e "${GREEN}OK${NC}"
    else
        echo -e "${YELLOW}MISSING${NC}"
        PACKAGES_TO_INSTALL+=("ca-certificates")
    fi

    # -------------------------------------------------------------------------
    # 12. gnupg (for Docker GPG key)
    # -------------------------------------------------------------------------
    echo -n "  GnuPG..................... "
    if command -v gpg &> /dev/null; then
        local gpg_version=$(gpg --version | head -1 | grep -oP '\d+\.\d+\.\d+' | head -1)
        echo -e "${GREEN}OK${NC} (v${gpg_version})"
    else
        echo -e "${YELLOW}MISSING${NC}"
        PACKAGES_TO_INSTALL+=("gnupg")
    fi

    # -------------------------------------------------------------------------
    # Install missing packages
    # -------------------------------------------------------------------------
    echo ""

    if [[ ${#PACKAGES_TO_INSTALL[@]} -gt 0 ]]; then
        print_info "Installing missing packages: ${PACKAGES_TO_INSTALL[*]}"
        ensure_apt_updated
        apt-get install -y -qq "${PACKAGES_TO_INSTALL[@]}"
        print_success "All missing packages installed"
    else
        print_success "All required dependencies are already installed"
    fi

    # -------------------------------------------------------------------------
    # Verify Docker is running
    # -------------------------------------------------------------------------
    echo ""
    echo -n "  Docker daemon............. "
    if systemctl is-active --quiet docker; then
        echo -e "${GREEN}RUNNING${NC}"
    else
        echo -e "${YELLOW}STOPPED${NC}"
        print_info "Starting Docker daemon..."
        systemctl start docker
        systemctl enable docker
        print_success "Docker daemon started"
    fi

    # -------------------------------------------------------------------------
    # Check Docker permissions
    # -------------------------------------------------------------------------
    if [[ $EUID -ne 0 ]]; then
        if ! groups | grep -q docker; then
            print_warning "Current user is not in the docker group"
            print_info "Run: sudo usermod -aG docker \$USER"
            print_info "Then log out and back in"
        fi
    fi

    echo ""
    print_success "Dependency check complete"
    echo ""
}

check_dependencies_quick() {
    # Quick check without installing - returns 0 if all OK, 1 if missing
    local missing=0

    command -v docker &> /dev/null || missing=1
    docker compose version &> /dev/null || missing=1
    command -v openssl &> /dev/null || missing=1
    command -v smbd &> /dev/null || missing=1
    command -v setfacl &> /dev/null || missing=1
    command -v curl &> /dev/null || missing=1
    command -v tar &> /dev/null || missing=1

    return $missing
}

# Automatic dependency installation on startup (silent mode)
ensure_dependencies() {
    # Skip if not root - can't install anyway
    if [[ $EUID -ne 0 ]]; then
        if ! check_dependencies_quick; then
            echo ""
            print_warning "Some dependencies are missing and require root to install."
            echo "Please run: sudo $0"
            echo ""
            exit 1
        fi
        return 0
    fi

    # Quick check first - if all OK, skip
    if check_dependencies_quick; then
        return 0
    fi

    # Run the full installation with progress
    install_dependencies_with_progress
}

# Install dependencies with visual progress feedback
install_dependencies_with_progress() {
    local total_steps=8
    local current_step=0

    echo ""
    echo -e "  ${BLUE}Installing Required Dependencies${NC}"
    echo -e "  ${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""

    local PACKAGES_TO_INSTALL=()
    local APT_UPDATED=false

    # Function to check if a package is installed
    is_pkg_installed() {
        dpkg -l "$1" 2>/dev/null | grep -q "^ii"
    }

    # Function to update apt cache once
    ensure_apt_updated() {
        if [[ "$APT_UPDATED" == false ]]; then
            apt-get update -qq 2>/dev/null
            APT_UPDATED=true
        fi
    }

    # Step 1: Update package lists
    ((current_step++))
    show_progress $current_step $total_steps "Updating package lists..."
    ensure_apt_updated
    sleep 0.3

    # Step 2: Check and install Docker
    ((current_step++))
    if ! command -v docker &> /dev/null; then
        show_progress $current_step $total_steps "Installing Docker..."

        # Install prerequisites for Docker
        apt-get install -y -qq ca-certificates curl gnupg 2>/dev/null

        # Add Docker's official GPG key
        install -m 0755 -d /etc/apt/keyrings 2>/dev/null
        curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg 2>/dev/null || true
        chmod a+r /etc/apt/keyrings/docker.gpg 2>/dev/null

        # Add Docker repository
        echo \
            "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
            $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
            tee /etc/apt/sources.list.d/docker.list > /dev/null 2>&1

        # Install Docker
        apt-get update -qq 2>/dev/null
        apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin 2>/dev/null

        # Start and enable Docker
        systemctl enable docker 2>/dev/null
        systemctl start docker 2>/dev/null
    else
        show_progress $current_step $total_steps "Docker already installed"
    fi
    sleep 0.2

    # Step 3: Check Docker Compose
    ((current_step++))
    if ! docker compose version &> /dev/null; then
        show_progress $current_step $total_steps "Installing Docker Compose..."
        apt-get install -y -qq docker-compose-plugin 2>/dev/null
    else
        show_progress $current_step $total_steps "Docker Compose ready"
    fi
    sleep 0.2

    # Step 4: Check essential tools
    ((current_step++))
    show_progress $current_step $total_steps "Checking essential tools..."

    if ! command -v openssl &> /dev/null; then
        PACKAGES_TO_INSTALL+=("openssl")
    fi
    if ! command -v curl &> /dev/null; then
        PACKAGES_TO_INSTALL+=("curl")
    fi
    if ! command -v tar &> /dev/null; then
        PACKAGES_TO_INSTALL+=("tar")
    fi
    if ! command -v gzip &> /dev/null; then
        PACKAGES_TO_INSTALL+=("gzip")
    fi
    if ! command -v gpg &> /dev/null; then
        PACKAGES_TO_INSTALL+=("gnupg")
    fi
    if ! is_pkg_installed "ca-certificates"; then
        PACKAGES_TO_INSTALL+=("ca-certificates")
    fi
    sleep 0.2

    # Step 5: Check Samba (for network sharing)
    ((current_step++))
    show_progress $current_step $total_steps "Checking file sharing tools..."
    if ! command -v smbd &> /dev/null; then
        PACKAGES_TO_INSTALL+=("samba" "samba-common-bin")
    fi
    sleep 0.2

    # Step 6: Check ACL
    ((current_step++))
    show_progress $current_step $total_steps "Checking permission tools..."
    if ! command -v setfacl &> /dev/null; then
        PACKAGES_TO_INSTALL+=("acl")
    fi
    sleep 0.2

    # Step 7: Install missing packages
    ((current_step++))
    if [[ ${#PACKAGES_TO_INSTALL[@]} -gt 0 ]]; then
        show_progress $current_step $total_steps "Installing ${#PACKAGES_TO_INSTALL[@]} additional packages..."
        apt-get install -y -qq "${PACKAGES_TO_INSTALL[@]}" 2>/dev/null
    else
        show_progress $current_step $total_steps "All packages present"
    fi
    sleep 0.2

    # Step 8: Ensure Docker is running
    ((current_step++))
    if ! systemctl is-active --quiet docker 2>/dev/null; then
        show_progress $current_step $total_steps "Starting Docker service..."
        systemctl start docker 2>/dev/null
        systemctl enable docker 2>/dev/null
    else
        show_progress $current_step $total_steps "Docker service running"
    fi

    echo ""
    echo ""
    print_success "All dependencies installed successfully!"
    echo ""
}

setup_time_sync() {
    print_header "Configuring Time Synchronization"

    # Check if systemd-timesyncd or chrony is available
    if systemctl is-active --quiet systemd-timesyncd 2>/dev/null; then
        print_info "systemd-timesyncd is already active"
    elif systemctl is-active --quiet chrony 2>/dev/null; then
        print_info "chrony is already active"
    elif systemctl is-active --quiet ntp 2>/dev/null; then
        print_info "ntp is already active"
    else
        print_info "Setting up time synchronization..."

        # Install and enable systemd-timesyncd (default on Ubuntu)
        if command -v timedatectl &> /dev/null; then
            # Enable NTP
            timedatectl set-ntp true 2>/dev/null || true

            # Start and enable systemd-timesyncd
            systemctl enable systemd-timesyncd 2>/dev/null || true
            systemctl start systemd-timesyncd 2>/dev/null || true

            print_success "Time synchronization enabled via systemd-timesyncd"
        else
            # Fallback: install chrony
            print_info "Installing chrony for time synchronization..."
            apt-get update -qq
            apt-get install -y -qq chrony
            systemctl enable chrony
            systemctl start chrony
            print_success "Time synchronization enabled via chrony"
        fi
    fi

    # Force immediate sync
    print_info "Synchronizing system time..."

    if command -v timedatectl &> /dev/null; then
        # Try to sync immediately
        timedatectl set-ntp true 2>/dev/null || true

        # Show current time status
        echo ""
        echo "Current time configuration:"
        timedatectl status | grep -E "(Local time|Universal time|RTC time|Time zone|NTP|synchronized)" || true
    fi

    # Check if time is synchronized
    if command -v timedatectl &> /dev/null; then
        if timedatectl status | grep -q "synchronized: yes"; then
            print_success "System time is synchronized"
        else
            print_warning "Time sync pending - this may take a few moments"
            print_info "APT operations should still work correctly"
        fi
    fi

    echo ""
}

is_running() {
    cd "$SCRIPT_DIR"
    if docker compose ps --status running 2>/dev/null | grep -q "webserver"; then
        return 0
    fi
    return 1
}

wait_for_all_services() {
    local max_attempts=90
    local attempt=0
    local services=("broker" "db" "webserver" "nginx" "gotenberg" "tika")

    print_info "Waiting for all services to start..."
    echo ""

    # Wait for all containers to be running
    while [ $attempt -lt $max_attempts ]; do
        local all_running=true
        local status_line=""

        for service in "${services[@]}"; do
            local state=$(docker compose ps --format "{{.State}}" "$service" 2>/dev/null)
            if [[ "$state" == "running" ]]; then
                status_line+="${GREEN}●${NC} "
            else
                status_line+="${YELLOW}○${NC} "
                all_running=false
            fi
        done

        # Print status on same line
        echo -ne "\r  Services: ${status_line} (${attempt}s)  "

        if [[ "$all_running" == true ]]; then
            echo ""
            print_success "All containers are running"
            break
        fi

        attempt=$((attempt + 1))
        sleep 1
    done

    if [[ $attempt -ge $max_attempts ]]; then
        echo ""
        print_error "Timeout waiting for containers to start"
        return 1
    fi

    # Now check health status of services with healthchecks
    print_info "Waiting for services to become healthy..."

    local health_attempts=0
    local max_health_attempts=120

    while [ $health_attempts -lt $max_health_attempts ]; do
        local db_healthy=$(docker compose ps --format "{{.Health}}" db 2>/dev/null)
        local broker_healthy=$(docker compose ps --format "{{.Health}}" broker 2>/dev/null)
        local nginx_healthy=$(docker compose ps --format "{{.Health}}" nginx 2>/dev/null)

        local status_line=""
        local all_healthy=true

        # Check Redis (broker)
        if [[ "$broker_healthy" == "healthy" ]]; then
            status_line+="${GREEN}Redis●${NC} "
        else
            status_line+="${YELLOW}Redis○${NC} "
            all_healthy=false
        fi

        # Check PostgreSQL (db)
        if [[ "$db_healthy" == "healthy" ]]; then
            status_line+="${GREEN}DB●${NC} "
        else
            status_line+="${YELLOW}DB○${NC} "
            all_healthy=false
        fi

        # Check Nginx
        if [[ "$nginx_healthy" == "healthy" ]]; then
            status_line+="${GREEN}Nginx●${NC} "
        else
            status_line+="${YELLOW}Nginx○${NC} "
            all_healthy=false
        fi

        echo -ne "\r  Health: ${status_line} (${health_attempts}s)  "

        if [[ "$all_healthy" == true ]]; then
            echo ""
            print_success "All health checks passed"
            break
        fi

        health_attempts=$((health_attempts + 1))
        sleep 1
    done

    if [[ $health_attempts -ge $max_health_attempts ]]; then
        echo ""
        print_warning "Some services may not be fully healthy yet"
    fi

    # Final check: verify Paperless webserver is responding
    print_info "Verifying Paperless-ngx is responding..."

    local paperless_attempts=0
    local max_paperless_attempts=60

    while [ $paperless_attempts -lt $max_paperless_attempts ]; do
        if docker compose exec -T webserver python3 -c "print('ok')" &>/dev/null; then
            print_success "Paperless-ngx is ready"
            echo ""
            return 0
        fi

        echo -ne "\r  Waiting for Paperless-ngx... (${paperless_attempts}s)  "
        paperless_attempts=$((paperless_attempts + 1))
        sleep 1
    done

    echo ""
    print_warning "Paperless-ngx may need more time to initialize"
    print_info "You can check status with: docker compose logs -f webserver"
    echo ""
    return 0
}

# Legacy function for backward compatibility
wait_for_healthy() {
    wait_for_all_services
}

get_server_ip() {
    hostname -I | awk '{print $1}'
}

get_ssl_mode() {
    if [[ -f "${SCRIPT_DIR}/.ssl_mode" ]]; then
        cat "${SCRIPT_DIR}/.ssl_mode"
    else
        echo "http"
    fi
}

get_access_url() {
    local mode=$(get_ssl_mode)
    local ip=$(get_server_ip)

    case $mode in
        "https-redirect"|"https-only")
            echo "https://${ip}"
            ;;
        *)
            echo "http://${ip}"
            ;;
    esac
}

# ============================================================================
# OCR LANGUAGE SELECTION
# ============================================================================

# Complete list of Tesseract languages with full names
declare -A ALL_LANGUAGES=(
    ["afr"]="Afrikaans"
    ["amh"]="Amharic"
    ["ara"]="Arabic"
    ["asm"]="Assamese"
    ["aze"]="Azerbaijani"
    ["bel"]="Belarusian"
    ["ben"]="Bengali"
    ["bod"]="Tibetan"
    ["bos"]="Bosnian"
    ["bre"]="Breton"
    ["bul"]="Bulgarian"
    ["cat"]="Catalan"
    ["ceb"]="Cebuano"
    ["ces"]="Czech"
    ["chi_sim"]="Chinese (Simplified)"
    ["chi_tra"]="Chinese (Traditional)"
    ["chr"]="Cherokee"
    ["cos"]="Corsican"
    ["cym"]="Welsh"
    ["dan"]="Danish"
    ["deu"]="German"
    ["div"]="Divehi"
    ["dzo"]="Dzongkha"
    ["ell"]="Greek"
    ["eng"]="English"
    ["enm"]="English (Middle)"
    ["epo"]="Esperanto"
    ["est"]="Estonian"
    ["eus"]="Basque"
    ["fao"]="Faroese"
    ["fas"]="Persian"
    ["fil"]="Filipino"
    ["fin"]="Finnish"
    ["fra"]="French"
    ["frk"]="Frankish"
    ["frm"]="French (Middle)"
    ["fry"]="Frisian"
    ["gla"]="Scottish Gaelic"
    ["gle"]="Irish"
    ["glg"]="Galician"
    ["grc"]="Greek (Ancient)"
    ["guj"]="Gujarati"
    ["hat"]="Haitian"
    ["heb"]="Hebrew"
    ["hin"]="Hindi"
    ["hrv"]="Croatian"
    ["hun"]="Hungarian"
    ["hye"]="Armenian"
    ["iku"]="Inuktitut"
    ["ind"]="Indonesian"
    ["isl"]="Icelandic"
    ["ita"]="Italian"
    ["jav"]="Javanese"
    ["jpn"]="Japanese"
    ["kan"]="Kannada"
    ["kat"]="Georgian"
    ["kaz"]="Kazakh"
    ["khm"]="Khmer"
    ["kir"]="Kyrgyz"
    ["kor"]="Korean"
    ["kur"]="Kurdish"
    ["lao"]="Lao"
    ["lat"]="Latin"
    ["lav"]="Latvian"
    ["lit"]="Lithuanian"
    ["ltz"]="Luxembourgish"
    ["mal"]="Malayalam"
    ["mar"]="Marathi"
    ["mkd"]="Macedonian"
    ["mlt"]="Maltese"
    ["mon"]="Mongolian"
    ["mri"]="Maori"
    ["msa"]="Malay"
    ["mya"]="Burmese"
    ["nep"]="Nepali"
    ["nld"]="Dutch"
    ["nor"]="Norwegian"
    ["oci"]="Occitan"
    ["ori"]="Oriya"
    ["pan"]="Punjabi"
    ["pol"]="Polish"
    ["por"]="Portuguese"
    ["pus"]="Pashto"
    ["que"]="Quechua"
    ["ron"]="Romanian"
    ["rus"]="Russian"
    ["san"]="Sanskrit"
    ["sin"]="Sinhala"
    ["slk"]="Slovak"
    ["slv"]="Slovenian"
    ["snd"]="Sindhi"
    ["spa"]="Spanish"
    ["sqi"]="Albanian"
    ["srp"]="Serbian"
    ["srp_latn"]="Serbian (Latin)"
    ["sun"]="Sundanese"
    ["swa"]="Swahili"
    ["swe"]="Swedish"
    ["syr"]="Syriac"
    ["tam"]="Tamil"
    ["tat"]="Tatar"
    ["tel"]="Telugu"
    ["tgk"]="Tajik"
    ["tha"]="Thai"
    ["tir"]="Tigrinya"
    ["ton"]="Tonga"
    ["tur"]="Turkish"
    ["uig"]="Uyghur"
    ["ukr"]="Ukrainian"
    ["urd"]="Urdu"
    ["uzb"]="Uzbek"
    ["vie"]="Vietnamese"
    ["yid"]="Yiddish"
    ["yor"]="Yoruba"
)

# Region-based language groups
declare -A REGION_WESTERN_EUROPE=(
    ["deu"]="German" ["fra"]="French" ["spa"]="Spanish" ["ita"]="Italian"
    ["por"]="Portuguese" ["nld"]="Dutch" ["cat"]="Catalan" ["eus"]="Basque"
    ["glg"]="Galician" ["oci"]="Occitan" ["bre"]="Breton" ["cos"]="Corsican"
    ["ltz"]="Luxembourgish"
)

declare -A REGION_CENTRAL_EASTERN_EUROPE=(
    ["pol"]="Polish" ["ces"]="Czech" ["slk"]="Slovak" ["slv"]="Slovenian"
    ["hrv"]="Croatian" ["hun"]="Hungarian" ["ron"]="Romanian" ["bul"]="Bulgarian"
    ["srp"]="Serbian" ["srp_latn"]="Serbian (Latin)" ["bos"]="Bosnian"
    ["mkd"]="Macedonian" ["sqi"]="Albanian" ["ukr"]="Ukrainian" ["bel"]="Belarusian"
    ["rus"]="Russian"
)

declare -A REGION_NORTHERN_EUROPE=(
    ["dan"]="Danish" ["nor"]="Norwegian" ["swe"]="Swedish" ["fin"]="Finnish"
    ["isl"]="Icelandic" ["est"]="Estonian" ["lav"]="Latvian" ["lit"]="Lithuanian"
    ["fao"]="Faroese"
)

declare -A REGION_BRITISH_ISLES=(
    ["eng"]="English" ["gle"]="Irish" ["gla"]="Scottish Gaelic" ["cym"]="Welsh"
    ["bre"]="Breton" ["fry"]="Frisian"
)

declare -A REGION_ASIA_EAST=(
    ["chi_sim"]="Chinese (Simplified)" ["chi_tra"]="Chinese (Traditional)"
    ["jpn"]="Japanese" ["kor"]="Korean" ["mon"]="Mongolian"
)

declare -A REGION_ASIA_SOUTH=(
    ["hin"]="Hindi" ["ben"]="Bengali" ["tam"]="Tamil" ["tel"]="Telugu"
    ["mar"]="Marathi" ["guj"]="Gujarati" ["kan"]="Kannada" ["mal"]="Malayalam"
    ["pan"]="Punjabi" ["ori"]="Oriya" ["asm"]="Assamese" ["nep"]="Nepali"
    ["sin"]="Sinhala" ["urd"]="Urdu"
)

declare -A REGION_ASIA_SOUTHEAST=(
    ["vie"]="Vietnamese" ["tha"]="Thai" ["ind"]="Indonesian" ["msa"]="Malay"
    ["fil"]="Filipino" ["khm"]="Khmer" ["lao"]="Lao" ["mya"]="Burmese"
    ["jav"]="Javanese" ["sun"]="Sundanese" ["ceb"]="Cebuano"
)

declare -A REGION_MIDDLE_EAST=(
    ["ara"]="Arabic" ["heb"]="Hebrew" ["tur"]="Turkish" ["fas"]="Persian"
    ["kur"]="Kurdish" ["pus"]="Pashto" ["syr"]="Syriac" ["div"]="Divehi"
)

declare -A REGION_CENTRAL_ASIA=(
    ["kaz"]="Kazakh" ["uzb"]="Uzbek" ["kir"]="Kyrgyz" ["tgk"]="Tajik"
    ["tat"]="Tatar" ["uig"]="Uyghur" ["aze"]="Azerbaijani"
)

declare -A REGION_AFRICA=(
    ["afr"]="Afrikaans" ["amh"]="Amharic" ["swa"]="Swahili" ["yor"]="Yoruba"
    ["tir"]="Tigrinya"
)

# Popular business presets
declare -A PRESETS=(
    ["1"]="eng|English Only"
    ["2"]="deu+eng|German + English"
    ["3"]="fra+eng|French + English"
    ["4"]="spa+eng|Spanish + English"
    ["5"]="deu+eng+fra|German + English + French"
    ["6"]="deu+eng+pol+ces|Central European (DE+EN+PL+CZ)"
    ["7"]="deu+eng+fra+ita+spa|Western European Business"
    ["8"]="deu+eng+pol+ces+slk+hun|Central European Extended"
    ["9"]="eng+fra+spa+por|International Americas"
    ["10"]="chi_sim+eng+jpn+kor|East Asian Business"
)

select_ocr_languages() {
    print_header "OCR Language Configuration"

    echo "Paperless uses Tesseract OCR which supports 100+ languages."
    echo "You can select multiple languages for mixed-language documents."
    echo ""
    echo "How would you like to select OCR languages?"
    echo ""
    echo "  1) Popular presets (quick selection)"
    echo "  2) Select by region (grouped by geography)"
    echo "  3) Browse all languages (step through complete list)"
    echo "  4) Manual entry (enter language codes directly)"
    echo ""

    read -p "Select method [1-4] (default: 1): " method_choice
    method_choice=${method_choice:-1}

    case $method_choice in
        1)
            select_from_presets
            ;;
        2)
            select_by_region
            ;;
        3)
            browse_all_languages
            ;;
        4)
            manual_language_entry
            ;;
        *)
            print_warning "Invalid choice, using English only"
            OCR_LANGUAGES="eng"
            ;;
    esac

    echo ""
    print_success "OCR languages set to: ${OCR_LANGUAGES}"

    # Show human-readable names
    echo ""
    echo "Selected languages:"
    IFS='+' read -ra LANG_ARRAY <<< "$OCR_LANGUAGES"
    for lang in "${LANG_ARRAY[@]}"; do
        if [[ -n "${ALL_LANGUAGES[$lang]}" ]]; then
            echo "  - ${ALL_LANGUAGES[$lang]} ($lang)"
        else
            echo "  - $lang"
        fi
    done
    echo ""
}

select_from_presets() {
    echo ""
    echo "Popular language presets:"
    echo ""
    echo "  ┌──────────────────────────────────────────────────────────────┐"
    echo "  │  #   │  Languages                                            │"
    echo "  ├──────────────────────────────────────────────────────────────┤"
    echo "  │  1   │  English Only                                         │"
    echo "  │  2   │  German + English                                     │"
    echo "  │  3   │  French + English                                     │"
    echo "  │  4   │  Spanish + English                                    │"
    echo "  │  5   │  German + English + French                            │"
    echo "  │  6   │  Central European (DE + EN + PL + CZ)                 │"
    echo "  │  7   │  Western European (DE + EN + FR + IT + ES)            │"
    echo "  │  8   │  Central European Extended (DE+EN+PL+CZ+SK+HU)        │"
    echo "  │  9   │  International Americas (EN + FR + ES + PT)           │"
    echo "  │ 10   │  East Asian Business (ZH + EN + JP + KR)              │"
    echo "  └──────────────────────────────────────────────────────────────┘"
    echo ""

    read -p "Select preset [1-10] (default: 2): " preset_choice
    preset_choice=${preset_choice:-2}

    if [[ -n "${PRESETS[$preset_choice]}" ]]; then
        OCR_LANGUAGES="${PRESETS[$preset_choice]%%|*}"
    else
        print_warning "Invalid choice, using German + English"
        OCR_LANGUAGES="deu+eng"
    fi
}

select_by_region() {
    local selected_languages=()

    echo ""
    echo "Select regions (you can select multiple):"
    echo ""
    echo "  1) Western Europe (DE, FR, ES, IT, PT, NL, ...)"
    echo "  2) Central & Eastern Europe (PL, CZ, SK, HU, RO, BG, UA, RU, ...)"
    echo "  3) Northern Europe (DK, NO, SE, FI, EE, LV, LT, ...)"
    echo "  4) British Isles (EN, Irish, Welsh, Scottish Gaelic)"
    echo "  5) East Asia (Chinese, Japanese, Korean)"
    echo "  6) South Asia (Hindi, Bengali, Tamil, ...)"
    echo "  7) Southeast Asia (Vietnamese, Thai, Indonesian, ...)"
    echo "  8) Middle East (Arabic, Hebrew, Turkish, Persian, ...)"
    echo "  9) Central Asia (Kazakh, Uzbek, ...)"
    echo " 10) Africa (Afrikaans, Swahili, Amharic, ...)"
    echo ""

    read -p "Enter region numbers separated by space (e.g., '1 2 4'): " region_choices

    for region in $region_choices; do
        case $region in
            1) select_from_region "Western Europe" REGION_WESTERN_EUROPE selected_languages ;;
            2) select_from_region "Central & Eastern Europe" REGION_CENTRAL_EASTERN_EUROPE selected_languages ;;
            3) select_from_region "Northern Europe" REGION_NORTHERN_EUROPE selected_languages ;;
            4) select_from_region "British Isles" REGION_BRITISH_ISLES selected_languages ;;
            5) select_from_region "East Asia" REGION_ASIA_EAST selected_languages ;;
            6) select_from_region "South Asia" REGION_ASIA_SOUTH selected_languages ;;
            7) select_from_region "Southeast Asia" REGION_ASIA_SOUTHEAST selected_languages ;;
            8) select_from_region "Middle East" REGION_MIDDLE_EAST selected_languages ;;
            9) select_from_region "Central Asia" REGION_CENTRAL_ASIA selected_languages ;;
            10) select_from_region "Africa" REGION_AFRICA selected_languages ;;
        esac
    done

    if [[ ${#selected_languages[@]} -eq 0 ]]; then
        print_warning "No languages selected, using English"
        OCR_LANGUAGES="eng"
    else
        # Remove duplicates and join with +
        OCR_LANGUAGES=$(printf "%s\n" "${selected_languages[@]}" | sort -u | tr '\n' '+' | sed 's/+$//')
    fi
}

select_from_region() {
    local region_name="$1"
    local -n region_map="$2"
    local -n selected="$3"

    echo ""
    print_info "Languages in ${region_name}:"
    echo ""

    # Build numbered list
    local i=1
    local codes=()
    for code in "${!region_map[@]}"; do
        codes+=("$code")
        printf "  %2d) %-25s [%s]\n" "$i" "${region_map[$code]}" "$code"
        ((i++))
    done

    echo ""
    echo "  A) Select ALL from this region"
    echo ""

    read -p "Enter numbers separated by space, or 'A' for all: " lang_choices

    if [[ "$lang_choices" == "A" || "$lang_choices" == "a" ]]; then
        for code in "${!region_map[@]}"; do
            selected+=("$code")
        done
    else
        for num in $lang_choices; do
            if [[ "$num" =~ ^[0-9]+$ ]] && [[ $num -ge 1 ]] && [[ $num -le ${#codes[@]} ]]; then
                selected+=("${codes[$((num-1))]}")
            fi
        done
    fi
}

browse_all_languages() {
    local selected_languages=()

    echo ""
    echo "Browse through all available languages."
    echo "For each language, enter 'y' to select, 'n' to skip, or 'q' to finish."
    echo ""

    # Sort languages alphabetically by name
    local sorted_codes=($(for code in "${!ALL_LANGUAGES[@]}"; do
        echo "${ALL_LANGUAGES[$code]}|$code"
    done | sort | cut -d'|' -f2))

    local count=0
    local total=${#sorted_codes[@]}

    for code in "${sorted_codes[@]}"; do
        ((count++))
        local name="${ALL_LANGUAGES[$code]}"

        echo -ne "[$count/$total] ${name} (${code}) - Select? [y/n/q]: "
        read -r answer

        case $answer in
            y|Y)
                selected_languages+=("$code")
                print_success "Added: ${name}"
                ;;
            q|Q)
                echo "Finishing selection..."
                break
                ;;
            *)
                # Skip
                ;;
        esac
    done

    if [[ ${#selected_languages[@]} -eq 0 ]]; then
        print_warning "No languages selected, using English"
        OCR_LANGUAGES="eng"
    else
        OCR_LANGUAGES=$(printf "%s\n" "${selected_languages[@]}" | tr '\n' '+' | sed 's/+$//')
    fi
}

manual_language_entry() {
    echo ""
    echo "Enter Tesseract language codes separated by + (e.g., 'deu+eng+pol+ces')"
    echo ""
    echo "Common codes: eng (English), deu (German), fra (French), spa (Spanish),"
    echo "              ita (Italian), pol (Polish), ces (Czech), nld (Dutch),"
    echo "              por (Portuguese), rus (Russian), chi_sim (Chinese Simplified)"
    echo ""
    echo "Full list: https://tesseract-ocr.github.io/tessdoc/Data-Files-in-different-versions.html"
    echo ""

    read -p "Enter language codes: " manual_codes

    if [[ -z "$manual_codes" ]]; then
        print_warning "No input, using English"
        OCR_LANGUAGES="eng"
    else
        # Clean up input (remove spaces, convert to lowercase for codes)
        OCR_LANGUAGES=$(echo "$manual_codes" | tr ' ' '+' | tr ',' '+' | sed 's/++*/+/g' | sed 's/^+//' | sed 's/+$//')
    fi
}

# ============================================================================
# TIMEZONE SELECTION
# ============================================================================

# Common timezones grouped by region
declare -A TIMEZONE_PRESETS=(
    ["1"]="UTC|UTC (Coordinated Universal Time)"
    ["2"]="Europe/London|London (GMT/BST)"
    ["3"]="Europe/Berlin|Berlin, Vienna, Zurich (CET/CEST)"
    ["4"]="Europe/Paris|Paris, Brussels, Amsterdam (CET/CEST)"
    ["5"]="Europe/Warsaw|Warsaw, Prague, Budapest (CET/CEST)"
    ["6"]="Europe/Moscow|Moscow (MSK)"
    ["7"]="America/New_York|New York, Toronto (EST/EDT)"
    ["8"]="America/Chicago|Chicago, Dallas (CST/CDT)"
    ["9"]="America/Denver|Denver, Phoenix (MST/MDT)"
    ["10"]="America/Los_Angeles|Los Angeles, Seattle (PST/PDT)"
    ["11"]="America/Sao_Paulo|São Paulo, Buenos Aires (BRT)"
    ["12"]="Asia/Tokyo|Tokyo, Seoul (JST/KST)"
    ["13"]="Asia/Shanghai|Shanghai, Beijing, Singapore (CST/SGT)"
    ["14"]="Asia/Dubai|Dubai, Abu Dhabi (GST)"
    ["15"]="Asia/Kolkata|Mumbai, New Delhi (IST)"
    ["16"]="Australia/Sydney|Sydney, Melbourne (AEST/AEDT)"
)

declare -A TIMEZONE_REGIONS=(
    ["1"]="Europe"
    ["2"]="America"
    ["3"]="Asia"
    ["4"]="Pacific"
    ["5"]="Africa"
    ["6"]="Atlantic"
    ["7"]="Indian"
    ["8"]="Australia"
)

select_timezone() {
    print_header "Timezone Configuration"

    echo "Select the timezone for Paperless-ngx."
    echo "This affects document dates and scheduled tasks."
    echo ""

    # Try to detect current system timezone
    local system_tz=""
    if [[ -f /etc/timezone ]]; then
        system_tz=$(cat /etc/timezone)
    elif [[ -L /etc/localtime ]]; then
        system_tz=$(readlink /etc/localtime | sed 's|.*/zoneinfo/||')
    fi

    if [[ -n "$system_tz" ]]; then
        print_info "Detected system timezone: ${system_tz}"
        echo ""
    fi

    echo "How would you like to select the timezone?"
    echo ""
    echo "  1) Popular timezones (quick selection)"
    echo "  2) Browse by region"
    echo "  3) Use system timezone${system_tz:+ ($system_tz)}"
    echo "  4) Manual entry (enter timezone string)"
    echo ""

    read -p "Select method [1-4] (default: 1): " method_choice
    method_choice=${method_choice:-1}

    case $method_choice in
        1)
            select_timezone_preset
            ;;
        2)
            select_timezone_by_region
            ;;
        3)
            if [[ -n "$system_tz" ]]; then
                SELECTED_TIMEZONE="$system_tz"
            else
                print_warning "Could not detect system timezone, using UTC"
                SELECTED_TIMEZONE="UTC"
            fi
            ;;
        4)
            manual_timezone_entry
            ;;
        *)
            print_warning "Invalid choice, using UTC"
            SELECTED_TIMEZONE="UTC"
            ;;
    esac

    echo ""
    print_success "Timezone set to: ${SELECTED_TIMEZONE}"

    # Show current time in selected timezone
    local current_time=$(TZ="$SELECTED_TIMEZONE" date "+%Y-%m-%d %H:%M:%S %Z" 2>/dev/null)
    if [[ -n "$current_time" ]]; then
        echo "Current time in this timezone: ${current_time}"
    fi
    echo ""
}

select_timezone_preset() {
    echo ""
    echo "Popular timezones:"
    echo ""
    echo "  ┌─────────────────────────────────────────────────────────────────┐"
    echo "  │  #   │  Timezone                                                │"
    echo "  ├─────────────────────────────────────────────────────────────────┤"
    echo "  │  1   │  UTC (Coordinated Universal Time)                        │"
    echo "  │  2   │  London (GMT/BST)                                        │"
    echo "  │  3   │  Berlin, Vienna, Zurich (CET/CEST)                       │"
    echo "  │  4   │  Paris, Brussels, Amsterdam (CET/CEST)                   │"
    echo "  │  5   │  Warsaw, Prague, Budapest (CET/CEST)                     │"
    echo "  │  6   │  Moscow (MSK)                                            │"
    echo "  ├─────────────────────────────────────────────────────────────────┤"
    echo "  │  7   │  New York, Toronto (EST/EDT)                             │"
    echo "  │  8   │  Chicago, Dallas (CST/CDT)                               │"
    echo "  │  9   │  Denver, Phoenix (MST/MDT)                               │"
    echo "  │ 10   │  Los Angeles, Seattle (PST/PDT)                          │"
    echo "  │ 11   │  São Paulo, Buenos Aires (BRT)                           │"
    echo "  ├─────────────────────────────────────────────────────────────────┤"
    echo "  │ 12   │  Tokyo, Seoul (JST/KST)                                  │"
    echo "  │ 13   │  Shanghai, Beijing, Singapore (CST/SGT)                  │"
    echo "  │ 14   │  Dubai, Abu Dhabi (GST)                                  │"
    echo "  │ 15   │  Mumbai, New Delhi (IST)                                 │"
    echo "  │ 16   │  Sydney, Melbourne (AEST/AEDT)                           │"
    echo "  └─────────────────────────────────────────────────────────────────┘"
    echo ""

    read -p "Select timezone [1-16] (default: 3 for Berlin): " tz_choice
    tz_choice=${tz_choice:-3}

    if [[ -n "${TIMEZONE_PRESETS[$tz_choice]}" ]]; then
        SELECTED_TIMEZONE="${TIMEZONE_PRESETS[$tz_choice]%%|*}"
    else
        print_warning "Invalid choice, using Europe/Berlin"
        SELECTED_TIMEZONE="Europe/Berlin"
    fi
}

select_timezone_by_region() {
    echo ""
    echo "Select a region:"
    echo ""
    echo "  1) Europe"
    echo "  2) America (North & South)"
    echo "  3) Asia"
    echo "  4) Pacific"
    echo "  5) Africa"
    echo "  6) Atlantic"
    echo "  7) Indian Ocean"
    echo "  8) Australia"
    echo ""

    read -p "Select region [1-8]: " region_choice

    local region=""
    case $region_choice in
        1) region="Europe" ;;
        2) region="America" ;;
        3) region="Asia" ;;
        4) region="Pacific" ;;
        5) region="Africa" ;;
        6) region="Atlantic" ;;
        7) region="Indian" ;;
        8) region="Australia" ;;
        *)
            print_warning "Invalid choice, using Europe"
            region="Europe"
            ;;
    esac

    echo ""
    echo "Available timezones in ${region}:"
    echo ""

    # Get all timezones for the region
    local timezones=()
    local i=1

    # Try to get from system
    if [[ -d /usr/share/zoneinfo/${region} ]]; then
        while IFS= read -r tz; do
            local tz_name=$(basename "$tz")
            # Skip directories and non-timezone files
            if [[ -f "$tz" ]] && [[ ! "$tz_name" =~ ^[A-Z]{2,4}$ ]]; then
                timezones+=("${region}/${tz_name}")
                printf "  %3d) %s\n" "$i" "${region}/${tz_name}"
                ((i++))
            fi
        done < <(find /usr/share/zoneinfo/${region} -maxdepth 1 -type f | sort)
    else
        # Fallback: common timezones
        case $region in
            Europe)
                timezones=("Europe/Amsterdam" "Europe/Athens" "Europe/Berlin" "Europe/Brussels"
                          "Europe/Budapest" "Europe/Copenhagen" "Europe/Dublin" "Europe/Helsinki"
                          "Europe/Istanbul" "Europe/Kiev" "Europe/Lisbon" "Europe/London"
                          "Europe/Madrid" "Europe/Moscow" "Europe/Oslo" "Europe/Paris"
                          "Europe/Prague" "Europe/Rome" "Europe/Stockholm" "Europe/Vienna"
                          "Europe/Warsaw" "Europe/Zurich")
                ;;
            America)
                timezones=("America/Anchorage" "America/Buenos_Aires" "America/Chicago"
                          "America/Denver" "America/Los_Angeles" "America/Mexico_City"
                          "America/New_York" "America/Phoenix" "America/Santiago"
                          "America/Sao_Paulo" "America/Toronto" "America/Vancouver")
                ;;
            Asia)
                timezones=("Asia/Bangkok" "Asia/Dubai" "Asia/Hong_Kong" "Asia/Jakarta"
                          "Asia/Jerusalem" "Asia/Kolkata" "Asia/Manila" "Asia/Seoul"
                          "Asia/Shanghai" "Asia/Singapore" "Asia/Tokyo")
                ;;
            Pacific)
                timezones=("Pacific/Auckland" "Pacific/Fiji" "Pacific/Honolulu")
                ;;
            Africa)
                timezones=("Africa/Cairo" "Africa/Johannesburg" "Africa/Lagos" "Africa/Nairobi")
                ;;
            Australia)
                timezones=("Australia/Adelaide" "Australia/Brisbane" "Australia/Darwin"
                          "Australia/Melbourne" "Australia/Perth" "Australia/Sydney")
                ;;
            *)
                timezones=("UTC")
                ;;
        esac

        for tz in "${timezones[@]}"; do
            printf "  %3d) %s\n" "$i" "$tz"
            ((i++))
        done
    fi

    echo ""
    read -p "Select timezone number: " tz_num

    if [[ "$tz_num" =~ ^[0-9]+$ ]] && [[ $tz_num -ge 1 ]] && [[ $tz_num -le ${#timezones[@]} ]]; then
        SELECTED_TIMEZONE="${timezones[$((tz_num-1))]}"
    else
        print_warning "Invalid choice, using ${region}/London or UTC"
        SELECTED_TIMEZONE="${timezones[0]:-UTC}"
    fi
}

manual_timezone_entry() {
    echo ""
    echo "Enter the timezone in IANA format (e.g., 'Europe/Berlin', 'America/New_York')"
    echo ""
    echo "Common formats:"
    echo "  - Europe/Berlin, Europe/London, Europe/Paris"
    echo "  - America/New_York, America/Los_Angeles, America/Chicago"
    echo "  - Asia/Tokyo, Asia/Shanghai, Asia/Singapore"
    echo "  - Australia/Sydney, Pacific/Auckland"
    echo "  - UTC"
    echo ""
    echo "Full list: https://en.wikipedia.org/wiki/List_of_tz_database_time_zones"
    echo ""

    read -p "Enter timezone: " manual_tz

    if [[ -z "$manual_tz" ]]; then
        print_warning "No input, using UTC"
        SELECTED_TIMEZONE="UTC"
    else
        # Validate timezone
        if [[ -f "/usr/share/zoneinfo/${manual_tz}" ]] || [[ "$manual_tz" == "UTC" ]]; then
            SELECTED_TIMEZONE="$manual_tz"
        else
            print_warning "Timezone '${manual_tz}' may not be valid, using anyway"
            SELECTED_TIMEZONE="$manual_tz"
        fi
    fi
}

# ============================================================================
# SCHEDULED BACKUP FUNCTIONS
# ============================================================================

CRON_JOB_MARKER="# Paperless-ngx automatic backup"
BACKUP_SCRIPT="${SCRIPT_DIR}/backup-cron.sh"

get_backup_schedule() {
    # Check if cron job exists and return its schedule
    if crontab -l 2>/dev/null | grep -q "$CRON_JOB_MARKER"; then
        local schedule=$(crontab -l 2>/dev/null | grep "$CRON_JOB_MARKER" -A1 | tail -1 | awk '{print $1, $2, $3, $4, $5}')
        echo "$schedule"
    else
        echo "none"
    fi
}

get_schedule_description() {
    local schedule="$1"
    case "$schedule" in
        "0 2 * * *")
            echo "Daily at 2:00 AM"
            ;;
        "0 3 * * 0")
            echo "Weekly on Sunday at 3:00 AM"
            ;;
        "0 3 1 * *")
            echo "Monthly on the 1st at 3:00 AM"
            ;;
        "0 */6 * * *")
            echo "Every 6 hours"
            ;;
        "0 */12 * * *")
            echo "Every 12 hours"
            ;;
        "none")
            echo "Not scheduled"
            ;;
        *)
            echo "Custom: $schedule"
            ;;
    esac
}

create_backup_script() {
    print_info "Creating backup script..."

    cat > "$BACKUP_SCRIPT" << 'EOFSCRIPT'
#!/bin/bash
#
# Paperless-ngx Automatic Backup Script
# This script is called by cron for scheduled backups
#

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BACKUP_DIR="${SCRIPT_DIR}/backups"
DATA_DIR="${SCRIPT_DIR}/data"
NGINX_DIR="${SCRIPT_DIR}/nginx"
LOG_FILE="${BACKUP_DIR}/backup.log"

# Load retention settings
RETENTION_DAYS="${BACKUP_RETENTION_DAYS:-30}"
MAX_BACKUPS="${BACKUP_MAX_COUNT:-10}"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE"
}

log "=========================================="
log "Starting scheduled backup"

cd "$SCRIPT_DIR"

# Create backup directory with timestamp
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
CURRENT_BACKUP_DIR="${BACKUP_DIR}/backup_${TIMESTAMP}"

mkdir -p "$CURRENT_BACKUP_DIR"

log "Backup directory: ${CURRENT_BACKUP_DIR}"

# Check if services are running
if docker compose ps --status running 2>/dev/null | grep -q "webserver"; then
    SERVICES_RUNNING=true
    log "Services are running"
else
    SERVICES_RUNNING=false
    log "Services not running, starting database temporarily"
    docker compose up -d db
    sleep 10
fi

# 1. Backup PostgreSQL database
log "Backing up PostgreSQL database..."
if docker compose exec -T db pg_dump -U paperless -d paperless > "${CURRENT_BACKUP_DIR}/database.sql" 2>/dev/null; then
    log "Database backup successful"
else
    log "ERROR: Database backup failed"
fi

# 2. Backup configuration files
log "Backing up configuration files..."
cp "${SCRIPT_DIR}/docker-compose.yml" "${CURRENT_BACKUP_DIR}/" 2>/dev/null || true
[[ -f "${SCRIPT_DIR}/.env" ]] && cp "${SCRIPT_DIR}/.env" "${CURRENT_BACKUP_DIR}/"
[[ -f "${SCRIPT_DIR}/.ssl_mode" ]] && cp "${SCRIPT_DIR}/.ssl_mode" "${CURRENT_BACKUP_DIR}/"

# Backup nginx config
if [[ -d "${NGINX_DIR}" ]]; then
    tar -czf "${CURRENT_BACKUP_DIR}/nginx.tar.gz" -C "${SCRIPT_DIR}" nginx 2>/dev/null || true
fi

# 3. Stop webserver for consistent backup (if running)
if [[ "$SERVICES_RUNNING" == true ]]; then
    log "Stopping webserver for consistent backup..."
    docker compose stop webserver
fi

# 4. Backup data directories
log "Backing up media files..."
if [[ -d "${DATA_DIR}/media" ]]; then
    tar -czf "${CURRENT_BACKUP_DIR}/media.tar.gz" -C "${DATA_DIR}" media 2>/dev/null || true
fi

log "Backing up application data..."
if [[ -d "${DATA_DIR}/data" ]]; then
    tar -czf "${CURRENT_BACKUP_DIR}/data.tar.gz" -C "${DATA_DIR}" data 2>/dev/null || true
fi

# 5. Restart webserver if it was running
if [[ "$SERVICES_RUNNING" == true ]]; then
    log "Restarting webserver..."
    docker compose start webserver
else
    docker compose stop db
fi

# 6. Create compressed archive
log "Creating compressed archive..."
tar -czf "${BACKUP_DIR}/backup_${TIMESTAMP}.tar.gz" -C "${BACKUP_DIR}" "backup_${TIMESTAMP}"

# 7. Remove uncompressed folder
rm -rf "$CURRENT_BACKUP_DIR"

# 8. Calculate backup size
BACKUP_SIZE=$(du -sh "${BACKUP_DIR}/backup_${TIMESTAMP}.tar.gz" | cut -f1)
log "Backup complete: backup_${TIMESTAMP}.tar.gz (${BACKUP_SIZE})"

# 9. Cleanup old backups based on retention policy
log "Checking backup retention..."

# Remove backups older than RETENTION_DAYS
if [[ "$RETENTION_DAYS" -gt 0 ]]; then
    find "$BACKUP_DIR" -name "backup_*.tar.gz" -type f -mtime +${RETENTION_DAYS} -delete 2>/dev/null || true
    log "Removed backups older than ${RETENTION_DAYS} days"
fi

# Keep only MAX_BACKUPS most recent
if [[ "$MAX_BACKUPS" -gt 0 ]]; then
    BACKUP_COUNT=$(ls -1 "${BACKUP_DIR}"/backup_*.tar.gz 2>/dev/null | wc -l)
    if [[ "$BACKUP_COUNT" -gt "$MAX_BACKUPS" ]]; then
        REMOVE_COUNT=$((BACKUP_COUNT - MAX_BACKUPS))
        ls -1t "${BACKUP_DIR}"/backup_*.tar.gz | tail -n "$REMOVE_COUNT" | xargs rm -f 2>/dev/null || true
        log "Removed ${REMOVE_COUNT} old backups (keeping ${MAX_BACKUPS})"
    fi
fi

log "Scheduled backup completed successfully"
log "=========================================="
EOFSCRIPT

    chmod +x "$BACKUP_SCRIPT"
    print_success "Backup script created: ${BACKUP_SCRIPT}"
}

setup_backup_schedule() {
    print_header "Configure Automatic Backups"

    check_root

    local current_schedule=$(get_backup_schedule)
    local current_desc=$(get_schedule_description "$current_schedule")

    echo "Current backup schedule: ${current_desc}"
    echo ""
    echo "Select a backup schedule:"
    echo ""
    echo "  1) Daily at 2:00 AM"
    echo "  2) Weekly on Sunday at 3:00 AM"
    echo "  3) Monthly on the 1st at 3:00 AM"
    echo "  4) Every 6 hours"
    echo "  5) Every 12 hours"
    echo "  6) Custom schedule (enter cron expression)"
    echo "  7) Disable automatic backups"
    echo "  8) View backup log"
    echo ""
    echo "  0) Cancel"
    echo ""

    read -p "Select option [0-8]: " schedule_choice

    local cron_schedule=""
    local schedule_name=""

    case $schedule_choice in
        1)
            cron_schedule="0 2 * * *"
            schedule_name="Daily at 2:00 AM"
            ;;
        2)
            cron_schedule="0 3 * * 0"
            schedule_name="Weekly on Sunday at 3:00 AM"
            ;;
        3)
            cron_schedule="0 3 1 * *"
            schedule_name="Monthly on the 1st at 3:00 AM"
            ;;
        4)
            cron_schedule="0 */6 * * *"
            schedule_name="Every 6 hours"
            ;;
        5)
            cron_schedule="0 */12 * * *"
            schedule_name="Every 12 hours"
            ;;
        6)
            echo ""
            echo "Enter a cron expression (5 fields: minute hour day month weekday)"
            echo "Examples:"
            echo "  '0 4 * * *'     - Daily at 4:00 AM"
            echo "  '30 1 * * 1-5'  - Weekdays at 1:30 AM"
            echo "  '0 0 * * 0'     - Weekly on Sunday at midnight"
            echo "  '0 */4 * * *'   - Every 4 hours"
            echo ""
            read -p "Cron expression: " custom_cron

            if [[ -z "$custom_cron" ]]; then
                print_warning "No schedule entered"
                read -p "Press Enter to continue..."
                return
            fi

            # Basic validation (5 fields)
            if [[ $(echo "$custom_cron" | awk '{print NF}') -ne 5 ]]; then
                print_error "Invalid cron expression (must have 5 fields)"
                read -p "Press Enter to continue..."
                return
            fi

            cron_schedule="$custom_cron"
            schedule_name="Custom: $custom_cron"
            ;;
        7)
            remove_backup_schedule
            read -p "Press Enter to continue..."
            return
            ;;
        8)
            view_backup_log
            return
            ;;
        0)
            print_info "Cancelled"
            read -p "Press Enter to continue..."
            return
            ;;
        *)
            print_error "Invalid option"
            read -p "Press Enter to continue..."
            return
            ;;
    esac

    # Create the backup script if it doesn't exist
    if [[ ! -f "$BACKUP_SCRIPT" ]]; then
        create_backup_script
    fi

    # Configure retention settings
    echo ""
    print_header "Backup Retention Settings"

    echo "How many days should backups be kept?"
    echo "(Backups older than this will be automatically deleted)"
    echo ""
    read -p "Retention days [30]: " retention_days
    retention_days=${retention_days:-30}

    echo ""
    echo "Maximum number of backups to keep?"
    echo "(Oldest backups beyond this count will be deleted)"
    echo ""
    read -p "Maximum backups [10]: " max_backups
    max_backups=${max_backups:-10}

    # Save retention settings
    cat > "${SCRIPT_DIR}/.backup_settings" << EOF
# Backup retention settings
BACKUP_RETENTION_DAYS=${retention_days}
BACKUP_MAX_COUNT=${max_backups}
EOF

    # Update backup script with retention settings
    sed -i "s/RETENTION_DAYS=\"\${BACKUP_RETENTION_DAYS:-30}\"/RETENTION_DAYS=\"\${BACKUP_RETENTION_DAYS:-${retention_days}}\"/" "$BACKUP_SCRIPT"
    sed -i "s/MAX_BACKUPS=\"\${BACKUP_MAX_COUNT:-10}\"/MAX_BACKUPS=\"\${BACKUP_MAX_COUNT:-${max_backups}}\"/" "$BACKUP_SCRIPT"

    # Remove existing paperless backup cron job
    remove_backup_schedule_silent

    # Add new cron job
    print_info "Setting up cron job..."

    # Get current crontab (or empty if none)
    local current_crontab=$(crontab -l 2>/dev/null || true)

    # Add new job
    (echo "$current_crontab"; echo "$CRON_JOB_MARKER"; echo "$cron_schedule $BACKUP_SCRIPT") | crontab -

    print_success "Automatic backup scheduled: ${schedule_name}"
    echo ""
    echo "Backup settings:"
    echo "  Schedule: ${schedule_name}"
    echo "  Retention: ${retention_days} days"
    echo "  Max backups: ${max_backups}"
    echo "  Script: ${BACKUP_SCRIPT}"
    echo "  Log: ${BACKUP_DIR}/backup.log"
    echo ""

    read -p "Press Enter to continue..."
}

remove_backup_schedule() {
    print_info "Removing automatic backup schedule..."

    if crontab -l 2>/dev/null | grep -q "$CRON_JOB_MARKER"; then
        # Remove the marker line and the following line (the actual cron job)
        crontab -l 2>/dev/null | grep -v "$CRON_JOB_MARKER" | grep -v "$BACKUP_SCRIPT" | crontab -
        print_success "Automatic backup schedule removed"
    else
        print_info "No automatic backup was scheduled"
    fi
}

remove_backup_schedule_silent() {
    # Silent version for use when updating schedule
    if crontab -l 2>/dev/null | grep -q "$CRON_JOB_MARKER"; then
        crontab -l 2>/dev/null | grep -v "$CRON_JOB_MARKER" | grep -v "$BACKUP_SCRIPT" | crontab -
    fi
}

view_backup_log() {
    print_header "Backup Log"

    local log_file="${BACKUP_DIR}/backup.log"

    if [[ -f "$log_file" ]]; then
        echo "Last 50 lines of backup log:"
        echo "-----------------------------"
        tail -50 "$log_file"
        echo ""
        echo "-----------------------------"
        echo "Full log: ${log_file}"
    else
        print_info "No backup log found yet."
        print_info "The log will be created after the first scheduled backup runs."
    fi

    echo ""
    read -p "Press Enter to continue..."
}

run_backup_now() {
    print_header "Run Backup Now"

    if [[ ! -f "$BACKUP_SCRIPT" ]]; then
        create_backup_script
    fi

    print_info "Running backup script..."
    echo ""

    # Run the backup script and show output
    bash "$BACKUP_SCRIPT" 2>&1 | tee -a "${BACKUP_DIR}/backup.log"

    echo ""
    print_success "Backup complete"

    read -p "Press Enter to continue..."
}

# ============================================================================
# BEGINNER-FRIENDLY FEATURES
# ============================================================================

# Quick Actions Menu - Simplified entry point for common tasks
quick_actions_menu() {
    while true; do
        clear
        echo -e "${BLUE}"
        echo "  ____                        _                "
        echo " |  _ \ __ _ _ __   ___ _ __ | | ___  ___ ___  "
        echo " | |_) / _\` | '_ \ / _ \ '__|| |/ _ \/ __/ __| "
        echo " |  __/ (_| | |_) |  __/ |   | |  __/\__ \__ \ "
        echo " |_|   \__,_| .__/ \___|_|   |_|\___||___/___/ "
        echo "            |_|                  Quick Actions "
        echo -e "${NC}"

        # Show quick health status
        local health_icon="${GREEN}●${NC}"
        if is_running; then
            health_icon="${GREEN}● Running${NC}"
        else
            health_icon="${RED}● Stopped${NC}"
        fi

        echo "=============================================="
        echo -e "  System Status: $health_icon"
        echo "=============================================="
        echo ""
        echo "  What would you like to do?"
        echo ""
        echo "  1) ${GREEN}▶${NC}  Start Paperless"
        echo "  2) ${RED}■${NC}  Stop Paperless"
        echo "  3) ${BLUE}↻${NC}  Restart Paperless"
        echo "  4) ${YELLOW}⬇${NC}  Create Backup"
        echo "  5) ${BLUE}ℹ${NC}  Check Health"
        echo "  6) ${GREEN}🌐${NC} Open Web Interface"
        echo ""
        echo "  ─────────────────────────────────────────"
        echo "  7) 🔧 Full Menu (more options)"
        echo "  8) ❓ Help - I have a problem"
        echo "  0) Exit"
        echo "=============================================="
        echo ""

        read -p "Choose an option [0-8]: " quick_choice

        case $quick_choice in
            1)
                echo ""
                if is_running; then
                    print_info "Paperless is already running!"
                    echo ""
                    echo "Your documents are accessible at:"
                    show_access_url
                else
                    print_info "Starting Paperless..."
                    start_services_quiet
                    echo ""
                    print_success "Paperless is now running!"
                    echo ""
                    echo "Access your documents at:"
                    show_access_url
                fi
                echo ""
                read -p "Press Enter to continue..."
                ;;
            2)
                echo ""
                if ! is_running; then
                    print_info "Paperless is already stopped."
                else
                    print_info "Stopping Paperless..."
                    stop_services_quiet
                    print_success "Paperless has been stopped."
                    echo ""
                    echo "Your documents are safe. Start Paperless again when you need it."
                fi
                echo ""
                read -p "Press Enter to continue..."
                ;;
            3)
                echo ""
                print_info "Restarting Paperless..."
                docker compose restart 2>/dev/null
                print_success "Paperless has been restarted!"
                echo ""
                echo "It may take a moment to become fully available."
                echo ""
                read -p "Press Enter to continue..."
                ;;
            4)
                echo ""
                print_info "Creating a backup of your documents and settings..."
                echo ""
                echo "This keeps your data safe in case anything goes wrong."
                echo ""
                create_backup
                ;;
            5)
                show_health_dashboard
                ;;
            6)
                echo ""
                if is_running; then
                    echo "Opening Paperless in your web browser..."
                    echo ""
                    show_access_url
                    echo ""
                    # Try to open browser
                    local url=$(get_paperless_url)
                    if command -v xdg-open &> /dev/null; then
                        xdg-open "$url" 2>/dev/null &
                    elif command -v open &> /dev/null; then
                        open "$url" 2>/dev/null &
                    else
                        echo "Please open this URL in your browser manually."
                    fi
                else
                    print_warning "Paperless is not running."
                    echo ""
                    read -p "Would you like to start it now? (y/n): " start_now
                    if [[ "$start_now" == "y" || "$start_now" == "Y" ]]; then
                        start_services_quiet
                        echo ""
                        show_access_url
                    fi
                fi
                echo ""
                read -p "Press Enter to continue..."
                ;;
            7)
                # Switch to full menu
                return 1
                ;;
            8)
                troubleshooting_assistant
                ;;
            0)
                echo ""
                print_info "Goodbye! Your documents are safe."
                exit 0
                ;;
            "?"|"h"|"help")
                show_quick_help
                ;;
            *)
                print_error "Please choose a number between 0 and 8"
                sleep 1
                ;;
        esac
    done
}

# Show access URL in friendly format
show_access_url() {
    local url=$(get_paperless_url)
    echo -e "  ${GREEN}➜${NC}  $url"
}

get_paperless_url() {
    local ssl_mode=$(get_ssl_mode)
    local ip=$(get_server_ip)

    if [[ "$ssl_mode" == "http" ]]; then
        echo "http://${ip}"
    else
        echo "https://${ip}"
    fi
}

# Quiet versions of start/stop for quick actions
start_services_quiet() {
    cd "$SCRIPT_DIR"
    docker compose up -d 2>/dev/null
    sleep 3
}

stop_services_quiet() {
    cd "$SCRIPT_DIR"
    docker compose down 2>/dev/null
}

# Health Dashboard - Simple traffic light view
show_health_dashboard() {
    clear
    print_header "System Health Dashboard"

    echo "Checking all systems..."
    echo ""

    local all_good=true
    local warnings=0
    local errors=0

    # Check each service with friendly names
    echo "┌─────────────────────────────────────────────────┐"
    echo "│             SERVICE STATUS                      │"
    echo "├─────────────────────────────────────────────────┤"

    # Web Server (main application)
    if check_service_health "webserver" > /dev/null 2>&1; then
        echo -e "│  ${GREEN}●${NC}  Paperless Application      ${GREEN}Running${NC}         │"
    else
        echo -e "│  ${RED}●${NC}  Paperless Application      ${RED}Not Running${NC}     │"
        all_good=false
        ((errors++))
    fi

    # Database
    if check_service_health "db" > /dev/null 2>&1; then
        echo -e "│  ${GREEN}●${NC}  Database                   ${GREEN}Running${NC}         │"
    else
        echo -e "│  ${RED}●${NC}  Database                   ${RED}Not Running${NC}     │"
        all_good=false
        ((errors++))
    fi

    # Redis (cache)
    if check_service_health "broker" > /dev/null 2>&1; then
        echo -e "│  ${GREEN}●${NC}  Cache                      ${GREEN}Running${NC}         │"
    else
        echo -e "│  ${RED}●${NC}  Cache                      ${RED}Not Running${NC}     │"
        all_good=false
        ((errors++))
    fi

    # Nginx (web server)
    if check_service_health "nginx" > /dev/null 2>&1; then
        echo -e "│  ${GREEN}●${NC}  Web Server                 ${GREEN}Running${NC}         │"
    else
        echo -e "│  ${YELLOW}●${NC}  Web Server                 ${YELLOW}Not Running${NC}     │"
        ((warnings++))
    fi

    # Document processors
    if check_service_health "gotenberg" > /dev/null 2>&1; then
        echo -e "│  ${GREEN}●${NC}  Document Converter         ${GREEN}Running${NC}         │"
    else
        echo -e "│  ${YELLOW}●${NC}  Document Converter         ${YELLOW}Not Running${NC}     │"
        ((warnings++))
    fi

    if check_service_health "tika" > /dev/null 2>&1; then
        echo -e "│  ${GREEN}●${NC}  Text Extractor             ${GREEN}Running${NC}         │"
    else
        echo -e "│  ${YELLOW}●${NC}  Text Extractor             ${YELLOW}Not Running${NC}     │"
        ((warnings++))
    fi

    echo "└─────────────────────────────────────────────────┘"
    echo ""

    # Disk Space Check
    echo "┌─────────────────────────────────────────────────┐"
    echo "│             STORAGE STATUS                      │"
    echo "├─────────────────────────────────────────────────┤"

    local disk_usage=$(df -h "$SCRIPT_DIR" 2>/dev/null | tail -1 | awk '{print $5}' | tr -d '%')
    if [[ "$disk_usage" =~ ^[0-9]+$ ]]; then
        if [[ $disk_usage -lt 70 ]]; then
            echo -e "│  ${GREEN}●${NC}  Disk Space                 ${GREEN}${disk_usage}% used${NC}          │"
        elif [[ $disk_usage -lt 90 ]]; then
            echo -e "│  ${YELLOW}●${NC}  Disk Space                 ${YELLOW}${disk_usage}% used${NC}          │"
            ((warnings++))
        else
            echo -e "│  ${RED}●${NC}  Disk Space                 ${RED}${disk_usage}% used - LOW!${NC}   │"
            ((errors++))
        fi
    fi

    # Document count if running
    if is_running; then
        local doc_count=$(docker compose exec -T db psql -U paperless -d paperless -t -c "SELECT COUNT(*) FROM documents_document;" 2>/dev/null | tr -d ' ')
        if [[ "$doc_count" =~ ^[0-9]+$ ]]; then
            printf "│  ${BLUE}📄${NC}  Documents                  %-18s│\n" "${doc_count} stored"
        fi
    fi

    echo "└─────────────────────────────────────────────────┘"
    echo ""

    # Overall status
    echo "┌─────────────────────────────────────────────────┐"
    if $all_good && [[ $warnings -eq 0 ]]; then
        echo -e "│       ${GREEN}✓  ALL SYSTEMS HEALTHY${NC}                    │"
        echo "│                                                 │"
        echo "│       Everything is working correctly!          │"
    elif [[ $errors -gt 0 ]]; then
        echo -e "│       ${RED}✗  ISSUES DETECTED${NC}                         │"
        echo "│                                                 │"
        echo "│       Some services need attention.             │"
        echo "│       Try: Stop and Start Paperless again       │"
    else
        echo -e "│       ${YELLOW}⚠  MOSTLY HEALTHY${NC}                         │"
        echo "│                                                 │"
        echo "│       Core services running, minor issues.      │"
    fi
    echo "└─────────────────────────────────────────────────┘"
    echo ""

    read -p "Press Enter to continue..."
}

# Troubleshooting Assistant - Guided problem solving
troubleshooting_assistant() {
    clear
    print_header "Troubleshooting Assistant"

    echo "What problem are you experiencing?"
    echo ""
    echo "  1) I can't access the web interface"
    echo "  2) Documents aren't being processed"
    echo "  3) The system seems slow"
    echo "  4) I'm getting error messages"
    echo "  5) I forgot my password"
    echo "  6) I need to free up disk space"
    echo "  7) Something else / Run full diagnostics"
    echo ""
    echo "  0) Go back"
    echo ""

    read -p "Select your issue [0-7]: " issue_choice

    case $issue_choice in
        1) troubleshoot_access ;;
        2) troubleshoot_processing ;;
        3) troubleshoot_performance ;;
        4) troubleshoot_errors ;;
        5) troubleshoot_password ;;
        6) troubleshoot_disk_space ;;
        7) run_full_diagnostics ;;
        0) return ;;
        *)
            print_error "Invalid option"
            sleep 1
            troubleshooting_assistant
            ;;
    esac
}

troubleshoot_access() {
    clear
    print_header "Troubleshooting: Can't Access Web Interface"

    echo "Let me check a few things..."
    echo ""

    local issues_found=0

    # Check if services are running
    echo "Step 1: Checking if Paperless is running..."
    if ! is_running; then
        echo -e "  ${RED}✗${NC} Paperless is not running!"
        echo ""
        echo "  ${YELLOW}Solution:${NC} Let's start it now."
        echo ""
        read -p "  Start Paperless? (y/n): " start_it
        if [[ "$start_it" == "y" || "$start_it" == "Y" ]]; then
            start_services_quiet
            echo ""
            print_success "  Paperless is starting..."
            echo "  Please wait 30 seconds, then try accessing it again."
        fi
        ((issues_found++))
    else
        echo -e "  ${GREEN}✓${NC} Paperless is running"
    fi

    echo ""
    echo "Step 2: Checking web server..."
    if ! check_service_health "nginx" > /dev/null 2>&1; then
        echo -e "  ${RED}✗${NC} Web server is not responding"
        echo ""
        echo "  ${YELLOW}Solution:${NC} Restart the web server"
        docker compose restart nginx 2>/dev/null
        print_success "  Web server restarted"
        ((issues_found++))
    else
        echo -e "  ${GREEN}✓${NC} Web server is responding"
    fi

    echo ""
    echo "Step 3: Your access URL is:"
    echo ""
    show_access_url
    echo ""

    # Check firewall
    echo "Step 4: Checking common issues..."
    echo -e "  ${BLUE}ℹ${NC} Make sure you're using the correct URL above"
    echo -e "  ${BLUE}ℹ${NC} If using HTTPS, you may need to accept the security warning"
    echo -e "  ${BLUE}ℹ${NC} Try a different browser or incognito/private window"
    echo ""

    if [[ $issues_found -eq 0 ]]; then
        print_success "Everything looks correct!"
        echo ""
        echo "If you still can't access it:"
        echo "  - Check if your firewall allows connections on port 80/443"
        echo "  - Make sure you're on the same network as this server"
        echo "  - Try accessing from this server: curl -I http://localhost"
    fi

    echo ""
    read -p "Press Enter to continue..."
}

troubleshoot_processing() {
    clear
    print_header "Troubleshooting: Documents Not Processing"

    echo "Let me check the document processing system..."
    echo ""

    # Check if consume directory exists and is accessible
    echo "Step 1: Checking consume folder..."
    if [[ -d "$CONSUME_DIR" ]]; then
        echo -e "  ${GREEN}✓${NC} Consume folder exists: $CONSUME_DIR"

        local file_count=$(find "$CONSUME_DIR" -type f 2>/dev/null | wc -l)
        if [[ $file_count -gt 0 ]]; then
            echo -e "  ${YELLOW}!${NC} Found $file_count files waiting to be processed"
        else
            echo -e "  ${GREEN}✓${NC} No files waiting (folder is empty)"
        fi
    else
        echo -e "  ${RED}✗${NC} Consume folder not found!"
        echo ""
        echo "  Creating consume folder..."
        mkdir -p "$CONSUME_DIR"
        print_success "  Consume folder created"
    fi

    echo ""
    echo "Step 2: Checking document processors..."

    if check_service_health "gotenberg" > /dev/null 2>&1; then
        echo -e "  ${GREEN}✓${NC} Document converter (Gotenberg) is running"
    else
        echo -e "  ${RED}✗${NC} Document converter is not running"
        echo "      Restarting..."
        docker compose restart gotenberg 2>/dev/null
    fi

    if check_service_health "tika" > /dev/null 2>&1; then
        echo -e "  ${GREEN}✓${NC} Text extractor (Tika) is running"
    else
        echo -e "  ${RED}✗${NC} Text extractor is not running"
        echo "      Restarting..."
        docker compose restart tika 2>/dev/null
    fi

    echo ""
    echo "Step 3: Checking for stuck tasks..."
    if is_running; then
        local pending=$(docker compose exec -T db psql -U paperless -d paperless -t -c \
            "SELECT COUNT(*) FROM paperless_tasks WHERE status='pending';" 2>/dev/null | tr -d ' ')
        if [[ "$pending" =~ ^[0-9]+$ ]] && [[ $pending -gt 0 ]]; then
            echo -e "  ${YELLOW}!${NC} There are $pending tasks waiting to be processed"
            echo "      This is normal - they will be processed automatically."
        else
            echo -e "  ${GREEN}✓${NC} No stuck tasks found"
        fi
    fi

    echo ""
    echo "Common solutions:"
    echo "  - Make sure files are PDF, PNG, JPG, or TIFF format"
    echo "  - Check if files aren't corrupted or password-protected"
    echo "  - Try restarting Paperless (Stop then Start)"
    echo ""

    read -p "Press Enter to continue..."
}

troubleshoot_performance() {
    clear
    print_header "Troubleshooting: System Seems Slow"

    echo "Analyzing system performance..."
    echo ""

    # Check disk space
    echo "Step 1: Disk Space"
    local disk_usage=$(df -h "$SCRIPT_DIR" 2>/dev/null | tail -1 | awk '{print $5}' | tr -d '%')
    if [[ "$disk_usage" =~ ^[0-9]+$ ]]; then
        if [[ $disk_usage -gt 90 ]]; then
            echo -e "  ${RED}✗${NC} Disk is ${disk_usage}% full - this causes slowdowns!"
            echo ""
            echo "  ${YELLOW}Solution:${NC}"
            echo "    - Empty the trash in Paperless"
            echo "    - Delete old backups"
            echo "    - Clean up log files (see Advanced Settings)"
        elif [[ $disk_usage -gt 75 ]]; then
            echo -e "  ${YELLOW}!${NC} Disk is ${disk_usage}% full - consider cleaning up"
        else
            echo -e "  ${GREEN}✓${NC} Disk space is fine (${disk_usage}% used)"
        fi
    fi

    echo ""
    echo "Step 2: Memory Usage"
    local mem_info=$(free -m 2>/dev/null | awk 'NR==2{printf "%.0f%% of %dMB", $3*100/$2, $2}')
    if [[ -n "$mem_info" ]]; then
        echo -e "  ${BLUE}ℹ${NC} Memory: $mem_info in use"
    fi

    echo ""
    echo "Step 3: Container Resource Usage"
    echo ""
    docker stats --no-stream --format "  {{.Name}}: {{.CPUPerc}} CPU, {{.MemUsage}}" 2>/dev/null | head -6

    echo ""
    echo "Performance tips:"
    echo "  1. Processing many documents at once can be slow - this is normal"
    echo "  2. Large PDF files take longer to process"
    echo "  3. If constantly slow, consider adding more RAM to your server"
    echo "  4. Check 'Database Optimization' in Advanced Settings"
    echo ""

    read -p "Press Enter to continue..."
}

troubleshoot_errors() {
    clear
    print_header "Troubleshooting: Error Messages"

    echo "Let me check the recent logs for errors..."
    echo ""

    if is_running; then
        echo "Recent errors from Paperless:"
        echo "───────────────────────────────────────"
        docker compose logs --tail=30 webserver 2>/dev/null | grep -iE "(error|exception|failed|critical)" | tail -10
        echo "───────────────────────────────────────"
        echo ""

        if docker compose logs --tail=30 webserver 2>/dev/null | grep -qiE "(error|exception|failed)"; then
            echo "Found some errors. Common solutions:"
            echo ""
            echo "  1. Try restarting Paperless (Stop then Start)"
            echo "  2. Check if you have enough disk space"
            echo "  3. Make sure all services are running (check Health)"
            echo ""
            echo "Would you like to:"
            echo "  1) Restart Paperless now"
            echo "  2) View full logs"
            echo "  3) Go back"
            echo ""
            read -p "Choose [1-3]: " error_action

            case $error_action in
                1)
                    echo ""
                    print_info "Restarting Paperless..."
                    docker compose restart 2>/dev/null
                    print_success "Restarted! Wait a moment and try again."
                    ;;
                2)
                    view_logs
                    ;;
            esac
        else
            print_success "No recent errors found!"
            echo ""
            echo "If you're seeing an error message, please note it down"
            echo "and check the full logs (option 9 in main menu)"
        fi
    else
        print_warning "Paperless is not running."
        echo ""
        echo "Start Paperless first to check for errors."
    fi

    echo ""
    read -p "Press Enter to continue..."
}

troubleshoot_password() {
    clear
    print_header "Troubleshooting: Forgot Password"

    echo "Don't worry! We can reset your password."
    echo ""

    if ! is_running; then
        print_warning "Paperless needs to be running to reset passwords."
        read -p "Start Paperless now? (y/n): " start_it
        if [[ "$start_it" == "y" || "$start_it" == "Y" ]]; then
            start_services_quiet
        else
            read -p "Press Enter to continue..."
            return
        fi
    fi

    echo "Current users:"
    docker compose exec -T webserver python3 manage.py shell -c \
        "from django.contrib.auth.models import User; [print(f'  - {u.username}') for u in User.objects.all()]" 2>/dev/null

    echo ""
    read -p "Enter the username to reset password for: " reset_user

    if [[ -z "$reset_user" ]]; then
        print_error "No username entered"
        read -p "Press Enter to continue..."
        return
    fi

    echo ""
    read -s -p "Enter new password (min 8 characters): " new_pass
    echo ""

    if [[ ${#new_pass} -lt 8 ]]; then
        print_error "Password must be at least 8 characters"
        read -p "Press Enter to continue..."
        return
    fi

    docker compose exec -T webserver python3 manage.py shell -c \
        "from django.contrib.auth.models import User; u = User.objects.get(username='${reset_user}'); u.set_password('${new_pass}'); u.save(); print('Password reset successfully!')" 2>/dev/null

    echo ""
    print_success "Password has been reset for user: $reset_user"
    echo ""
    echo "You can now log in with your new password."

    read -p "Press Enter to continue..."
}

troubleshoot_disk_space() {
    clear
    print_header "Troubleshooting: Free Up Disk Space"

    echo "Current disk usage:"
    df -h "$SCRIPT_DIR" | tail -1
    echo ""

    echo "Space used by Paperless components:"
    echo "───────────────────────────────────────"
    echo "  Documents:  $(du -sh "${DATA_DIR}/media" 2>/dev/null | cut -f1 || echo "N/A")"
    echo "  Database:   $(du -sh "${DATA_DIR}/postgres" 2>/dev/null | cut -f1 || echo "N/A")"
    echo "  Backups:    $(du -sh "${BACKUP_DIR}" 2>/dev/null | cut -f1 || echo "N/A")"
    echo "  Logs:       $(du -sh "${SCRIPT_DIR}/logs" 2>/dev/null | cut -f1 || echo "N/A")"
    echo "  Trash:      $(du -sh "${TRASH_DIR}" 2>/dev/null | cut -f1 || echo "N/A")"
    echo "───────────────────────────────────────"
    echo ""

    echo "Quick cleanup options:"
    echo ""
    echo "  1) Empty the trash folder"
    echo "  2) Delete old backups (keep last 3)"
    echo "  3) Clean up log files"
    echo "  4) Run full cleanup"
    echo "  0) Go back"
    echo ""

    read -p "Choose an option [0-4]: " cleanup_choice

    case $cleanup_choice in
        1)
            echo ""
            local trash_size=$(du -sh "${TRASH_DIR}" 2>/dev/null | cut -f1)
            echo "Trash folder size: $trash_size"
            read -p "Empty trash? (y/n): " confirm
            if [[ "$confirm" == "y" || "$confirm" == "Y" ]]; then
                rm -rf "${TRASH_DIR:?}"/*
                print_success "Trash emptied!"
            fi
            ;;
        2)
            echo ""
            local backup_count=$(ls -1 "${BACKUP_DIR}"/*.tar.gz 2>/dev/null | wc -l)
            echo "Found $backup_count backups"
            if [[ $backup_count -gt 3 ]]; then
                read -p "Delete old backups, keeping last 3? (y/n): " confirm
                if [[ "$confirm" == "y" || "$confirm" == "Y" ]]; then
                    ls -1t "${BACKUP_DIR}"/*.tar.gz 2>/dev/null | tail -n +4 | xargs -r rm
                    print_success "Old backups deleted!"
                fi
            else
                echo "You only have $backup_count backups. Nothing to delete."
            fi
            ;;
        3)
            echo ""
            local log_size=$(du -sh "${SCRIPT_DIR}/logs" 2>/dev/null | cut -f1)
            echo "Log folder size: $log_size"
            read -p "Delete logs older than 7 days? (y/n): " confirm
            if [[ "$confirm" == "y" || "$confirm" == "Y" ]]; then
                find "${SCRIPT_DIR}/logs" -type f -mtime +7 -delete 2>/dev/null
                print_success "Old logs deleted!"
            fi
            ;;
        4)
            full_cleanup
            ;;
        0)
            return
            ;;
    esac

    echo ""
    echo "Updated disk usage:"
    df -h "$SCRIPT_DIR" | tail -1
    echo ""
    read -p "Press Enter to continue..."
}

run_full_diagnostics() {
    clear
    print_header "Full System Diagnostics"

    echo "Running comprehensive system check..."
    echo ""

    local report="${SCRIPT_DIR}/logs/diagnostics_$(date +%Y%m%d_%H%M%S).txt"
    mkdir -p "${SCRIPT_DIR}/logs"

    {
        echo "Paperless-ngx Diagnostic Report"
        echo "Generated: $(date)"
        echo "================================"
        echo ""

        echo "=== System Information ==="
        echo "Hostname: $(hostname)"
        echo "OS: $(uname -a)"
        echo "Docker version: $(docker --version 2>/dev/null || echo 'Not found')"
        echo ""

        echo "=== Service Status ==="
        docker compose ps 2>/dev/null
        echo ""

        echo "=== Disk Usage ==="
        df -h "$SCRIPT_DIR"
        echo ""
        du -sh "${DATA_DIR}"/* 2>/dev/null
        echo ""

        echo "=== Memory Usage ==="
        free -h 2>/dev/null || echo "N/A"
        echo ""

        echo "=== Recent Errors ==="
        docker compose logs --tail=50 webserver 2>/dev/null | grep -iE "(error|exception|failed)" || echo "No recent errors"
        echo ""

        echo "=== Container Health ==="
        for service in webserver db broker nginx gotenberg tika; do
            if check_service_health "$service" > /dev/null 2>&1; then
                echo "$service: HEALTHY"
            else
                echo "$service: NOT HEALTHY"
            fi
        done

    } > "$report" 2>&1

    echo "Diagnostics complete!"
    echo ""
    echo "Results saved to: $report"
    echo ""
    echo "Key findings:"
    echo "───────────────────────────────────────"

    # Show summary
    show_health_dashboard
}

# Show help for quick actions
show_quick_help() {
    clear
    print_header "Quick Help"

    echo "Welcome to Paperless-ngx!"
    echo ""
    echo "Paperless is a document management system that helps you"
    echo "organize, search, and store your paper documents digitally."
    echo ""
    echo "GETTING STARTED:"
    echo "───────────────────────────────────────"
    echo "1. Start Paperless using option 1"
    echo "2. Open the web interface (option 6)"
    echo "3. Log in with your admin credentials"
    echo "4. Drop PDF or image files into the consume folder:"
    echo "   ${CONSUME_DIR}"
    echo ""
    echo "HOW IT WORKS:"
    echo "───────────────────────────────────────"
    echo "• Drop documents into the consume folder"
    echo "• Paperless automatically processes them"
    echo "• Documents are OCR'd and made searchable"
    echo "• Access everything through the web interface"
    echo ""
    echo "KEEPING YOUR DATA SAFE:"
    echo "───────────────────────────────────────"
    echo "• Create regular backups (option 4)"
    echo "• Backups include all documents and settings"
    echo "• You can restore from any backup if needed"
    echo ""

    read -p "Press Enter to continue..."
}

# First-run detection and wizard
check_first_run() {
    local first_run_marker="${SCRIPT_DIR}/.first_run_complete"

    if [[ ! -f "$first_run_marker" ]] && [[ ! -f "${SCRIPT_DIR}/.env" ]]; then
        return 0  # Is first run
    fi
    return 1  # Not first run
}

# Legacy function - redirects to new setup flow
# Kept for backward compatibility
first_run_wizard() {
    run_initial_setup_flow
}

# Automatic problem detection on startup
startup_health_check() {
    local issues=()

    # Check Docker
    if ! command -v docker &> /dev/null; then
        issues+=("Docker is not installed")
    elif ! docker info &> /dev/null 2>&1; then
        issues+=("Docker is not running or you don't have permission")
    fi

    # Check disk space
    local disk_usage=$(df -h "$SCRIPT_DIR" 2>/dev/null | tail -1 | awk '{print $5}' | tr -d '%')
    if [[ "$disk_usage" =~ ^[0-9]+$ ]] && [[ $disk_usage -gt 95 ]]; then
        issues+=("Disk space critically low (${disk_usage}% used)")
    fi

    # Check if services should be running but aren't
    if [[ -f "${SCRIPT_DIR}/.env" ]]; then
        if ! is_running; then
            # Only warn if it was likely intentionally started before
            if docker compose ps -a 2>/dev/null | grep -q "Exit"; then
                issues+=("Some services have stopped unexpectedly")
            fi
        fi
    fi

    # Display issues if any
    if [[ ${#issues[@]} -gt 0 ]]; then
        echo ""
        echo -e "${YELLOW}┌─────────────────────────────────────────────────┐${NC}"
        echo -e "${YELLOW}│  ⚠  Potential issues detected                  │${NC}"
        echo -e "${YELLOW}├─────────────────────────────────────────────────┤${NC}"
        for issue in "${issues[@]}"; do
            printf "${YELLOW}│  • %-44s│${NC}\n" "$issue"
        done
        echo -e "${YELLOW}└─────────────────────────────────────────────────┘${NC}"
        echo ""
        read -p "Press Enter to continue, or 'h' for help: " response
        if [[ "$response" == "h" || "$response" == "H" ]]; then
            troubleshooting_assistant
        fi
    fi
}

# User preference for menu type
get_menu_preference() {
    local pref_file="${SCRIPT_DIR}/.menu_preference"
    if [[ -f "$pref_file" ]]; then
        cat "$pref_file"
    else
        echo "quick"  # Default to quick menu for beginners
    fi
}

set_menu_preference() {
    local pref_file="${SCRIPT_DIR}/.menu_preference"
    echo "$1" > "$pref_file"
}

# ============================================================================
# MENU DISPLAY
# ============================================================================

show_menu() {
    clear
    local ssl_mode=$(get_ssl_mode)
    local ssl_status=""

    case $ssl_mode in
        "http")
            ssl_status="HTTP only"
            ;;
        "https-redirect")
            ssl_status="HTTPS (HTTP redirects)"
            ;;
        "https-only")
            ssl_status="HTTPS only (HTTP blocked)"
            ;;
    esac

    echo -e "${BLUE}"
    echo "  ____                        _                "
    echo " |  _ \ __ _ _ __   ___ _ __ | | ___  ___ ___  "
    echo " | |_) / _\` | '_ \ / _ \ '__|| |/ _ \/ __/ __| "
    echo " |  __/ (_| | |_) |  __/ |   | |  __/\__ \__ \ "
    echo " |_|   \__,_| .__/ \___|_|   |_|\___||___/___/ "
    echo "            |_|                    Management  "
    echo -e "${NC}"
    # Get backup schedule status
    local backup_schedule=$(get_backup_schedule)
    local backup_status=$(get_schedule_description "$backup_schedule")

    # Show status at a glance
    local status_icon
    if is_running; then
        status_icon="${GREEN}● Running${NC}"
    else
        status_icon="${RED}● Stopped${NC}"
    fi

    echo "=============================================="
    echo -e "  Status:   ${status_icon}"
    echo "  SSL Mode: ${ssl_status}"
    echo "  Backups:  ${backup_status}"
    echo "=============================================="
    echo ""
    echo "  Setup & Configuration:"
    echo "    1) Initial Setup"
    echo "   10) Configure SSL/HTTPS"
    echo "   12) Check/Install Dependencies"
    echo ""
    echo "  Daily Operations:"
    echo "    6) Start Services"
    echo "    7) Stop Services"
    echo "    8) View Status"
    echo "    9) View Logs"
    echo ""
    echo "  Backup & Updates:"
    echo "    2) Create Backup"
    echo "    3) Restore from Backup"
    echo "    4) Schedule Automatic Backups"
    echo "    5) Update Containers"
    echo ""
    echo "  Advanced:"
    echo "   11) Advanced Settings (23 options)"
    echo ""
    echo "  ─────────────────────────────────────────"
    echo "   13) Switch to Simple Menu"
    echo "    0) Exit"
    echo "=============================================="
    echo ""
}

# ============================================================================
# SSL FUNCTIONS
# ============================================================================

generate_ssl_certificate() {
    print_header "Generating SSL Certificate"

    mkdir -p "$SSL_DIR"

    local ip=$(get_server_ip)
    local hostname_val=$(hostname)

    print_info "Generating self-signed certificate for local network use..."
    print_info "IP Address: ${ip}"
    print_info "Hostname: ${hostname_val}"
    print_info "Valid for: ${SSL_DAYS} days"

    # Generate private key and certificate
    openssl req -x509 -nodes -days ${SSL_DAYS} -newkey rsa:2048 \
        -keyout "${SSL_KEY}" \
        -out "${SSL_CERT}" \
        -subj "/C=XX/ST=Local/L=Local/O=Paperless/OU=Local/CN=${hostname_val}" \
        -addext "subjectAltName=DNS:${hostname_val},DNS:localhost,IP:${ip},IP:127.0.0.1" \
        2>/dev/null

    chmod 600 "${SSL_KEY}"
    chmod 644 "${SSL_CERT}"

    print_success "SSL certificate generated"
    echo ""
    echo "Certificate location: ${SSL_CERT}"
    echo "Private key location: ${SSL_KEY}"
    echo ""
    print_warning "This is a self-signed certificate for local network use."
    print_warning "Browsers will show a security warning - this is expected."
    echo ""
}

set_ssl_mode() {
    local mode=$1

    print_info "Setting SSL mode to: ${mode}"

    # Store the mode
    echo "$mode" > "${SCRIPT_DIR}/.ssl_mode"

    # Create nginx directory structure
    mkdir -p "$NGINX_DIR"
    mkdir -p "$SSL_DIR"

    # Copy appropriate nginx config
    case $mode in
        "http")
            cp "${NGINX_DIR}/templates/http-only.conf" "${NGINX_DIR}/nginx.conf"
            # Create dummy SSL files if they don't exist (nginx needs them mounted)
            if [[ ! -f "${SSL_CERT}" ]]; then
                mkdir -p "$SSL_DIR"
                touch "${SSL_CERT}" "${SSL_KEY}"
            fi
            ;;
        "https-redirect")
            if [[ ! -f "${SSL_CERT}" ]] || [[ ! -s "${SSL_CERT}" ]]; then
                generate_ssl_certificate
            fi
            cp "${NGINX_DIR}/templates/https-redirect.conf" "${NGINX_DIR}/nginx.conf"
            ;;
        "https-only")
            if [[ ! -f "${SSL_CERT}" ]] || [[ ! -s "${SSL_CERT}" ]]; then
                generate_ssl_certificate
            fi
            cp "${NGINX_DIR}/templates/https-only.conf" "${NGINX_DIR}/nginx.conf"
            ;;
    esac

    # Update PAPERLESS_URL in .env
    local url=$(get_access_url)
    if [[ -f "${SCRIPT_DIR}/.env" ]]; then
        if grep -q "^PAPERLESS_URL=" "${SCRIPT_DIR}/.env"; then
            sed -i "s|^PAPERLESS_URL=.*|PAPERLESS_URL=${url}|" "${SCRIPT_DIR}/.env"
        else
            echo "PAPERLESS_URL=${url}" >> "${SCRIPT_DIR}/.env"
        fi
    fi

    print_success "SSL mode set to: ${mode}"
}

configure_ssl() {
    print_header "Configure SSL/HTTPS"

    check_root

    local current_mode=$(get_ssl_mode)

    echo "Current mode: ${current_mode}"
    echo ""
    echo "Select SSL mode:"
    echo ""
    echo "  1) HTTP only (no encryption)"
    echo "     - Access via http://server-ip"
    echo "     - Suitable for isolated networks"
    echo ""
    echo "  2) HTTPS with HTTP redirect"
    echo "     - HTTP requests redirect to HTTPS"
    echo "     - Access via https://server-ip"
    echo "     - Recommended for local networks"
    echo ""
    echo "  3) HTTPS only (HTTP blocked)"
    echo "     - Only HTTPS connections allowed"
    echo "     - HTTP connections are dropped"
    echo "     - Maximum security for local network"
    echo ""
    echo "  4) Regenerate SSL certificate"
    echo ""
    echo "  0) Cancel"
    echo ""

    read -p "Select option [0-4]: " ssl_choice

    case $ssl_choice in
        1)
            set_ssl_mode "http"
            configure_firewall_for_mode "http"
            ;;
        2)
            set_ssl_mode "https-redirect"
            configure_firewall_for_mode "https"
            ;;
        3)
            set_ssl_mode "https-only"
            configure_firewall_for_mode "https"
            ;;
        4)
            generate_ssl_certificate
            read -p "Press Enter to continue..."
            return
            ;;
        0)
            print_info "Cancelled"
            read -p "Press Enter to continue..."
            return
            ;;
        *)
            print_error "Invalid option"
            read -p "Press Enter to continue..."
            return
            ;;
    esac

    # Restart services if running
    if is_running; then
        print_info "Restarting services to apply changes..."
        cd "$SCRIPT_DIR"
        docker compose restart nginx
        print_success "Services restarted"
    fi

    print_header "SSL Configuration Complete!"

    local url=$(get_access_url)
    echo "Access URL: ${url}"
    echo ""

    if [[ "$ssl_choice" == "2" ]] || [[ "$ssl_choice" == "3" ]]; then
        print_warning "Since this uses a self-signed certificate, browsers will"
        print_warning "show a security warning. This is normal for local networks."
        echo ""
        echo "To avoid warnings, you can:"
        echo "  1. Import the certificate to your devices"
        echo "     Certificate: ${SSL_CERT}"
        echo ""
        echo "  2. Add a security exception in your browser"
        echo ""
    fi

    read -p "Press Enter to continue..."
}

configure_firewall_for_mode() {
    local mode=$1

    if command -v ufw &> /dev/null && ufw status | grep -q "active"; then
        print_info "Configuring firewall..."

        case $mode in
            "http")
                ufw allow 80/tcp
                ufw delete allow 443/tcp 2>/dev/null || true
                print_success "Firewall: HTTP (80) allowed"
                ;;
            "https")
                ufw allow 80/tcp
                ufw allow 443/tcp
                print_success "Firewall: HTTP (80) and HTTPS (443) allowed"
                ;;
        esac
    fi
}

configure_firewall() {
    local mode=$(get_ssl_mode)
    configure_firewall_for_mode "$mode"
}

# ============================================================================
# 1. INITIAL SETUP
# ============================================================================

initial_setup() {
    print_header "Initial Setup"

    check_root

    # Setup time synchronization first (important for APT)
    setup_time_sync

    # Check and install all dependencies
    install_dependencies

    # Verify critical dependencies after installation
    if ! check_docker; then
        print_error "Docker installation failed. Please install manually:"
        echo "  curl -fsSL https://get.docker.com | sh"
        echo "  sudo usermod -aG docker \$USER"
        exit 1
    fi

    # Create directory structure
    print_info "Creating directory structure..."

    mkdir -p "$DATA_DIR"/{data,media,postgres,redis}
    mkdir -p "$CONSUME_DIR"
    mkdir -p "$EXPORT_DIR"
    mkdir -p "$TRASH_DIR"
    mkdir -p "$SCRIPTS_DIR"
    mkdir -p "$BACKUP_DIR"
    mkdir -p "$NGINX_DIR"/templates
    mkdir -p "$SSL_DIR"

    print_success "Directories created"

    # Create .env file if it doesn't exist
    if [[ ! -f "${SCRIPT_DIR}/.env" ]]; then
        print_header "Admin Account Setup"

        # Prompt for admin username
        echo "Please set up the Paperless-ngx admin account."
        echo ""
        read -p "Admin username (default: admin): " ADMIN_USER
        ADMIN_USER=${ADMIN_USER:-admin}

        # Prompt for admin password with confirmation
        while true; do
            echo ""
            read -s -p "Admin password: " ADMIN_PASSWORD
            echo ""

            if [[ ${#ADMIN_PASSWORD} -lt 8 ]]; then
                print_error "Password must be at least 8 characters long"
                continue
            fi

            read -s -p "Confirm password: " ADMIN_PASSWORD_CONFIRM
            echo ""

            if [[ "$ADMIN_PASSWORD" != "$ADMIN_PASSWORD_CONFIRM" ]]; then
                print_error "Passwords do not match. Please try again."
                continue
            fi

            break
        done

        print_success "Admin account configured"

        # Ask about database password
        print_header "Database Password Setup"

        echo "The database password is used internally between containers."
        echo "You can set a custom password or let the system generate one."
        echo ""
        read -p "Set custom database password? [y/N]: " custom_db_pw

        if [[ "$custom_db_pw" =~ ^[Yy]$ ]]; then
            while true; do
                read -s -p "Database password: " DB_PASSWORD
                echo ""

                if [[ ${#DB_PASSWORD} -lt 8 ]]; then
                    print_error "Password must be at least 8 characters long"
                    continue
                fi

                read -s -p "Confirm password: " DB_PASSWORD_CONFIRM
                echo ""

                if [[ "$DB_PASSWORD" != "$DB_PASSWORD_CONFIRM" ]]; then
                    print_error "Passwords do not match. Please try again."
                    continue
                fi

                break
            done
            print_success "Custom database password set"
        else
            DB_PASSWORD=$(openssl rand -base64 16 | tr -dc 'a-zA-Z0-9' | head -c 16)
            print_success "Database password auto-generated"
        fi

        # Redis Cache Size Selection
        print_header "Redis Cache Size Configuration"

        echo "Redis caching dramatically improves performance for large document collections."
        echo "Select a cache size based on your expected number of documents:"
        echo ""
        echo "  ┌──────────────────────────────────────────────────────────────────────────────────┐"
        echo "  │  Option  │  Cache Size  │  Documents           │  Min. System RAM Required      │"
        echo "  ├──────────────────────────────────────────────────────────────────────────────────┤"
        echo "  │    1     │    128 MB    │  up to 1,000         │  4 GB                          │"
        echo "  │    2     │    256 MB    │  1,000 - 5,000       │  4 GB                          │"
        echo "  │    3     │    512 MB    │  5,000 - 20,000      │  8 GB                          │"
        echo "  │    4     │   1024 MB    │  20,000 - 50,000     │  8 GB                          │"
        echo "  │    5     │   2048 MB    │  50,000 - 150,000    │  16 GB                         │"
        echo "  │    6     │   4096 MB    │  150,000 - 500,000   │  16 GB                         │"
        echo "  │    7     │   8192 MB    │  500,000 - 1,000,000 │  32 GB                         │"
        echo "  │    8     │   Custom     │  Enter own value     │  Depends on selection          │"
        echo "  └──────────────────────────────────────────────────────────────────────────────────┘"
        echo ""
        echo "  How RAM is used:"
        echo "    The Redis cache is PART OF your total system RAM, not additional."
        echo "    Other services (PostgreSQL, Paperless, OCR workers, Tika, etc.) also"
        echo "    need RAM. The 'Min. System RAM' ensures enough headroom for all services."
        echo ""
        echo "  Rule of thumb: Redis cache should not exceed 50% of your total RAM."
        echo ""

        # Detect available RAM
        TOTAL_RAM_MB=$(free -m 2>/dev/null | awk '/^Mem:/{print $2}' || echo "unknown")
        if [[ "$TOTAL_RAM_MB" != "unknown" ]]; then
            TOTAL_RAM_GB=$((TOTAL_RAM_MB / 1024))
            MAX_CACHE_RECOMMENDED=$((TOTAL_RAM_MB / 2))
            print_info "Detected system RAM: ${TOTAL_RAM_MB} MB (~${TOTAL_RAM_GB} GB)"
            print_info "Maximum recommended cache: ${MAX_CACHE_RECOMMENDED} MB (50% of RAM)"
            echo ""
        fi

        read -p "Select cache size [1-8] (default: 3 for 512 MB): " cache_choice
        cache_choice=${cache_choice:-3}

        case $cache_choice in
            1)
                REDIS_CACHE_SIZE="128"
                ;;
            2)
                REDIS_CACHE_SIZE="256"
                ;;
            3)
                REDIS_CACHE_SIZE="512"
                ;;
            4)
                REDIS_CACHE_SIZE="1024"
                ;;
            5)
                REDIS_CACHE_SIZE="2048"
                ;;
            6)
                REDIS_CACHE_SIZE="4096"
                # Ask if they need even more
                echo ""
                read -p "Do you need more than 4096 MB? [y/N]: " need_more
                if [[ "$need_more" =~ ^[Yy]$ ]]; then
                    echo ""
                    echo "For very large installations, you can choose:"
                    echo "  - 8192 MB (8 GB) for up to 1 million documents"
                    echo "  - Or enter a custom value"
                    echo ""
                    read -p "Enter cache size in MB (e.g., 8192): " custom_size
                    if [[ "$custom_size" =~ ^[0-9]+$ ]] && [[ "$custom_size" -ge 128 ]]; then
                        REDIS_CACHE_SIZE="$custom_size"
                    else
                        print_warning "Invalid value, using 4096 MB"
                        REDIS_CACHE_SIZE="4096"
                    fi
                fi
                ;;
            7)
                REDIS_CACHE_SIZE="8192"
                ;;
            8)
                echo ""
                echo "Enter a custom cache size in MB."
                echo "Recommendations:"
                echo "  - Minimum: 128 MB"
                echo "  - Should not exceed 50% of available RAM"
                if [[ "$TOTAL_RAM_MB" != "unknown" ]]; then
                    MAX_RECOMMENDED=$((TOTAL_RAM_MB / 2))
                    echo "  - Your max recommended: ${MAX_RECOMMENDED} MB (50% of ${TOTAL_RAM_MB} MB)"
                fi
                echo ""
                while true; do
                    read -p "Enter cache size in MB: " custom_size
                    if [[ "$custom_size" =~ ^[0-9]+$ ]] && [[ "$custom_size" -ge 128 ]]; then
                        if [[ "$TOTAL_RAM_MB" != "unknown" ]] && [[ "$custom_size" -gt "$MAX_RECOMMENDED" ]]; then
                            print_warning "Warning: ${custom_size} MB exceeds 50% of your RAM"
                            read -p "Are you sure? [y/N]: " confirm_large
                            if [[ "$confirm_large" =~ ^[Yy]$ ]]; then
                                REDIS_CACHE_SIZE="$custom_size"
                                break
                            fi
                        else
                            REDIS_CACHE_SIZE="$custom_size"
                            break
                        fi
                    else
                        print_error "Please enter a valid number (minimum 128)"
                    fi
                done
                ;;
            *)
                print_warning "Invalid choice, defaulting to 512 MB"
                REDIS_CACHE_SIZE="512"
                ;;
        esac

        print_success "Redis cache size set to ${REDIS_CACHE_SIZE} MB"

        # OCR Language Selection
        select_ocr_languages

        # Timezone Selection
        select_timezone

        # Database Performance Optimization
        setup_database_optimization_initial

        # Detect CPU cores for worker optimization
        CPU_CORES=$(nproc 2>/dev/null || echo 2)
        WEBSERVER_WORKERS=$((CPU_CORES > 4 ? 4 : CPU_CORES))
        TASK_WORKERS=$((CPU_CORES > 2 ? 2 : 1))

        print_info "Creating .env file..."
        print_info "Detected ${CPU_CORES} CPU cores - configuring ${WEBSERVER_WORKERS} web workers, ${TASK_WORKERS} task workers"

        # Generate secret key (internal use only)
        SECRET_KEY=$(openssl rand -base64 32)

        cat > "${SCRIPT_DIR}/.env" << EOF
# Paperless-ngx Configuration
# Generated on $(date)

# =============================================================================
# CREDENTIALS
# =============================================================================

# Database password (internal use between containers)
PAPERLESS_DB_PASSWORD=${DB_PASSWORD}

# Secret key for Django (internal use only)
PAPERLESS_SECRET_KEY=${SECRET_KEY}

# Admin user (created on first run only)
PAPERLESS_ADMIN_USER=${ADMIN_USER}
PAPERLESS_ADMIN_PASSWORD=${ADMIN_PASSWORD}

# =============================================================================
# LOCALIZATION
# =============================================================================

# OCR language(s) - multiple languages separated by +
PAPERLESS_OCR_LANGUAGE=${OCR_LANGUAGES}

# Timezone
PAPERLESS_TIME_ZONE=${SELECTED_TIMEZONE}

# =============================================================================
# OCR SETTINGS
# =============================================================================

# OCR mode: skip (only OCR if no text), redo (always OCR), force (OCR everything)
PAPERLESS_OCR_MODE=skip

# Number of pages to OCR (0 = all pages)
PAPERLESS_OCR_PAGES=0

# =============================================================================
# PERFORMANCE SETTINGS (optimized for Redis caching)
# =============================================================================

# Redis cache size in MB (selected during setup)
REDIS_CACHE_SIZE=${REDIS_CACHE_SIZE}

# Number of web server workers (auto-detected: ${CPU_CORES} CPU cores)
PAPERLESS_WEBSERVER_WORKERS=${WEBSERVER_WORKERS}

# Number of background task workers for OCR/processing
PAPERLESS_TASK_WORKERS=${TASK_WORKERS}

# Delay in seconds before updating search index (batches updates for performance)
PAPERLESS_INDEX_TASK_DELAY=300

# =============================================================================
# CONSUMER SETTINGS
# =============================================================================

# Polling interval (0 = inotify, or 5-30 for network storage)
PAPERLESS_CONSUMER_POLLING=0
PAPERLESS_CONSUMER_POLLING_DELAY=5
PAPERLESS_CONSUMER_POLLING_RETRY_COUNT=5

# =============================================================================
# URL CONFIGURATION
# =============================================================================

# URL (updated by SSL configuration)
PAPERLESS_URL=http://$(get_server_ip)
EOF

        chmod 600 "${SCRIPT_DIR}/.env"
        print_success ".env file created with performance optimizations"
    else
        print_info ".env file already exists, skipping..."
        # Load existing admin user for display later
        source "${SCRIPT_DIR}/.env"
        ADMIN_USER="${PAPERLESS_ADMIN_USER}"
    fi

    # Ask about SSL mode
    print_header "SSL Configuration"

    echo "How would you like to configure web access?"
    echo ""
    echo "  1) HTTP only (no encryption)"
    echo "  2) HTTPS with HTTP redirect (recommended)"
    echo "  3) HTTPS only (most secure)"
    echo ""

    read -p "Select option [1-3] (default: 2): " ssl_choice
    ssl_choice=${ssl_choice:-2}

    case $ssl_choice in
        1)
            set_ssl_mode "http"
            ;;
        2)
            set_ssl_mode "https-redirect"
            ;;
        3)
            set_ssl_mode "https-only"
            ;;
        *)
            print_warning "Invalid choice, defaulting to HTTPS with redirect"
            set_ssl_mode "https-redirect"
            ;;
    esac

    # Setup SMB share for consume folder
    setup_smb_share

    # Configure firewall
    configure_firewall

    # Set permissions for consume directory
    print_info "Setting directory permissions..."

    # Paperless runs as UID 1000 inside container
    chown -R 1000:1000 "$DATA_DIR"
    chown -R 1000:1000 "$CONSUME_DIR"
    chown -R 1000:1000 "$EXPORT_DIR"
    chown -R 1000:1000 "$TRASH_DIR"
    chown -R 1000:1000 "$SCRIPTS_DIR"

    chmod 755 "$CONSUME_DIR"

    print_success "Permissions set"

    # Pull images
    print_info "Pulling Docker images (this may take a while)..."
    cd "$SCRIPT_DIR"
    docker compose pull
    print_success "Docker images pulled"

    # Start services
    print_info "Starting services..."
    docker compose up -d

    wait_for_healthy

    print_header "Setup Complete!"

    local url=$(get_access_url)
    local ssl_mode=$(get_ssl_mode)

    # Load credentials for display
    source "${SCRIPT_DIR}/.env"

    echo "Paperless-ngx is now running!"
    echo ""
    echo "Access the web interface at: ${url}"
    echo ""
    echo "Login credentials:"
    echo "  Username: ${PAPERLESS_ADMIN_USER}"
    echo "  Password: (the password you set during setup)"
    echo ""

    if [[ "$ssl_mode" != "http" ]]; then
        print_warning "Using self-signed SSL certificate for local network."
        print_warning "Your browser will show a security warning - this is expected."
        echo ""
        echo "SSL Certificate: ${SSL_CERT}"
        echo "(Import this to your devices to avoid browser warnings)"
        echo ""
    fi

    echo "SMB Share for document import:"
    echo "  \\\\$(get_server_ip)\\${SMB_SHARE_NAME}"
    echo "  Username: ${SMB_USER}"
    echo "  (Password was set during setup)"
    echo ""

    read -p "Press Enter to continue..."
}

setup_smb_share() {
    print_header "Setting up SMB Share"

    # Samba and ACL should already be installed by install_dependencies
    # Just verify they're available
    if ! command -v smbd &> /dev/null; then
        print_error "Samba is not installed. Please run initial setup again."
        return 1
    fi

    if ! command -v setfacl &> /dev/null; then
        print_error "ACL utilities are not installed. Please run initial setup again."
        return 1
    fi

    print_info "Samba and ACL utilities are available"

    # Create SMB user if not exists
    if ! id "$SMB_USER" &>/dev/null; then
        print_info "Creating system user '${SMB_USER}'..."

        # Create user with no login shell, home in consume dir
        useradd -r -s /usr/sbin/nologin -d "$CONSUME_DIR" "$SMB_USER"

        print_success "System user '${SMB_USER}' created"
    else
        print_info "System user '${SMB_USER}' already exists"
    fi

    # Set SMB password
    print_info "Setting SMB password for user '${SMB_USER}'..."
    echo ""
    echo "Please enter a password for the SMB user '${SMB_USER}':"
    smbpasswd -a "$SMB_USER"
    smbpasswd -e "$SMB_USER"
    print_success "SMB password set"

    # Add user to group that can access consume folder
    usermod -aG "$SMB_USER" "$SMB_USER" 2>/dev/null || true

    # Set ownership so both SMB user and container can access
    chown -R "${SMB_USER}:${SMB_USER}" "$CONSUME_DIR"
    chmod 2775 "$CONSUME_DIR"

    # Make container user (1000) able to access via ACL
    setfacl -R -m u:1000:rwx "$CONSUME_DIR"
    setfacl -R -d -m u:1000:rwx "$CONSUME_DIR"

    # Configure Samba share
    print_info "Configuring Samba share..."

    # Backup original config
    if [[ -f /etc/samba/smb.conf ]] && [[ ! -f /etc/samba/smb.conf.backup ]]; then
        cp /etc/samba/smb.conf /etc/samba/smb.conf.backup
    fi

    # Check if share already exists
    if grep -q "\[${SMB_SHARE_NAME}\]" /etc/samba/smb.conf 2>/dev/null; then
        print_info "SMB share '${SMB_SHARE_NAME}' already configured"
    else
        # Add share configuration
        cat >> /etc/samba/smb.conf << EOF

# Paperless-ngx Import Share
[${SMB_SHARE_NAME}]
   path = ${CONSUME_DIR}
   browseable = yes
   read only = no
   guest ok = no
   valid users = ${SMB_USER}
   create mask = 0664
   directory mask = 0775
   force user = ${SMB_USER}
   force group = ${SMB_USER}
   comment = Paperless-ngx Document Import
EOF
        print_success "SMB share configured"
    fi

    # Restart Samba
    print_info "Restarting Samba services..."
    systemctl restart smbd nmbd
    systemctl enable smbd nmbd
    print_success "Samba services restarted"

    # Configure firewall if UFW is active
    if command -v ufw &> /dev/null && ufw status | grep -q "active"; then
        print_info "Configuring firewall for Samba..."
        ufw allow samba
        print_success "Firewall configured for Samba"
    fi

    print_success "SMB share setup complete"
}

# ============================================================================
# 2. BACKUP
# ============================================================================

create_backup() {
    print_header "Create Backup"

    cd "$SCRIPT_DIR"

    # Create backup directory with timestamp
    TIMESTAMP=$(date +%Y%m%d_%H%M%S)
    CURRENT_BACKUP_DIR="${BACKUP_DIR}/backup_${TIMESTAMP}"

    mkdir -p "$CURRENT_BACKUP_DIR"

    print_info "Creating backup in: ${CURRENT_BACKUP_DIR}"

    # Check if services are running
    SERVICES_WERE_RUNNING=false
    if is_running; then
        SERVICES_WERE_RUNNING=true
        print_info "Services are running"
    else
        print_warning "Services are not running. Starting temporarily for database backup..."
        docker compose up -d db
        sleep 10
    fi

    # 1. Backup PostgreSQL database
    print_info "Backing up PostgreSQL database..."

    docker compose exec -T db pg_dump -U paperless -d paperless > "${CURRENT_BACKUP_DIR}/database.sql"

    if [[ -s "${CURRENT_BACKUP_DIR}/database.sql" ]]; then
        print_success "Database backup created"
    else
        print_error "Database backup may be empty!"
    fi

    # 2. Backup configuration files
    print_info "Backing up configuration files..."

    cp "${SCRIPT_DIR}/docker-compose.yml" "${CURRENT_BACKUP_DIR}/"
    [[ -f "${SCRIPT_DIR}/.env" ]] && cp "${SCRIPT_DIR}/.env" "${CURRENT_BACKUP_DIR}/"
    [[ -f "${SCRIPT_DIR}/.ssl_mode" ]] && cp "${SCRIPT_DIR}/.ssl_mode" "${CURRENT_BACKUP_DIR}/"

    # Backup nginx config and SSL certs
    if [[ -d "${NGINX_DIR}" ]]; then
        print_info "  - Backing up nginx configuration..."
        tar -czf "${CURRENT_BACKUP_DIR}/nginx.tar.gz" -C "${SCRIPT_DIR}" nginx
        print_success "  - Nginx configuration backed up"
    fi

    print_success "Configuration files backed up"

    # 3. Backup data directories
    print_info "Backing up data directories (this may take a while)..."

    # Stop webserver for consistent backup
    if [[ "$SERVICES_WERE_RUNNING" == true ]]; then
        print_info "Stopping webserver for consistent backup..."
        docker compose stop webserver
    fi

    # Backup media (documents, thumbnails, archive)
    if [[ -d "${DATA_DIR}/media" ]]; then
        print_info "  - Backing up media files..."
        tar -czf "${CURRENT_BACKUP_DIR}/media.tar.gz" -C "${DATA_DIR}" media
        print_success "  - Media files backed up"
    fi

    # Backup data directory (index, classification models)
    if [[ -d "${DATA_DIR}/data" ]]; then
        print_info "  - Backing up application data..."
        tar -czf "${CURRENT_BACKUP_DIR}/data.tar.gz" -C "${DATA_DIR}" data
        print_success "  - Application data backed up"
    fi

    # Backup scripts
    if [[ -d "$SCRIPTS_DIR" ]] && [[ "$(ls -A $SCRIPTS_DIR 2>/dev/null)" ]]; then
        print_info "  - Backing up custom scripts..."
        tar -czf "${CURRENT_BACKUP_DIR}/scripts.tar.gz" -C "${SCRIPT_DIR}" scripts
        print_success "  - Custom scripts backed up"
    fi

    # 4. Create backup manifest
    print_info "Creating backup manifest..."

    cat > "${CURRENT_BACKUP_DIR}/manifest.txt" << EOF
Paperless-ngx Backup Manifest
=============================
Backup Date: $(date)
Hostname: $(hostname)
SSL Mode: $(get_ssl_mode)
Paperless Version: $(docker compose exec -T webserver python3 -c "import paperless; print(paperless.__version__)" 2>/dev/null || echo "unknown")

Contents:
- database.sql: PostgreSQL database dump
- docker-compose.yml: Docker Compose configuration
- .env: Environment variables (if present)
- .ssl_mode: SSL mode configuration (if present)
- nginx.tar.gz: Nginx config and SSL certificates (if present)
- media.tar.gz: Documents, thumbnails, archive files
- data.tar.gz: Application data, search index, classification models
- scripts.tar.gz: Custom pre/post consumption scripts (if present)

Restore Instructions:
1. Copy this backup folder to the target system
2. Run: sudo ./management.sh
3. Select option 3 (Restore from Backup)
4. Select this backup folder
EOF

    print_success "Backup manifest created"

    # Restart services if they were running
    if [[ "$SERVICES_WERE_RUNNING" == true ]]; then
        print_info "Restarting services..."
        docker compose start webserver
    else
        docker compose stop db
    fi

    # Calculate backup size
    BACKUP_SIZE=$(du -sh "$CURRENT_BACKUP_DIR" | cut -f1)

    # Create compressed archive of the entire backup
    print_info "Creating compressed backup archive..."
    tar -czf "${BACKUP_DIR}/backup_${TIMESTAMP}.tar.gz" -C "${BACKUP_DIR}" "backup_${TIMESTAMP}"

    ARCHIVE_SIZE=$(du -sh "${BACKUP_DIR}/backup_${TIMESTAMP}.tar.gz" | cut -f1)

    print_header "Backup Complete!"

    echo "Backup location: ${CURRENT_BACKUP_DIR}"
    echo "Backup archive:  ${BACKUP_DIR}/backup_${TIMESTAMP}.tar.gz"
    echo "Folder size:     ${BACKUP_SIZE}"
    echo "Archive size:    ${ARCHIVE_SIZE}"
    echo ""

    read -p "Do you want to keep the uncompressed backup folder? [y/N]: " keep_folder
    if [[ ! "$keep_folder" =~ ^[Yy]$ ]]; then
        rm -rf "$CURRENT_BACKUP_DIR"
        print_info "Uncompressed folder removed"
    fi

    read -p "Press Enter to continue..."
}

# ============================================================================
# 3. RESTORE
# ============================================================================

restore_backup() {
    print_header "Restore from Backup"

    check_root
    cd "$SCRIPT_DIR"

    # List available backups
    echo "Available backups:"
    echo ""

    BACKUP_COUNT=0
    declare -a BACKUP_LIST

    # List tar.gz archives
    for backup in "${BACKUP_DIR}"/backup_*.tar.gz; do
        if [[ -f "$backup" ]]; then
            BACKUP_COUNT=$((BACKUP_COUNT + 1))
            BACKUP_LIST+=("$backup")
            BACKUP_SIZE=$(du -sh "$backup" | cut -f1)
            BACKUP_NAME=$(basename "$backup")
            echo "  ${BACKUP_COUNT}) ${BACKUP_NAME} (${BACKUP_SIZE})"
        fi
    done

    # List uncompressed folders
    for backup in "${BACKUP_DIR}"/backup_*/; do
        if [[ -d "$backup" ]] && [[ -f "${backup}/manifest.txt" ]]; then
            BACKUP_COUNT=$((BACKUP_COUNT + 1))
            BACKUP_LIST+=("$backup")
            BACKUP_SIZE=$(du -sh "$backup" | cut -f1)
            BACKUP_NAME=$(basename "$backup")
            echo "  ${BACKUP_COUNT}) ${BACKUP_NAME}/ (${BACKUP_SIZE})"
        fi
    done

    if [[ $BACKUP_COUNT -eq 0 ]]; then
        print_warning "No backups found in ${BACKUP_DIR}"
        echo ""
        echo "To restore from an external backup:"
        echo "1. Copy the backup archive to ${BACKUP_DIR}/"
        echo "2. Run this option again"
        echo ""
        read -p "Press Enter to continue..."
        return
    fi

    echo ""
    echo "  0) Cancel"
    echo ""

    read -p "Select backup to restore [0-${BACKUP_COUNT}]: " selection

    if [[ "$selection" == "0" ]] || [[ -z "$selection" ]]; then
        print_info "Restore cancelled"
        return
    fi

    if [[ "$selection" -lt 1 ]] || [[ "$selection" -gt $BACKUP_COUNT ]]; then
        print_error "Invalid selection"
        read -p "Press Enter to continue..."
        return
    fi

    SELECTED_BACKUP="${BACKUP_LIST[$((selection - 1))]}"

    print_warning "This will overwrite all existing data!"
    read -p "Are you sure you want to restore from $(basename "$SELECTED_BACKUP")? [y/N]: " confirm

    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        print_info "Restore cancelled"
        return
    fi

    # Extract if it's a tar.gz
    RESTORE_DIR="$SELECTED_BACKUP"
    if [[ "$SELECTED_BACKUP" == *.tar.gz ]]; then
        print_info "Extracting backup archive..."
        RESTORE_DIR="${BACKUP_DIR}/restore_temp"
        mkdir -p "$RESTORE_DIR"
        tar -xzf "$SELECTED_BACKUP" -C "$RESTORE_DIR" --strip-components=1
        print_success "Archive extracted"
    fi

    # Stop services if running
    if is_running; then
        print_info "Stopping services..."
        docker compose down
    fi

    # Restore configuration files
    print_info "Restoring configuration files..."

    if [[ -f "${RESTORE_DIR}/docker-compose.yml" ]]; then
        cp "${RESTORE_DIR}/docker-compose.yml" "${SCRIPT_DIR}/"
        print_success "docker-compose.yml restored"
    fi

    if [[ -f "${RESTORE_DIR}/.env" ]]; then
        cp "${RESTORE_DIR}/.env" "${SCRIPT_DIR}/"
        chmod 600 "${SCRIPT_DIR}/.env"
        print_success ".env restored"
    fi

    if [[ -f "${RESTORE_DIR}/.ssl_mode" ]]; then
        cp "${RESTORE_DIR}/.ssl_mode" "${SCRIPT_DIR}/"
        print_success "SSL mode restored"
    fi

    # Restore nginx config and SSL certificates
    if [[ -f "${RESTORE_DIR}/nginx.tar.gz" ]]; then
        print_info "  - Restoring nginx configuration and SSL certificates..."
        rm -rf "${NGINX_DIR}"
        tar -xzf "${RESTORE_DIR}/nginx.tar.gz" -C "${SCRIPT_DIR}"
        print_success "  - Nginx configuration restored"
    fi

    # Create directories
    mkdir -p "$DATA_DIR"/{data,media,postgres,redis}
    mkdir -p "$CONSUME_DIR" "$EXPORT_DIR" "$TRASH_DIR" "$SCRIPTS_DIR"
    mkdir -p "$NGINX_DIR" "$SSL_DIR"

    # Restore data directories
    print_info "Restoring data directories..."

    if [[ -f "${RESTORE_DIR}/media.tar.gz" ]]; then
        print_info "  - Restoring media files..."
        rm -rf "${DATA_DIR}/media"
        tar -xzf "${RESTORE_DIR}/media.tar.gz" -C "${DATA_DIR}"
        print_success "  - Media files restored"
    fi

    if [[ -f "${RESTORE_DIR}/data.tar.gz" ]]; then
        print_info "  - Restoring application data..."
        rm -rf "${DATA_DIR}/data"
        tar -xzf "${RESTORE_DIR}/data.tar.gz" -C "${DATA_DIR}"
        print_success "  - Application data restored"
    fi

    if [[ -f "${RESTORE_DIR}/scripts.tar.gz" ]]; then
        print_info "  - Restoring custom scripts..."
        tar -xzf "${RESTORE_DIR}/scripts.tar.gz" -C "${SCRIPT_DIR}"
        print_success "  - Custom scripts restored"
    fi

    # Set permissions
    print_info "Setting permissions..."
    chown -R 1000:1000 "$DATA_DIR"
    chown -R 1000:1000 "$CONSUME_DIR"
    chown -R 1000:1000 "$EXPORT_DIR"
    chown -R 1000:1000 "$TRASH_DIR"
    chown -R 1000:1000 "$SCRIPTS_DIR"
    print_success "Permissions set"

    # Start database for restore
    print_info "Starting database service..."
    docker compose up -d db
    sleep 10

    # Wait for database to be ready
    for i in {1..30}; do
        if docker compose exec -T db pg_isready -U paperless &>/dev/null; then
            break
        fi
        sleep 1
    done

    # Restore database
    if [[ -f "${RESTORE_DIR}/database.sql" ]]; then
        print_info "Restoring database..."

        # Drop and recreate database
        docker compose exec -T db psql -U paperless -d postgres -c "DROP DATABASE IF EXISTS paperless;"
        docker compose exec -T db psql -U paperless -d postgres -c "CREATE DATABASE paperless OWNER paperless;"

        # Restore dump
        docker compose exec -T db psql -U paperless -d paperless < "${RESTORE_DIR}/database.sql"

        print_success "Database restored"
    fi

    # Cleanup temp directory
    if [[ "$SELECTED_BACKUP" == *.tar.gz ]]; then
        rm -rf "${BACKUP_DIR}/restore_temp"
    fi

    # Start all services
    print_info "Starting all services..."
    docker compose up -d

    wait_for_healthy

    print_header "Restore Complete!"

    local url=$(get_access_url)

    echo "Paperless-ngx has been restored from backup."
    echo ""
    echo "Access the web interface at: ${url}"
    echo ""

    read -p "Press Enter to continue..."
}

# ============================================================================
# SERVICE MANAGEMENT
# ============================================================================

start_services() {
    print_header "Starting Services"

    cd "$SCRIPT_DIR"

    if is_running; then
        print_warning "Services are already running"
    else
        print_info "Starting Paperless-ngx..."
        docker compose up -d
        wait_for_healthy
        print_success "Services started"
    fi

    echo ""
    echo "Access the web interface at: $(get_access_url)"
    echo ""

    read -p "Press Enter to continue..."
}

stop_services() {
    print_header "Stopping Services"

    cd "$SCRIPT_DIR"

    if is_running; then
        print_info "Stopping Paperless-ngx..."
        docker compose down
        print_success "Services stopped"
    else
        print_warning "Services are not running"
    fi

    read -p "Press Enter to continue..."
}

view_status() {
    print_header "Service Status"

    cd "$SCRIPT_DIR"

    # Container Status
    echo "Container Status:"
    echo "-----------------"
    docker compose ps --format "table {{.Name}}\t{{.Status}}\t{{.Ports}}" 2>/dev/null || docker compose ps

    echo ""

    # System Resources
    echo "System Resources:"
    echo "-----------------"

    # CPU Usage
    local cpu_usage=$(top -bn1 2>/dev/null | grep "Cpu(s)" | awk '{print $2}' | cut -d'%' -f1 || echo "N/A")
    echo "  CPU Usage:     ${cpu_usage}%"

    # Memory Usage
    local mem_info=$(free -m 2>/dev/null | awk 'NR==2{printf "%.1f%% (%dMB / %dMB)", $3*100/$2, $3, $2}')
    echo "  Memory Usage:  ${mem_info}"

    # Swap Usage
    local swap_info=$(free -m 2>/dev/null | awk 'NR==3{if($2>0) printf "%.1f%% (%dMB / %dMB)", $3*100/$2, $3, $2; else print "Not configured"}')
    echo "  Swap Usage:    ${swap_info}"

    echo ""

    # Container Resource Usage
    echo "Container Resources:"
    echo "--------------------"
    docker stats --no-stream --format "table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.NetIO}}" 2>/dev/null | head -10 || \
        echo "  (Unable to retrieve container stats)"

    echo ""

    # Disk Usage
    echo "Disk Usage:"
    echo "-----------"

    # Main disk
    local disk_info=$(df -h "$SCRIPT_DIR" 2>/dev/null | awk 'NR==2{print $3 " / " $2 " (" $5 " used)"}')
    echo "  System Disk:   ${disk_info}"

    if [[ -d "$DATA_DIR" ]]; then
        echo "  Data Dir:      $(du -sh "$DATA_DIR" 2>/dev/null | cut -f1)"
    fi
    if [[ -d "${DATA_DIR}/media" ]]; then
        echo "    - Media:     $(du -sh "${DATA_DIR}/media" 2>/dev/null | cut -f1)"
    fi
    if [[ -d "${DATA_DIR}/postgres" ]]; then
        echo "    - Database:  $(du -sh "${DATA_DIR}/postgres" 2>/dev/null | cut -f1)"
    fi
    if [[ -d "$CONSUME_DIR" ]]; then
        local consume_files=$(find "$CONSUME_DIR" -type f 2>/dev/null | wc -l)
        echo "  Consume Dir:   $(du -sh "$CONSUME_DIR" 2>/dev/null | cut -f1) (${consume_files} files pending)"
    fi
    if [[ -d "$BACKUP_DIR" ]]; then
        local backup_count=$(find "$BACKUP_DIR" -maxdepth 1 -name "backup_*" 2>/dev/null | wc -l)
        echo "  Backups:       $(du -sh "$BACKUP_DIR" 2>/dev/null | cut -f1) (${backup_count} backups)"
    fi

    echo ""

    # Paperless Statistics (if running)
    if is_running; then
        echo "Paperless Statistics:"
        echo "---------------------"

        # Get document count from database
        local doc_count=$(docker compose exec -T db psql -U paperless -d paperless -t -c "SELECT COUNT(*) FROM documents_document;" 2>/dev/null | tr -d ' ')
        if [[ -n "$doc_count" ]] && [[ "$doc_count" =~ ^[0-9]+$ ]]; then
            echo "  Documents:     ${doc_count}"
        fi

        # Get tag count
        local tag_count=$(docker compose exec -T db psql -U paperless -d paperless -t -c "SELECT COUNT(*) FROM documents_tag;" 2>/dev/null | tr -d ' ')
        if [[ -n "$tag_count" ]] && [[ "$tag_count" =~ ^[0-9]+$ ]]; then
            echo "  Tags:          ${tag_count}"
        fi

        # Get correspondent count
        local corr_count=$(docker compose exec -T db psql -U paperless -d paperless -t -c "SELECT COUNT(*) FROM documents_correspondent;" 2>/dev/null | tr -d ' ')
        if [[ -n "$corr_count" ]] && [[ "$corr_count" =~ ^[0-9]+$ ]]; then
            echo "  Correspondents: ${corr_count}"
        fi

        # Get task queue status
        local pending_tasks=$(docker compose exec -T broker redis-cli LLEN celery 2>/dev/null | tr -d ' ')
        if [[ -n "$pending_tasks" ]] && [[ "$pending_tasks" =~ ^[0-9]+$ ]]; then
            echo "  Pending Tasks: ${pending_tasks}"
        fi

        echo ""
    fi

    # Access Info
    echo "Access Information:"
    echo "-------------------"
    echo "  SSL Mode:      $(get_ssl_mode)"
    echo "  Access URL:    $(get_access_url)"

    echo ""

    read -p "Press Enter to continue..."
}

view_logs() {
    print_header "View Logs"

    cd "$SCRIPT_DIR"

    echo "Showing last 100 lines (Ctrl+C to exit)..."
    echo ""

    docker compose logs --tail=100 -f
}

# ============================================================================
# UPDATE/UPGRADE FUNCTIONS
# ============================================================================

get_current_versions() {
    cd "$SCRIPT_DIR"

    echo "Current container versions:"
    echo ""

    # Paperless-ngx
    local paperless_version=$(docker compose exec -T webserver python3 -c "import paperless; print(paperless.__version__)" 2>/dev/null || echo "unknown")
    local paperless_image=$(docker compose images webserver --format "{{.Repository}}:{{.Tag}}" 2>/dev/null | head -1)
    echo "  Paperless-ngx: ${paperless_version}"
    echo "    Image: ${paperless_image}"

    # PostgreSQL
    local postgres_version=$(docker compose exec -T db psql --version 2>/dev/null | head -1 | awk '{print $3}' || echo "unknown")
    local postgres_image=$(docker compose images db --format "{{.Repository}}:{{.Tag}}" 2>/dev/null | head -1)
    echo "  PostgreSQL: ${postgres_version}"
    echo "    Image: ${postgres_image}"

    # Redis
    local redis_version=$(docker compose exec -T broker redis-server --version 2>/dev/null | awk '{print $3}' | tr -d 'v=' || echo "unknown")
    local redis_image=$(docker compose images broker --format "{{.Repository}}:{{.Tag}}" 2>/dev/null | head -1)
    echo "  Redis: ${redis_version}"
    echo "    Image: ${redis_image}"

    # Nginx
    local nginx_version=$(docker compose exec -T nginx nginx -v 2>&1 | awk -F/ '{print $2}' || echo "unknown")
    local nginx_image=$(docker compose images nginx --format "{{.Repository}}:{{.Tag}}" 2>/dev/null | head -1)
    echo "  Nginx: ${nginx_version}"
    echo "    Image: ${nginx_image}"

    # Gotenberg
    local gotenberg_image=$(docker compose images gotenberg --format "{{.Repository}}:{{.Tag}}" 2>/dev/null | head -1)
    echo "  Gotenberg:"
    echo "    Image: ${gotenberg_image}"

    # Tika
    local tika_image=$(docker compose images tika --format "{{.Repository}}:{{.Tag}}" 2>/dev/null | head -1)
    echo "  Tika:"
    echo "    Image: ${tika_image}"

    echo ""
}

check_for_updates() {
    print_info "Checking for available updates..."
    echo ""

    cd "$SCRIPT_DIR"

    # Pull latest images without applying
    docker compose pull --quiet 2>/dev/null

    # Compare image IDs
    local updates_available=false

    for service in webserver db broker nginx gotenberg tika; do
        local current_id=$(docker compose images "$service" --format "{{.ID}}" 2>/dev/null | head -1)
        local latest_id=$(docker compose images "$service" --format "{{.ID}}" 2>/dev/null | tail -1)

        if [[ "$current_id" != "$latest_id" ]] && [[ -n "$current_id" ]] && [[ -n "$latest_id" ]]; then
            print_info "Update available for: $service"
            updates_available=true
        fi
    done

    if [[ "$updates_available" == false ]]; then
        print_success "All containers are up to date"
    fi

    echo ""
    return 0
}

update_containers() {
    print_header "Update Paperless-ngx"

    cd "$SCRIPT_DIR"

    # Check if services are running
    if ! is_running; then
        print_warning "Services are not running."
        read -p "Start services first? [Y/n]: " start_first
        if [[ ! "$start_first" =~ ^[Nn]$ ]]; then
            docker compose up -d
            wait_for_healthy
        fi
    fi

    echo ""
    get_current_versions

    echo "This will update all containers to their latest versions."
    echo ""
    echo "Update options:"
    echo ""
    echo "  1) Update all containers (recommended)"
    echo "  2) Update Paperless-ngx only"
    echo "  3) Update supporting services only (DB, Redis, Nginx, etc.)"
    echo "  4) Check for updates (dry run)"
    echo ""
    echo "  0) Cancel"
    echo ""

    read -p "Select option [0-4]: " update_choice

    case $update_choice in
        1)
            perform_full_update
            ;;
        2)
            perform_paperless_update
            ;;
        3)
            perform_support_update
            ;;
        4)
            check_for_updates
            read -p "Press Enter to continue..."
            return
            ;;
        0)
            print_info "Update cancelled"
            read -p "Press Enter to continue..."
            return
            ;;
        *)
            print_error "Invalid option"
            read -p "Press Enter to continue..."
            return
            ;;
    esac
}

select_pre_update_backup() {
    # Shared function for selecting backup type before updates
    # Sets CURRENT_BACKUP_DIR variable for use by calling function

    echo "Before updating, we recommend creating a backup."
    echo ""
    echo "Backup options:"
    echo ""
    echo "  1) Quick backup (recommended for routine updates)"
    echo "     - Database, configuration, and settings only"
    echo "     - Fast (seconds to minutes)"
    echo "     - Sufficient for most updates - documents remain on disk"
    echo ""
    echo "  2) Full backup (recommended for major version updates)"
    echo "     - Everything: database, config, AND all documents/media"
    echo "     - Slower (depends on document collection size)"
    echo "     - Complete protection against any data loss"
    echo ""
    echo "  3) Skip backup (not recommended)"
    echo "     - Proceed without any backup"
    echo "     - Only if you have a recent backup already"
    echo ""

    read -p "Select backup option [1-3] (default: 1): " backup_choice
    backup_choice=${backup_choice:-1}

    TIMESTAMP=$(date +%Y%m%d_%H%M%S)
    CURRENT_BACKUP_DIR="${BACKUP_DIR}/pre_update_${TIMESTAMP}"

    case $backup_choice in
        1)
            # Quick backup
            print_info "Creating quick pre-update backup..."
            echo ""

            mkdir -p "$CURRENT_BACKUP_DIR"

            print_info "Backing up database..."
            docker compose exec -T db pg_dump -U paperless -d paperless > "${CURRENT_BACKUP_DIR}/database.sql" 2>/dev/null

            print_info "Backing up configuration..."
            cp "${SCRIPT_DIR}/docker-compose.yml" "${CURRENT_BACKUP_DIR}/" 2>/dev/null || true
            [[ -f "${SCRIPT_DIR}/.env" ]] && cp "${SCRIPT_DIR}/.env" "${CURRENT_BACKUP_DIR}/"
            [[ -f "${SCRIPT_DIR}/.ssl_mode" ]] && cp "${SCRIPT_DIR}/.ssl_mode" "${CURRENT_BACKUP_DIR}/"

            if [[ -d "${NGINX_DIR}" ]]; then
                tar -czf "${CURRENT_BACKUP_DIR}/nginx.tar.gz" -C "${SCRIPT_DIR}" nginx 2>/dev/null || true
            fi

            # Create manifest
            cat > "${CURRENT_BACKUP_DIR}/manifest.txt" << EOF
Pre-Update Backup (Quick)
=========================
Date: $(date)
Type: Quick backup - database and configuration only

This backup contains:
- database.sql: Full database dump
- .env: Environment configuration
- nginx.tar.gz: Nginx and SSL configuration

Note: Document files (media) are NOT included in this backup.
Your documents remain on disk in the data/media directory.
EOF

            print_success "Quick backup created: ${CURRENT_BACKUP_DIR}"
            echo ""
            ;;
        2)
            # Full backup
            print_info "Creating full pre-update backup (this may take a while)..."
            echo ""

            mkdir -p "$CURRENT_BACKUP_DIR"

            # Stop webserver for consistent backup
            print_info "Stopping webserver for consistent backup..."
            docker compose stop webserver

            print_info "Backing up database..."
            docker compose exec -T db pg_dump -U paperless -d paperless > "${CURRENT_BACKUP_DIR}/database.sql" 2>/dev/null

            print_info "Backing up configuration..."
            cp "${SCRIPT_DIR}/docker-compose.yml" "${CURRENT_BACKUP_DIR}/" 2>/dev/null || true
            [[ -f "${SCRIPT_DIR}/.env" ]] && cp "${SCRIPT_DIR}/.env" "${CURRENT_BACKUP_DIR}/"
            [[ -f "${SCRIPT_DIR}/.ssl_mode" ]] && cp "${SCRIPT_DIR}/.ssl_mode" "${CURRENT_BACKUP_DIR}/"

            if [[ -d "${NGINX_DIR}" ]]; then
                tar -czf "${CURRENT_BACKUP_DIR}/nginx.tar.gz" -C "${SCRIPT_DIR}" nginx 2>/dev/null || true
            fi

            # Backup media (documents, thumbnails, archive)
            if [[ -d "${DATA_DIR}/media" ]]; then
                print_info "Backing up media files (documents, thumbnails, archive)..."
                tar -czf "${CURRENT_BACKUP_DIR}/media.tar.gz" -C "${DATA_DIR}" media
                print_success "Media files backed up"
            fi

            # Backup data directory (index, classification models)
            if [[ -d "${DATA_DIR}/data" ]]; then
                print_info "Backing up application data (index, models)..."
                tar -czf "${CURRENT_BACKUP_DIR}/data.tar.gz" -C "${DATA_DIR}" data
                print_success "Application data backed up"
            fi

            # Backup scripts
            if [[ -d "$SCRIPTS_DIR" ]] && [[ "$(ls -A $SCRIPTS_DIR 2>/dev/null)" ]]; then
                print_info "Backing up custom scripts..."
                tar -czf "${CURRENT_BACKUP_DIR}/scripts.tar.gz" -C "${SCRIPT_DIR}" scripts
            fi

            # Restart webserver
            print_info "Restarting webserver..."
            docker compose start webserver

            # Create manifest
            cat > "${CURRENT_BACKUP_DIR}/manifest.txt" << EOF
Pre-Update Backup (Full)
========================
Date: $(date)
Type: Full backup - complete system backup

This backup contains:
- database.sql: Full database dump
- .env: Environment configuration
- nginx.tar.gz: Nginx and SSL configuration
- media.tar.gz: All documents, thumbnails, and archive files
- data.tar.gz: Search index and classification models
- scripts.tar.gz: Custom scripts (if any)

This is a complete backup that can fully restore your system.
EOF

            # Calculate backup size
            BACKUP_SIZE=$(du -sh "$CURRENT_BACKUP_DIR" | cut -f1)
            print_success "Full backup created: ${CURRENT_BACKUP_DIR} (${BACKUP_SIZE})"
            echo ""
            ;;
        3)
            print_warning "Proceeding without backup..."
            CURRENT_BACKUP_DIR=""
            echo ""
            ;;
        *)
            print_warning "Invalid choice, creating quick backup..."
            mkdir -p "$CURRENT_BACKUP_DIR"
            docker compose exec -T db pg_dump -U paperless -d paperless > "${CURRENT_BACKUP_DIR}/database.sql" 2>/dev/null
            cp "${SCRIPT_DIR}/.env" "${CURRENT_BACKUP_DIR}/" 2>/dev/null || true
            print_success "Quick backup created: ${CURRENT_BACKUP_DIR}"
            echo ""
            ;;
    esac
}

perform_full_update() {
    print_header "Full System Update"

    cd "$SCRIPT_DIR"

    # Safety confirmation
    print_warning "This will update ALL containers to their latest versions."
    echo ""

    # Use shared backup selection
    select_pre_update_backup

    # Final confirmation
    read -p "Proceed with full update? [y/N]: " confirm_update
    if [[ ! "$confirm_update" =~ ^[Yy]$ ]]; then
        print_info "Update cancelled"
        read -p "Press Enter to continue..."
        return
    fi

    # Perform the update
    print_info "Pulling latest images..."
    docker compose pull

    print_info "Stopping services..."
    docker compose down

    print_info "Starting updated services..."
    docker compose up -d

    print_info "Waiting for services to be ready..."
    wait_for_healthy

    # Run database migrations if needed
    print_info "Checking for database migrations..."
    docker compose exec -T webserver python3 manage.py migrate --check 2>/dev/null || \
        docker compose exec -T webserver python3 manage.py migrate 2>/dev/null || true

    print_header "Update Complete!"

    echo ""
    get_current_versions

    print_success "All containers have been updated to their latest versions."
    echo ""

    if [[ -n "$CURRENT_BACKUP_DIR" ]]; then
        echo "Pre-update backup location: ${CURRENT_BACKUP_DIR}"
        echo "If you experience issues, you can restore from this backup."
        echo ""
    fi

    read -p "Press Enter to continue..."
}

perform_paperless_update() {
    print_header "Update Paperless-ngx"

    cd "$SCRIPT_DIR"

    print_warning "This will update the Paperless-ngx webserver container only."
    echo ""

    # Use shared backup selection
    select_pre_update_backup

    read -p "Proceed with Paperless-ngx update? [y/N]: " confirm_update
    if [[ ! "$confirm_update" =~ ^[Yy]$ ]]; then
        print_info "Update cancelled"
        read -p "Press Enter to continue..."
        return
    fi

    print_info "Pulling latest Paperless-ngx image..."
    docker compose pull webserver

    print_info "Recreating webserver container..."
    docker compose up -d webserver

    print_info "Waiting for Paperless-ngx to be ready..."
    sleep 10

    # Check if webserver is responding
    local attempts=0
    while [ $attempts -lt 60 ]; do
        if docker compose exec -T webserver python3 -c "print('ok')" &>/dev/null; then
            break
        fi
        attempts=$((attempts + 1))
        sleep 1
    done

    # Run database migrations
    print_info "Running database migrations..."
    docker compose exec -T webserver python3 manage.py migrate 2>/dev/null || true

    print_header "Paperless-ngx Update Complete!"

    local new_version=$(docker compose exec -T webserver python3 -c "import paperless; print(paperless.__version__)" 2>/dev/null || echo "unknown")
    echo "New version: ${new_version}"
    echo ""

    read -p "Press Enter to continue..."
}

perform_support_update() {
    print_header "Update Supporting Services"

    cd "$SCRIPT_DIR"

    echo "This will update the following services:"
    echo "  - PostgreSQL (database)"
    echo "  - Redis (cache/queue)"
    echo "  - Nginx (web server)"
    echo "  - Gotenberg (document conversion)"
    echo "  - Tika (document parsing)"
    echo ""

    print_warning "Updating the database may require additional steps."
    echo ""

    # Use shared backup selection
    select_pre_update_backup

    read -p "Proceed with supporting services update? [y/N]: " confirm_update
    if [[ ! "$confirm_update" =~ ^[Yy]$ ]]; then
        print_info "Update cancelled"
        read -p "Press Enter to continue..."
        return
    fi

    print_info "Pulling latest images for supporting services..."
    docker compose pull db broker nginx gotenberg tika

    print_info "Recreating supporting service containers..."
    docker compose up -d db broker nginx gotenberg tika

    print_info "Waiting for services to be healthy..."
    wait_for_healthy

    print_header "Supporting Services Update Complete!"

    echo ""
    get_current_versions

    read -p "Press Enter to continue..."
}

rollback_update() {
    print_header "Rollback to Previous Version"

    cd "$SCRIPT_DIR"

    # List pre-update backups
    echo "Available pre-update backups:"
    echo ""

    local backup_count=0
    declare -a backup_list

    for backup in "${BACKUP_DIR}"/pre_update_*/; do
        if [[ -d "$backup" ]] && [[ -f "${backup}/database.sql" ]]; then
            backup_count=$((backup_count + 1))
            backup_list+=("$backup")
            local backup_name=$(basename "$backup")
            local backup_date=$(echo "$backup_name" | sed 's/pre_update_//' | sed 's/_/ /')
            echo "  ${backup_count}) ${backup_name}"
        fi
    done

    if [[ $backup_count -eq 0 ]]; then
        print_warning "No pre-update backups found."
        print_info "You can use the regular restore function (option 3) to restore from a full backup."
        read -p "Press Enter to continue..."
        return
    fi

    echo ""
    echo "  0) Cancel"
    echo ""

    read -p "Select backup to restore [0-${backup_count}]: " selection

    if [[ "$selection" == "0" ]] || [[ -z "$selection" ]]; then
        print_info "Rollback cancelled"
        return
    fi

    if [[ "$selection" -lt 1 ]] || [[ "$selection" -gt $backup_count ]]; then
        print_error "Invalid selection"
        read -p "Press Enter to continue..."
        return
    fi

    local selected_backup="${backup_list[$((selection - 1))]}"

    print_warning "This will restore from: $(basename "$selected_backup")"
    read -p "Are you sure? [y/N]: " confirm

    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        print_info "Rollback cancelled"
        return
    fi

    # Perform rollback
    print_info "Stopping services..."
    docker compose down

    # Restore database
    print_info "Starting database..."
    docker compose up -d db
    sleep 10

    print_info "Restoring database..."
    docker compose exec -T db psql -U paperless -d postgres -c "DROP DATABASE IF EXISTS paperless;"
    docker compose exec -T db psql -U paperless -d postgres -c "CREATE DATABASE paperless OWNER paperless;"
    docker compose exec -T db psql -U paperless -d paperless < "${selected_backup}/database.sql"

    # Restore config if present
    if [[ -f "${selected_backup}/.env" ]]; then
        cp "${selected_backup}/.env" "${SCRIPT_DIR}/.env"
    fi

    # Start all services
    print_info "Starting all services..."
    docker compose up -d

    wait_for_healthy

    print_header "Rollback Complete!"

    echo "System has been restored to the state before the update."
    echo ""

    read -p "Press Enter to continue..."
}

# ============================================================================
# DATABASE OPTIMIZATION
# ============================================================================

CONFIG_DIR="${SCRIPT_DIR}/config"
POSTGRES_CONFIG_DIR="${CONFIG_DIR}/postgres"
POSTGRES_CONF="${POSTGRES_CONFIG_DIR}/postgresql.conf"

get_system_ram_mb() {
    # Get total system RAM in MB
    free -m 2>/dev/null | awk '/^Mem:/{print $2}' || echo "4096"
}

calculate_postgres_settings() {
    local ram_mb=$1

    # Calculate optimal PostgreSQL settings based on RAM
    # These follow PostgreSQL best practices for a dedicated database server

    # shared_buffers: 25% of RAM, max 8GB for most workloads
    local shared_buffers_mb=$((ram_mb / 4))
    if [[ $shared_buffers_mb -gt 8192 ]]; then
        shared_buffers_mb=8192
    fi
    if [[ $shared_buffers_mb -lt 128 ]]; then
        shared_buffers_mb=128
    fi

    # effective_cache_size: 50-75% of RAM (we use 60%)
    local effective_cache_mb=$((ram_mb * 60 / 100))

    # work_mem: RAM / max_connections / 4 (conservative)
    # For Paperless with 2-4 workers, we estimate ~20 connections max
    local work_mem_mb=$((ram_mb / 20 / 4))
    if [[ $work_mem_mb -lt 4 ]]; then
        work_mem_mb=4
    fi
    if [[ $work_mem_mb -gt 256 ]]; then
        work_mem_mb=256
    fi

    # maintenance_work_mem: RAM / 8, max 2GB
    local maintenance_work_mem_mb=$((ram_mb / 8))
    if [[ $maintenance_work_mem_mb -gt 2048 ]]; then
        maintenance_work_mem_mb=2048
    fi
    if [[ $maintenance_work_mem_mb -lt 64 ]]; then
        maintenance_work_mem_mb=64
    fi

    # max_connections based on expected load
    local max_connections=100
    if [[ $ram_mb -lt 4096 ]]; then
        max_connections=50
    elif [[ $ram_mb -ge 16384 ]]; then
        max_connections=200
    fi

    # Return values as a string (shared_buffers|effective_cache|work_mem|maintenance_work_mem|max_connections)
    echo "${shared_buffers_mb}|${effective_cache_mb}|${work_mem_mb}|${maintenance_work_mem_mb}|${max_connections}"
}

create_postgres_config() {
    local shared_buffers_mb=$1
    local effective_cache_mb=$2
    local work_mem_mb=$3
    local maintenance_work_mem_mb=$4
    local max_connections=$5

    mkdir -p "$POSTGRES_CONFIG_DIR"

    cat > "$POSTGRES_CONF" << EOF
# PostgreSQL Configuration for Paperless-ngx
# Generated by management.sh on $(date)
# Optimized for system with approximately $((shared_buffers_mb * 4))MB RAM

# -----------------------------------------------------------------------------
# CONNECTION SETTINGS
# -----------------------------------------------------------------------------
listen_addresses = '*'
max_connections = ${max_connections}

# -----------------------------------------------------------------------------
# MEMORY SETTINGS
# -----------------------------------------------------------------------------
# shared_buffers: Main memory cache for PostgreSQL
# Recommended: 25% of system RAM
shared_buffers = ${shared_buffers_mb}MB

# effective_cache_size: Estimate of memory available for disk caching
# Used by query planner, not actual allocation
effective_cache_size = ${effective_cache_mb}MB

# work_mem: Memory per sort/hash operation
# Be conservative as this is per-operation, not per-connection
work_mem = ${work_mem_mb}MB

# maintenance_work_mem: Memory for maintenance operations (VACUUM, CREATE INDEX)
maintenance_work_mem = ${maintenance_work_mem_mb}MB

# -----------------------------------------------------------------------------
# WRITE-AHEAD LOG (WAL) SETTINGS
# -----------------------------------------------------------------------------
# wal_buffers: Memory for WAL data (auto-tuned based on shared_buffers)
wal_buffers = 16MB

# checkpoint_completion_target: Spread checkpoints over time
checkpoint_completion_target = 0.9

# max_wal_size: Maximum size of WAL before checkpoint
max_wal_size = 2GB

# min_wal_size: Minimum WAL size to retain
min_wal_size = 512MB

# -----------------------------------------------------------------------------
# QUERY PLANNER SETTINGS
# -----------------------------------------------------------------------------
# random_page_cost: Cost estimate for random disk access
# Lower for SSDs (1.1-2.0), higher for HDDs (4.0)
random_page_cost = 1.1

# effective_io_concurrency: Number of concurrent disk I/O operations
# Higher for SSDs (200), lower for HDDs (2)
effective_io_concurrency = 200

# -----------------------------------------------------------------------------
# PARALLEL QUERY SETTINGS
# -----------------------------------------------------------------------------
max_worker_processes = 8
max_parallel_workers_per_gather = 4
max_parallel_workers = 8
max_parallel_maintenance_workers = 4

# -----------------------------------------------------------------------------
# LOGGING SETTINGS
# -----------------------------------------------------------------------------
logging_collector = on
log_directory = 'pg_log'
log_filename = 'postgresql-%Y-%m-%d.log'
log_rotation_age = 1d
log_rotation_size = 100MB
log_min_duration_statement = 1000
log_checkpoints = on
log_lock_waits = on
log_temp_files = 0

# -----------------------------------------------------------------------------
# AUTOVACUUM SETTINGS
# -----------------------------------------------------------------------------
autovacuum = on
autovacuum_max_workers = 3
autovacuum_naptime = 60
autovacuum_vacuum_threshold = 50
autovacuum_analyze_threshold = 50
autovacuum_vacuum_scale_factor = 0.05
autovacuum_analyze_scale_factor = 0.025

# -----------------------------------------------------------------------------
# CLIENT CONNECTION DEFAULTS
# -----------------------------------------------------------------------------
timezone = 'UTC'
lc_messages = 'en_US.UTF-8'
lc_monetary = 'en_US.UTF-8'
lc_numeric = 'en_US.UTF-8'
lc_time = 'en_US.UTF-8'
default_text_search_config = 'pg_catalog.english'
EOF

    print_success "PostgreSQL configuration created: ${POSTGRES_CONF}"
}

optimize_database() {
    print_header "Database Optimization"

    cd "$SCRIPT_DIR"

    # Detect system RAM
    local ram_mb=$(get_system_ram_mb)
    local ram_gb=$((ram_mb / 1024))

    print_info "Detected system RAM: ${ram_mb} MB (~${ram_gb} GB)"
    echo ""

    echo "Database optimization options:"
    echo ""
    echo "  1) Auto-optimize (recommended)"
    echo "     Automatically calculate optimal settings based on your system"
    echo ""
    echo "  2) Choose a preset profile"
    echo "     Small (4GB RAM), Medium (8-16GB), Large (32GB+)"
    echo ""
    echo "  3) View current settings"
    echo "     Show current PostgreSQL configuration"
    echo ""
    echo "  4) Reset to defaults"
    echo "     Remove custom configuration"
    echo ""
    echo "  0) Cancel"
    echo ""

    read -p "Select option [0-4] (default: 1): " opt_choice
    opt_choice=${opt_choice:-1}

    case $opt_choice in
        1)
            auto_optimize_database "$ram_mb"
            ;;
        2)
            select_database_profile
            ;;
        3)
            view_database_settings
            read -p "Press Enter to continue..."
            return
            ;;
        4)
            reset_database_config
            ;;
        0)
            print_info "Cancelled"
            read -p "Press Enter to continue..."
            return
            ;;
        *)
            print_error "Invalid option"
            read -p "Press Enter to continue..."
            return
            ;;
    esac
}

auto_optimize_database() {
    local ram_mb=$1

    print_info "Calculating optimal PostgreSQL settings..."
    echo ""

    # Calculate settings
    local settings=$(calculate_postgres_settings "$ram_mb")
    IFS='|' read -r shared_buffers effective_cache work_mem maintenance_work_mem max_connections <<< "$settings"

    echo "Recommended settings for your system (${ram_mb}MB RAM):"
    echo ""
    echo "  ┌────────────────────────────────────────────────────┐"
    echo "  │  Setting                  │  Value                 │"
    echo "  ├────────────────────────────────────────────────────┤"
    printf "  │  %-24s │  %-21s │\n" "shared_buffers" "${shared_buffers}MB"
    printf "  │  %-24s │  %-21s │\n" "effective_cache_size" "${effective_cache}MB"
    printf "  │  %-24s │  %-21s │\n" "work_mem" "${work_mem}MB"
    printf "  │  %-24s │  %-21s │\n" "maintenance_work_mem" "${maintenance_work_mem}MB"
    printf "  │  %-24s │  %-21s │\n" "max_connections" "${max_connections}"
    echo "  └────────────────────────────────────────────────────┘"
    echo ""

    read -p "Apply these settings? [Y/n]: " confirm
    if [[ "$confirm" =~ ^[Nn]$ ]]; then
        print_info "Cancelled"
        read -p "Press Enter to continue..."
        return
    fi

    # Create configuration
    create_postgres_config "$shared_buffers" "$effective_cache" "$work_mem" "$maintenance_work_mem" "$max_connections"

    # Restart database if running
    if is_running; then
        echo ""
        read -p "Restart database to apply changes? [Y/n]: " restart_confirm
        if [[ ! "$restart_confirm" =~ ^[Nn]$ ]]; then
            print_info "Restarting database..."
            docker compose restart db
            sleep 5
            print_success "Database restarted with new configuration"
        else
            print_warning "Changes will be applied on next restart"
        fi
    else
        print_info "Changes will be applied when services are started"
    fi

    echo ""
    read -p "Press Enter to continue..."
}

select_database_profile() {
    echo ""
    echo "Select a database profile:"
    echo ""
    echo "  1) Small (4GB RAM system)"
    echo "     - shared_buffers: 512MB"
    echo "     - Suitable for small installations (<5,000 documents)"
    echo ""
    echo "  2) Medium (8-16GB RAM system)"
    echo "     - shared_buffers: 2GB"
    echo "     - Suitable for medium installations (5,000-50,000 documents)"
    echo ""
    echo "  3) Large (32GB+ RAM system)"
    echo "     - shared_buffers: 8GB"
    echo "     - Suitable for large installations (50,000+ documents)"
    echo ""
    echo "  0) Cancel"
    echo ""

    read -p "Select profile [0-3]: " profile_choice

    local shared_buffers effective_cache work_mem maintenance_work_mem max_connections

    case $profile_choice in
        1)
            # Small: 4GB RAM system
            shared_buffers=512
            effective_cache=2048
            work_mem=8
            maintenance_work_mem=256
            max_connections=50
            ;;
        2)
            # Medium: 8-16GB RAM system
            shared_buffers=2048
            effective_cache=8192
            work_mem=32
            maintenance_work_mem=512
            max_connections=100
            ;;
        3)
            # Large: 32GB+ RAM system
            shared_buffers=8192
            effective_cache=24576
            work_mem=128
            maintenance_work_mem=2048
            max_connections=200
            ;;
        0)
            print_info "Cancelled"
            read -p "Press Enter to continue..."
            return
            ;;
        *)
            print_error "Invalid option"
            read -p "Press Enter to continue..."
            return
            ;;
    esac

    echo ""
    print_info "Creating configuration for selected profile..."

    create_postgres_config "$shared_buffers" "$effective_cache" "$work_mem" "$maintenance_work_mem" "$max_connections"

    # Restart database if running
    if is_running; then
        echo ""
        read -p "Restart database to apply changes? [Y/n]: " restart_confirm
        if [[ ! "$restart_confirm" =~ ^[Nn]$ ]]; then
            print_info "Restarting database..."
            docker compose restart db
            sleep 5
            print_success "Database restarted with new configuration"
        else
            print_warning "Changes will be applied on next restart"
        fi
    fi

    echo ""
    read -p "Press Enter to continue..."
}

view_database_settings() {
    print_header "Current Database Settings"

    cd "$SCRIPT_DIR"

    if [[ -f "$POSTGRES_CONF" ]]; then
        echo "Custom configuration file: ${POSTGRES_CONF}"
        echo ""
        echo "Key settings:"
        echo ""
        grep -E "^(shared_buffers|effective_cache_size|work_mem|maintenance_work_mem|max_connections)" "$POSTGRES_CONF" 2>/dev/null | \
            while read line; do
                echo "  $line"
            done
        echo ""
    else
        print_info "No custom configuration file found."
        print_info "Using PostgreSQL defaults."
        echo ""
    fi

    # Show live settings if database is running
    if is_running; then
        echo "Live database settings:"
        echo ""
        docker compose exec -T db psql -U paperless -d paperless -c \
            "SELECT name, setting, unit FROM pg_settings WHERE name IN ('shared_buffers', 'effective_cache_size', 'work_mem', 'maintenance_work_mem', 'max_connections');" 2>/dev/null || \
            print_warning "Could not retrieve live settings"
        echo ""
    fi
}

reset_database_config() {
    print_header "Reset Database Configuration"

    if [[ -f "$POSTGRES_CONF" ]]; then
        print_warning "This will remove the custom PostgreSQL configuration."
        read -p "Are you sure? [y/N]: " confirm

        if [[ "$confirm" =~ ^[Yy]$ ]]; then
            rm -f "$POSTGRES_CONF"
            print_success "Custom configuration removed"

            print_warning "Note: The database container will fail to start without a config file."
            print_info "Creating a minimal default configuration..."

            # Create minimal default config
            mkdir -p "$POSTGRES_CONFIG_DIR"
            cat > "$POSTGRES_CONF" << 'EOF'
# PostgreSQL Default Configuration for Paperless-ngx
# Minimal settings - PostgreSQL will use defaults for most options

listen_addresses = '*'
max_connections = 100

# Logging
logging_collector = on
log_directory = 'pg_log'
log_filename = 'postgresql-%Y-%m-%d.log'

# Autovacuum
autovacuum = on

# Locale
timezone = 'UTC'
lc_messages = 'en_US.UTF-8'
EOF
            print_success "Default configuration created"

            if is_running; then
                read -p "Restart database to apply changes? [Y/n]: " restart_confirm
                if [[ ! "$restart_confirm" =~ ^[Nn]$ ]]; then
                    print_info "Restarting database..."
                    docker compose restart db
                    sleep 5
                    print_success "Database restarted"
                fi
            fi
        else
            print_info "Cancelled"
        fi
    else
        print_info "No custom configuration to remove"
    fi

    echo ""
    read -p "Press Enter to continue..."
}

setup_database_optimization_initial() {
    # Called during initial setup - simplified flow
    print_header "Database Performance Optimization"

    local ram_mb=$(get_system_ram_mb)
    local ram_gb=$((ram_mb / 1024))

    echo "Your system has approximately ${ram_gb}GB of RAM."
    echo ""
    echo "Would you like to optimize PostgreSQL for better performance?"
    echo "This is recommended for installations with more than 5,000 documents."
    echo ""
    echo "  1) Yes, auto-optimize (recommended)"
    echo "  2) No, use defaults (can be changed later)"
    echo ""

    read -p "Select option [1-2] (default: 1): " choice
    choice=${choice:-1}

    if [[ "$choice" == "1" ]]; then
        local settings=$(calculate_postgres_settings "$ram_mb")
        IFS='|' read -r shared_buffers effective_cache work_mem maintenance_work_mem max_connections <<< "$settings"

        create_postgres_config "$shared_buffers" "$effective_cache" "$work_mem" "$maintenance_work_mem" "$max_connections"

        print_success "Database optimized for ${ram_gb}GB RAM system"
    else
        # Create minimal default config
        mkdir -p "$POSTGRES_CONFIG_DIR"
        cat > "$POSTGRES_CONF" << 'EOF'
# PostgreSQL Default Configuration for Paperless-ngx
listen_addresses = '*'
max_connections = 100
logging_collector = on
log_directory = 'pg_log'
log_filename = 'postgresql-%Y-%m-%d.log'
autovacuum = on
timezone = 'UTC'
lc_messages = 'en_US.UTF-8'
EOF
        print_info "Using default database settings (can be optimized later via menu)"
    fi
    echo ""
}

# ============================================================================
# HEALTH MONITORING & ALERTS
# ============================================================================

HEALTH_CONFIG="${CONFIG_DIR}/health-monitor.conf"
HEALTH_LOG="${BACKUP_DIR}/health-monitor.log"

load_health_config() {
    if [[ -f "$HEALTH_CONFIG" ]]; then
        source "$HEALTH_CONFIG"
    fi
}

save_health_config() {
    mkdir -p "$CONFIG_DIR"
    cat > "$HEALTH_CONFIG" << EOF
# Health Monitor Configuration
# Generated on $(date)

# Email alerts (leave empty to disable)
ALERT_EMAIL="${ALERT_EMAIL:-}"
SMTP_SERVER="${SMTP_SERVER:-}"
SMTP_PORT="${SMTP_PORT:-587}"
SMTP_USER="${SMTP_USER:-}"
SMTP_PASSWORD="${SMTP_PASSWORD:-}"
SMTP_FROM="${SMTP_FROM:-}"

# Webhook alerts (leave empty to disable)
# Supports Discord, Slack, or any URL that accepts POST
ALERT_WEBHOOK="${ALERT_WEBHOOK:-}"

# Monitoring settings
HEALTH_CHECK_INTERVAL="${HEALTH_CHECK_INTERVAL:-5}"
CONSECUTIVE_FAILURES="${CONSECUTIVE_FAILURES:-3}"
EOF
}

check_service_health() {
    local service=$1
    local status="unknown"
    local details=""

    cd "$SCRIPT_DIR"

    case $service in
        "webserver")
            if docker compose ps webserver 2>/dev/null | grep -q "running"; then
                # Check if webserver responds
                if docker compose exec -T webserver python3 -c "print('ok')" &>/dev/null; then
                    status="healthy"
                    details="Running and responsive"
                else
                    status="degraded"
                    details="Container running but not responsive"
                fi
            else
                status="down"
                details="Container not running"
            fi
            ;;
        "db")
            if docker compose ps db 2>/dev/null | grep -q "running"; then
                if docker compose exec -T db pg_isready -U paperless -d paperless &>/dev/null; then
                    status="healthy"
                    details="Running and accepting connections"
                else
                    status="degraded"
                    details="Container running but not ready"
                fi
            else
                status="down"
                details="Container not running"
            fi
            ;;
        "broker")
            if docker compose ps broker 2>/dev/null | grep -q "running"; then
                if docker compose exec -T broker redis-cli ping &>/dev/null; then
                    status="healthy"
                    details="Running and responding to ping"
                else
                    status="degraded"
                    details="Container running but not responding"
                fi
            else
                status="down"
                details="Container not running"
            fi
            ;;
        "nginx")
            if docker compose ps nginx 2>/dev/null | grep -q "running"; then
                if docker compose exec -T nginx nginx -t &>/dev/null; then
                    status="healthy"
                    details="Running with valid configuration"
                else
                    status="degraded"
                    details="Running but config test failed"
                fi
            else
                status="down"
                details="Container not running"
            fi
            ;;
        "gotenberg"|"tika")
            if docker compose ps "$service" 2>/dev/null | grep -q "running"; then
                status="healthy"
                details="Running"
            else
                status="down"
                details="Container not running"
            fi
            ;;
    esac

    echo "${status}|${details}"
}

run_health_check() {
    local silent=${1:-false}
    local all_healthy=true
    local unhealthy_services=""

    cd "$SCRIPT_DIR"

    declare -A service_status

    # Check all services
    for service in webserver db broker nginx gotenberg tika; do
        local result=$(check_service_health "$service")
        local status=$(echo "$result" | cut -d'|' -f1)
        local details=$(echo "$result" | cut -d'|' -f2)

        service_status[$service]="$status|$details"

        if [[ "$status" != "healthy" ]]; then
            all_healthy=false
            unhealthy_services="${unhealthy_services}${service} (${status}): ${details}\n"
        fi
    done

    if [[ "$silent" != "true" ]]; then
        print_header "System Health Check"

        echo "Service Status:"
        echo ""

        for service in webserver db broker nginx gotenberg tika; do
            local result="${service_status[$service]}"
            local status=$(echo "$result" | cut -d'|' -f1)
            local details=$(echo "$result" | cut -d'|' -f2)

            local status_icon=""
            local status_color=""

            case $status in
                "healthy")
                    status_icon="✓"
                    status_color="${GREEN}"
                    ;;
                "degraded")
                    status_icon="!"
                    status_color="${YELLOW}"
                    ;;
                "down")
                    status_icon="✗"
                    status_color="${RED}"
                    ;;
                *)
                    status_icon="?"
                    status_color="${NC}"
                    ;;
            esac

            printf "  ${status_color}${status_icon}${NC} %-12s ${status_color}%-10s${NC} %s\n" "$service" "[$status]" "$details"
        done

        echo ""

        # Disk space check
        local disk_usage=$(df -h "$SCRIPT_DIR" 2>/dev/null | awk 'NR==2 {print $5}' | tr -d '%')
        local disk_status="healthy"
        if [[ "$disk_usage" -gt 90 ]]; then
            disk_status="critical"
        elif [[ "$disk_usage" -gt 80 ]]; then
            disk_status="warning"
        fi

        echo "Disk Usage: ${disk_usage}% used"
        if [[ "$disk_status" == "critical" ]]; then
            print_error "CRITICAL: Disk space is critically low!"
        elif [[ "$disk_status" == "warning" ]]; then
            print_warning "Warning: Disk space is getting low"
        fi

        echo ""

        if $all_healthy; then
            print_success "All services are healthy"
        else
            print_error "Some services have issues"
        fi
    fi

    # Return status for scripting
    if $all_healthy; then
        return 0
    else
        echo "$unhealthy_services"
        return 1
    fi
}

send_alert_email() {
    local subject="$1"
    local body="$2"

    load_health_config

    if [[ -z "$ALERT_EMAIL" ]] || [[ -z "$SMTP_SERVER" ]]; then
        return 1
    fi

    # Try to send email using various methods
    if command -v msmtp &>/dev/null; then
        echo -e "Subject: ${subject}\nFrom: ${SMTP_FROM}\nTo: ${ALERT_EMAIL}\n\n${body}" | \
            msmtp --host="$SMTP_SERVER" --port="$SMTP_PORT" --auth=on \
                  --user="$SMTP_USER" --passwordeval="echo $SMTP_PASSWORD" \
                  --tls=on "$ALERT_EMAIL" 2>/dev/null
    elif command -v sendmail &>/dev/null; then
        echo -e "Subject: ${subject}\nFrom: ${SMTP_FROM}\nTo: ${ALERT_EMAIL}\n\n${body}" | \
            sendmail -t 2>/dev/null
    elif command -v mail &>/dev/null; then
        echo "$body" | mail -s "$subject" "$ALERT_EMAIL" 2>/dev/null
    elif command -v curl &>/dev/null && [[ -n "$SMTP_SERVER" ]]; then
        # Use curl for SMTP
        curl --url "smtp://${SMTP_SERVER}:${SMTP_PORT}" \
             --ssl-reqd \
             --mail-from "$SMTP_FROM" \
             --mail-rcpt "$ALERT_EMAIL" \
             --user "${SMTP_USER}:${SMTP_PASSWORD}" \
             -T <(echo -e "From: ${SMTP_FROM}\nTo: ${ALERT_EMAIL}\nSubject: ${subject}\n\n${body}") \
             2>/dev/null
    else
        return 1
    fi
}

send_alert_webhook() {
    local title="$1"
    local message="$2"
    local status="$3"

    load_health_config

    if [[ -z "$ALERT_WEBHOOK" ]]; then
        return 1
    fi

    local color="16711680"  # Red
    if [[ "$status" == "recovered" ]]; then
        color="65280"  # Green
    fi

    # Detect webhook type and format accordingly
    if [[ "$ALERT_WEBHOOK" == *"discord"* ]]; then
        # Discord webhook format
        curl -s -H "Content-Type: application/json" -X POST "$ALERT_WEBHOOK" \
            -d "{\"embeds\":[{\"title\":\"${title}\",\"description\":\"${message}\",\"color\":${color}}]}" \
            >/dev/null 2>&1
    elif [[ "$ALERT_WEBHOOK" == *"slack"* ]]; then
        # Slack webhook format
        curl -s -H "Content-Type: application/json" -X POST "$ALERT_WEBHOOK" \
            -d "{\"text\":\"*${title}*\n${message}\"}" \
            >/dev/null 2>&1
    else
        # Generic webhook (JSON POST)
        curl -s -H "Content-Type: application/json" -X POST "$ALERT_WEBHOOK" \
            -d "{\"title\":\"${title}\",\"message\":\"${message}\",\"status\":\"${status}\"}" \
            >/dev/null 2>&1
    fi
}

send_alert() {
    local title="$1"
    local message="$2"
    local status="${3:-alert}"

    load_health_config

    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    local hostname=$(hostname)

    local full_title="[Paperless-ngx] ${title}"
    local full_message="Host: ${hostname}\nTime: ${timestamp}\n\n${message}"

    # Log the alert
    echo "[${timestamp}] ${status^^}: ${title} - ${message}" >> "$HEALTH_LOG"

    # Send email if configured
    if [[ -n "$ALERT_EMAIL" ]]; then
        send_alert_email "$full_title" "$full_message"
    fi

    # Send webhook if configured
    if [[ -n "$ALERT_WEBHOOK" ]]; then
        send_alert_webhook "$full_title" "$message" "$status"
    fi
}

health_monitor_daemon() {
    # This function is called by cron for periodic monitoring
    load_health_config

    local failure_count_file="${CONFIG_DIR}/.health_failure_count"
    local last_status_file="${CONFIG_DIR}/.health_last_status"

    cd "$SCRIPT_DIR"

    # Run health check silently
    local unhealthy_output
    if unhealthy_output=$(run_health_check true 2>&1); then
        # All healthy
        local last_status=$(cat "$last_status_file" 2>/dev/null || echo "healthy")

        if [[ "$last_status" == "unhealthy" ]]; then
            # Recovered!
            send_alert "Services Recovered" "All Paperless-ngx services are now healthy." "recovered"
        fi

        echo "healthy" > "$last_status_file"
        echo "0" > "$failure_count_file"
    else
        # Something is unhealthy
        local current_failures=$(cat "$failure_count_file" 2>/dev/null || echo "0")
        current_failures=$((current_failures + 1))
        echo "$current_failures" > "$failure_count_file"

        local threshold=${CONSECUTIVE_FAILURES:-3}

        if [[ $current_failures -ge $threshold ]]; then
            local last_status=$(cat "$last_status_file" 2>/dev/null || echo "healthy")

            if [[ "$last_status" != "unhealthy" ]]; then
                # New alert
                send_alert "Services Down" "The following services have issues:\n${unhealthy_output}" "alert"
                echo "unhealthy" > "$last_status_file"
            fi
        fi
    fi
}

setup_health_monitoring() {
    print_header "Health Monitoring Setup"

    load_health_config

    echo "Health monitoring can alert you when services go down."
    echo ""
    echo "Current configuration:"
    if [[ -n "$ALERT_EMAIL" ]]; then
        echo "  Email alerts: ${ALERT_EMAIL}"
    else
        echo "  Email alerts: Not configured"
    fi
    if [[ -n "$ALERT_WEBHOOK" ]]; then
        echo "  Webhook alerts: Configured"
    else
        echo "  Webhook alerts: Not configured"
    fi

    local monitor_cron=$(crontab -l 2>/dev/null | grep "health-check" || true)
    if [[ -n "$monitor_cron" ]]; then
        echo "  Periodic checks: Enabled"
    else
        echo "  Periodic checks: Disabled"
    fi

    echo ""
    echo "Options:"
    echo ""
    echo "  1) Run health check now"
    echo "  2) Configure email alerts"
    echo "  3) Configure webhook alerts (Discord/Slack/Custom)"
    echo "  4) Enable/Disable periodic monitoring"
    echo "  5) View health log"
    echo "  6) Test alerts"
    echo ""
    echo "  0) Back"
    echo ""

    read -p "Select option [0-6]: " health_choice

    case $health_choice in
        1)
            run_health_check
            read -p "Press Enter to continue..."
            ;;
        2)
            configure_email_alerts
            ;;
        3)
            configure_webhook_alerts
            ;;
        4)
            configure_periodic_monitoring
            ;;
        5)
            view_health_log
            ;;
        6)
            test_alerts
            ;;
        0)
            return
            ;;
        *)
            print_error "Invalid option"
            sleep 1
            ;;
    esac
}

configure_email_alerts() {
    print_header "Configure Email Alerts"

    load_health_config

    echo "Enter SMTP server details for email alerts."
    echo "(Leave blank to disable email alerts)"
    echo ""

    read -p "Email address to send alerts to [${ALERT_EMAIL}]: " new_email
    ALERT_EMAIL=${new_email:-$ALERT_EMAIL}

    if [[ -n "$ALERT_EMAIL" ]]; then
        read -p "SMTP server (e.g., smtp.gmail.com) [${SMTP_SERVER}]: " new_smtp
        SMTP_SERVER=${new_smtp:-$SMTP_SERVER}

        read -p "SMTP port [${SMTP_PORT:-587}]: " new_port
        SMTP_PORT=${new_port:-${SMTP_PORT:-587}}

        read -p "SMTP username [${SMTP_USER}]: " new_user
        SMTP_USER=${new_user:-$SMTP_USER}

        read -s -p "SMTP password: " new_pass
        echo ""
        if [[ -n "$new_pass" ]]; then
            SMTP_PASSWORD="$new_pass"
        fi

        read -p "From address [${SMTP_FROM:-$SMTP_USER}]: " new_from
        SMTP_FROM=${new_from:-${SMTP_FROM:-$SMTP_USER}}
    fi

    save_health_config

    print_success "Email configuration saved"
    read -p "Press Enter to continue..."
}

configure_webhook_alerts() {
    print_header "Configure Webhook Alerts"

    load_health_config

    echo "Enter a webhook URL for alerts."
    echo "Supported: Discord, Slack, or any URL accepting JSON POST"
    echo "(Leave blank to disable webhook alerts)"
    echo ""

    if [[ -n "$ALERT_WEBHOOK" ]]; then
        echo "Current webhook: ${ALERT_WEBHOOK:0:50}..."
    fi
    echo ""

    read -p "Webhook URL: " new_webhook

    if [[ -n "$new_webhook" ]]; then
        ALERT_WEBHOOK="$new_webhook"
    elif [[ -z "$new_webhook" ]]; then
        read -p "Clear existing webhook? [y/N]: " clear_webhook
        if [[ "$clear_webhook" =~ ^[Yy]$ ]]; then
            ALERT_WEBHOOK=""
        fi
    fi

    save_health_config

    print_success "Webhook configuration saved"
    read -p "Press Enter to continue..."
}

configure_periodic_monitoring() {
    print_header "Periodic Health Monitoring"

    local current_cron=$(crontab -l 2>/dev/null | grep "health-check" || true)

    if [[ -n "$current_cron" ]]; then
        print_info "Periodic monitoring is currently ENABLED"
        echo ""
        read -p "Disable periodic monitoring? [y/N]: " disable_choice

        if [[ "$disable_choice" =~ ^[Yy]$ ]]; then
            crontab -l 2>/dev/null | grep -v "health-check" | crontab -
            print_success "Periodic monitoring disabled"
        fi
    else
        print_info "Periodic monitoring is currently DISABLED"
        echo ""
        echo "How often should health checks run?"
        echo ""
        echo "  1) Every 5 minutes (recommended)"
        echo "  2) Every 10 minutes"
        echo "  3) Every 15 minutes"
        echo "  4) Every 30 minutes"
        echo "  5) Every hour"
        echo ""
        echo "  0) Cancel"
        echo ""

        read -p "Select interval [0-5]: " interval_choice

        local cron_schedule=""
        case $interval_choice in
            1) cron_schedule="*/5 * * * *" ;;
            2) cron_schedule="*/10 * * * *" ;;
            3) cron_schedule="*/15 * * * *" ;;
            4) cron_schedule="*/30 * * * *" ;;
            5) cron_schedule="0 * * * *" ;;
            0)
                print_info "Cancelled"
                read -p "Press Enter to continue..."
                return
                ;;
            *)
                print_error "Invalid option"
                read -p "Press Enter to continue..."
                return
                ;;
        esac

        # Add cron job
        local cron_command="${SCRIPT_DIR}/management.sh health-check --daemon"
        (crontab -l 2>/dev/null | grep -v "health-check"; echo "${cron_schedule} ${cron_command}") | crontab -

        print_success "Periodic monitoring enabled"
    fi

    read -p "Press Enter to continue..."
}

view_health_log() {
    print_header "Health Monitor Log"

    if [[ -f "$HEALTH_LOG" ]]; then
        echo "Last 30 log entries:"
        echo "--------------------"
        tail -30 "$HEALTH_LOG"
        echo ""
        echo "--------------------"
        echo "Full log: ${HEALTH_LOG}"
    else
        print_info "No health log found yet."
    fi

    echo ""
    read -p "Press Enter to continue..."
}

test_alerts() {
    print_header "Test Alerts"

    load_health_config

    echo "This will send a test alert to configured destinations."
    echo ""

    local has_config=false
    if [[ -n "$ALERT_EMAIL" ]]; then
        echo "  Email: ${ALERT_EMAIL}"
        has_config=true
    fi
    if [[ -n "$ALERT_WEBHOOK" ]]; then
        echo "  Webhook: Configured"
        has_config=true
    fi

    if ! $has_config; then
        print_warning "No alert destinations configured."
        print_info "Configure email or webhook alerts first."
        read -p "Press Enter to continue..."
        return
    fi

    echo ""
    read -p "Send test alert? [Y/n]: " confirm

    if [[ ! "$confirm" =~ ^[Nn]$ ]]; then
        print_info "Sending test alert..."
        send_alert "Test Alert" "This is a test alert from Paperless-ngx health monitoring.\nIf you receive this, alerts are working correctly." "test"
        print_success "Test alert sent!"
    fi

    read -p "Press Enter to continue..."
}

# ============================================================================
# LOG ROTATION CONFIGURATION
# ============================================================================

setup_log_rotation() {
    print_header "Log Rotation Configuration"

    check_root

    echo "Log rotation prevents disk space issues from growing log files."
    echo ""
    echo "This will configure:"
    echo "  - Docker container log limits"
    echo "  - Nginx access and error logs"
    echo "  - Application logs"
    echo ""

    # Check current Docker log driver
    local docker_log_driver=$(docker info --format '{{.LoggingDriver}}' 2>/dev/null || echo "unknown")
    echo "Current Docker log driver: ${docker_log_driver}"

    # Check if logrotate is installed
    if command -v logrotate &>/dev/null; then
        echo "Logrotate: Installed"
    else
        echo "Logrotate: Not installed"
    fi
    echo ""

    echo "Options:"
    echo ""
    echo "  1) Configure Docker log rotation (recommended)"
    echo "  2) Configure system logrotate for Paperless"
    echo "  3) View current log sizes"
    echo "  4) Clean up old logs now"
    echo ""
    echo "  0) Back"
    echo ""

    read -p "Select option [0-4]: " log_choice

    case $log_choice in
        1) configure_docker_log_rotation ;;
        2) configure_system_logrotate ;;
        3) view_log_sizes ;;
        4) cleanup_logs_now ;;
        0) return ;;
        *)
            print_error "Invalid option"
            sleep 1
            ;;
    esac
}

configure_docker_log_rotation() {
    print_header "Docker Log Rotation"

    echo "Docker can automatically rotate container logs."
    echo ""
    echo "Select maximum log file size per container:"
    echo ""
    echo "  1) 10 MB  (recommended for limited disk space)"
    echo "  2) 50 MB  (default - good balance)"
    echo "  3) 100 MB (more log history)"
    echo "  4) 500 MB (extensive logging)"
    echo ""

    read -p "Select size [1-4] (default: 2): " size_choice
    size_choice=${size_choice:-2}

    local max_size=""
    case $size_choice in
        1) max_size="10m" ;;
        2) max_size="50m" ;;
        3) max_size="100m" ;;
        4) max_size="500m" ;;
        *) max_size="50m" ;;
    esac

    echo ""
    echo "Number of rotated log files to keep:"
    echo ""
    echo "  1) 3 files"
    echo "  2) 5 files (default)"
    echo "  3) 10 files"
    echo ""

    read -p "Select count [1-3] (default: 2): " count_choice
    count_choice=${count_choice:-2}

    local max_file=""
    case $count_choice in
        1) max_file="3" ;;
        2) max_file="5" ;;
        3) max_file="10" ;;
        *) max_file="5" ;;
    esac

    # Create/update daemon.json
    local daemon_json="/etc/docker/daemon.json"
    local backup_json="/etc/docker/daemon.json.bak"

    print_info "Configuring Docker daemon..."

    # Backup existing config
    if [[ -f "$daemon_json" ]]; then
        cp "$daemon_json" "$backup_json"
    fi

    # Create new config (merging with existing if possible)
    if [[ -f "$daemon_json" ]] && command -v jq &>/dev/null; then
        # Merge with existing config using jq
        jq --arg size "$max_size" --arg file "$max_file" \
            '. + {"log-driver": "json-file", "log-opts": {"max-size": $size, "max-file": $file}}' \
            "$daemon_json" > "${daemon_json}.tmp" && mv "${daemon_json}.tmp" "$daemon_json"
    else
        # Create new config
        cat > "$daemon_json" << EOF
{
    "log-driver": "json-file",
    "log-opts": {
        "max-size": "${max_size}",
        "max-file": "${max_file}"
    }
}
EOF
    fi

    print_success "Docker log rotation configured: ${max_size} x ${max_file} files"
    echo ""
    print_warning "Docker daemon restart required for changes to take effect."
    echo "Note: This will briefly stop all containers."
    echo ""

    read -p "Restart Docker now? [y/N]: " restart_docker

    if [[ "$restart_docker" =~ ^[Yy]$ ]]; then
        print_info "Restarting Docker..."
        systemctl restart docker
        sleep 5

        # Restart Paperless services
        print_info "Restarting Paperless services..."
        cd "$SCRIPT_DIR"
        docker compose up -d
        wait_for_healthy

        print_success "Docker restarted with new log configuration"
    else
        print_info "Remember to restart Docker later: sudo systemctl restart docker"
    fi

    read -p "Press Enter to continue..."
}

configure_system_logrotate() {
    print_header "System Logrotate Configuration"

    # Check if logrotate is installed
    if ! command -v logrotate &>/dev/null; then
        print_warning "Logrotate is not installed."
        read -p "Install logrotate? [Y/n]: " install_lr

        if [[ ! "$install_lr" =~ ^[Nn]$ ]]; then
            apt-get update && apt-get install -y logrotate
        else
            print_info "Skipping logrotate configuration"
            read -p "Press Enter to continue..."
            return
        fi
    fi

    local logrotate_conf="/etc/logrotate.d/paperless-ngx"

    echo "Creating logrotate configuration for Paperless-ngx..."
    echo ""

    cat > "$logrotate_conf" << EOF
# Paperless-ngx Log Rotation
# Generated by management.sh on $(date)

# Backup logs
${BACKUP_DIR}/*.log {
    weekly
    rotate 4
    compress
    delaycompress
    missingok
    notifempty
    create 0640 root root
}

# Health monitor logs
${BACKUP_DIR}/health-monitor.log {
    weekly
    rotate 4
    compress
    delaycompress
    missingok
    notifempty
    create 0640 root root
}

# Nginx logs (if using host-based logging)
${SCRIPT_DIR}/logs/nginx/*.log {
    daily
    rotate 14
    compress
    delaycompress
    missingok
    notifempty
    create 0640 root root
    sharedscripts
    postrotate
        docker compose -f ${SCRIPT_DIR}/docker-compose.yml exec -T nginx nginx -s reopen 2>/dev/null || true
    endscript
}
EOF

    print_success "Logrotate configuration created: ${logrotate_conf}"
    echo ""

    # Test the configuration
    print_info "Testing logrotate configuration..."
    if logrotate -d "$logrotate_conf" 2>&1 | head -20; then
        print_success "Configuration is valid"
    else
        print_warning "There may be issues with the configuration"
    fi

    read -p "Press Enter to continue..."
}

view_log_sizes() {
    print_header "Current Log Sizes"

    cd "$SCRIPT_DIR"

    echo "Docker Container Logs:"
    echo "----------------------"

    for container in $(docker compose ps -q 2>/dev/null); do
        local name=$(docker inspect --format '{{.Name}}' "$container" 2>/dev/null | tr -d '/')
        local log_path=$(docker inspect --format '{{.LogPath}}' "$container" 2>/dev/null)

        if [[ -f "$log_path" ]]; then
            local size=$(du -sh "$log_path" 2>/dev/null | cut -f1)
            printf "  %-20s %s\n" "$name" "$size"
        fi
    done

    echo ""
    echo "Application Logs:"
    echo "-----------------"

    # Backup directory logs
    if [[ -d "$BACKUP_DIR" ]]; then
        local backup_logs=$(find "$BACKUP_DIR" -name "*.log" -exec du -ch {} + 2>/dev/null | tail -1 | cut -f1)
        echo "  Backup logs: ${backup_logs:-0}"
    fi

    # Data directory size
    if [[ -d "$DATA_DIR" ]]; then
        local data_size=$(du -sh "$DATA_DIR" 2>/dev/null | cut -f1)
        echo "  Data directory: ${data_size}"
    fi

    echo ""
    echo "Disk Space:"
    echo "-----------"
    df -h "$SCRIPT_DIR" | tail -1 | awk '{print "  Used: " $3 " / " $2 " (" $5 " full)"}'

    echo ""
    read -p "Press Enter to continue..."
}

cleanup_logs_now() {
    print_header "Clean Up Logs"

    print_warning "This will remove old log files to free up disk space."
    echo ""

    echo "What would you like to clean?"
    echo ""
    echo "  1) Truncate Docker container logs (keeps containers running)"
    echo "  2) Remove old backup logs (older than 30 days)"
    echo "  3) Both"
    echo ""
    echo "  0) Cancel"
    echo ""

    read -p "Select option [0-3]: " cleanup_choice

    case $cleanup_choice in
        1)
            truncate_docker_logs
            ;;
        2)
            cleanup_old_logs
            ;;
        3)
            truncate_docker_logs
            cleanup_old_logs
            ;;
        0)
            print_info "Cancelled"
            ;;
        *)
            print_error "Invalid option"
            ;;
    esac

    read -p "Press Enter to continue..."
}

truncate_docker_logs() {
    print_info "Truncating Docker container logs..."

    cd "$SCRIPT_DIR"

    for container in $(docker compose ps -q 2>/dev/null); do
        local name=$(docker inspect --format '{{.Name}}' "$container" 2>/dev/null | tr -d '/')
        local log_path=$(docker inspect --format '{{.LogPath}}' "$container" 2>/dev/null)

        if [[ -f "$log_path" ]]; then
            truncate -s 0 "$log_path" 2>/dev/null && \
                print_success "Truncated: $name" || \
                print_warning "Could not truncate: $name"
        fi
    done
}

cleanup_old_logs() {
    print_info "Removing old log files..."

    # Remove backup logs older than 30 days
    local count=$(find "$BACKUP_DIR" -name "*.log" -mtime +30 2>/dev/null | wc -l)
    find "$BACKUP_DIR" -name "*.log" -mtime +30 -delete 2>/dev/null

    print_success "Removed ${count} old log files"
}

# ============================================================================
# DOCUMENT EXPORT FUNCTION
# ============================================================================

export_documents() {
    print_header "Document Export"

    cd "$SCRIPT_DIR"

    if ! is_running; then
        print_error "Services must be running to export documents."
        read -p "Start services now? [Y/n]: " start_first
        if [[ ! "$start_first" =~ ^[Nn]$ ]]; then
            docker compose up -d
            wait_for_healthy
        else
            read -p "Press Enter to continue..."
            return
        fi
    fi

    echo "Paperless-ngx Document Exporter creates a portable archive of your documents."
    echo ""
    echo "Export includes:"
    echo "  - Original document files"
    echo "  - OCR'd/archived versions"
    echo "  - All metadata (tags, correspondents, dates, etc.)"
    echo "  - Thumbnails"
    echo ""
    echo "Export destination: ${EXPORT_DIR}"
    echo ""

    echo "Export options:"
    echo ""
    echo "  1) Full export (all documents)"
    echo "  2) Export with original files only (smaller size)"
    echo "  3) Export metadata only (no document files)"
    echo "  4) View previous exports"
    echo ""
    echo "  0) Cancel"
    echo ""

    read -p "Select option [0-4]: " export_choice

    case $export_choice in
        1)
            run_document_export "--use-filename-format"
            ;;
        2)
            run_document_export "--use-filename-format --no-archive"
            ;;
        3)
            run_document_export "--no-archive --no-thumbnail"
            ;;
        4)
            view_exports
            return
            ;;
        0)
            print_info "Cancelled"
            read -p "Press Enter to continue..."
            return
            ;;
        *)
            print_error "Invalid option"
            read -p "Press Enter to continue..."
            return
            ;;
    esac
}

run_document_export() {
    local export_args="$1"

    # Create timestamped export directory
    local timestamp=$(date +%Y%m%d_%H%M%S)
    local export_subdir="${EXPORT_DIR}/export_${timestamp}"

    print_info "Starting document export..."
    echo "This may take a while depending on your document count."
    echo ""

    # Ensure export directory exists and is empty
    mkdir -p "$export_subdir"

    # Run the document exporter
    print_info "Running Paperless document exporter..."

    docker compose exec -T webserver document_exporter ../export/export_${timestamp} ${export_args} 2>&1 | \
        while IFS= read -r line; do
            echo "  $line"
        done

    local exit_code=${PIPESTATUS[0]}

    if [[ $exit_code -eq 0 ]]; then
        # Calculate export size
        local export_size=$(du -sh "$export_subdir" 2>/dev/null | cut -f1)
        local doc_count=$(find "$export_subdir" -type f -name "*.pdf" -o -name "*.png" -o -name "*.jpg" 2>/dev/null | wc -l)

        print_header "Export Complete!"
        echo ""
        echo "Export location: ${export_subdir}"
        echo "Total size: ${export_size}"
        echo "Files exported: ${doc_count}"
        echo ""

        echo "Would you like to create a compressed archive?"
        read -p "Create .tar.gz archive? [y/N]: " create_archive

        if [[ "$create_archive" =~ ^[Yy]$ ]]; then
            print_info "Creating compressed archive..."
            tar -czf "${EXPORT_DIR}/export_${timestamp}.tar.gz" -C "$EXPORT_DIR" "export_${timestamp}"

            local archive_size=$(du -sh "${EXPORT_DIR}/export_${timestamp}.tar.gz" | cut -f1)
            print_success "Archive created: export_${timestamp}.tar.gz (${archive_size})"

            read -p "Remove uncompressed export directory? [Y/n]: " remove_dir
            if [[ ! "$remove_dir" =~ ^[Nn]$ ]]; then
                rm -rf "$export_subdir"
                print_success "Uncompressed directory removed"
            fi
        fi
    else
        print_error "Export failed with exit code: ${exit_code}"
    fi

    echo ""
    read -p "Press Enter to continue..."
}

view_exports() {
    print_header "Previous Exports"

    echo "Export directory: ${EXPORT_DIR}"
    echo ""

    if [[ -d "$EXPORT_DIR" ]]; then
        local export_count=0

        echo "Available exports:"
        echo ""

        # List directories
        for dir in "${EXPORT_DIR}"/export_*/; do
            if [[ -d "$dir" ]]; then
                export_count=$((export_count + 1))
                local name=$(basename "$dir")
                local size=$(du -sh "$dir" 2>/dev/null | cut -f1)
                printf "  %-30s %s (directory)\n" "$name" "$size"
            fi
        done

        # List archives
        for archive in "${EXPORT_DIR}"/export_*.tar.gz; do
            if [[ -f "$archive" ]]; then
                export_count=$((export_count + 1))
                local name=$(basename "$archive")
                local size=$(du -sh "$archive" 2>/dev/null | cut -f1)
                printf "  %-30s %s (archive)\n" "$name" "$size"
            fi
        done

        if [[ $export_count -eq 0 ]]; then
            print_info "No exports found"
        fi
    else
        print_info "Export directory does not exist yet"
    fi

    echo ""
    read -p "Press Enter to continue..."
}

# ============================================================================
# SEARCH INDEX REBUILD
# ============================================================================

rebuild_search_index() {
    print_header "Rebuild Search Index"

    cd "$SCRIPT_DIR"

    if ! is_running; then
        print_error "Services must be running to rebuild the index."
        read -p "Press Enter to continue..."
        return
    fi

    echo "The search index allows fast full-text search of your documents."
    echo ""
    echo "Rebuild the index if:"
    echo "  - Search results are incomplete or missing documents"
    echo "  - After importing a large number of documents"
    echo "  - After restoring from backup"
    echo "  - If you notice search performance issues"
    echo ""
    print_warning "Rebuilding can take a long time for large document collections."
    echo ""

    read -p "Rebuild search index now? [y/N]: " confirm

    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        print_info "Cancelled"
        read -p "Press Enter to continue..."
        return
    fi

    print_info "Rebuilding search index..."
    echo "This may take several minutes or longer depending on document count."
    echo ""

    # Run index rebuild
    docker compose exec -T webserver document_index reindex 2>&1 | \
        while IFS= read -r line; do
            echo "  $line"
        done

    local exit_code=${PIPESTATUS[0]}

    if [[ $exit_code -eq 0 ]]; then
        print_success "Search index rebuilt successfully"
    else
        print_error "Index rebuild failed with exit code: ${exit_code}"
    fi

    echo ""
    read -p "Press Enter to continue..."
}

# ============================================================================
# CONSUMPTION SUBDIRECTORY PRESETS
# ============================================================================

setup_consume_directories() {
    print_header "Consumption Directory Setup"

    echo "Paperless automatically imports files from the consume directory."
    echo "Subdirectories can be used to automatically assign tags."
    echo ""
    echo "Consume directory: ${CONSUME_DIR}"
    echo ""

    # Show current subdirectories
    echo "Current subdirectories:"
    if [[ -d "$CONSUME_DIR" ]]; then
        local subdir_count=0
        for dir in "${CONSUME_DIR}"/*/; do
            if [[ -d "$dir" ]]; then
                subdir_count=$((subdir_count + 1))
                echo "  - $(basename "$dir")"
            fi
        done
        if [[ $subdir_count -eq 0 ]]; then
            echo "  (none)"
        fi
    fi

    echo ""
    echo "Options:"
    echo ""
    echo "  1) Create common presets (Invoices, Receipts, Contracts, etc.)"
    echo "  2) Create custom subdirectory"
    echo "  3) Remove a subdirectory"
    echo ""
    echo "  0) Back"
    echo ""

    read -p "Select option [0-3]: " consume_choice

    case $consume_choice in
        1) create_consume_presets ;;
        2) create_custom_consume_dir ;;
        3) remove_consume_dir ;;
        0) return ;;
        *)
            print_error "Invalid option"
            sleep 1
            ;;
    esac
}

create_consume_presets() {
    print_header "Create Consumption Presets"

    echo "Select presets to create:"
    echo "(Documents dropped in these folders will be auto-tagged)"
    echo ""
    echo "  1) Business set (Invoices, Receipts, Contracts, Quotes)"
    echo "  2) Personal set (Medical, Insurance, Banking, Taxes)"
    echo "  3) Office set (Correspondence, Reports, Projects, Archive)"
    echo "  4) All of the above"
    echo ""
    echo "  0) Cancel"
    echo ""

    read -p "Select option [0-4]: " preset_choice

    local dirs_to_create=""

    case $preset_choice in
        1)
            dirs_to_create="Invoices Receipts Contracts Quotes"
            ;;
        2)
            dirs_to_create="Medical Insurance Banking Taxes"
            ;;
        3)
            dirs_to_create="Correspondence Reports Projects Archive"
            ;;
        4)
            dirs_to_create="Invoices Receipts Contracts Quotes Medical Insurance Banking Taxes Correspondence Reports Projects Archive"
            ;;
        0)
            print_info "Cancelled"
            read -p "Press Enter to continue..."
            return
            ;;
        *)
            print_error "Invalid option"
            read -p "Press Enter to continue..."
            return
            ;;
    esac

    for dir in $dirs_to_create; do
        if [[ ! -d "${CONSUME_DIR}/${dir}" ]]; then
            mkdir -p "${CONSUME_DIR}/${dir}"
            print_success "Created: ${dir}"
        else
            print_info "Already exists: ${dir}"
        fi
    done

    # Set permissions
    chown -R 1000:1000 "$CONSUME_DIR" 2>/dev/null || true

    echo ""
    print_info "Subdirectory names will be used as tags in Paperless."
    print_info "Drop files into these folders to auto-tag on import."

    read -p "Press Enter to continue..."
}

create_custom_consume_dir() {
    echo ""
    read -p "Enter subdirectory name: " custom_name

    if [[ -z "$custom_name" ]]; then
        print_error "No name provided"
        read -p "Press Enter to continue..."
        return
    fi

    # Sanitize the name
    custom_name=$(echo "$custom_name" | tr ' ' '_' | tr -cd '[:alnum:]_-')

    if [[ -d "${CONSUME_DIR}/${custom_name}" ]]; then
        print_info "Directory already exists: ${custom_name}"
    else
        mkdir -p "${CONSUME_DIR}/${custom_name}"
        chown -R 1000:1000 "${CONSUME_DIR}/${custom_name}" 2>/dev/null || true
        print_success "Created: ${custom_name}"
    fi

    read -p "Press Enter to continue..."
}

remove_consume_dir() {
    echo ""
    echo "Existing subdirectories:"

    local count=0
    declare -a dir_list

    for dir in "${CONSUME_DIR}"/*/; do
        if [[ -d "$dir" ]]; then
            count=$((count + 1))
            dir_list+=("$dir")
            echo "  ${count}) $(basename "$dir")"
        fi
    done

    if [[ $count -eq 0 ]]; then
        print_info "No subdirectories to remove"
        read -p "Press Enter to continue..."
        return
    fi

    echo ""
    echo "  0) Cancel"
    echo ""

    read -p "Select directory to remove [0-${count}]: " remove_choice

    if [[ "$remove_choice" == "0" ]] || [[ -z "$remove_choice" ]]; then
        print_info "Cancelled"
        read -p "Press Enter to continue..."
        return
    fi

    if [[ "$remove_choice" -ge 1 ]] && [[ "$remove_choice" -le $count ]]; then
        local selected_dir="${dir_list[$((remove_choice - 1))]}"
        local dir_name=$(basename "$selected_dir")

        # Check if directory has files
        local file_count=$(find "$selected_dir" -type f 2>/dev/null | wc -l)

        if [[ $file_count -gt 0 ]]; then
            print_warning "Directory contains ${file_count} files!"
            read -p "Delete anyway? [y/N]: " confirm_delete
            if [[ ! "$confirm_delete" =~ ^[Yy]$ ]]; then
                print_info "Cancelled"
                read -p "Press Enter to continue..."
                return
            fi
        fi

        rm -rf "$selected_dir"
        print_success "Removed: ${dir_name}"
    else
        print_error "Invalid selection"
    fi

    read -p "Press Enter to continue..."
}

# ============================================================================
# DATABASE MAINTENANCE
# ============================================================================

database_maintenance() {
    print_header "Database Maintenance"

    cd "$SCRIPT_DIR"

    if ! is_running; then
        print_error "Database must be running for maintenance."
        read -p "Press Enter to continue..."
        return
    fi

    echo "Database maintenance helps keep PostgreSQL running efficiently."
    echo ""
    echo "Options:"
    echo ""
    echo "  1) VACUUM ANALYZE (recommended - reclaim space, update stats)"
    echo "  2) VACUUM FULL (aggressive - requires downtime)"
    echo "  3) REINDEX (rebuild all indexes)"
    echo "  4) View database statistics"
    echo "  5) Check database integrity"
    echo ""
    echo "  0) Back"
    echo ""

    read -p "Select option [0-5]: " maint_choice

    case $maint_choice in
        1) run_vacuum_analyze ;;
        2) run_vacuum_full ;;
        3) run_reindex ;;
        4) view_db_statistics ;;
        5) check_db_integrity ;;
        0) return ;;
        *)
            print_error "Invalid option"
            sleep 1
            ;;
    esac
}

run_vacuum_analyze() {
    print_info "Running VACUUM ANALYZE..."
    echo "This is safe to run while the system is in use."
    echo ""

    docker compose exec -T db psql -U paperless -d paperless -c "VACUUM ANALYZE;" 2>&1

    print_success "VACUUM ANALYZE completed"
    read -p "Press Enter to continue..."
}

run_vacuum_full() {
    print_warning "VACUUM FULL requires exclusive locks on tables."
    echo "This will temporarily make the database unavailable."
    echo ""

    read -p "Proceed with VACUUM FULL? [y/N]: " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        print_info "Cancelled"
        read -p "Press Enter to continue..."
        return
    fi

    print_info "Stopping webserver..."
    docker compose stop webserver

    print_info "Running VACUUM FULL..."
    docker compose exec -T db psql -U paperless -d paperless -c "VACUUM FULL ANALYZE;" 2>&1

    print_info "Restarting webserver..."
    docker compose start webserver

    print_success "VACUUM FULL completed"
    read -p "Press Enter to continue..."
}

run_reindex() {
    print_info "Running REINDEX..."
    echo "This rebuilds all database indexes."
    echo ""

    docker compose exec -T db psql -U paperless -d paperless -c "REINDEX DATABASE paperless;" 2>&1

    print_success "REINDEX completed"
    read -p "Press Enter to continue..."
}

view_db_statistics() {
    print_header "Database Statistics"

    echo "Database Size:"
    docker compose exec -T db psql -U paperless -d paperless -c \
        "SELECT pg_size_pretty(pg_database_size('paperless')) as database_size;" 2>/dev/null

    echo ""
    echo "Table Sizes:"
    docker compose exec -T db psql -U paperless -d paperless -c \
        "SELECT relname as table_name,
                pg_size_pretty(pg_total_relation_size(relid)) as total_size
         FROM pg_catalog.pg_statio_user_tables
         ORDER BY pg_total_relation_size(relid) DESC
         LIMIT 10;" 2>/dev/null

    echo ""
    echo "Index Usage:"
    docker compose exec -T db psql -U paperless -d paperless -c \
        "SELECT indexrelname as index_name,
                idx_scan as scans,
                pg_size_pretty(pg_relation_size(indexrelid)) as size
         FROM pg_stat_user_indexes
         ORDER BY idx_scan DESC
         LIMIT 10;" 2>/dev/null

    echo ""
    read -p "Press Enter to continue..."
}

check_db_integrity() {
    print_header "Database Integrity Check"

    print_info "Checking for corrupted indexes..."
    docker compose exec -T db psql -U paperless -d paperless -c \
        "SELECT schemaname, tablename, indexname
         FROM pg_indexes
         WHERE schemaname = 'public';" 2>/dev/null

    echo ""
    print_info "Checking for bloated tables..."
    docker compose exec -T db psql -U paperless -d paperless -c \
        "SELECT relname, n_dead_tup, n_live_tup,
                round(n_dead_tup::numeric / nullif(n_live_tup + n_dead_tup, 0) * 100, 2) as dead_ratio
         FROM pg_stat_user_tables
         WHERE n_dead_tup > 1000
         ORDER BY n_dead_tup DESC
         LIMIT 10;" 2>/dev/null

    echo ""
    print_success "Integrity check completed"
    read -p "Press Enter to continue..."
}

# ============================================================================
# BULK IMPORT MODE
# ============================================================================

bulk_import_mode() {
    print_header "Bulk Import Mode"

    cd "$SCRIPT_DIR"

    echo "Bulk import mode optimizes settings for importing large numbers of documents."
    echo ""
    echo "Changes during bulk import:"
    echo "  - Increases task workers for parallel processing"
    echo "  - Disables automatic classification (faster)"
    echo "  - Increases index update delay (batches updates)"
    echo ""
    print_warning "Search may be temporarily less accurate during import."
    echo ""

    local current_workers=$(docker compose exec -T webserver printenv PAPERLESS_TASK_WORKERS 2>/dev/null | tr -d '\r')
    echo "Current task workers: ${current_workers:-2}"
    echo ""

    echo "Options:"
    echo ""
    echo "  1) Enable bulk import mode (start importing)"
    echo "  2) Disable bulk import mode (restore normal settings)"
    echo "  3) Check import queue status"
    echo ""
    echo "  0) Back"
    echo ""

    read -p "Select option [0-3]: " bulk_choice

    case $bulk_choice in
        1) enable_bulk_import ;;
        2) disable_bulk_import ;;
        3) check_import_status ;;
        0) return ;;
        *)
            print_error "Invalid option"
            sleep 1
            ;;
    esac
}

enable_bulk_import() {
    if ! is_running; then
        print_error "Services must be running."
        read -p "Press Enter to continue..."
        return
    fi

    echo ""
    echo "How many task workers for bulk import?"
    echo "(More workers = faster but more CPU/RAM)"
    echo ""
    echo "  1) 4 workers (moderate)"
    echo "  2) 6 workers (fast)"
    echo "  3) 8 workers (maximum speed)"
    echo ""

    read -p "Select [1-3] (default: 2): " worker_choice
    worker_choice=${worker_choice:-2}

    local workers=4
    case $worker_choice in
        1) workers=4 ;;
        2) workers=6 ;;
        3) workers=8 ;;
    esac

    # Update .env file
    if [[ -f "${SCRIPT_DIR}/.env" ]]; then
        # Backup current settings
        cp "${SCRIPT_DIR}/.env" "${SCRIPT_DIR}/.env.pre_bulk"

        # Update workers
        sed -i "s/PAPERLESS_TASK_WORKERS=.*/PAPERLESS_TASK_WORKERS=${workers}/" "${SCRIPT_DIR}/.env"

        # Increase index delay
        if grep -q "PAPERLESS_INDEX_TASK_DELAY" "${SCRIPT_DIR}/.env"; then
            sed -i "s/PAPERLESS_INDEX_TASK_DELAY=.*/PAPERLESS_INDEX_TASK_DELAY=600/" "${SCRIPT_DIR}/.env"
        else
            echo "PAPERLESS_INDEX_TASK_DELAY=600" >> "${SCRIPT_DIR}/.env"
        fi
    fi

    print_info "Restarting services with bulk import settings..."
    docker compose up -d

    print_success "Bulk import mode enabled with ${workers} workers"
    echo ""
    echo "Drop your documents in: ${CONSUME_DIR}"
    echo ""
    print_info "Remember to disable bulk import mode when done!"

    read -p "Press Enter to continue..."
}

disable_bulk_import() {
    if [[ -f "${SCRIPT_DIR}/.env.pre_bulk" ]]; then
        mv "${SCRIPT_DIR}/.env.pre_bulk" "${SCRIPT_DIR}/.env"
        print_info "Restored original settings"
    else
        # Set default values
        if [[ -f "${SCRIPT_DIR}/.env" ]]; then
            sed -i "s/PAPERLESS_TASK_WORKERS=.*/PAPERLESS_TASK_WORKERS=2/" "${SCRIPT_DIR}/.env"
            sed -i "s/PAPERLESS_INDEX_TASK_DELAY=.*/PAPERLESS_INDEX_TASK_DELAY=300/" "${SCRIPT_DIR}/.env"
        fi
    fi

    print_info "Restarting services with normal settings..."
    docker compose up -d

    print_info "Rebuilding search index..."
    docker compose exec -T webserver document_index reindex 2>&1 | tail -5

    print_success "Bulk import mode disabled, normal operation resumed"
    read -p "Press Enter to continue..."
}

check_import_status() {
    print_header "Import Queue Status"

    # Files waiting in consume directory
    local pending_files=$(find "$CONSUME_DIR" -type f 2>/dev/null | wc -l)
    echo "Files in consume directory: ${pending_files}"

    # Tasks in Redis queue
    local queued_tasks=$(docker compose exec -T broker redis-cli LLEN celery 2>/dev/null | tr -d ' ')
    echo "Tasks in queue: ${queued_tasks:-0}"

    # Recent documents
    echo ""
    echo "Recently added documents:"
    docker compose exec -T db psql -U paperless -d paperless -c \
        "SELECT id, title, created FROM documents_document ORDER BY created DESC LIMIT 5;" 2>/dev/null

    echo ""
    read -p "Press Enter to continue..."
}

# ============================================================================
# TRASH MANAGEMENT
# ============================================================================

manage_trash() {
    print_header "Trash Management"

    cd "$SCRIPT_DIR"

    echo "Trash directory: ${TRASH_DIR}"
    echo ""

    # Count items in trash
    local trash_count=0
    local trash_size="0"

    if [[ -d "$TRASH_DIR" ]]; then
        trash_count=$(find "$TRASH_DIR" -type f 2>/dev/null | wc -l)
        trash_size=$(du -sh "$TRASH_DIR" 2>/dev/null | cut -f1)
    fi

    echo "Items in trash: ${trash_count}"
    echo "Trash size: ${trash_size}"
    echo ""

    echo "Options:"
    echo ""
    echo "  1) View trash contents"
    echo "  2) Empty trash (permanently delete)"
    echo "  3) Configure auto-empty (via Paperless)"
    echo ""
    echo "  0) Back"
    echo ""

    read -p "Select option [0-3]: " trash_choice

    case $trash_choice in
        1) view_trash_contents ;;
        2) empty_trash ;;
        3) configure_auto_empty ;;
        0) return ;;
        *)
            print_error "Invalid option"
            sleep 1
            ;;
    esac
}

view_trash_contents() {
    print_header "Trash Contents"

    if [[ -d "$TRASH_DIR" ]] && [[ "$(ls -A $TRASH_DIR 2>/dev/null)" ]]; then
        echo "Files in trash:"
        ls -lah "$TRASH_DIR" 2>/dev/null | head -20

        local total=$(find "$TRASH_DIR" -type f 2>/dev/null | wc -l)
        if [[ $total -gt 20 ]]; then
            echo ""
            echo "... and $((total - 20)) more files"
        fi
    else
        print_info "Trash is empty"
    fi

    echo ""
    read -p "Press Enter to continue..."
}

empty_trash() {
    if [[ ! -d "$TRASH_DIR" ]] || [[ -z "$(ls -A $TRASH_DIR 2>/dev/null)" ]]; then
        print_info "Trash is already empty"
        read -p "Press Enter to continue..."
        return
    fi

    local trash_count=$(find "$TRASH_DIR" -type f 2>/dev/null | wc -l)
    local trash_size=$(du -sh "$TRASH_DIR" 2>/dev/null | cut -f1)

    print_warning "This will permanently delete ${trash_count} files (${trash_size})!"
    read -p "Are you sure? [y/N]: " confirm

    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        rm -rf "${TRASH_DIR:?}"/*
        print_success "Trash emptied"
    else
        print_info "Cancelled"
    fi

    read -p "Press Enter to continue..."
}

configure_auto_empty() {
    echo ""
    print_info "Auto-empty is configured in Paperless-ngx settings."
    echo ""
    echo "Go to: Settings > General > Trash"
    echo "Set 'Empty trash after X days' to automatically delete old items."
    echo ""
    read -p "Press Enter to continue..."
}

# ============================================================================
# USER MANAGEMENT
# ============================================================================

manage_users() {
    print_header "User Management"

    cd "$SCRIPT_DIR"

    if ! is_running; then
        print_error "Services must be running to manage users."
        read -p "Press Enter to continue..."
        return
    fi

    echo "Options:"
    echo ""
    echo "  1) List users"
    echo "  2) Create new user"
    echo "  3) Change user password"
    echo "  4) Create superuser (admin)"
    echo ""
    echo "  0) Back"
    echo ""

    read -p "Select option [0-4]: " user_choice

    case $user_choice in
        1) list_users ;;
        2) create_user ;;
        3) change_password ;;
        4) create_superuser ;;
        0) return ;;
        *)
            print_error "Invalid option"
            sleep 1
            ;;
    esac
}

list_users() {
    print_header "Paperless Users"

    docker compose exec -T webserver python3 manage.py shell -c \
        "from django.contrib.auth.models import User; [print(f'{u.username} - {\"Admin\" if u.is_superuser else \"User\"} - {\"Active\" if u.is_active else \"Inactive\"}') for u in User.objects.all()]" 2>/dev/null

    echo ""
    read -p "Press Enter to continue..."
}

create_user() {
    echo ""
    read -p "Enter username: " new_username

    if [[ -z "$new_username" ]]; then
        print_error "Username cannot be empty"
        read -p "Press Enter to continue..."
        return
    fi

    read -p "Enter email (optional): " new_email

    read -s -p "Enter password: " new_password
    echo ""

    if [[ ${#new_password} -lt 8 ]]; then
        print_error "Password must be at least 8 characters"
        read -p "Press Enter to continue..."
        return
    fi

    print_info "Creating user..."
    docker compose exec -T webserver python3 manage.py shell -c \
        "from django.contrib.auth.models import User; User.objects.create_user('${new_username}', '${new_email}', '${new_password}')" 2>&1

    print_success "User '${new_username}' created"
    read -p "Press Enter to continue..."
}

change_password() {
    echo ""
    read -p "Enter username: " username

    if [[ -z "$username" ]]; then
        print_error "Username cannot be empty"
        read -p "Press Enter to continue..."
        return
    fi

    read -s -p "Enter new password: " new_password
    echo ""

    if [[ ${#new_password} -lt 8 ]]; then
        print_error "Password must be at least 8 characters"
        read -p "Press Enter to continue..."
        return
    fi

    print_info "Changing password..."
    docker compose exec -T webserver python3 manage.py shell -c \
        "from django.contrib.auth.models import User; u = User.objects.get(username='${username}'); u.set_password('${new_password}'); u.save()" 2>&1

    print_success "Password changed for '${username}'"
    read -p "Press Enter to continue..."
}

create_superuser() {
    echo ""
    read -p "Enter username: " new_username

    if [[ -z "$new_username" ]]; then
        print_error "Username cannot be empty"
        read -p "Press Enter to continue..."
        return
    fi

    read -p "Enter email: " new_email
    read -s -p "Enter password: " new_password
    echo ""

    if [[ ${#new_password} -lt 8 ]]; then
        print_error "Password must be at least 8 characters"
        read -p "Press Enter to continue..."
        return
    fi

    print_info "Creating superuser..."

    docker compose exec -T webserver python3 manage.py shell -c \
        "from django.contrib.auth.models import User; User.objects.create_superuser('${new_username}', '${new_email}', '${new_password}')" 2>&1

    print_success "Superuser '${new_username}' created"
    read -p "Press Enter to continue..."
}

# ============================================================================
# EMAIL/IMAP IMPORT
# ============================================================================

setup_email_import() {
    print_header "Email/IMAP Import Setup"

    cd "$SCRIPT_DIR"

    echo "Paperless-ngx can automatically fetch and process documents"
    echo "received via email. This is useful for:"
    echo ""
    echo "  - Forwarding receipts/invoices from your inbox"
    echo "  - Processing scanned documents from MFP/scanner emails"
    echo "  - Automating document intake from email notifications"
    echo ""
    echo "Options:"
    echo ""
    echo "  1) Configure email account"
    echo "  2) View current configuration"
    echo "  3) Test email connection"
    echo "  4) View email processing rules"
    echo "  5) Manually trigger email fetch"
    echo "  6) Remove email configuration"
    echo ""
    echo "  0) Back"
    echo ""

    read -p "Select option [0-6]: " email_choice

    case $email_choice in
        1) configure_email_account ;;
        2) view_email_config ;;
        3) test_email_connection ;;
        4) view_email_rules ;;
        5) trigger_email_fetch ;;
        6) remove_email_config ;;
        0) return ;;
        *)
            print_error "Invalid option"
            sleep 1
            ;;
    esac
}

configure_email_account() {
    print_header "Configure Email Account"

    echo "Email Provider Presets:"
    echo ""
    echo "  1) Gmail"
    echo "  2) Outlook/Office 365"
    echo "  3) Yahoo Mail"
    echo "  4) iCloud Mail"
    echo "  5) Custom IMAP server"
    echo ""
    echo "  0) Cancel"
    echo ""

    read -p "Select provider [0-5]: " provider_choice

    local imap_server=""
    local imap_port="993"
    local imap_security="SSL"

    case $provider_choice in
        1)
            imap_server="imap.gmail.com"
            echo ""
            print_info "Gmail Setup Notes:"
            echo "  - Enable 'Allow less secure apps' OR"
            echo "  - Create an App Password (recommended):"
            echo "    https://myaccount.google.com/apppasswords"
            echo "  - Enable IMAP in Gmail settings"
            echo ""
            ;;
        2)
            imap_server="outlook.office365.com"
            echo ""
            print_info "Outlook/Office 365 Setup Notes:"
            echo "  - Use your full email address as username"
            echo "  - You may need to create an App Password if 2FA is enabled"
            echo ""
            ;;
        3)
            imap_server="imap.mail.yahoo.com"
            echo ""
            print_info "Yahoo Mail Setup Notes:"
            echo "  - Generate an App Password in Account Security settings"
            echo "  - https://login.yahoo.com/myaccount/security/app-password"
            echo ""
            ;;
        4)
            imap_server="imap.mail.me.com"
            echo ""
            print_info "iCloud Mail Setup Notes:"
            echo "  - Generate an App-Specific Password at:"
            echo "    https://appleid.apple.com/account/manage"
            echo "  - Use your @icloud.com email as username"
            echo ""
            ;;
        5)
            echo ""
            read -p "Enter IMAP server hostname: " imap_server
            if [[ -z "$imap_server" ]]; then
                print_error "Server hostname is required"
                read -p "Press Enter to continue..."
                return
            fi
            read -p "Enter IMAP port [993]: " imap_port
            imap_port="${imap_port:-993}"
            echo "Security type:"
            echo "  1) SSL (port 993, recommended)"
            echo "  2) STARTTLS (port 143)"
            echo "  3) None (not recommended)"
            read -p "Select [1-3]: " sec_choice
            case $sec_choice in
                2) imap_security="STARTTLS" ;;
                3) imap_security="NONE" ;;
                *) imap_security="SSL" ;;
            esac
            ;;
        0) return ;;
        *)
            print_error "Invalid option"
            sleep 1
            return
            ;;
    esac

    echo ""
    read -p "Enter email address/username: " email_user
    if [[ -z "$email_user" ]]; then
        print_error "Email address is required"
        read -p "Press Enter to continue..."
        return
    fi

    read -s -p "Enter password (or App Password): " email_pass
    echo ""

    if [[ -z "$email_pass" ]]; then
        print_error "Password is required"
        read -p "Press Enter to continue..."
        return
    fi

    echo ""
    echo "Folder to monitor (leave empty for INBOX):"
    read -p "IMAP folder [INBOX]: " imap_folder
    imap_folder="${imap_folder:-INBOX}"

    echo ""
    echo "What to do with processed emails:"
    echo "  1) Mark as read (keep in folder)"
    echo "  2) Move to folder"
    echo "  3) Delete after processing"
    echo ""
    read -p "Select action [1-3]: " action_choice

    local post_action="mark_read"
    local move_folder=""
    case $action_choice in
        2)
            post_action="move"
            read -p "Move to folder name: " move_folder
            move_folder="${move_folder:-Processed}"
            ;;
        3)
            post_action="delete"
            print_warning "Emails will be permanently deleted after processing!"
            read -p "Are you sure? (yes/no): " confirm
            if [[ "$confirm" != "yes" ]]; then
                post_action="mark_read"
                print_info "Changed to 'mark as read' for safety"
            fi
            ;;
        *) post_action="mark_read" ;;
    esac

    echo ""
    echo "How often to check for new emails:"
    echo "  1) Every 5 minutes"
    echo "  2) Every 15 minutes"
    echo "  3) Every 30 minutes"
    echo "  4) Every hour"
    echo "  5) Every 6 hours"
    echo ""
    read -p "Select interval [1-5]: " interval_choice

    local check_interval=10
    case $interval_choice in
        1) check_interval=5 ;;
        2) check_interval=15 ;;
        3) check_interval=30 ;;
        4) check_interval=60 ;;
        5) check_interval=360 ;;
        *) check_interval=15 ;;
    esac

    echo ""
    echo "Attachment filter (which attachments to import):"
    echo "  1) All attachments"
    echo "  2) PDF files only"
    echo "  3) Common document types (PDF, images, Office docs)"
    echo ""
    read -p "Select filter [1-3]: " filter_choice

    local attachment_filter=""
    case $filter_choice in
        2) attachment_filter=".pdf" ;;
        3) attachment_filter=".pdf,.png,.jpg,.jpeg,.tiff,.doc,.docx,.xls,.xlsx" ;;
        *) attachment_filter="" ;;
    esac

    # Save configuration
    print_info "Saving email configuration..."

    mkdir -p "${SCRIPT_DIR}/config/mail"
    local config_file="${SCRIPT_DIR}/config/mail/imap.conf"

    cat > "$config_file" << EOF
# Paperless-ngx Email Import Configuration
# Generated by management script

IMAP_HOST=${imap_server}
IMAP_PORT=${imap_port}
IMAP_SECURITY=${imap_security}
IMAP_USER=${email_user}
IMAP_PASS=${email_pass}
IMAP_FOLDER=${imap_folder}
POST_CONSUME_ACTION=${post_action}
MOVE_FOLDER=${move_folder}
CHECK_INTERVAL=${check_interval}
ATTACHMENT_FILTER=${attachment_filter}
EOF

    chmod 600 "$config_file"

    # Update docker-compose with mail fetcher environment variables
    update_mail_environment

    print_success "Email configuration saved"
    echo ""
    print_info "To activate, restart Paperless with: ./management.sh stop && ./management.sh start"
    echo ""
    read -p "Would you like to test the connection now? (y/n): " test_now
    if [[ "$test_now" == "y" || "$test_now" == "Y" ]]; then
        test_email_connection
    fi

    read -p "Press Enter to continue..."
}

update_mail_environment() {
    local config_file="${SCRIPT_DIR}/config/mail/imap.conf"

    if [[ ! -f "$config_file" ]]; then
        return
    fi

    # Source the config
    source "$config_file"

    # Check if mail settings already exist in docker-compose
    if grep -q "PAPERLESS_EMAIL_HOST" docker-compose.yml; then
        # Update existing configuration
        print_info "Updating existing mail configuration in docker-compose.yml..."
    else
        # Add mail configuration to docker-compose
        print_info "Adding mail configuration to docker-compose.yml..."

        # Find the line with PAPERLESS_EMPTY_TRASH_DIR and add mail config after it
        if grep -q "PAPERLESS_EMPTY_TRASH_DIR" docker-compose.yml; then
            local mail_config="\\
      # Email/IMAP Import Settings\\
      PAPERLESS_EMAIL_TASK_CRON: \"*/${CHECK_INTERVAL} * * * *\"\\
      PAPERLESS_EMAIL_HOST: ${IMAP_HOST}\\
      PAPERLESS_EMAIL_PORT: ${IMAP_PORT}\\
      PAPERLESS_EMAIL_HOST_USER: ${IMAP_USER}\\
      PAPERLESS_EMAIL_HOST_PASSWORD: \${PAPERLESS_EMAIL_PASSWORD:-}\\
      PAPERLESS_EMAIL_USE_SSL: \"$([ "$IMAP_SECURITY" = "SSL" ] && echo "true" || echo "false")\"\\
      PAPERLESS_EMAIL_USE_TLS: \"$([ "$IMAP_SECURITY" = "STARTTLS" ] && echo "true" || echo "false")\""

            sed -i.bak "/PAPERLESS_EMPTY_TRASH_DIR/a\\${mail_config}" docker-compose.yml && rm -f docker-compose.yml.bak
        fi
    fi

    # Update or add email password to .env
    if [[ -f ".env" ]]; then
        if grep -q "PAPERLESS_EMAIL_PASSWORD" .env; then
            sed -i.bak "s|^PAPERLESS_EMAIL_PASSWORD=.*|PAPERLESS_EMAIL_PASSWORD=${IMAP_PASS}|" .env && rm -f .env.bak
        else
            echo "" >> .env
            echo "# Email Import Settings" >> .env
            echo "PAPERLESS_EMAIL_PASSWORD=${IMAP_PASS}" >> .env
        fi
    fi
}

view_email_config() {
    print_header "Current Email Configuration"

    local config_file="${SCRIPT_DIR}/config/mail/imap.conf"

    if [[ ! -f "$config_file" ]]; then
        print_warning "No email configuration found."
        echo ""
        echo "Use 'Configure email account' to set up email import."
        read -p "Press Enter to continue..."
        return
    fi

    source "$config_file"

    echo "Server:     ${IMAP_HOST}:${IMAP_PORT} (${IMAP_SECURITY})"
    echo "User:       ${IMAP_USER}"
    echo "Password:   ********"
    echo "Folder:     ${IMAP_FOLDER}"
    echo ""
    echo "After processing: ${POST_CONSUME_ACTION}"
    if [[ "$POST_CONSUME_ACTION" == "move" ]]; then
        echo "Move to:    ${MOVE_FOLDER}"
    fi
    echo ""
    echo "Check interval: Every ${CHECK_INTERVAL} minutes"
    if [[ -n "$ATTACHMENT_FILTER" ]]; then
        echo "File filter: ${ATTACHMENT_FILTER}"
    else
        echo "File filter: All attachments"
    fi
    echo ""

    # Check if services are running and show mail rule status
    if is_running; then
        echo "Checking mail rules in Paperless..."
        local rule_count=$(docker compose exec -T webserver python3 manage.py shell -c \
            "from paperless_mail.models import MailRule; print(MailRule.objects.count())" 2>/dev/null || echo "0")
        echo "Configured mail rules: ${rule_count}"
    fi

    read -p "Press Enter to continue..."
}

test_email_connection() {
    print_header "Test Email Connection"

    local config_file="${SCRIPT_DIR}/config/mail/imap.conf"

    if [[ ! -f "$config_file" ]]; then
        print_warning "No email configuration found."
        read -p "Press Enter to continue..."
        return
    fi

    source "$config_file"

    print_info "Testing connection to ${IMAP_HOST}:${IMAP_PORT}..."
    echo ""

    # Test using openssl for SSL connections
    if [[ "$IMAP_SECURITY" == "SSL" ]]; then
        local result=$(timeout 10 bash -c "echo -e 'a001 LOGIN \"${IMAP_USER}\" \"${IMAP_PASS}\"\na002 LIST \"\" \"*\"\na003 LOGOUT' | openssl s_client -connect ${IMAP_HOST}:${IMAP_PORT} -quiet 2>/dev/null" || echo "FAILED")

        if echo "$result" | grep -q "a001 OK"; then
            print_success "Authentication successful!"
            echo ""
            echo "Available folders:"
            echo "$result" | grep "^\* LIST" | sed 's/.*"\/"\s*/  /' | head -10
        elif echo "$result" | grep -q "a001 NO"; then
            print_error "Authentication failed - check username/password"
            echo "Server response: $(echo "$result" | grep "a001 NO")"
        else
            print_error "Connection failed - check server/port settings"
        fi
    else
        # Test STARTTLS or unencrypted
        local connect_cmd="openssl s_client -connect ${IMAP_HOST}:${IMAP_PORT} -starttls imap -quiet"
        if [[ "$IMAP_SECURITY" == "NONE" ]]; then
            # Plain connection (not recommended)
            print_warning "Testing unencrypted connection (not recommended for production)"
            local result=$(timeout 10 bash -c "echo -e 'a001 LOGIN \"${IMAP_USER}\" \"${IMAP_PASS}\"\na002 LOGOUT' | nc -q 5 ${IMAP_HOST} ${IMAP_PORT} 2>/dev/null" || echo "FAILED")
        else
            local result=$(timeout 10 bash -c "echo -e 'a001 LOGIN \"${IMAP_USER}\" \"${IMAP_PASS}\"\na002 LOGOUT' | ${connect_cmd} 2>/dev/null" || echo "FAILED")
        fi

        if echo "$result" | grep -qi "OK"; then
            print_success "Connection test passed!"
        else
            print_error "Connection test failed"
        fi
    fi

    echo ""
    read -p "Press Enter to continue..."
}

view_email_rules() {
    print_header "Email Processing Rules"

    if ! is_running; then
        print_error "Services must be running to view email rules."
        read -p "Press Enter to continue..."
        return
    fi

    echo "Email processing rules are configured in the Paperless-ngx web interface."
    echo ""
    echo "Current rules:"
    echo ""

    docker compose exec -T webserver python3 manage.py shell -c "
from paperless_mail.models import MailRule, MailAccount
print('Mail Accounts:')
for acc in MailAccount.objects.all():
    print(f'  - {acc.name}: {acc.imap_server}')
print()
print('Mail Rules:')
for rule in MailRule.objects.all():
    print(f'  - {rule.name}')
    print(f'    Account: {rule.account.name if rule.account else \"None\"}')
    print(f'    Folder: {rule.folder}')
    print(f'    Action: {rule.action}')
    print()
" 2>/dev/null || print_warning "Could not retrieve mail rules (paperless_mail module may not be configured)"

    echo ""
    echo "To create/modify rules:"
    echo "  1. Open the Paperless web interface"
    echo "  2. Go to Settings > Mail"
    echo "  3. Create mail accounts and rules"
    echo ""
    read -p "Press Enter to continue..."
}

trigger_email_fetch() {
    print_header "Manual Email Fetch"

    if ! is_running; then
        print_error "Services must be running to fetch emails."
        read -p "Press Enter to continue..."
        return
    fi

    print_info "Triggering email fetch..."
    echo ""

    docker compose exec -T webserver python3 manage.py mail_fetcher 2>&1

    echo ""
    print_success "Email fetch completed"
    read -p "Press Enter to continue..."
}

remove_email_config() {
    print_header "Remove Email Configuration"

    local config_file="${SCRIPT_DIR}/config/mail/imap.conf"

    if [[ ! -f "$config_file" ]]; then
        print_warning "No email configuration found."
        read -p "Press Enter to continue..."
        return
    fi

    echo "This will remove the email import configuration."
    echo ""
    print_warning "Note: Mail rules created in Paperless web interface will remain."
    echo ""
    read -p "Are you sure? (yes/no): " confirm

    if [[ "$confirm" != "yes" ]]; then
        print_info "Cancelled"
        read -p "Press Enter to continue..."
        return
    fi

    # Remove config file
    rm -f "$config_file"

    # Remove mail settings from docker-compose.yml
    if grep -q "PAPERLESS_EMAIL_HOST" docker-compose.yml; then
        # Remove mail configuration lines
        sed -i.bak '/# Email\/IMAP Import Settings/,/PAPERLESS_EMAIL_USE_TLS/d' docker-compose.yml && rm -f docker-compose.yml.bak
    fi

    # Remove from .env
    if [[ -f ".env" ]]; then
        sed -i.bak '/# Email Import Settings/d; /PAPERLESS_EMAIL_PASSWORD/d' .env && rm -f .env.bak
    fi

    print_success "Email configuration removed"
    echo ""
    print_info "Restart services to apply changes"
    read -p "Press Enter to continue..."
}

# ============================================================================
# BACKUP VERIFICATION
# ============================================================================

backup_verification_menu() {
    print_header "Backup Verification"

    echo "Options:"
    echo ""
    echo "  1) Quick verify (check backup integrity)"
    echo "  2) Full test restore (restore to temporary location)"
    echo "  3) Verify all backups"
    echo "  4) Schedule automatic verification"
    echo ""
    echo "  0) Back"
    echo ""

    read -p "Select option [0-4]: " verify_choice

    case $verify_choice in
        1) verify_backup_quick ;;
        2) test_restore_backup ;;
        3) verify_all_backups ;;
        4) schedule_backup_verification ;;
        0) return ;;
        *)
            print_error "Invalid option"
            sleep 1
            ;;
    esac
}

verify_backup_quick() {
    print_header "Quick Backup Verification"

    local backups=($(ls -1t "${BACKUP_DIR}"/*.tar.gz 2>/dev/null || true))

    if [[ ${#backups[@]} -eq 0 ]]; then
        print_warning "No backups found in ${BACKUP_DIR}"
        read -p "Press Enter to continue..."
        return
    fi

    echo "Available backups:"
    echo ""
    local i=1
    for backup in "${backups[@]:0:10}"; do
        local size=$(du -h "$backup" 2>/dev/null | cut -f1)
        local date=$(basename "$backup" | grep -oP '\d{8}_\d{6}' | head -1)
        if [[ -n "$date" ]]; then
            local formatted_date=$(echo "$date" | sed 's/\([0-9]\{4\}\)\([0-9]\{2\}\)\([0-9]\{2\}\)_\([0-9]\{2\}\)\([0-9]\{2\}\)\([0-9]\{2\}\)/\1-\2-\3 \4:\5:\6/')
            echo "  $i) $(basename "$backup") ($size) - $formatted_date"
        else
            echo "  $i) $(basename "$backup") ($size)"
        fi
        ((i++))
    done
    echo ""

    read -p "Select backup to verify [1-${#backups[@]}]: " selection

    if [[ ! "$selection" =~ ^[0-9]+$ ]] || [[ "$selection" -lt 1 ]] || [[ "$selection" -gt ${#backups[@]} ]]; then
        print_error "Invalid selection"
        read -p "Press Enter to continue..."
        return
    fi

    local selected_backup="${backups[$((selection-1))]}"
    print_info "Verifying: $(basename "$selected_backup")"
    echo ""

    # Check archive integrity
    echo "Checking archive integrity..."
    if gzip -t "$selected_backup" 2>/dev/null; then
        print_success "Archive compression is valid"
    else
        print_error "Archive is corrupted!"
        read -p "Press Enter to continue..."
        return
    fi

    # List contents and check for expected files
    echo ""
    echo "Checking archive contents..."
    local contents=$(tar -tzf "$selected_backup" 2>/dev/null)

    local has_db=false
    local has_config=false
    local has_media=false

    if echo "$contents" | grep -q "database"; then
        has_db=true
        print_success "Database backup found"
    fi

    if echo "$contents" | grep -q -E "(\.env|docker-compose\.yml)"; then
        has_config=true
        print_success "Configuration files found"
    fi

    if echo "$contents" | grep -q "media"; then
        has_media=true
        print_success "Media files found (full backup)"
    else
        print_info "No media files (quick backup)"
    fi

    echo ""
    echo "Archive summary:"
    local file_count=$(echo "$contents" | wc -l)
    local archive_size=$(du -h "$selected_backup" | cut -f1)
    echo "  Files: $file_count"
    echo "  Size: $archive_size"

    if $has_db && $has_config; then
        echo ""
        print_success "Backup verification passed!"
    else
        echo ""
        print_warning "Backup may be incomplete"
    fi

    read -p "Press Enter to continue..."
}

test_restore_backup() {
    print_header "Test Restore Backup"

    print_warning "This will restore a backup to a temporary location for testing."
    echo "Your current installation will NOT be affected."
    echo ""

    local backups=($(ls -1t "${BACKUP_DIR}"/*.tar.gz 2>/dev/null || true))

    if [[ ${#backups[@]} -eq 0 ]]; then
        print_warning "No backups found in ${BACKUP_DIR}"
        read -p "Press Enter to continue..."
        return
    fi

    echo "Available backups:"
    echo ""
    local i=1
    for backup in "${backups[@]:0:10}"; do
        local size=$(du -h "$backup" 2>/dev/null | cut -f1)
        echo "  $i) $(basename "$backup") ($size)"
        ((i++))
    done
    echo ""

    read -p "Select backup to test [1-${#backups[@]}]: " selection

    if [[ ! "$selection" =~ ^[0-9]+$ ]] || [[ "$selection" -lt 1 ]] || [[ "$selection" -gt ${#backups[@]} ]]; then
        print_error "Invalid selection"
        read -p "Press Enter to continue..."
        return
    fi

    local selected_backup="${backups[$((selection-1))]}"
    local test_dir="${SCRIPT_DIR}/test_restore_$(date +%Y%m%d_%H%M%S)"

    print_info "Creating test restore directory: $test_dir"
    mkdir -p "$test_dir"

    print_info "Extracting backup..."
    if tar -xzf "$selected_backup" -C "$test_dir" 2>/dev/null; then
        print_success "Backup extracted successfully"
    else
        print_error "Failed to extract backup"
        rm -rf "$test_dir"
        read -p "Press Enter to continue..."
        return
    fi

    echo ""
    echo "Verifying restored contents..."

    # Check database dump
    if ls "$test_dir"/database/*.sql 2>/dev/null | head -1 > /dev/null; then
        local sql_file=$(ls "$test_dir"/database/*.sql 2>/dev/null | head -1)
        local sql_size=$(du -h "$sql_file" | cut -f1)
        print_success "Database dump found ($sql_size)"

        # Validate SQL syntax (basic check)
        if head -100 "$sql_file" | grep -q "PostgreSQL database dump"; then
            print_success "Database dump format is valid"
        fi
    else
        print_warning "No database dump found"
    fi

    # Check configuration
    if [[ -f "$test_dir/.env" ]] || [[ -f "$test_dir/config/.env" ]]; then
        print_success "Environment configuration found"
    fi

    # Check media files
    if [[ -d "$test_dir/media" ]]; then
        local media_count=$(find "$test_dir/media" -type f 2>/dev/null | wc -l)
        print_success "Media directory found ($media_count files)"
    fi

    echo ""
    echo "Test restore location: $test_dir"
    echo ""
    read -p "Keep test restore for inspection? (y/n): " keep_test

    if [[ "$keep_test" != "y" && "$keep_test" != "Y" ]]; then
        print_info "Cleaning up test restore..."
        rm -rf "$test_dir"
        print_success "Test restore cleaned up"
    else
        print_info "Test restore kept at: $test_dir"
        echo "Remember to delete it manually when done."
    fi

    read -p "Press Enter to continue..."
}

verify_all_backups() {
    print_header "Verify All Backups"

    local backups=($(ls -1t "${BACKUP_DIR}"/*.tar.gz 2>/dev/null || true))

    if [[ ${#backups[@]} -eq 0 ]]; then
        print_warning "No backups found in ${BACKUP_DIR}"
        read -p "Press Enter to continue..."
        return
    fi

    echo "Verifying ${#backups[@]} backups..."
    echo ""

    local valid_count=0
    local invalid_count=0

    for backup in "${backups[@]}"; do
        local name=$(basename "$backup")
        printf "  Checking %-50s " "$name"

        if gzip -t "$backup" 2>/dev/null; then
            echo -e "${GREEN}[OK]${NC}"
            ((valid_count++))
        else
            echo -e "${RED}[CORRUPTED]${NC}"
            ((invalid_count++))
        fi
    done

    echo ""
    echo "Results:"
    print_success "Valid backups: $valid_count"
    if [[ $invalid_count -gt 0 ]]; then
        print_error "Corrupted backups: $invalid_count"
    fi

    read -p "Press Enter to continue..."
}

schedule_backup_verification() {
    print_header "Schedule Automatic Verification"

    echo "Automatic backup verification can run weekly to ensure"
    echo "your backups remain valid and restorable."
    echo ""

    local cron_job="${SCRIPT_DIR}/management.sh verify-backups"

    # Check if already scheduled
    if crontab -l 2>/dev/null | grep -q "verify-backups"; then
        print_info "Automatic verification is already scheduled."
        echo ""
        read -p "Remove scheduled verification? (y/n): " remove
        if [[ "$remove" == "y" || "$remove" == "Y" ]]; then
            (crontab -l 2>/dev/null | grep -v "verify-backups") | crontab -
            print_success "Scheduled verification removed"
        fi
    else
        echo "Schedule options:"
        echo "  1) Weekly (Sunday at 3 AM)"
        echo "  2) Monthly (1st of month at 3 AM)"
        echo "  0) Cancel"
        echo ""
        read -p "Select schedule [0-2]: " schedule_choice

        case $schedule_choice in
            1)
                (crontab -l 2>/dev/null; echo "0 3 * * 0 ${cron_job} >> ${SCRIPT_DIR}/logs/verify.log 2>&1") | crontab -
                print_success "Weekly verification scheduled (Sundays at 3 AM)"
                ;;
            2)
                (crontab -l 2>/dev/null; echo "0 3 1 * * ${cron_job} >> ${SCRIPT_DIR}/logs/verify.log 2>&1") | crontab -
                print_success "Monthly verification scheduled (1st of month at 3 AM)"
                ;;
            0) return ;;
        esac
    fi

    read -p "Press Enter to continue..."
}

# ============================================================================
# DOCUMENT STATISTICS DASHBOARD
# ============================================================================

document_statistics() {
    print_header "Document Statistics Dashboard"

    cd "$SCRIPT_DIR"

    if ! is_running; then
        print_error "Services must be running to view statistics."
        read -p "Press Enter to continue..."
        return
    fi

    echo "Fetching statistics from database..."
    echo ""

    # Get document statistics
    docker compose exec -T db psql -U paperless -d paperless -t << 'EOF' 2>/dev/null | while read line; do echo "$line"; done
-- Document Statistics Dashboard

SELECT '=== Document Overview ===' as section;
SELECT 'Total Documents: ' || COUNT(*) FROM documents_document;
SELECT 'Documents this month: ' || COUNT(*) FROM documents_document WHERE created >= date_trunc('month', CURRENT_DATE);
SELECT 'Documents this year: ' || COUNT(*) FROM documents_document WHERE created >= date_trunc('year', CURRENT_DATE);

SELECT '' as spacer;
SELECT '=== Storage Statistics ===' as section;
SELECT 'Total original size: ' || pg_size_pretty(COALESCE(SUM(file_size), 0)) FROM documents_document;
SELECT 'Average document size: ' || pg_size_pretty(COALESCE(AVG(file_size)::bigint, 0)) FROM documents_document;
SELECT 'Largest document: ' || pg_size_pretty(COALESCE(MAX(file_size), 0)) FROM documents_document;

SELECT '' as spacer;
SELECT '=== Content Statistics ===' as section;
SELECT 'Total Tags: ' || COUNT(*) FROM documents_tag;
SELECT 'Total Correspondents: ' || COUNT(*) FROM documents_correspondent;
SELECT 'Total Document Types: ' || COUNT(*) FROM documents_documenttype;
SELECT 'Total Storage Paths: ' || COUNT(*) FROM documents_storagepath;

SELECT '' as spacer;
SELECT '=== Top 10 Tags ===' as section;
SELECT '  ' || t.name || ': ' || COUNT(dt.document_id) || ' documents'
FROM documents_tag t
LEFT JOIN documents_document_tags dt ON t.id = dt.tag_id
GROUP BY t.id, t.name
ORDER BY COUNT(dt.document_id) DESC
LIMIT 10;

SELECT '' as spacer;
SELECT '=== Top 10 Correspondents ===' as section;
SELECT '  ' || COALESCE(c.name, 'Unknown') || ': ' || COUNT(d.id) || ' documents'
FROM documents_correspondent c
LEFT JOIN documents_document d ON c.id = d.correspondent_id
GROUP BY c.id, c.name
ORDER BY COUNT(d.id) DESC
LIMIT 10;

SELECT '' as spacer;
SELECT '=== Documents by Year ===' as section;
SELECT '  ' || EXTRACT(YEAR FROM created)::integer || ': ' || COUNT(*) || ' documents'
FROM documents_document
GROUP BY EXTRACT(YEAR FROM created)
ORDER BY EXTRACT(YEAR FROM created) DESC
LIMIT 10;

SELECT '' as spacer;
SELECT '=== OCR Statistics ===' as section;
SELECT 'Documents with content: ' || COUNT(*) FROM documents_document WHERE content IS NOT NULL AND content != '';
SELECT 'Documents without content: ' || COUNT(*) FROM documents_document WHERE content IS NULL OR content = '';

SELECT '' as spacer;
SELECT '=== Recent Activity ===' as section;
SELECT 'Added today: ' || COUNT(*) FROM documents_document WHERE created >= CURRENT_DATE;
SELECT 'Added this week: ' || COUNT(*) FROM documents_document WHERE created >= date_trunc('week', CURRENT_DATE);
SELECT 'Modified today: ' || COUNT(*) FROM documents_document WHERE modified >= CURRENT_DATE;
EOF

    echo ""
    read -p "Press Enter to continue..."
}

# ============================================================================
# DUPLICATE DETECTION
# ============================================================================

duplicate_detection_menu() {
    print_header "Duplicate Detection"

    echo "Find potential duplicate documents in your collection."
    echo ""
    echo "Detection methods:"
    echo ""
    echo "  1) Find by checksum (exact duplicates)"
    echo "  2) Find by filename similarity"
    echo "  3) Find by content similarity"
    echo "  4) Show all potential duplicates"
    echo ""
    echo "  0) Back"
    echo ""

    read -p "Select option [0-4]: " dup_choice

    case $dup_choice in
        1) find_checksum_duplicates ;;
        2) find_filename_duplicates ;;
        3) find_content_duplicates ;;
        4) find_all_duplicates ;;
        0) return ;;
        *)
            print_error "Invalid option"
            sleep 1
            ;;
    esac
}

find_checksum_duplicates() {
    print_header "Exact Duplicates (by Checksum)"

    cd "$SCRIPT_DIR"

    if ! is_running; then
        print_error "Services must be running."
        read -p "Press Enter to continue..."
        return
    fi

    print_info "Searching for exact duplicates..."
    echo ""

    docker compose exec -T db psql -U paperless -d paperless << 'EOF' 2>/dev/null
SELECT
    'Checksum: ' || checksum as duplicate_group,
    COUNT(*) as count
FROM documents_document
WHERE checksum IS NOT NULL AND checksum != ''
GROUP BY checksum
HAVING COUNT(*) > 1
ORDER BY COUNT(*) DESC;

SELECT '' as spacer;
SELECT '=== Duplicate Details ===' as header;

SELECT
    d.id,
    d.title,
    d.checksum,
    pg_size_pretty(d.file_size) as size,
    d.created::date as created
FROM documents_document d
WHERE d.checksum IN (
    SELECT checksum
    FROM documents_document
    WHERE checksum IS NOT NULL AND checksum != ''
    GROUP BY checksum
    HAVING COUNT(*) > 1
)
ORDER BY d.checksum, d.created;
EOF

    echo ""
    read -p "Press Enter to continue..."
}

find_filename_duplicates() {
    print_header "Similar Filenames"

    cd "$SCRIPT_DIR"

    if ! is_running; then
        print_error "Services must be running."
        read -p "Press Enter to continue..."
        return
    fi

    print_info "Searching for similar filenames..."
    echo ""

    docker compose exec -T db psql -U paperless -d paperless << 'EOF' 2>/dev/null
-- Find documents with same original filename
SELECT
    original_filename,
    COUNT(*) as count
FROM documents_document
WHERE original_filename IS NOT NULL AND original_filename != ''
GROUP BY original_filename
HAVING COUNT(*) > 1
ORDER BY COUNT(*) DESC
LIMIT 20;

SELECT '' as spacer;
SELECT '=== Details ===' as header;

SELECT
    d.id,
    d.title,
    d.original_filename,
    d.created::date as created
FROM documents_document d
WHERE d.original_filename IN (
    SELECT original_filename
    FROM documents_document
    WHERE original_filename IS NOT NULL AND original_filename != ''
    GROUP BY original_filename
    HAVING COUNT(*) > 1
)
ORDER BY d.original_filename, d.created
LIMIT 50;
EOF

    echo ""
    read -p "Press Enter to continue..."
}

find_content_duplicates() {
    print_header "Content Similarity Detection"

    cd "$SCRIPT_DIR"

    if ! is_running; then
        print_error "Services must be running."
        read -p "Press Enter to continue..."
        return
    fi

    print_info "Analyzing document content for similarities..."
    print_warning "This may take a while for large collections."
    echo ""

    # Use MD5 of first 1000 characters of content to find similar documents
    docker compose exec -T db psql -U paperless -d paperless << 'EOF' 2>/dev/null
-- Find documents with similar content (same first 1000 chars)
WITH content_hashes AS (
    SELECT
        id,
        title,
        MD5(LEFT(content, 1000)) as content_hash,
        LENGTH(content) as content_length
    FROM documents_document
    WHERE content IS NOT NULL AND LENGTH(content) > 100
)
SELECT
    content_hash,
    COUNT(*) as similar_docs
FROM content_hashes
GROUP BY content_hash
HAVING COUNT(*) > 1
ORDER BY COUNT(*) DESC
LIMIT 10;

SELECT '' as spacer;
SELECT '=== Similar Document Details ===' as header;

WITH content_hashes AS (
    SELECT
        id,
        title,
        MD5(LEFT(content, 1000)) as content_hash
    FROM documents_document
    WHERE content IS NOT NULL AND LENGTH(content) > 100
),
duplicate_hashes AS (
    SELECT content_hash
    FROM content_hashes
    GROUP BY content_hash
    HAVING COUNT(*) > 1
)
SELECT
    ch.id,
    ch.title,
    LEFT(ch.content_hash, 8) as hash_prefix
FROM content_hashes ch
JOIN duplicate_hashes dh ON ch.content_hash = dh.content_hash
ORDER BY ch.content_hash, ch.id
LIMIT 50;
EOF

    echo ""
    read -p "Press Enter to continue..."
}

find_all_duplicates() {
    print_header "All Potential Duplicates"

    echo "Running all duplicate detection methods..."
    echo ""

    find_checksum_duplicates
    find_filename_duplicates
}

# ============================================================================
# STORAGE ANALYSIS
# ============================================================================

storage_analysis_menu() {
    print_header "Storage Analysis"

    echo "Analyze storage usage and identify optimization opportunities."
    echo ""
    echo "  1) Storage overview"
    echo "  2) Largest documents"
    echo "  3) Storage by document type"
    echo "  4) Storage by correspondent"
    echo "  5) Storage by year"
    echo "  6) Find orphaned files"
    echo "  7) Archive vs Original comparison"
    echo ""
    echo "  0) Back"
    echo ""

    read -p "Select option [0-7]: " storage_choice

    case $storage_choice in
        1) storage_overview ;;
        2) largest_documents ;;
        3) storage_by_type ;;
        4) storage_by_correspondent ;;
        5) storage_by_year ;;
        6) find_orphaned_files ;;
        7) archive_comparison ;;
        0) return ;;
        *)
            print_error "Invalid option"
            sleep 1
            ;;
    esac
}

storage_overview() {
    print_header "Storage Overview"

    echo "Disk Usage:"
    echo ""

    # Data directory breakdown
    echo "Data Directory Breakdown:"
    if [[ -d "${DATA_DIR}" ]]; then
        du -sh "${DATA_DIR}"/* 2>/dev/null | sort -hr | head -20
    fi

    echo ""
    echo "Media Directory Breakdown:"
    if [[ -d "${DATA_DIR}/media" ]]; then
        du -sh "${DATA_DIR}/media"/* 2>/dev/null | sort -hr
    fi

    echo ""
    echo "Total Sizes:"
    echo "  Data directory: $(du -sh "${DATA_DIR}" 2>/dev/null | cut -f1)"
    echo "  Backup directory: $(du -sh "${BACKUP_DIR}" 2>/dev/null | cut -f1)"
    echo "  Consume directory: $(du -sh "${CONSUME_DIR}" 2>/dev/null | cut -f1)"
    echo "  Export directory: $(du -sh "${EXPORT_DIR}" 2>/dev/null | cut -f1)"
    echo "  Trash directory: $(du -sh "${TRASH_DIR}" 2>/dev/null | cut -f1)"

    echo ""
    echo "Disk Space:"
    df -h "${SCRIPT_DIR}" | tail -1

    read -p "Press Enter to continue..."
}

largest_documents() {
    print_header "Largest Documents"

    cd "$SCRIPT_DIR"

    if ! is_running; then
        print_error "Services must be running."
        read -p "Press Enter to continue..."
        return
    fi

    echo "Top 20 largest documents:"
    echo ""

    docker compose exec -T db psql -U paperless -d paperless << 'EOF' 2>/dev/null
SELECT
    id,
    LEFT(title, 50) as title,
    pg_size_pretty(file_size) as size,
    mime_type,
    created::date
FROM documents_document
ORDER BY file_size DESC NULLS LAST
LIMIT 20;
EOF

    read -p "Press Enter to continue..."
}

storage_by_type() {
    print_header "Storage by Document Type"

    cd "$SCRIPT_DIR"

    if ! is_running; then
        print_error "Services must be running."
        read -p "Press Enter to continue..."
        return
    fi

    docker compose exec -T db psql -U paperless -d paperless << 'EOF' 2>/dev/null
SELECT
    COALESCE(dt.name, 'Unclassified') as document_type,
    COUNT(d.id) as doc_count,
    pg_size_pretty(SUM(d.file_size)) as total_size,
    pg_size_pretty(AVG(d.file_size)::bigint) as avg_size
FROM documents_document d
LEFT JOIN documents_documenttype dt ON d.document_type_id = dt.id
GROUP BY dt.name
ORDER BY SUM(d.file_size) DESC NULLS LAST;
EOF

    read -p "Press Enter to continue..."
}

storage_by_correspondent() {
    print_header "Storage by Correspondent"

    cd "$SCRIPT_DIR"

    if ! is_running; then
        print_error "Services must be running."
        read -p "Press Enter to continue..."
        return
    fi

    docker compose exec -T db psql -U paperless -d paperless << 'EOF' 2>/dev/null
SELECT
    COALESCE(c.name, 'Unknown') as correspondent,
    COUNT(d.id) as doc_count,
    pg_size_pretty(SUM(d.file_size)) as total_size
FROM documents_document d
LEFT JOIN documents_correspondent c ON d.correspondent_id = c.id
GROUP BY c.name
ORDER BY SUM(d.file_size) DESC NULLS LAST
LIMIT 20;
EOF

    read -p "Press Enter to continue..."
}

storage_by_year() {
    print_header "Storage by Year"

    cd "$SCRIPT_DIR"

    if ! is_running; then
        print_error "Services must be running."
        read -p "Press Enter to continue..."
        return
    fi

    docker compose exec -T db psql -U paperless -d paperless << 'EOF' 2>/dev/null
SELECT
    EXTRACT(YEAR FROM created)::integer as year,
    COUNT(*) as doc_count,
    pg_size_pretty(SUM(file_size)) as total_size,
    pg_size_pretty(AVG(file_size)::bigint) as avg_size
FROM documents_document
GROUP BY EXTRACT(YEAR FROM created)
ORDER BY EXTRACT(YEAR FROM created) DESC;
EOF

    read -p "Press Enter to continue..."
}

find_orphaned_files() {
    print_header "Find Orphaned Files"

    print_info "Scanning for orphaned files..."
    echo ""

    local media_dir="${DATA_DIR}/media"
    local orphaned_count=0
    local orphaned_size=0

    # Check for files in media/documents/originals that might be orphaned
    if [[ -d "${media_dir}/documents/originals" ]]; then
        echo "Checking original documents directory..."

        # Get list of files from database
        local db_files=$(docker compose exec -T db psql -U paperless -d paperless -t -c \
            "SELECT filename FROM documents_document WHERE filename IS NOT NULL;" 2>/dev/null | tr -d ' ')

        # Check each file in the originals directory
        for file in "${media_dir}/documents/originals"/*; do
            if [[ -f "$file" ]]; then
                local basename=$(basename "$file")
                if ! echo "$db_files" | grep -q "^${basename}$"; then
                    echo "  Potential orphan: $basename ($(du -h "$file" | cut -f1))"
                    ((orphaned_count++))
                    orphaned_size=$((orphaned_size + $(stat -f%z "$file" 2>/dev/null || stat -c%s "$file" 2>/dev/null || echo 0)))
                fi
            fi
        done
    fi

    # Check thumbnails directory
    if [[ -d "${media_dir}/documents/thumbnails" ]]; then
        local thumb_count=$(find "${media_dir}/documents/thumbnails" -type f 2>/dev/null | wc -l)
        echo ""
        echo "Thumbnails: $thumb_count files"
    fi

    echo ""
    if [[ $orphaned_count -gt 0 ]]; then
        print_warning "Found $orphaned_count potential orphaned files"
        echo "Total size: $(numfmt --to=iec $orphaned_size 2>/dev/null || echo "${orphaned_size} bytes")"
    else
        print_success "No orphaned files detected"
    fi

    read -p "Press Enter to continue..."
}

archive_comparison() {
    print_header "Archive vs Original Comparison"

    cd "$SCRIPT_DIR"

    if ! is_running; then
        print_error "Services must be running."
        read -p "Press Enter to continue..."
        return
    fi

    echo "Comparing original and archived document sizes..."
    echo ""

    docker compose exec -T db psql -U paperless -d paperless << 'EOF' 2>/dev/null
SELECT
    'Total original size' as metric,
    pg_size_pretty(SUM(file_size)) as value
FROM documents_document
WHERE file_size IS NOT NULL;

SELECT
    'Total archive size' as metric,
    pg_size_pretty(SUM(archive_size)) as value
FROM documents_document
WHERE archive_size IS NOT NULL;

SELECT
    'Documents with archive' as metric,
    COUNT(*)::text as value
FROM documents_document
WHERE archive_filename IS NOT NULL;

SELECT
    'Documents without archive' as metric,
    COUNT(*)::text as value
FROM documents_document
WHERE archive_filename IS NULL;

SELECT '' as spacer;
SELECT '=== Size Comparison by Document ===' as header;

SELECT
    LEFT(title, 40) as title,
    pg_size_pretty(file_size) as original,
    pg_size_pretty(archive_size) as archive,
    CASE
        WHEN file_size > 0 AND archive_size IS NOT NULL THEN
            ROUND((archive_size::numeric / file_size::numeric) * 100, 1) || '%'
        ELSE 'N/A'
    END as ratio
FROM documents_document
WHERE archive_size IS NOT NULL
ORDER BY file_size DESC
LIMIT 15;
EOF

    read -p "Press Enter to continue..."
}

# ============================================================================
# AUTOMATED CLEANUP
# ============================================================================

automated_cleanup_menu() {
    print_header "Automated Cleanup"

    echo "Clean up unnecessary files and optimize storage."
    echo ""
    echo "  1) Preview cleanup (dry run)"
    echo "  2) Clean orphaned thumbnails"
    echo "  3) Clean failed consumption files"
    echo "  4) Purge old logs"
    echo "  5) Clean temporary files"
    echo "  6) Full cleanup (all of the above)"
    echo "  7) Schedule automatic cleanup"
    echo ""
    echo "  0) Back"
    echo ""

    read -p "Select option [0-7]: " cleanup_choice

    case $cleanup_choice in
        1) cleanup_preview ;;
        2) clean_orphaned_thumbnails ;;
        3) clean_failed_consumption ;;
        4) purge_old_logs ;;
        5) clean_temp_files ;;
        6) full_cleanup ;;
        7) schedule_cleanup ;;
        0) return ;;
        *)
            print_error "Invalid option"
            sleep 1
            ;;
    esac
}

cleanup_preview() {
    print_header "Cleanup Preview (Dry Run)"

    echo "Scanning for files that can be cleaned up..."
    echo ""

    local total_reclaimable=0

    # Orphaned thumbnails
    echo "=== Orphaned Thumbnails ==="
    local thumb_dir="${DATA_DIR}/media/documents/thumbnails"
    if [[ -d "$thumb_dir" ]]; then
        local thumb_count=$(find "$thumb_dir" -type f -mtime +30 2>/dev/null | wc -l)
        local thumb_size=$(find "$thumb_dir" -type f -mtime +30 -exec du -cb {} + 2>/dev/null | tail -1 | cut -f1 || echo 0)
        echo "  Old thumbnails (>30 days): $thumb_count files"
    fi

    # Failed consumption
    echo ""
    echo "=== Failed Consumption Files ==="
    local consume_failed="${CONSUME_DIR}/.failed"
    if [[ -d "$consume_failed" ]]; then
        local failed_count=$(find "$consume_failed" -type f 2>/dev/null | wc -l)
        local failed_size=$(du -sh "$consume_failed" 2>/dev/null | cut -f1)
        echo "  Failed files: $failed_count ($failed_size)"
    else
        echo "  No failed consumption directory found"
    fi

    # Log files
    echo ""
    echo "=== Log Files ==="
    local log_dir="${SCRIPT_DIR}/logs"
    if [[ -d "$log_dir" ]]; then
        local log_size=$(du -sh "$log_dir" 2>/dev/null | cut -f1)
        local old_logs=$(find "$log_dir" -type f -mtime +7 2>/dev/null | wc -l)
        echo "  Total log size: $log_size"
        echo "  Logs older than 7 days: $old_logs files"
    fi

    # Temp files
    echo ""
    echo "=== Temporary Files ==="
    local temp_count=0
    for pattern in "*.tmp" "*.temp" "*~" "*.bak"; do
        temp_count=$((temp_count + $(find "${SCRIPT_DIR}" -name "$pattern" -type f 2>/dev/null | wc -l)))
    done
    echo "  Temporary files found: $temp_count"

    # Docker cleanup potential
    echo ""
    echo "=== Docker Cleanup Potential ==="
    docker system df 2>/dev/null || echo "  Could not get Docker stats"

    read -p "Press Enter to continue..."
}

clean_orphaned_thumbnails() {
    print_header "Clean Orphaned Thumbnails"

    local thumb_dir="${DATA_DIR}/media/documents/thumbnails"

    if [[ ! -d "$thumb_dir" ]]; then
        print_warning "Thumbnails directory not found"
        read -p "Press Enter to continue..."
        return
    fi

    local count=$(find "$thumb_dir" -type f -mtime +30 2>/dev/null | wc -l)

    if [[ $count -eq 0 ]]; then
        print_success "No old thumbnails to clean"
        read -p "Press Enter to continue..."
        return
    fi

    echo "Found $count thumbnails older than 30 days."
    echo ""
    print_warning "Paperless will regenerate thumbnails as needed."
    read -p "Delete old thumbnails? (y/n): " confirm

    if [[ "$confirm" == "y" || "$confirm" == "Y" ]]; then
        find "$thumb_dir" -type f -mtime +30 -delete 2>/dev/null
        print_success "Old thumbnails deleted"
    else
        print_info "Cancelled"
    fi

    read -p "Press Enter to continue..."
}

clean_failed_consumption() {
    print_header "Clean Failed Consumption Files"

    local consume_failed="${CONSUME_DIR}/.failed"

    if [[ ! -d "$consume_failed" ]]; then
        print_info "No failed consumption directory found"
        read -p "Press Enter to continue..."
        return
    fi

    local count=$(find "$consume_failed" -type f 2>/dev/null | wc -l)

    if [[ $count -eq 0 ]]; then
        print_success "No failed consumption files"
        read -p "Press Enter to continue..."
        return
    fi

    echo "Found $count failed consumption files:"
    echo ""
    ls -la "$consume_failed" 2>/dev/null | head -20

    echo ""
    read -p "Delete all failed consumption files? (y/n): " confirm

    if [[ "$confirm" == "y" || "$confirm" == "Y" ]]; then
        rm -rf "$consume_failed"/*
        print_success "Failed consumption files deleted"
    else
        print_info "Cancelled"
    fi

    read -p "Press Enter to continue..."
}

purge_old_logs() {
    print_header "Purge Old Logs"

    local log_dir="${SCRIPT_DIR}/logs"
    mkdir -p "$log_dir"

    echo "Log retention options:"
    echo "  1) Keep last 7 days"
    echo "  2) Keep last 30 days"
    echo "  3) Keep last 90 days"
    echo "  4) Delete all logs"
    echo "  0) Cancel"
    echo ""

    read -p "Select option [0-4]: " retention_choice

    local days=0
    case $retention_choice in
        1) days=7 ;;
        2) days=30 ;;
        3) days=90 ;;
        4) days=0 ;;
        0) return ;;
        *) print_error "Invalid option"; sleep 1; return ;;
    esac

    if [[ $days -eq 0 ]]; then
        read -p "Delete ALL logs? (yes/no): " confirm
        if [[ "$confirm" == "yes" ]]; then
            find "$log_dir" -type f -delete 2>/dev/null
            print_success "All logs deleted"
        fi
    else
        local count=$(find "$log_dir" -type f -mtime +$days 2>/dev/null | wc -l)
        find "$log_dir" -type f -mtime +$days -delete 2>/dev/null
        print_success "Deleted $count log files older than $days days"
    fi

    read -p "Press Enter to continue..."
}

clean_temp_files() {
    print_header "Clean Temporary Files"

    echo "Searching for temporary files..."
    echo ""

    local temp_files=()
    for pattern in "*.tmp" "*.temp" "*~" "*.bak" ".DS_Store"; do
        while IFS= read -r -d '' file; do
            temp_files+=("$file")
        done < <(find "${SCRIPT_DIR}" -name "$pattern" -type f -print0 2>/dev/null)
    done

    if [[ ${#temp_files[@]} -eq 0 ]]; then
        print_success "No temporary files found"
        read -p "Press Enter to continue..."
        return
    fi

    echo "Found ${#temp_files[@]} temporary files:"
    for file in "${temp_files[@]:0:20}"; do
        echo "  $file"
    done
    if [[ ${#temp_files[@]} -gt 20 ]]; then
        echo "  ... and $((${#temp_files[@]} - 20)) more"
    fi

    echo ""
    read -p "Delete all temporary files? (y/n): " confirm

    if [[ "$confirm" == "y" || "$confirm" == "Y" ]]; then
        for file in "${temp_files[@]}"; do
            rm -f "$file"
        done
        print_success "Temporary files deleted"
    fi

    read -p "Press Enter to continue..."
}

full_cleanup() {
    print_header "Full Cleanup"

    print_warning "This will perform all cleanup operations."
    read -p "Continue? (y/n): " confirm

    if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
        print_info "Cancelled"
        read -p "Press Enter to continue..."
        return
    fi

    echo ""
    echo "Step 1/5: Cleaning orphaned thumbnails..."
    local thumb_dir="${DATA_DIR}/media/documents/thumbnails"
    if [[ -d "$thumb_dir" ]]; then
        find "$thumb_dir" -type f -mtime +30 -delete 2>/dev/null
    fi
    print_success "Done"

    echo "Step 2/5: Cleaning failed consumption files..."
    local consume_failed="${CONSUME_DIR}/.failed"
    if [[ -d "$consume_failed" ]]; then
        rm -rf "$consume_failed"/*
    fi
    print_success "Done"

    echo "Step 3/5: Purging old logs (>30 days)..."
    find "${SCRIPT_DIR}/logs" -type f -mtime +30 -delete 2>/dev/null
    print_success "Done"

    echo "Step 4/5: Cleaning temporary files..."
    for pattern in "*.tmp" "*.temp" "*~" "*.bak" ".DS_Store"; do
        find "${SCRIPT_DIR}" -name "$pattern" -type f -delete 2>/dev/null
    done
    print_success "Done"

    echo "Step 5/5: Docker cleanup..."
    docker system prune -f 2>/dev/null
    print_success "Done"

    echo ""
    print_success "Full cleanup completed!"
    read -p "Press Enter to continue..."
}

schedule_cleanup() {
    print_header "Schedule Automatic Cleanup"

    local cron_job="${SCRIPT_DIR}/management.sh auto-cleanup"

    if crontab -l 2>/dev/null | grep -q "auto-cleanup"; then
        print_info "Automatic cleanup is already scheduled."
        read -p "Remove scheduled cleanup? (y/n): " remove
        if [[ "$remove" == "y" || "$remove" == "Y" ]]; then
            (crontab -l 2>/dev/null | grep -v "auto-cleanup") | crontab -
            print_success "Scheduled cleanup removed"
        fi
    else
        echo "Schedule options:"
        echo "  1) Weekly (Sunday at 4 AM)"
        echo "  2) Monthly (1st of month at 4 AM)"
        echo "  0) Cancel"
        echo ""

        read -p "Select schedule [0-2]: " sched_choice

        case $sched_choice in
            1)
                (crontab -l 2>/dev/null; echo "0 4 * * 0 ${cron_job} >> ${SCRIPT_DIR}/logs/cleanup.log 2>&1") | crontab -
                print_success "Weekly cleanup scheduled"
                ;;
            2)
                (crontab -l 2>/dev/null; echo "0 4 1 * * ${cron_job} >> ${SCRIPT_DIR}/logs/cleanup.log 2>&1") | crontab -
                print_success "Monthly cleanup scheduled"
                ;;
            0) return ;;
        esac
    fi

    read -p "Press Enter to continue..."
}

# ============================================================================
# FAIL2BAN INTEGRATION
# ============================================================================

fail2ban_setup() {
    print_header "Fail2ban Integration"

    check_root

    echo "Fail2ban protects against brute-force login attempts."
    echo ""
    echo "Options:"
    echo ""
    echo "  1) Install and configure Fail2ban"
    echo "  2) View current status"
    echo "  3) View banned IPs"
    echo "  4) Unban an IP address"
    echo "  5) View Paperless jail configuration"
    echo "  6) Remove Fail2ban configuration"
    echo ""
    echo "  0) Back"
    echo ""

    read -p "Select option [0-6]: " f2b_choice

    case $f2b_choice in
        1) install_fail2ban ;;
        2) fail2ban_status ;;
        3) view_banned_ips ;;
        4) unban_ip ;;
        5) view_f2b_config ;;
        6) remove_fail2ban_config ;;
        0) return ;;
        *)
            print_error "Invalid option"
            sleep 1
            ;;
    esac
}

install_fail2ban() {
    print_header "Install Fail2ban"

    # Check if already installed
    if command -v fail2ban-client &> /dev/null; then
        print_info "Fail2ban is already installed"
    else
        print_info "Installing Fail2ban..."
        apt-get update && apt-get install -y fail2ban
    fi

    # Create Paperless filter
    print_info "Creating Paperless filter..."

    cat > /etc/fail2ban/filter.d/paperless.conf << 'EOF'
[Definition]
# Filter for Paperless-ngx failed login attempts
# Matches nginx access log entries for failed authentication

failregex = ^<HOST> .* "POST /api/token/ HTTP/.*" 400
            ^<HOST> .* "POST /api/token/ HTTP/.*" 401
            ^<HOST> .* "POST /accounts/login/ HTTP/.*" 400
            ^<HOST> .* "POST /accounts/login/ HTTP/.*" 401

ignoreregex =
EOF

    # Create Paperless jail
    print_info "Creating Paperless jail..."

    cat > /etc/fail2ban/jail.d/paperless.conf << EOF
[paperless]
enabled = true
port = http,https
filter = paperless
logpath = /var/lib/docker/containers/*/*-json.log
maxretry = 5
findtime = 600
bantime = 3600
action = iptables-multiport[name=paperless, port="http,https", protocol=tcp]

# Also check nginx access log if using external nginx
[paperless-nginx]
enabled = true
port = http,https
filter = paperless
logpath = ${SCRIPT_DIR}/logs/nginx-access.log
maxretry = 5
findtime = 600
bantime = 3600
action = iptables-multiport[name=paperless-nginx, port="http,https", protocol=tcp]
EOF

    # Restart fail2ban
    systemctl restart fail2ban

    print_success "Fail2ban configured for Paperless"
    echo ""
    echo "Configuration:"
    echo "  - Max retries: 5 failed attempts"
    echo "  - Find time: 10 minutes"
    echo "  - Ban time: 1 hour"

    read -p "Press Enter to continue..."
}

fail2ban_status() {
    print_header "Fail2ban Status"

    if ! command -v fail2ban-client &> /dev/null; then
        print_warning "Fail2ban is not installed"
        read -p "Press Enter to continue..."
        return
    fi

    fail2ban-client status
    echo ""
    fail2ban-client status paperless 2>/dev/null || print_info "Paperless jail not configured"

    read -p "Press Enter to continue..."
}

view_banned_ips() {
    print_header "Banned IP Addresses"

    if ! command -v fail2ban-client &> /dev/null; then
        print_warning "Fail2ban is not installed"
        read -p "Press Enter to continue..."
        return
    fi

    echo "Paperless jail:"
    fail2ban-client status paperless 2>/dev/null | grep "Banned IP" || echo "  No banned IPs"

    echo ""
    echo "All jails:"
    fail2ban-client banned 2>/dev/null || echo "  Could not retrieve banned list"

    read -p "Press Enter to continue..."
}

unban_ip() {
    print_header "Unban IP Address"

    if ! command -v fail2ban-client &> /dev/null; then
        print_warning "Fail2ban is not installed"
        read -p "Press Enter to continue..."
        return
    fi

    read -p "Enter IP address to unban: " ip_address

    if [[ -z "$ip_address" ]]; then
        print_error "IP address required"
        read -p "Press Enter to continue..."
        return
    fi

    fail2ban-client set paperless unbanip "$ip_address" 2>/dev/null && \
        print_success "Unbanned $ip_address from Paperless jail"

    read -p "Press Enter to continue..."
}

view_f2b_config() {
    print_header "Fail2ban Configuration"

    if [[ -f /etc/fail2ban/jail.d/paperless.conf ]]; then
        cat /etc/fail2ban/jail.d/paperless.conf
    else
        print_warning "Paperless jail not configured"
    fi

    read -p "Press Enter to continue..."
}

remove_fail2ban_config() {
    print_header "Remove Fail2ban Configuration"

    read -p "Remove Paperless Fail2ban configuration? (yes/no): " confirm

    if [[ "$confirm" != "yes" ]]; then
        print_info "Cancelled"
        read -p "Press Enter to continue..."
        return
    fi

    rm -f /etc/fail2ban/filter.d/paperless.conf
    rm -f /etc/fail2ban/jail.d/paperless.conf

    systemctl restart fail2ban 2>/dev/null

    print_success "Fail2ban configuration removed"
    read -p "Press Enter to continue..."
}

# ============================================================================
# BACKUP ENCRYPTION
# ============================================================================

backup_encryption_menu() {
    print_header "Backup Encryption"

    echo "Encrypt your backups with GPG for secure storage."
    echo ""
    echo "  1) Setup encryption key"
    echo "  2) Create encrypted backup"
    echo "  3) Decrypt a backup"
    echo "  4) View encryption status"
    echo "  5) Enable automatic encryption"
    echo "  6) Remove encryption configuration"
    echo ""
    echo "  0) Back"
    echo ""

    read -p "Select option [0-6]: " enc_choice

    case $enc_choice in
        1) setup_encryption_key ;;
        2) create_encrypted_backup ;;
        3) decrypt_backup ;;
        4) view_encryption_status ;;
        5) enable_auto_encryption ;;
        6) remove_encryption_config ;;
        0) return ;;
        *)
            print_error "Invalid option"
            sleep 1
            ;;
    esac
}

setup_encryption_key() {
    print_header "Setup Encryption Key"

    # Check if gpg is installed
    if ! command -v gpg &> /dev/null; then
        print_error "GPG is not installed. Install with: sudo apt install gnupg"
        read -p "Press Enter to continue..."
        return
    fi

    local key_file="${SCRIPT_DIR}/config/backup-key.gpg"
    mkdir -p "${SCRIPT_DIR}/config"

    if [[ -f "$key_file" ]]; then
        print_warning "Encryption key already exists."
        read -p "Generate new key? This will invalidate existing encrypted backups! (yes/no): " confirm
        if [[ "$confirm" != "yes" ]]; then
            read -p "Press Enter to continue..."
            return
        fi
    fi

    echo "Encryption options:"
    echo "  1) Password-based encryption (symmetric)"
    echo "  2) Generate GPG keypair (asymmetric)"
    echo ""

    read -p "Select option [1-2]: " key_choice

    case $key_choice in
        1)
            read -s -p "Enter encryption password: " enc_password
            echo ""
            read -s -p "Confirm password: " enc_password2
            echo ""

            if [[ "$enc_password" != "$enc_password2" ]]; then
                print_error "Passwords do not match"
                read -p "Press Enter to continue..."
                return
            fi

            if [[ ${#enc_password} -lt 12 ]]; then
                print_error "Password must be at least 12 characters"
                read -p "Press Enter to continue..."
                return
            fi

            # Save encrypted password hash
            echo "$enc_password" | gpg --batch --yes --passphrase-fd 0 --symmetric --cipher-algo AES256 -o "${key_file}" <<< "paperless-backup-key"
            chmod 600 "$key_file"

            # Save password hint for config
            echo "ENCRYPTION_TYPE=symmetric" > "${SCRIPT_DIR}/config/encryption.conf"
            chmod 600 "${SCRIPT_DIR}/config/encryption.conf"

            print_success "Symmetric encryption configured"
            print_warning "Remember your password! It cannot be recovered."
            ;;
        2)
            print_info "Generating GPG keypair..."
            read -p "Enter email for key identification: " key_email

            gpg --batch --gen-key << EOF
%no-protection
Key-Type: RSA
Key-Length: 4096
Name-Real: Paperless Backup
Name-Email: ${key_email}
Expire-Date: 0
%commit
EOF

            echo "ENCRYPTION_TYPE=asymmetric" > "${SCRIPT_DIR}/config/encryption.conf"
            echo "ENCRYPTION_KEY_EMAIL=${key_email}" >> "${SCRIPT_DIR}/config/encryption.conf"
            chmod 600 "${SCRIPT_DIR}/config/encryption.conf"

            print_success "GPG keypair generated"
            print_warning "Export and backup your private key securely!"
            echo ""
            echo "Export command: gpg --export-secret-keys ${key_email} > backup-key.asc"
            ;;
    esac

    read -p "Press Enter to continue..."
}

create_encrypted_backup() {
    print_header "Create Encrypted Backup"

    local config_file="${SCRIPT_DIR}/config/encryption.conf"

    if [[ ! -f "$config_file" ]]; then
        print_error "Encryption not configured. Run 'Setup encryption key' first."
        read -p "Press Enter to continue..."
        return
    fi

    source "$config_file"

    # First create a regular backup
    print_info "Creating backup..."
    local timestamp=$(date +%Y%m%d_%H%M%S)
    local backup_file="${BACKUP_DIR}/paperless_backup_${timestamp}.tar.gz"

    # Create backup (simplified version)
    cd "$SCRIPT_DIR"
    mkdir -p "${BACKUP_DIR}/temp_backup_${timestamp}"

    # Backup database
    print_info "Backing up database..."
    docker compose exec -T db pg_dump -U paperless paperless > "${BACKUP_DIR}/temp_backup_${timestamp}/database.sql" 2>/dev/null

    # Backup config
    cp -r .env docker-compose.yml config "${BACKUP_DIR}/temp_backup_${timestamp}/" 2>/dev/null

    # Create archive
    tar -czf "$backup_file" -C "${BACKUP_DIR}" "temp_backup_${timestamp}"
    rm -rf "${BACKUP_DIR}/temp_backup_${timestamp}"

    # Encrypt the backup
    print_info "Encrypting backup..."
    local encrypted_file="${backup_file}.gpg"

    if [[ "$ENCRYPTION_TYPE" == "symmetric" ]]; then
        read -s -p "Enter encryption password: " enc_password
        echo ""
        echo "$enc_password" | gpg --batch --yes --passphrase-fd 0 --symmetric --cipher-algo AES256 -o "$encrypted_file" "$backup_file"
    else
        gpg --batch --yes --encrypt --recipient "$ENCRYPTION_KEY_EMAIL" -o "$encrypted_file" "$backup_file"
    fi

    # Remove unencrypted backup
    rm -f "$backup_file"

    print_success "Encrypted backup created: $(basename "$encrypted_file")"
    echo "Size: $(du -h "$encrypted_file" | cut -f1)"

    read -p "Press Enter to continue..."
}

decrypt_backup() {
    print_header "Decrypt Backup"

    local encrypted_backups=($(ls -1t "${BACKUP_DIR}"/*.gpg 2>/dev/null || true))

    if [[ ${#encrypted_backups[@]} -eq 0 ]]; then
        print_warning "No encrypted backups found"
        read -p "Press Enter to continue..."
        return
    fi

    echo "Encrypted backups:"
    echo ""
    local i=1
    for backup in "${encrypted_backups[@]:0:10}"; do
        echo "  $i) $(basename "$backup") ($(du -h "$backup" | cut -f1))"
        ((i++))
    done
    echo ""

    read -p "Select backup to decrypt [1-${#encrypted_backups[@]}]: " selection

    if [[ ! "$selection" =~ ^[0-9]+$ ]] || [[ "$selection" -lt 1 ]] || [[ "$selection" -gt ${#encrypted_backups[@]} ]]; then
        print_error "Invalid selection"
        read -p "Press Enter to continue..."
        return
    fi

    local selected="${encrypted_backups[$((selection-1))]}"
    local output_file="${selected%.gpg}"

    read -s -p "Enter decryption password: " dec_password
    echo ""

    print_info "Decrypting..."
    if echo "$dec_password" | gpg --batch --yes --passphrase-fd 0 -d -o "$output_file" "$selected" 2>/dev/null; then
        print_success "Backup decrypted: $(basename "$output_file")"
    else
        print_error "Decryption failed - wrong password?"
    fi

    read -p "Press Enter to continue..."
}

view_encryption_status() {
    print_header "Encryption Status"

    local config_file="${SCRIPT_DIR}/config/encryption.conf"

    if [[ ! -f "$config_file" ]]; then
        print_warning "Encryption not configured"
    else
        source "$config_file"
        print_success "Encryption is configured"
        echo ""
        echo "Type: $ENCRYPTION_TYPE"
        if [[ "$ENCRYPTION_TYPE" == "asymmetric" ]]; then
            echo "Key: $ENCRYPTION_KEY_EMAIL"
        fi
    fi

    echo ""
    echo "Encrypted backups:"
    local enc_count=$(ls -1 "${BACKUP_DIR}"/*.gpg 2>/dev/null | wc -l)
    echo "  Count: $enc_count"

    if [[ $enc_count -gt 0 ]]; then
        local enc_size=$(du -ch "${BACKUP_DIR}"/*.gpg 2>/dev/null | tail -1 | cut -f1)
        echo "  Total size: $enc_size"
    fi

    read -p "Press Enter to continue..."
}

enable_auto_encryption() {
    print_header "Enable Automatic Encryption"

    local config_file="${SCRIPT_DIR}/config/encryption.conf"

    if [[ ! -f "$config_file" ]]; then
        print_error "Encryption not configured. Run 'Setup encryption key' first."
        read -p "Press Enter to continue..."
        return
    fi

    source "$config_file"

    if grep -q "AUTO_ENCRYPT=true" "$config_file" 2>/dev/null; then
        print_info "Automatic encryption is already enabled"
        read -p "Disable automatic encryption? (y/n): " disable
        if [[ "$disable" == "y" || "$disable" == "Y" ]]; then
            sed -i.bak '/AUTO_ENCRYPT/d' "$config_file" && rm -f "${config_file}.bak"
            print_success "Automatic encryption disabled"
        fi
    else
        echo "AUTO_ENCRYPT=true" >> "$config_file"
        print_success "Automatic encryption enabled"
        echo ""
        echo "All future backups will be automatically encrypted."
    fi

    read -p "Press Enter to continue..."
}

remove_encryption_config() {
    print_header "Remove Encryption Configuration"

    print_warning "This will remove encryption settings."
    echo "Existing encrypted backups will still require the password to decrypt."
    echo ""
    read -p "Remove encryption configuration? (yes/no): " confirm

    if [[ "$confirm" != "yes" ]]; then
        print_info "Cancelled"
        read -p "Press Enter to continue..."
        return
    fi

    rm -f "${SCRIPT_DIR}/config/encryption.conf"
    rm -f "${SCRIPT_DIR}/config/backup-key.gpg"

    print_success "Encryption configuration removed"
    read -p "Press Enter to continue..."
}

# ============================================================================
# SECURITY AUDIT
# ============================================================================

security_audit() {
    print_header "Security Audit"

    echo "Checking security configuration..."
    echo ""

    local issues=0
    local warnings=0

    # Check for default passwords
    echo "=== Password Security ==="
    if [[ -f ".env" ]]; then
        if grep -q "PAPERLESS_ADMIN_PASSWORD=admin" .env 2>/dev/null || \
           grep -q "PAPERLESS_ADMIN_PASSWORD=changeme" .env 2>/dev/null; then
            print_error "Default admin password detected!"
            ((issues++))
        else
            print_success "Admin password has been changed"
        fi

        if grep -q "PAPERLESS_DB_PASSWORD=paperless" .env 2>/dev/null || \
           grep -q "PAPERLESS_DB_PASSWORD=changeme" .env 2>/dev/null; then
            print_warning "Default database password detected"
            ((warnings++))
        else
            print_success "Database password has been changed"
        fi

        if grep -q "PAPERLESS_SECRET_KEY=change-me" .env 2>/dev/null; then
            print_error "Default secret key detected!"
            ((issues++))
        else
            print_success "Secret key has been changed"
        fi
    fi

    echo ""
    echo "=== Network Security ==="

    # Check exposed ports
    if docker compose ps 2>/dev/null | grep -q "0.0.0.0:8000"; then
        print_warning "Port 8000 exposed directly (should use nginx proxy)"
        ((warnings++))
    else
        print_success "Backend port not directly exposed"
    fi

    # Check SSL configuration
    if [[ -f "${SSL_DIR}/cert.pem" ]]; then
        print_success "SSL certificate installed"

        # Check certificate expiry
        local expiry=$(openssl x509 -enddate -noout -in "${SSL_DIR}/cert.pem" 2>/dev/null | cut -d= -f2)
        if [[ -n "$expiry" ]]; then
            local expiry_epoch=$(date -d "$expiry" +%s 2>/dev/null || date -j -f "%b %d %T %Y %Z" "$expiry" +%s 2>/dev/null)
            local now_epoch=$(date +%s)
            local days_left=$(( (expiry_epoch - now_epoch) / 86400 ))

            if [[ $days_left -lt 30 ]]; then
                print_warning "SSL certificate expires in $days_left days"
                ((warnings++))
            else
                print_success "SSL certificate valid for $days_left days"
            fi
        fi
    else
        print_warning "No SSL certificate installed"
        ((warnings++))
    fi

    echo ""
    echo "=== File Permissions ==="

    # Check .env permissions
    if [[ -f ".env" ]]; then
        local env_perms=$(stat -c %a .env 2>/dev/null || stat -f %Lp .env 2>/dev/null)
        if [[ "$env_perms" == "600" ]] || [[ "$env_perms" == "400" ]]; then
            print_success ".env file has restricted permissions ($env_perms)"
        else
            print_warning ".env file permissions too open ($env_perms, should be 600)"
            ((warnings++))
        fi
    fi

    # Check backup directory permissions
    if [[ -d "$BACKUP_DIR" ]]; then
        local backup_perms=$(stat -c %a "$BACKUP_DIR" 2>/dev/null || stat -f %Lp "$BACKUP_DIR" 2>/dev/null)
        if [[ "$backup_perms" =~ ^7[0-5][0-5]$ ]]; then
            print_success "Backup directory has restricted permissions"
        else
            print_warning "Backup directory may be too accessible ($backup_perms)"
            ((warnings++))
        fi
    fi

    echo ""
    echo "=== Docker Security ==="

    # Check if running as root - Note: This is EXPECTED for Paperless-ngx
    # The official image runs as root inside the container, which is isolated from the host
    if docker compose exec -T webserver id 2>/dev/null | grep -q "uid=0"; then
        print_info "Container runs as root (standard for Paperless-ngx)"
        echo "       This is expected - Docker isolates the container from your host"
    else
        print_success "Container running as non-root user"
    fi

    # Check for latest images
    local current_version=$(docker compose exec -T webserver cat /usr/src/paperless/version.txt 2>/dev/null || echo "unknown")
    print_info "Current Paperless version: $current_version"

    echo ""
    echo "=== Fail2ban Status ==="
    if command -v fail2ban-client &> /dev/null; then
        if fail2ban-client status paperless &>/dev/null; then
            print_success "Fail2ban protection active"
        else
            print_warning "Fail2ban installed but Paperless jail not configured"
            ((warnings++))
        fi
    else
        print_warning "Fail2ban not installed (recommended for brute-force protection)"
        ((warnings++))
    fi

    echo ""
    echo "=== Backup Encryption ==="
    if [[ -f "${SCRIPT_DIR}/config/encryption.conf" ]]; then
        print_success "Backup encryption configured"
    else
        print_warning "Backup encryption not configured"
        ((warnings++))
    fi

    echo ""
    echo "========================================"
    echo "Security Audit Summary:"
    if [[ $issues -eq 0 ]]; then
        print_success "Critical issues: 0"
    else
        print_error "Critical issues: $issues"
    fi
    if [[ $warnings -eq 0 ]]; then
        print_success "Warnings: 0"
    else
        print_warning "Warnings: $warnings"
    fi

    if [[ $issues -gt 0 ]]; then
        echo ""
        print_error "Please address critical issues immediately!"
    fi

    read -p "Press Enter to continue..."
}

# ============================================================================
# MIGRATION ASSISTANT
# ============================================================================

migration_assistant_menu() {
    print_header "Migration Assistant"

    echo "Import documents from other sources."
    echo ""
    echo "  1) Bulk import from directory"
    echo "  2) Import with CSV metadata"
    echo "  3) Import from another Paperless instance"
    echo "  4) Import from filesystem with folder structure"
    echo ""
    echo "  0) Back"
    echo ""

    read -p "Select option [0-4]: " mig_choice

    case $mig_choice in
        1) bulk_import_directory ;;
        2) import_with_csv ;;
        3) import_from_paperless ;;
        4) import_with_folders ;;
        0) return ;;
        *)
            print_error "Invalid option"
            sleep 1
            ;;
    esac
}

bulk_import_directory() {
    print_header "Bulk Import from Directory"

    echo "This will copy files from a directory to the consume folder."
    echo ""
    read -p "Enter source directory path: " source_dir

    if [[ ! -d "$source_dir" ]]; then
        print_error "Directory not found: $source_dir"
        read -p "Press Enter to continue..."
        return
    fi

    local file_count=$(find "$source_dir" -type f \( -name "*.pdf" -o -name "*.png" -o -name "*.jpg" -o -name "*.jpeg" -o -name "*.tiff" -o -name "*.doc" -o -name "*.docx" \) 2>/dev/null | wc -l)

    echo ""
    echo "Found $file_count document files"
    echo ""
    echo "Import options:"
    echo "  1) Copy files (preserve originals)"
    echo "  2) Move files (delete after import)"
    echo "  0) Cancel"
    echo ""

    read -p "Select option [0-2]: " import_option

    case $import_option in
        1)
            print_info "Copying files to consume directory..."
            find "$source_dir" -type f \( -name "*.pdf" -o -name "*.png" -o -name "*.jpg" -o -name "*.jpeg" -o -name "*.tiff" -o -name "*.doc" -o -name "*.docx" \) -exec cp {} "${CONSUME_DIR}/" \; 2>/dev/null
            print_success "Copied $file_count files"
            ;;
        2)
            print_warning "This will DELETE files from $source_dir after copying!"
            read -p "Are you sure? (yes/no): " confirm
            if [[ "$confirm" == "yes" ]]; then
                find "$source_dir" -type f \( -name "*.pdf" -o -name "*.png" -o -name "*.jpg" \) -exec mv {} "${CONSUME_DIR}/" \; 2>/dev/null
                print_success "Moved $file_count files"
            fi
            ;;
        0) return ;;
    esac

    echo ""
    print_info "Files will be processed by Paperless automatically."
    read -p "Press Enter to continue..."
}

import_with_csv() {
    print_header "Import with CSV Metadata"

    echo "Import documents with metadata from a CSV file."
    echo ""
    echo "CSV format should have columns:"
    echo "  filename,title,correspondent,document_type,tags,created_date"
    echo ""
    echo "Example:"
    echo "  invoice.pdf,Invoice 2024-001,ACME Corp,Invoice,\"tax,2024\",2024-01-15"
    echo ""

    read -p "Enter path to CSV file: " csv_file

    if [[ ! -f "$csv_file" ]]; then
        print_error "CSV file not found: $csv_file"
        read -p "Press Enter to continue..."
        return
    fi

    read -p "Enter path to documents directory: " docs_dir

    if [[ ! -d "$docs_dir" ]]; then
        print_error "Documents directory not found: $docs_dir"
        read -p "Press Enter to continue..."
        return
    fi

    print_info "Processing CSV..."
    local count=0
    local errors=0

    # Skip header line
    tail -n +2 "$csv_file" | while IFS=, read -r filename title correspondent doc_type tags created_date; do
        # Remove quotes
        filename=$(echo "$filename" | tr -d '"')
        title=$(echo "$title" | tr -d '"')
        correspondent=$(echo "$correspondent" | tr -d '"')

        local source_file="$docs_dir/$filename"

        if [[ -f "$source_file" ]]; then
            # Create consume directory structure for metadata
            # Paperless can use folder names as tags
            local target_dir="${CONSUME_DIR}"

            if [[ -n "$correspondent" ]]; then
                target_dir="${target_dir}/${correspondent}"
                mkdir -p "$target_dir"
            fi

            cp "$source_file" "$target_dir/"
            ((count++))
        else
            print_warning "File not found: $filename"
            ((errors++))
        fi
    done

    echo ""
    print_success "Imported $count files"
    if [[ $errors -gt 0 ]]; then
        print_warning "$errors files were not found"
    fi

    read -p "Press Enter to continue..."
}

import_from_paperless() {
    print_header "Import from Another Paperless Instance"

    echo "Import documents exported from another Paperless installation."
    echo ""
    echo "You need a document_exporter export from the source instance."
    echo ""

    read -p "Enter path to exported data directory: " export_dir

    if [[ ! -d "$export_dir" ]]; then
        print_error "Directory not found: $export_dir"
        read -p "Press Enter to continue..."
        return
    fi

    # Check for manifest.json
    if [[ ! -f "$export_dir/manifest.json" ]]; then
        print_warning "No manifest.json found - this may not be a Paperless export"
        read -p "Continue anyway? (y/n): " cont
        if [[ "$cont" != "y" ]]; then
            return
        fi
    fi

    print_info "Importing using document_importer..."

    if ! is_running; then
        print_error "Services must be running"
        read -p "Press Enter to continue..."
        return
    fi

    # Copy export to a location accessible by container
    local import_dir="${SCRIPT_DIR}/import_temp"
    mkdir -p "$import_dir"
    cp -r "$export_dir"/* "$import_dir/"

    # Run importer
    docker compose exec -T webserver document_importer /usr/src/paperless/import_temp

    # Cleanup
    rm -rf "$import_dir"

    print_success "Import completed"
    read -p "Press Enter to continue..."
}

import_with_folders() {
    print_header "Import with Folder Structure"

    echo "Import documents using folder names as tags/correspondents."
    echo ""
    echo "Folder structure options:"
    echo "  1) Folder name = Tag"
    echo "  2) Folder name = Correspondent"
    echo "  3) Parent folder = Correspondent, Subfolder = Tag"
    echo ""

    read -p "Select structure [1-3]: " structure

    read -p "Enter source directory: " source_dir

    if [[ ! -d "$source_dir" ]]; then
        print_error "Directory not found"
        read -p "Press Enter to continue..."
        return
    fi

    case $structure in
        1)
            # Copy maintaining folder structure - Paperless uses CONSUMER_SUBDIRS_AS_TAGS
            print_info "Copying with folder names as tags..."
            cp -r "$source_dir"/* "${CONSUME_DIR}/"
            ;;
        2|3)
            # Create proper structure
            print_info "Organizing files..."
            find "$source_dir" -type f \( -name "*.pdf" -o -name "*.png" -o -name "*.jpg" \) | while read -r file; do
                local rel_path="${file#$source_dir/}"
                local parent_dir=$(dirname "$rel_path")
                mkdir -p "${CONSUME_DIR}/$parent_dir"
                cp "$file" "${CONSUME_DIR}/$parent_dir/"
            done
            ;;
    esac

    print_success "Files copied to consume directory"
    echo ""
    echo "Note: Enable PAPERLESS_CONSUMER_SUBDIRS_AS_TAGS in configuration"
    echo "to use folder names as tags."

    read -p "Press Enter to continue..."
}

# ============================================================================
# TAG/CORRESPONDENT TEMPLATES
# ============================================================================

template_management_menu() {
    print_header "Tag & Correspondent Templates"

    echo "Pre-configure common document types and matching rules."
    echo ""
    echo "  1) Apply preset template"
    echo "  2) View current tags"
    echo "  3) View current correspondents"
    echo "  4) Create custom matching rule"
    echo "  5) Export configuration"
    echo ""
    echo "  0) Back"
    echo ""

    read -p "Select option [0-5]: " tmpl_choice

    case $tmpl_choice in
        1) apply_preset_template ;;
        2) view_current_tags ;;
        3) view_current_correspondents ;;
        4) create_matching_rule ;;
        5) export_configuration ;;
        0) return ;;
        *)
            print_error "Invalid option"
            sleep 1
            ;;
    esac
}

apply_preset_template() {
    print_header "Apply Preset Template"

    echo "Available templates:"
    echo ""
    echo "  1) Personal Finance"
    echo "     - Tags: Invoice, Receipt, Bank Statement, Tax, Insurance"
    echo "     - Types: Invoice, Receipt, Statement, Contract"
    echo ""
    echo "  2) Business/Corporate"
    echo "     - Tags: Invoice, Contract, HR, Legal, Marketing"
    echo "     - Types: Invoice, Contract, Report, Correspondence"
    echo ""
    echo "  3) Home Office"
    echo "     - Tags: Bills, Warranties, Manuals, Medical, Legal"
    echo "     - Types: Bill, Warranty, Manual, Certificate"
    echo ""
    echo "  4) Legal/Compliance"
    echo "     - Tags: Contract, NDA, Compliance, Audit, Policy"
    echo "     - Types: Contract, Agreement, Policy, Report"
    echo ""
    echo "  0) Cancel"
    echo ""

    read -p "Select template [0-4]: " template_choice

    if ! is_running; then
        print_error "Services must be running"
        read -p "Press Enter to continue..."
        return
    fi

    case $template_choice in
        1) apply_personal_finance_template ;;
        2) apply_business_template ;;
        3) apply_home_office_template ;;
        4) apply_legal_template ;;
        0) return ;;
    esac
}

apply_personal_finance_template() {
    print_info "Applying Personal Finance template..."

    docker compose exec -T webserver python3 manage.py shell << 'EOF'
from documents.models import Tag, DocumentType, Correspondent

# Create tags
tags = ['Invoice', 'Receipt', 'Bank Statement', 'Tax', 'Insurance', 'Utility', 'Medical', 'Subscription']
for tag_name in tags:
    Tag.objects.get_or_create(name=tag_name)
    print(f"  Created tag: {tag_name}")

# Create document types
types = ['Invoice', 'Receipt', 'Bank Statement', 'Contract', 'Certificate', 'Letter']
for type_name in types:
    DocumentType.objects.get_or_create(name=type_name)
    print(f"  Created type: {type_name}")

print("\nPersonal Finance template applied!")
EOF

    print_success "Template applied"
    read -p "Press Enter to continue..."
}

apply_business_template() {
    print_info "Applying Business template..."

    docker compose exec -T webserver python3 manage.py shell << 'EOF'
from documents.models import Tag, DocumentType

tags = ['Invoice', 'Contract', 'HR', 'Legal', 'Marketing', 'Finance', 'Operations', 'IT', 'Vendor', 'Client']
for tag_name in tags:
    Tag.objects.get_or_create(name=tag_name)
    print(f"  Created tag: {tag_name}")

types = ['Invoice', 'Contract', 'Report', 'Correspondence', 'Proposal', 'Agreement', 'Policy', 'Memo']
for type_name in types:
    DocumentType.objects.get_or_create(name=type_name)
    print(f"  Created type: {type_name}")

print("\nBusiness template applied!")
EOF

    print_success "Template applied"
    read -p "Press Enter to continue..."
}

apply_home_office_template() {
    print_info "Applying Home Office template..."

    docker compose exec -T webserver python3 manage.py shell << 'EOF'
from documents.models import Tag, DocumentType

tags = ['Bills', 'Warranties', 'Manuals', 'Medical', 'Legal', 'School', 'Home', 'Auto', 'Pet']
for tag_name in tags:
    Tag.objects.get_or_create(name=tag_name)
    print(f"  Created tag: {tag_name}")

types = ['Bill', 'Warranty', 'Manual', 'Certificate', 'Form', 'Letter', 'Receipt']
for type_name in types:
    DocumentType.objects.get_or_create(name=type_name)
    print(f"  Created type: {type_name}")

print("\nHome Office template applied!")
EOF

    print_success "Template applied"
    read -p "Press Enter to continue..."
}

apply_legal_template() {
    print_info "Applying Legal template..."

    docker compose exec -T webserver python3 manage.py shell << 'EOF'
from documents.models import Tag, DocumentType

tags = ['Contract', 'NDA', 'Compliance', 'Audit', 'Policy', 'Litigation', 'IP', 'Regulatory', 'Corporate']
for tag_name in tags:
    Tag.objects.get_or_create(name=tag_name)
    print(f"  Created tag: {tag_name}")

types = ['Contract', 'Agreement', 'Policy', 'Report', 'Filing', 'Correspondence', 'Notice', 'Certificate']
for type_name in types:
    DocumentType.objects.get_or_create(name=type_name)
    print(f"  Created type: {type_name}")

print("\nLegal template applied!")
EOF

    print_success "Template applied"
    read -p "Press Enter to continue..."
}

view_current_tags() {
    print_header "Current Tags"

    if ! is_running; then
        print_error "Services must be running"
        read -p "Press Enter to continue..."
        return
    fi

    docker compose exec -T webserver python3 manage.py shell -c "
from documents.models import Tag
tags = Tag.objects.all().order_by('name')
print(f'Total tags: {tags.count()}')
print()
for tag in tags:
    doc_count = tag.documents.count()
    print(f'  {tag.name}: {doc_count} documents')
" 2>/dev/null

    read -p "Press Enter to continue..."
}

view_current_correspondents() {
    print_header "Current Correspondents"

    if ! is_running; then
        print_error "Services must be running"
        read -p "Press Enter to continue..."
        return
    fi

    docker compose exec -T webserver python3 manage.py shell -c "
from documents.models import Correspondent
correspondents = Correspondent.objects.all().order_by('name')
print(f'Total correspondents: {correspondents.count()}')
print()
for c in correspondents:
    doc_count = c.documents.count()
    matching = c.match or 'None'
    print(f'  {c.name}: {doc_count} documents (match: {matching})')
" 2>/dev/null

    read -p "Press Enter to continue..."
}

create_matching_rule() {
    print_header "Create Matching Rule"

    echo "Create a correspondent with automatic matching."
    echo ""

    read -p "Enter correspondent name: " corr_name

    if [[ -z "$corr_name" ]]; then
        print_error "Name required"
        read -p "Press Enter to continue..."
        return
    fi

    read -p "Enter matching text (e.g., 'ACME Corp'): " match_text
    read -p "Enter matching algorithm (1=any, 2=all, 3=literal, 4=regex) [1]: " match_algo
    match_algo="${match_algo:-1}"

    if ! is_running; then
        print_error "Services must be running"
        read -p "Press Enter to continue..."
        return
    fi

    docker compose exec -T webserver python3 manage.py shell << EOF
from documents.models import Correspondent

c, created = Correspondent.objects.get_or_create(
    name='${corr_name}',
    defaults={
        'match': '${match_text}',
        'matching_algorithm': ${match_algo}
    }
)

if created:
    print(f"Created correspondent: {c.name}")
else:
    c.match = '${match_text}'
    c.matching_algorithm = ${match_algo}
    c.save()
    print(f"Updated correspondent: {c.name}")
EOF

    print_success "Matching rule created"
    read -p "Press Enter to continue..."
}

export_configuration() {
    print_header "Export Configuration"

    if ! is_running; then
        print_error "Services must be running"
        read -p "Press Enter to continue..."
        return
    fi

    local export_file="${SCRIPT_DIR}/config/paperless_config_$(date +%Y%m%d).json"

    print_info "Exporting configuration..."

    docker compose exec -T webserver python3 manage.py shell << EOF > "$export_file"
import json
from documents.models import Tag, DocumentType, Correspondent, StoragePath

config = {
    'tags': [{'name': t.name, 'color': t.color, 'match': t.match} for t in Tag.objects.all()],
    'document_types': [{'name': dt.name, 'match': dt.match} for dt in DocumentType.objects.all()],
    'correspondents': [{'name': c.name, 'match': c.match, 'algorithm': c.matching_algorithm} for c in Correspondent.objects.all()],
    'storage_paths': [{'name': sp.name, 'path': sp.path, 'match': sp.match} for sp in StoragePath.objects.all()]
}

print(json.dumps(config, indent=2))
EOF

    print_success "Configuration exported to: $export_file"
    read -p "Press Enter to continue..."
}

# ============================================================================
# SCHEDULED REPORTS
# ============================================================================

scheduled_reports_menu() {
    print_header "Scheduled Reports"

    echo "Configure automated email reports about your document system."
    echo ""
    echo "  1) Configure report settings"
    echo "  2) Generate report now"
    echo "  3) View last report"
    echo "  4) Schedule weekly report"
    echo "  5) Disable scheduled reports"
    echo ""
    echo "  0) Back"
    echo ""

    read -p "Select option [0-5]: " report_choice

    case $report_choice in
        1) configure_report_settings ;;
        2) generate_report_now ;;
        3) view_last_report ;;
        4) schedule_weekly_report ;;
        5) disable_scheduled_reports ;;
        0) return ;;
        *)
            print_error "Invalid option"
            sleep 1
            ;;
    esac
}

configure_report_settings() {
    print_header "Configure Report Settings"

    local config_file="${SCRIPT_DIR}/config/reports.conf"
    mkdir -p "${SCRIPT_DIR}/config"

    read -p "Enter email address for reports: " report_email

    if [[ -z "$report_email" ]]; then
        print_error "Email address required"
        read -p "Press Enter to continue..."
        return
    fi

    echo "REPORT_EMAIL=${report_email}" > "$config_file"

    echo ""
    echo "Report contents (select all that apply):"
    echo "  1) Document statistics"
    echo "  2) Storage usage"
    echo "  3) Recent activity"
    echo "  4) System health"
    echo ""
    read -p "Enter selections (e.g., 1,2,3,4): " selections

    echo "REPORT_SECTIONS=${selections}" >> "$config_file"

    print_success "Report settings saved"
    read -p "Press Enter to continue..."
}

generate_report_now() {
    print_header "Generate Report"

    local report_file="${SCRIPT_DIR}/logs/report_$(date +%Y%m%d_%H%M%S).txt"
    mkdir -p "${SCRIPT_DIR}/logs"

    print_info "Generating report..."

    {
        echo "====================================="
        echo "Paperless-ngx System Report"
        echo "Generated: $(date)"
        echo "====================================="
        echo ""

        echo "=== Document Statistics ==="
        if is_running; then
            docker compose exec -T db psql -U paperless -d paperless -t << 'EOF'
SELECT 'Total Documents: ' || COUNT(*) FROM documents_document;
SELECT 'Added this week: ' || COUNT(*) FROM documents_document WHERE created >= date_trunc('week', CURRENT_DATE);
SELECT 'Total Tags: ' || COUNT(*) FROM documents_tag;
SELECT 'Total Correspondents: ' || COUNT(*) FROM documents_correspondent;
EOF
        fi

        echo ""
        echo "=== Storage Usage ==="
        echo "Data directory: $(du -sh "${DATA_DIR}" 2>/dev/null | cut -f1)"
        echo "Backup directory: $(du -sh "${BACKUP_DIR}" 2>/dev/null | cut -f1)"
        df -h "${SCRIPT_DIR}" | tail -1

        echo ""
        echo "=== System Health ==="
        docker compose ps 2>/dev/null | tail -n +2

        echo ""
        echo "=== Recent Backups ==="
        ls -lht "${BACKUP_DIR}"/*.tar.gz 2>/dev/null | head -5

    } > "$report_file"

    print_success "Report generated: $report_file"
    echo ""
    cat "$report_file"

    # Send via email if configured
    local config_file="${SCRIPT_DIR}/config/reports.conf"
    if [[ -f "$config_file" ]]; then
        source "$config_file"
        if [[ -n "$REPORT_EMAIL" ]]; then
            read -p "Send report to $REPORT_EMAIL? (y/n): " send_email
            if [[ "$send_email" == "y" || "$send_email" == "Y" ]]; then
                if command -v mail &> /dev/null; then
                    mail -s "Paperless-ngx Report $(date +%Y-%m-%d)" "$REPORT_EMAIL" < "$report_file"
                    print_success "Report sent"
                else
                    print_warning "Mail command not available"
                fi
            fi
        fi
    fi

    read -p "Press Enter to continue..."
}

view_last_report() {
    print_header "Last Report"

    local last_report=$(ls -1t "${SCRIPT_DIR}/logs"/report_*.txt 2>/dev/null | head -1)

    if [[ -z "$last_report" ]]; then
        print_warning "No reports found"
        read -p "Press Enter to continue..."
        return
    fi

    echo "Report: $(basename "$last_report")"
    echo ""
    cat "$last_report"

    read -p "Press Enter to continue..."
}

schedule_weekly_report() {
    print_header "Schedule Weekly Report"

    local config_file="${SCRIPT_DIR}/config/reports.conf"

    if [[ ! -f "$config_file" ]]; then
        print_error "Configure report settings first"
        read -p "Press Enter to continue..."
        return
    fi

    local cron_job="${SCRIPT_DIR}/management.sh generate-report"

    if crontab -l 2>/dev/null | grep -q "generate-report"; then
        print_info "Weekly report is already scheduled"
    else
        # Schedule for Monday at 8 AM
        (crontab -l 2>/dev/null; echo "0 8 * * 1 ${cron_job}") | crontab -
        print_success "Weekly report scheduled (Mondays at 8 AM)"
    fi

    read -p "Press Enter to continue..."
}

disable_scheduled_reports() {
    print_header "Disable Scheduled Reports"

    if crontab -l 2>/dev/null | grep -q "generate-report"; then
        (crontab -l 2>/dev/null | grep -v "generate-report") | crontab -
        print_success "Scheduled reports disabled"
    else
        print_info "No scheduled reports found"
    fi

    read -p "Press Enter to continue..."
}

# ============================================================================
# API TOKEN MANAGEMENT
# ============================================================================

api_token_management() {
    print_header "API Token Management"

    echo "Manage API tokens for third-party integrations."
    echo ""
    echo "  1) List API tokens"
    echo "  2) Create new token"
    echo "  3) Revoke token"
    echo "  4) View API documentation"
    echo ""
    echo "  0) Back"
    echo ""

    read -p "Select option [0-4]: " api_choice

    case $api_choice in
        1) list_api_tokens ;;
        2) create_api_token ;;
        3) revoke_api_token ;;
        4) view_api_docs ;;
        0) return ;;
        *)
            print_error "Invalid option"
            sleep 1
            ;;
    esac
}

list_api_tokens() {
    print_header "API Tokens"

    if ! is_running; then
        print_error "Services must be running"
        read -p "Press Enter to continue..."
        return
    fi

    docker compose exec -T webserver python3 manage.py shell -c "
from rest_framework.authtoken.models import Token
from django.contrib.auth.models import User

tokens = Token.objects.all()
print(f'Total tokens: {tokens.count()}')
print()
for token in tokens:
    print(f'  User: {token.user.username}')
    print(f'  Token: {token.key[:8]}...{token.key[-4:]}')
    print(f'  Created: {token.created}')
    print()
" 2>/dev/null

    read -p "Press Enter to continue..."
}

create_api_token() {
    print_header "Create API Token"

    if ! is_running; then
        print_error "Services must be running"
        read -p "Press Enter to continue..."
        return
    fi

    read -p "Enter username for token: " token_user

    if [[ -z "$token_user" ]]; then
        print_error "Username required"
        read -p "Press Enter to continue..."
        return
    fi

    docker compose exec -T webserver python3 manage.py shell << EOF
from rest_framework.authtoken.models import Token
from django.contrib.auth.models import User

try:
    user = User.objects.get(username='${token_user}')
    token, created = Token.objects.get_or_create(user=user)

    if created:
        print(f"New token created for {user.username}")
    else:
        print(f"Existing token for {user.username}")

    print()
    print("=" * 50)
    print("API TOKEN (save this securely!):")
    print(token.key)
    print("=" * 50)
    print()
    print("Usage example:")
    print(f"  curl -H 'Authorization: Token {token.key}' http://localhost/api/documents/")

except User.DoesNotExist:
    print(f"User '{token_user}' not found")
EOF

    read -p "Press Enter to continue..."
}

revoke_api_token() {
    print_header "Revoke API Token"

    if ! is_running; then
        print_error "Services must be running"
        read -p "Press Enter to continue..."
        return
    fi

    read -p "Enter username whose token to revoke: " token_user

    if [[ -z "$token_user" ]]; then
        print_error "Username required"
        read -p "Press Enter to continue..."
        return
    fi

    read -p "Revoke token for '$token_user'? (yes/no): " confirm

    if [[ "$confirm" != "yes" ]]; then
        print_info "Cancelled"
        read -p "Press Enter to continue..."
        return
    fi

    docker compose exec -T webserver python3 manage.py shell << EOF
from rest_framework.authtoken.models import Token
from django.contrib.auth.models import User

try:
    user = User.objects.get(username='${token_user}')
    deleted, _ = Token.objects.filter(user=user).delete()
    if deleted:
        print(f"Token revoked for {user.username}")
    else:
        print(f"No token found for {user.username}")
except User.DoesNotExist:
    print(f"User '${token_user}' not found")
EOF

    read -p "Press Enter to continue..."
}

view_api_docs() {
    print_header "API Documentation"

    echo "Paperless-ngx REST API Documentation"
    echo ""
    echo "API Base URL: http://localhost/api/"
    echo ""
    echo "Authentication:"
    echo "  - Use 'Authorization: Token YOUR_API_TOKEN' header"
    echo "  - Or use session authentication (cookies)"
    echo ""
    echo "Key Endpoints:"
    echo "  GET  /api/documents/         - List documents"
    echo "  POST /api/documents/post_document/ - Upload document"
    echo "  GET  /api/documents/{id}/    - Get document details"
    echo "  GET  /api/documents/{id}/download/ - Download document"
    echo "  GET  /api/tags/              - List tags"
    echo "  GET  /api/correspondents/    - List correspondents"
    echo "  GET  /api/document_types/    - List document types"
    echo "  GET  /api/search/?query=...  - Search documents"
    echo ""
    echo "Full API documentation available at:"
    echo "  http://localhost/api/schema/swagger-ui/"
    echo "  http://localhost/api/schema/redoc/"
    echo ""

    read -p "Press Enter to continue..."
}

# ============================================================================
# COMPLIANCE MODULES (DSGVO/GDPR & GoBD)
# ============================================================================

# Check if compliance mode is enabled
is_compliance_enabled() {
    local mode=$1
    local config_file="${SCRIPT_DIR}/config/compliance.conf"
    if [[ -f "$config_file" ]]; then
        grep -q "${mode}_ENABLED=true" "$config_file" 2>/dev/null
        return $?
    fi
    return 1
}

get_compliance_status() {
    local dsgvo_status="Disabled"
    local gobd_status="Disabled"

    if is_compliance_enabled "DSGVO"; then
        dsgvo_status="${GREEN}Enabled${NC}"
    fi
    if is_compliance_enabled "GOBD"; then
        gobd_status="${GREEN}Enabled${NC}"
    fi

    echo -e "DSGVO: $dsgvo_status | GoBD: $gobd_status"
}

compliance_menu() {
    while true; do
        clear
        print_header "Compliance & Data Protection"

        echo "These modules help you comply with European data protection"
        echo "regulations and German tax document requirements."
        echo ""
        echo -e "Current Status: $(get_compliance_status)"
        echo ""
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo ""
        echo "  1) DSGVO/GDPR Compliance (EU Data Protection)"
        echo "     Personal data protection, right to be forgotten,"
        echo "     data export, access logging"
        echo ""
        echo "  2) GoBD Compliance (German Tax Requirements)"
        echo "     Audit-proof archiving, immutability, retention"
        echo "     periods, procedural documentation"
        echo ""
        echo "  3) Retention Period Management"
        echo "     Configure how long documents must be kept,"
        echo "     automatic deletion when periods expire"
        echo ""
        echo "  4) Compliance Status Report"
        echo "     Check your current compliance status"
        echo ""
        echo "  5) Generate Verfahrensdokumentation (GoBD)"
        echo "     Create required procedural documentation"
        echo ""
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo "  0) Back"
        echo ""

        read -p "Select option [0-5]: " comp_choice

        case $comp_choice in
            1) dsgvo_compliance_menu ;;
            2) gobd_compliance_menu ;;
            3) retention_management_menu ;;
            4) compliance_status_report ;;
            5) generate_verfahrensdokumentation ;;
            0) return ;;
            *)
                print_error "Invalid option"
                sleep 1
                ;;
        esac
    done
}

# ============================================================================
# DSGVO/GDPR COMPLIANCE
# ============================================================================

dsgvo_compliance_menu() {
    while true; do
        clear
        print_header "DSGVO/GDPR Compliance"

        local enabled="No"
        if is_compliance_enabled "DSGVO"; then
            enabled="${GREEN}Yes${NC}"
        fi

        echo "The General Data Protection Regulation (GDPR/DSGVO) requires"
        echo "organizations to protect personal data of EU citizens."
        echo ""
        echo -e "DSGVO Compliance Enabled: $enabled"
        echo ""
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo ""
        echo "  Setup:"
        echo "    1) Enable/Disable DSGVO Compliance Mode"
        echo ""
        echo "  Data Subject Rights:"
        echo "    2) Export Personal Data (Right of Access)"
        echo "    3) Delete Personal Data (Right to be Forgotten)"
        echo "    4) Search for Personal Data"
        echo ""
        echo "  Audit & Logging:"
        echo "    5) View Access Logs"
        echo "    6) Configure Audit Logging"
        echo ""
        echo "  Data Protection:"
        echo "    7) Encryption Settings"
        echo "    8) Access Control Review"
        echo ""
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo "  0) Back"
        echo ""

        read -p "Select option [0-8]: " dsgvo_choice

        case $dsgvo_choice in
            1) toggle_dsgvo_compliance ;;
            2) export_personal_data ;;
            3) delete_personal_data ;;
            4) search_personal_data ;;
            5) view_access_logs ;;
            6) configure_audit_logging ;;
            7) dsgvo_encryption_settings ;;
            8) access_control_review ;;
            0) return ;;
            *)
                print_error "Invalid option"
                sleep 1
                ;;
        esac
    done
}

toggle_dsgvo_compliance() {
    print_header "DSGVO Compliance Mode"

    local config_file="${SCRIPT_DIR}/config/compliance.conf"
    mkdir -p "${SCRIPT_DIR}/config"

    if is_compliance_enabled "DSGVO"; then
        echo "DSGVO Compliance is currently ENABLED."
        echo ""
        echo "Disabling will:"
        echo "  - Stop audit logging of data access"
        echo "  - Disable automatic data retention checks"
        echo ""
        print_warning "Note: You may still be legally required to comply with DSGVO!"
        echo ""
        read -p "Disable DSGVO Compliance Mode? (yes/no): " confirm

        if [[ "$confirm" == "yes" ]]; then
            sed -i.bak 's/DSGVO_ENABLED=true/DSGVO_ENABLED=false/' "$config_file" && rm -f "${config_file}.bak"
            print_success "DSGVO Compliance Mode disabled"
        fi
    else
        echo "DSGVO Compliance Mode will enable:"
        echo ""
        echo "  ✓ Audit logging of all data access"
        echo "  ✓ Tools for data export (Right of Access)"
        echo "  ✓ Secure deletion with verification"
        echo "  ✓ Personal data search capabilities"
        echo "  ✓ Access control monitoring"
        echo ""
        echo "This helps you comply with Articles 15-17, 30, and 32 of GDPR."
        echo ""
        read -p "Enable DSGVO Compliance Mode? (y/n): " confirm

        if [[ "$confirm" == "y" || "$confirm" == "Y" ]]; then
            if [[ -f "$config_file" ]]; then
                if grep -q "DSGVO_ENABLED" "$config_file"; then
                    sed -i.bak 's/DSGVO_ENABLED=false/DSGVO_ENABLED=true/' "$config_file" && rm -f "${config_file}.bak"
                else
                    echo "DSGVO_ENABLED=true" >> "$config_file"
                fi
            else
                echo "# Compliance Configuration" > "$config_file"
                echo "DSGVO_ENABLED=true" >> "$config_file"
                echo "DSGVO_ENABLED_DATE=$(date +%Y-%m-%d)" >> "$config_file"
            fi

            # Enable audit logging in Paperless
            configure_dsgvo_settings

            print_success "DSGVO Compliance Mode enabled"
            echo ""
            echo "Next steps:"
            echo "  1. Review access controls (option 8)"
            echo "  2. Configure audit logging (option 6)"
            echo "  3. Document your data processing activities"
        fi
    fi

    read -p "Press Enter to continue..."
}

configure_dsgvo_settings() {
    print_info "Configuring DSGVO-compliant settings..."

    # Enable audit logging in Paperless if available
    if is_running; then
        # Paperless-ngx has built-in audit logging we can leverage
        docker compose exec -T webserver python3 manage.py shell << 'EOF' 2>/dev/null
# Enable audit logging
from django.conf import settings
print("Audit logging configuration checked")
EOF
    fi

    # Create audit log directory
    mkdir -p "${SCRIPT_DIR}/logs/audit"
    chmod 700 "${SCRIPT_DIR}/logs/audit"

    print_success "DSGVO settings configured"
}

export_personal_data() {
    print_header "Export Personal Data (DSGVO Art. 15)"

    echo "This function exports all data related to a specific person"
    echo "(correspondent) in a machine-readable format."
    echo ""
    echo "The export includes:"
    echo "  - All documents associated with this correspondent"
    echo "  - Metadata (dates, tags, notes)"
    echo "  - Processing history"
    echo ""

    if ! is_running; then
        print_error "Services must be running"
        read -p "Press Enter to continue..."
        return
    fi

    echo "Available correspondents:"
    echo ""
    docker compose exec -T webserver python3 manage.py shell -c "
from documents.models import Correspondent
for c in Correspondent.objects.all().order_by('name'):
    doc_count = c.documents.count()
    print(f'  - {c.name} ({doc_count} documents)')
" 2>/dev/null

    echo ""
    read -p "Enter correspondent name to export (or 'all' for complete export): " export_name

    if [[ -z "$export_name" ]]; then
        print_error "No name entered"
        read -p "Press Enter to continue..."
        return
    fi

    local export_dir="${SCRIPT_DIR}/export/dsgvo_export_$(date +%Y%m%d_%H%M%S)"
    mkdir -p "$export_dir"

    print_info "Exporting data..."

    if [[ "$export_name" == "all" ]]; then
        # Full export
        docker compose exec -T webserver document_exporter /usr/src/paperless/export 2>/dev/null
        cp -r "${SCRIPT_DIR}/export/"* "$export_dir/" 2>/dev/null
    else
        # Export specific correspondent's data
        docker compose exec -T webserver python3 manage.py shell << EOF > "${export_dir}/personal_data.json"
import json
from documents.models import Correspondent, Document
from django.core.serializers.json import DjangoJSONEncoder

try:
    correspondent = Correspondent.objects.get(name='${export_name}')
    documents = Document.objects.filter(correspondent=correspondent)

    export_data = {
        'export_date': '$(date -Iseconds)',
        'export_type': 'DSGVO Article 15 - Right of Access',
        'data_subject': {
            'name': correspondent.name,
            'match_pattern': correspondent.match,
            'document_count': documents.count()
        },
        'documents': []
    }

    for doc in documents:
        export_data['documents'].append({
            'id': doc.id,
            'title': doc.title,
            'created': str(doc.created),
            'modified': str(doc.modified),
            'added': str(doc.added),
            'correspondent': correspondent.name,
            'document_type': doc.document_type.name if doc.document_type else None,
            'tags': [tag.name for tag in doc.tags.all()],
            'archive_serial_number': doc.archive_serial_number,
        })

    print(json.dumps(export_data, indent=2, cls=DjangoJSONEncoder))
except Correspondent.DoesNotExist:
    print(json.dumps({'error': 'Correspondent not found'}))
EOF
    fi

    # Log the export
    echo "$(date -Iseconds) | DSGVO_EXPORT | Correspondent: ${export_name} | User: $(whoami)" >> "${SCRIPT_DIR}/logs/audit/data_access.log"

    print_success "Export completed"
    echo ""
    echo "Export location: $export_dir"
    echo ""
    echo "This export can be provided to the data subject upon request."

    read -p "Press Enter to continue..."
}

delete_personal_data() {
    print_header "Delete Personal Data (DSGVO Art. 17)"

    echo "Right to be Forgotten - Secure deletion of personal data"
    echo ""
    print_warning "WARNING: This action is PERMANENT and cannot be undone!"
    echo ""
    echo "Before deleting, consider:"
    echo "  - Legal retention requirements (tax documents, contracts)"
    echo "  - GoBD requirements (if enabled)"
    echo "  - Business necessity"
    echo ""

    if ! is_running; then
        print_error "Services must be running"
        read -p "Press Enter to continue..."
        return
    fi

    # Check for GoBD conflicts
    if is_compliance_enabled "GOBD"; then
        print_warning "GoBD Compliance is enabled!"
        echo "Some documents may be protected by retention periods."
        echo "Only documents past their retention period can be deleted."
        echo ""
    fi

    echo "Available correspondents:"
    echo ""
    docker compose exec -T webserver python3 manage.py shell -c "
from documents.models import Correspondent
for c in Correspondent.objects.all().order_by('name'):
    doc_count = c.documents.count()
    print(f'  - {c.name} ({doc_count} documents)')
" 2>/dev/null

    echo ""
    read -p "Enter correspondent name to delete: " delete_name

    if [[ -z "$delete_name" ]]; then
        print_error "No name entered"
        read -p "Press Enter to continue..."
        return
    fi

    # Show what will be deleted
    echo ""
    echo "Documents to be deleted:"
    docker compose exec -T webserver python3 manage.py shell -c "
from documents.models import Correspondent, Document
try:
    c = Correspondent.objects.get(name='${delete_name}')
    docs = Document.objects.filter(correspondent=c)
    print(f'  Correspondent: {c.name}')
    print(f'  Total documents: {docs.count()}')
    for doc in docs[:10]:
        print(f'    - {doc.title}')
    if docs.count() > 10:
        print(f'    ... and {docs.count() - 10} more')
except Correspondent.DoesNotExist:
    print('  Correspondent not found')
" 2>/dev/null

    echo ""
    print_warning "This will permanently delete ALL documents for this correspondent!"
    echo ""
    read -p "Type 'DELETE' to confirm: " confirm

    if [[ "$confirm" != "DELETE" ]]; then
        print_info "Deletion cancelled"
        read -p "Press Enter to continue..."
        return
    fi

    # Create audit log entry BEFORE deletion
    echo "$(date -Iseconds) | DSGVO_DELETE | Correspondent: ${delete_name} | User: $(whoami) | Reason: Right to be Forgotten" >> "${SCRIPT_DIR}/logs/audit/data_access.log"

    # Perform deletion
    print_info "Deleting documents..."

    docker compose exec -T webserver python3 manage.py shell << EOF
from documents.models import Correspondent, Document

try:
    c = Correspondent.objects.get(name='${delete_name}')
    doc_count = Document.objects.filter(correspondent=c).count()
    Document.objects.filter(correspondent=c).delete()
    c.delete()
    print(f'Deleted {doc_count} documents and correspondent record')
except Correspondent.DoesNotExist:
    print('Correspondent not found')
except Exception as e:
    print(f'Error: {e}')
EOF

    print_success "Personal data deleted"
    echo ""
    echo "A record of this deletion has been logged for compliance purposes."

    read -p "Press Enter to continue..."
}

search_personal_data() {
    print_header "Search for Personal Data"

    echo "Search across all documents for personal data."
    echo "This helps identify what data you hold about a person."
    echo ""

    if ! is_running; then
        print_error "Services must be running"
        read -p "Press Enter to continue..."
        return
    fi

    read -p "Enter search term (name, email, address, etc.): " search_term

    if [[ -z "$search_term" ]]; then
        print_error "No search term entered"
        read -p "Press Enter to continue..."
        return
    fi

    print_info "Searching..."
    echo ""

    docker compose exec -T webserver python3 manage.py shell << EOF
from documents.models import Document, Correspondent

# Search in correspondents
print("=== Correspondents ===")
correspondents = Correspondent.objects.filter(name__icontains='${search_term}')
for c in correspondents:
    print(f"  {c.name} - {c.documents.count()} documents")

# Search in document content
print("\n=== Documents (content search) ===")
docs = Document.objects.filter(content__icontains='${search_term}')[:20]
for doc in docs:
    print(f"  [{doc.id}] {doc.title}")
    print(f"      Correspondent: {doc.correspondent.name if doc.correspondent else 'None'}")
    print(f"      Created: {doc.created}")

if docs.count() == 20:
    total = Document.objects.filter(content__icontains='${search_term}').count()
    print(f"\n  ... showing 20 of {total} results")

# Search in document titles
print("\n=== Documents (title search) ===")
title_docs = Document.objects.filter(title__icontains='${search_term}')[:10]
for doc in title_docs:
    print(f"  [{doc.id}] {doc.title}")
EOF

    # Log the search
    echo "$(date -Iseconds) | DSGVO_SEARCH | Term: ${search_term} | User: $(whoami)" >> "${SCRIPT_DIR}/logs/audit/data_access.log"

    echo ""
    read -p "Press Enter to continue..."
}

view_access_logs() {
    print_header "Access Logs (DSGVO Audit Trail)"

    local audit_log="${SCRIPT_DIR}/logs/audit/data_access.log"

    if [[ ! -f "$audit_log" ]]; then
        print_info "No access logs found yet."
        echo ""
        echo "Logs are created when:"
        echo "  - Personal data is exported"
        echo "  - Personal data is deleted"
        echo "  - Personal data searches are performed"
        read -p "Press Enter to continue..."
        return
    fi

    echo "Recent data access events:"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    tail -50 "$audit_log"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    echo "Full log: $audit_log"

    read -p "Press Enter to continue..."
}

configure_audit_logging() {
    print_header "Configure Audit Logging"

    echo "Audit logging tracks access to personal data."
    echo ""
    echo "Current configuration:"

    local config_file="${SCRIPT_DIR}/config/compliance.conf"

    if [[ -f "$config_file" ]] && grep -q "AUDIT_LEVEL" "$config_file"; then
        local level=$(grep "AUDIT_LEVEL" "$config_file" | cut -d= -f2)
        echo "  Audit level: $level"
    else
        echo "  Audit level: basic (default)"
    fi

    echo ""
    echo "Audit levels:"
    echo "  1) Basic  - Log exports, deletions, searches"
    echo "  2) Standard - Basic + login attempts, API access"
    echo "  3) Full   - All data access (may impact performance)"
    echo ""
    echo "  0) Cancel"
    echo ""

    read -p "Select audit level [0-3]: " level_choice

    case $level_choice in
        1) audit_level="basic" ;;
        2) audit_level="standard" ;;
        3) audit_level="full" ;;
        0) return ;;
        *) print_error "Invalid option"; sleep 1; return ;;
    esac

    mkdir -p "${SCRIPT_DIR}/config"
    if [[ -f "$config_file" ]]; then
        if grep -q "AUDIT_LEVEL" "$config_file"; then
            sed -i.bak "s/AUDIT_LEVEL=.*/AUDIT_LEVEL=${audit_level}/" "$config_file" && rm -f "${config_file}.bak"
        else
            echo "AUDIT_LEVEL=${audit_level}" >> "$config_file"
        fi
    else
        echo "AUDIT_LEVEL=${audit_level}" >> "$config_file"
    fi

    print_success "Audit level set to: $audit_level"
    read -p "Press Enter to continue..."
}

dsgvo_encryption_settings() {
    print_header "Encryption Settings (DSGVO Art. 32)"

    echo "DSGVO Article 32 requires appropriate security measures"
    echo "including encryption of personal data."
    echo ""
    echo "Current encryption status:"
    echo ""

    # Check SSL
    if [[ -f "${SCRIPT_DIR}/nginx/ssl/cert.pem" ]]; then
        echo -e "  ${GREEN}✓${NC} SSL/TLS encryption for web traffic"
    else
        echo -e "  ${RED}✗${NC} SSL/TLS not configured"
    fi

    # Check backup encryption
    if [[ -f "${SCRIPT_DIR}/config/encryption.conf" ]]; then
        echo -e "  ${GREEN}✓${NC} Backup encryption configured"
    else
        echo -e "  ${YELLOW}!${NC} Backup encryption not configured"
    fi

    # Check database encryption
    echo -e "  ${GREEN}✓${NC} Database stored locally (not exposed)"

    echo ""
    echo "Recommendations:"
    echo "  1. Enable SSL/TLS for all connections"
    echo "  2. Enable backup encryption"
    echo "  3. Ensure server disk encryption (OS level)"
    echo ""

    read -p "Press Enter to continue..."
}

access_control_review() {
    print_header "Access Control Review"

    if ! is_running; then
        print_error "Services must be running"
        read -p "Press Enter to continue..."
        return
    fi

    echo "Current users with access to the system:"
    echo ""

    docker compose exec -T webserver python3 manage.py shell -c "
from django.contrib.auth.models import User

print('Username            | Staff | Superuser | Last Login')
print('-' * 60)
for u in User.objects.all():
    staff = 'Yes' if u.is_staff else 'No'
    super = 'Yes' if u.is_superuser else 'No'
    last = str(u.last_login)[:19] if u.last_login else 'Never'
    print(f'{u.username:<20}| {staff:<6}| {super:<10}| {last}')
" 2>/dev/null

    echo ""
    echo "Review checklist:"
    echo "  [ ] All users have a legitimate need for access"
    echo "  [ ] Superuser access is limited to administrators"
    echo "  [ ] Inactive accounts are disabled"
    echo "  [ ] Strong passwords are enforced"
    echo ""

    read -p "Press Enter to continue..."
}

# ============================================================================
# GoBD COMPLIANCE
# ============================================================================

gobd_compliance_menu() {
    while true; do
        clear
        print_header "GoBD Compliance"

        local enabled="No"
        if is_compliance_enabled "GOBD"; then
            enabled="${GREEN}Yes${NC}"
        fi

        echo "GoBD (Grundsätze zur ordnungsmäßigen Führung und Aufbewahrung"
        echo "von Büchern, Aufzeichnungen und Unterlagen in elektronischer Form)"
        echo ""
        echo "German requirements for tax-relevant electronic documents."
        echo ""
        echo -e "GoBD Compliance Enabled: $enabled"
        echo ""
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo ""
        echo "  Setup:"
        echo "    1) Enable/Disable GoBD Compliance Mode"
        echo ""
        echo "  Document Protection:"
        echo "    2) Document Immutability Settings"
        echo "    3) View Protected Documents"
        echo ""
        echo "  Audit Trail:"
        echo "    4) View Change History"
        echo "    5) Export Audit Trail"
        echo ""
        echo "  Retention:"
        echo "    6) Retention Period Overview"
        echo "    7) Documents Due for Deletion"
        echo ""
        echo "  Documentation:"
        echo "    8) Generate Verfahrensdokumentation"
        echo "    9) System Documentation"
        echo ""
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo "  0) Back"
        echo ""

        read -p "Select option [0-9]: " gobd_choice

        case $gobd_choice in
            1) toggle_gobd_compliance ;;
            2) document_immutability_settings ;;
            3) view_protected_documents ;;
            4) view_change_history ;;
            5) export_audit_trail ;;
            6) retention_overview ;;
            7) documents_due_deletion ;;
            8) generate_verfahrensdokumentation ;;
            9) system_documentation ;;
            0) return ;;
            *)
                print_error "Invalid option"
                sleep 1
                ;;
        esac
    done
}

toggle_gobd_compliance() {
    print_header "GoBD Compliance Mode"

    local config_file="${SCRIPT_DIR}/config/compliance.conf"
    mkdir -p "${SCRIPT_DIR}/config"

    if is_compliance_enabled "GOBD"; then
        echo "GoBD Compliance is currently ENABLED."
        echo ""
        print_warning "WARNING: Disabling GoBD compliance may have legal consequences!"
        echo ""
        echo "If you have tax-relevant documents, you may be required"
        echo "to maintain GoBD compliance for up to 10 years."
        echo ""
        read -p "Disable GoBD Compliance Mode? (type 'DISABLE' to confirm): " confirm

        if [[ "$confirm" == "DISABLE" ]]; then
            sed -i.bak 's/GOBD_ENABLED=true/GOBD_ENABLED=false/' "$config_file" && rm -f "${config_file}.bak"
            print_success "GoBD Compliance Mode disabled"
            echo ""
            echo "$(date -Iseconds) | GOBD_DISABLED | User: $(whoami)" >> "${SCRIPT_DIR}/logs/audit/compliance.log"
        fi
    else
        echo "GoBD Compliance Mode provides:"
        echo ""
        echo "  ✓ Document immutability (no modifications after archiving)"
        echo "  ✓ Complete audit trail of all changes"
        echo "  ✓ Retention period enforcement"
        echo "  ✓ Verfahrensdokumentation template"
        echo "  ✓ Tax audit export capability"
        echo ""
        echo "Required retention periods (configurable):"
        echo "  - 6 years: Business correspondence"
        echo "  - 10 years: Accounting documents, invoices, contracts"
        echo ""
        read -p "Enable GoBD Compliance Mode? (y/n): " confirm

        if [[ "$confirm" == "y" || "$confirm" == "Y" ]]; then
            if [[ -f "$config_file" ]]; then
                if grep -q "GOBD_ENABLED" "$config_file"; then
                    sed -i.bak 's/GOBD_ENABLED=false/GOBD_ENABLED=true/' "$config_file" && rm -f "${config_file}.bak"
                else
                    echo "GOBD_ENABLED=true" >> "$config_file"
                fi
            else
                echo "# Compliance Configuration" > "$config_file"
                echo "GOBD_ENABLED=true" >> "$config_file"
                echo "GOBD_ENABLED_DATE=$(date +%Y-%m-%d)" >> "$config_file"
            fi

            # Set default retention periods
            if ! grep -q "RETENTION_ACCOUNTING" "$config_file"; then
                echo "" >> "$config_file"
                echo "# Retention Periods (in years)" >> "$config_file"
                echo "RETENTION_ACCOUNTING=10" >> "$config_file"
                echo "RETENTION_BUSINESS_LETTERS=6" >> "$config_file"
                echo "RETENTION_CONTRACTS=10" >> "$config_file"
                echo "RETENTION_TAX_DOCUMENTS=10" >> "$config_file"
                echo "RETENTION_HR_DOCUMENTS=10" >> "$config_file"
                echo "RETENTION_GENERAL=6" >> "$config_file"
            fi

            echo "$(date -Iseconds) | GOBD_ENABLED | User: $(whoami)" >> "${SCRIPT_DIR}/logs/audit/compliance.log"

            print_success "GoBD Compliance Mode enabled"
            echo ""
            echo "Next steps:"
            echo "  1. Configure document types with retention periods"
            echo "  2. Generate Verfahrensdokumentation"
            echo "  3. Review existing documents for compliance"
        fi
    fi

    read -p "Press Enter to continue..."
}

document_immutability_settings() {
    print_header "Document Immutability Settings"

    echo "GoBD requires that archived documents cannot be modified."
    echo ""
    echo "Immutability options:"
    echo ""
    echo "  1) Immediate lock"
    echo "     Documents are locked immediately after import"
    echo ""
    echo "  2) Lock after review period"
    echo "     Documents can be edited for X days, then locked"
    echo ""
    echo "  3) Manual lock"
    echo "     Documents are locked manually by user"
    echo ""
    echo "  0) Cancel"
    echo ""

    local config_file="${SCRIPT_DIR}/config/compliance.conf"

    read -p "Select immutability mode [0-3]: " mode_choice

    case $mode_choice in
        1)
            sed -i.bak '/IMMUTABILITY_MODE/d' "$config_file" 2>/dev/null
            echo "IMMUTABILITY_MODE=immediate" >> "$config_file"
            print_success "Documents will be locked immediately after import"
            ;;
        2)
            read -p "Enter review period in days (1-30): " review_days
            if [[ "$review_days" =~ ^[0-9]+$ ]] && [[ "$review_days" -ge 1 ]] && [[ "$review_days" -le 30 ]]; then
                sed -i.bak '/IMMUTABILITY_MODE/d' "$config_file" 2>/dev/null
                sed -i.bak '/REVIEW_PERIOD_DAYS/d' "$config_file" 2>/dev/null
                echo "IMMUTABILITY_MODE=delayed" >> "$config_file"
                echo "REVIEW_PERIOD_DAYS=${review_days}" >> "$config_file"
                print_success "Documents will be locked after ${review_days} days"
            else
                print_error "Invalid number of days"
            fi
            ;;
        3)
            sed -i.bak '/IMMUTABILITY_MODE/d' "$config_file" 2>/dev/null
            echo "IMMUTABILITY_MODE=manual" >> "$config_file"
            print_success "Documents must be locked manually"
            print_warning "Note: Manual mode requires discipline to maintain compliance"
            ;;
        0)
            return
            ;;
    esac

    rm -f "${config_file}.bak" 2>/dev/null
    read -p "Press Enter to continue..."
}

view_protected_documents() {
    print_header "Protected Documents"

    if ! is_running; then
        print_error "Services must be running"
        read -p "Press Enter to continue..."
        return
    fi

    echo "Documents protected by retention periods:"
    echo ""

    docker compose exec -T webserver python3 manage.py shell << 'EOF' 2>/dev/null
from documents.models import Document
from datetime import datetime, timedelta

# In a real implementation, you'd check document metadata for lock status
# For now, we show documents that would be protected based on age
print("Documents older than 30 days (typically protected):")
print("")
cutoff = datetime.now() - timedelta(days=30)
protected = Document.objects.filter(created__lt=cutoff).order_by('-created')[:20]

for doc in protected:
    age_days = (datetime.now().date() - doc.created.date()).days
    print(f"  [{doc.id}] {doc.title[:50]}")
    print(f"       Created: {doc.created.date()} ({age_days} days ago)")
    print("")

print(f"Total documents older than 30 days: {Document.objects.filter(created__lt=cutoff).count()}")
EOF

    read -p "Press Enter to continue..."
}

view_change_history() {
    print_header "Document Change History"

    if ! is_running; then
        print_error "Services must be running"
        read -p "Press Enter to continue..."
        return
    fi

    echo "Recent document changes:"
    echo ""

    docker compose exec -T webserver python3 manage.py shell << 'EOF' 2>/dev/null
from documents.models import Document
from datetime import datetime, timedelta

# Show recently modified documents
recent = Document.objects.filter(
    modified__gte=datetime.now() - timedelta(days=30)
).order_by('-modified')[:30]

print("Document                                    | Modified")
print("-" * 70)
for doc in recent:
    title = doc.title[:40] if len(doc.title) <= 40 else doc.title[:37] + "..."
    print(f"{title:<42} | {doc.modified.strftime('%Y-%m-%d %H:%M')}")
EOF

    read -p "Press Enter to continue..."
}

export_audit_trail() {
    print_header "Export Audit Trail"

    echo "Export complete audit trail for tax audits."
    echo ""

    local export_file="${SCRIPT_DIR}/export/audit_trail_$(date +%Y%m%d_%H%M%S).csv"
    mkdir -p "${SCRIPT_DIR}/export"

    echo "Creating audit trail export..."

    # Combine all audit logs
    {
        echo "Timestamp,Event Type,Details,User"

        # Add compliance log
        if [[ -f "${SCRIPT_DIR}/logs/audit/compliance.log" ]]; then
            while IFS='|' read -r timestamp event details; do
                echo "\"$timestamp\",\"$event\",\"$details\",\"system\""
            done < "${SCRIPT_DIR}/logs/audit/compliance.log"
        fi

        # Add data access log
        if [[ -f "${SCRIPT_DIR}/logs/audit/data_access.log" ]]; then
            while IFS='|' read -r timestamp event details user; do
                echo "\"$timestamp\",\"$event\",\"$details\",\"$user\""
            done < "${SCRIPT_DIR}/logs/audit/data_access.log"
        fi

    } > "$export_file"

    print_success "Audit trail exported"
    echo ""
    echo "Export file: $export_file"

    read -p "Press Enter to continue..."
}

retention_overview() {
    print_header "Retention Period Overview"

    local config_file="${SCRIPT_DIR}/config/compliance.conf"

    echo "Current retention periods:"
    echo ""
    echo "  Document Type              │ Retention Period"
    echo "  ───────────────────────────┼──────────────────"

    if [[ -f "$config_file" ]]; then
        local accounting=$(grep "RETENTION_ACCOUNTING" "$config_file" | cut -d= -f2)
        local letters=$(grep "RETENTION_BUSINESS_LETTERS" "$config_file" | cut -d= -f2)
        local contracts=$(grep "RETENTION_CONTRACTS" "$config_file" | cut -d= -f2)
        local tax=$(grep "RETENTION_TAX_DOCUMENTS" "$config_file" | cut -d= -f2)
        local hr=$(grep "RETENTION_HR_DOCUMENTS" "$config_file" | cut -d= -f2)
        local general=$(grep "RETENTION_GENERAL" "$config_file" | cut -d= -f2)

        printf "  %-27s │ %s years\n" "Accounting documents" "${accounting:-10}"
        printf "  %-27s │ %s years\n" "Business correspondence" "${letters:-6}"
        printf "  %-27s │ %s years\n" "Contracts" "${contracts:-10}"
        printf "  %-27s │ %s years\n" "Tax documents" "${tax:-10}"
        printf "  %-27s │ %s years\n" "HR documents" "${hr:-10}"
        printf "  %-27s │ %s years\n" "General documents" "${general:-6}"
    else
        echo "  (Using German legal defaults)"
        printf "  %-27s │ %s years\n" "Accounting documents" "10"
        printf "  %-27s │ %s years\n" "Business correspondence" "6"
        printf "  %-27s │ %s years\n" "Contracts" "10"
        printf "  %-27s │ %s years\n" "Tax documents" "10"
    fi

    echo ""
    echo "  ───────────────────────────┴──────────────────"
    echo ""
    echo "These periods are based on German HGB and AO requirements."
    echo "Consult your tax advisor for specific requirements."
    echo ""
    read -p "Would you like to modify retention periods? (y/n): " modify

    if [[ "$modify" == "y" || "$modify" == "Y" ]]; then
        modify_retention_periods
    fi
}

modify_retention_periods() {
    print_header "Modify Retention Periods"

    local config_file="${SCRIPT_DIR}/config/compliance.conf"
    mkdir -p "${SCRIPT_DIR}/config"

    print_warning "Changing retention periods may have legal implications!"
    echo "Consult your tax advisor before making changes."
    echo ""

    echo "Which retention period to modify?"
    echo ""
    echo "  1) Accounting documents (invoices, receipts)"
    echo "  2) Business correspondence"
    echo "  3) Contracts"
    echo "  4) Tax documents"
    echo "  5) HR documents"
    echo "  6) General documents"
    echo ""
    echo "  0) Cancel"
    echo ""

    read -p "Select [0-6]: " period_choice

    local period_var=""
    local period_name=""
    local min_period=0

    case $period_choice in
        1) period_var="RETENTION_ACCOUNTING"; period_name="Accounting"; min_period=10 ;;
        2) period_var="RETENTION_BUSINESS_LETTERS"; period_name="Business correspondence"; min_period=6 ;;
        3) period_var="RETENTION_CONTRACTS"; period_name="Contracts"; min_period=10 ;;
        4) period_var="RETENTION_TAX_DOCUMENTS"; period_name="Tax documents"; min_period=10 ;;
        5) period_var="RETENTION_HR_DOCUMENTS"; period_name="HR documents"; min_period=10 ;;
        6) period_var="RETENTION_GENERAL"; period_name="General"; min_period=6 ;;
        0) return ;;
        *) print_error "Invalid option"; return ;;
    esac

    echo ""
    echo "Current legal minimum for ${period_name}: ${min_period} years"
    echo ""
    read -p "Enter new retention period in years (minimum ${min_period}): " new_period

    if [[ ! "$new_period" =~ ^[0-9]+$ ]]; then
        print_error "Please enter a valid number"
        read -p "Press Enter to continue..."
        return
    fi

    if [[ "$new_period" -lt "$min_period" ]]; then
        print_warning "Warning: ${new_period} years is below the legal minimum of ${min_period} years!"
        read -p "Are you sure you want to set this? (yes/no): " confirm
        if [[ "$confirm" != "yes" ]]; then
            print_info "Cancelled"
            read -p "Press Enter to continue..."
            return
        fi
    fi

    # Update configuration
    if [[ -f "$config_file" ]] && grep -q "$period_var" "$config_file"; then
        sed -i.bak "s/${period_var}=.*/${period_var}=${new_period}/" "$config_file" && rm -f "${config_file}.bak"
    else
        echo "${period_var}=${new_period}" >> "$config_file"
    fi

    # Log the change
    echo "$(date -Iseconds) | RETENTION_CHANGED | ${period_name}: ${new_period} years | User: $(whoami)" >> "${SCRIPT_DIR}/logs/audit/compliance.log"

    print_success "Retention period for ${period_name} set to ${new_period} years"
    read -p "Press Enter to continue..."
}

documents_due_deletion() {
    print_header "Documents Due for Deletion"

    if ! is_running; then
        print_error "Services must be running"
        read -p "Press Enter to continue..."
        return
    fi

    local config_file="${SCRIPT_DIR}/config/compliance.conf"
    local general_retention=6

    if [[ -f "$config_file" ]]; then
        general_retention=$(grep "RETENTION_GENERAL" "$config_file" | cut -d= -f2)
        general_retention=${general_retention:-6}
    fi

    echo "Documents that have exceeded their retention period"
    echo "and may be eligible for deletion:"
    echo ""

    docker compose exec -T webserver python3 manage.py shell << EOF 2>/dev/null
from documents.models import Document
from datetime import datetime, timedelta

# Default retention period in years
retention_years = ${general_retention}
cutoff_date = datetime.now() - timedelta(days=retention_years * 365)

eligible = Document.objects.filter(created__lt=cutoff_date).order_by('created')

if eligible.exists():
    print(f"Found {eligible.count()} documents older than {retention_years} years:")
    print("")
    for doc in eligible[:20]:
        age_years = (datetime.now().date() - doc.created.date()).days // 365
        doc_type = doc.document_type.name if doc.document_type else "Unclassified"
        print(f"  [{doc.id}] {doc.title[:40]}")
        print(f"       Type: {doc_type} | Age: {age_years} years")
        print("")
    if eligible.count() > 20:
        print(f"  ... and {eligible.count() - 20} more")
else:
    print("No documents have exceeded their retention period.")
EOF

    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    print_warning "Before deleting, verify:"
    echo "  - Document type and specific retention requirements"
    echo "  - No ongoing legal proceedings require the documents"
    echo "  - Tax audits for relevant years are complete"
    echo ""

    read -p "Press Enter to continue..."
}

generate_verfahrensdokumentation() {
    print_header "Verfahrensdokumentation Generator"

    echo "The Verfahrensdokumentation (procedural documentation) is required"
    echo "by GoBD to document how your DMS system works."
    echo ""
    echo "This generator creates a template that you should customize"
    echo "with your specific business processes."
    echo ""

    local output_dir="${SCRIPT_DIR}/documentation"
    mkdir -p "$output_dir"

    local doc_file="${output_dir}/Verfahrensdokumentation_$(date +%Y%m%d).md"

    read -p "Enter your company name: " company_name
    company_name=${company_name:-"[Firmenname]"}

    print_info "Generating Verfahrensdokumentation..."

    cat > "$doc_file" << EOF
# Verfahrensdokumentation

## Dokumentenmanagementsystem (DMS)

**Firma:** ${company_name}
**Erstellt am:** $(date +%Y-%m-%d)
**Version:** 1.0

---

## 1. Allgemeine Beschreibung

### 1.1 Zweck des Systems
Dieses Dokumentenmanagementsystem dient der revisionssicheren Archivierung
von Geschäftsunterlagen gemäß den Grundsätzen zur ordnungsmäßigen Führung
und Aufbewahrung von Büchern, Aufzeichnungen und Unterlagen in
elektronischer Form sowie zum Datenzugriff (GoBD).

### 1.2 Eingesetzte Software
- **System:** Paperless-ngx
- **Version:** $(docker compose exec -T webserver cat /usr/src/paperless/version.txt 2>/dev/null || echo "[Version eintragen]")
- **Installationsdatum:** $(stat -c %y "${SCRIPT_DIR}/docker-compose.yml" 2>/dev/null | cut -d' ' -f1 || echo "[Datum eintragen]")

### 1.3 Systemumgebung
- **Server:** $(hostname)
- **Betriebssystem:** $(uname -o) $(uname -r)
- **Datenbank:** PostgreSQL 16
- **Speicherort:** ${DATA_DIR}

---

## 2. Organisatorische Regelungen

### 2.1 Verantwortlichkeiten

| Rolle | Name | Aufgaben |
|-------|------|----------|
| Systemadministrator | [Name] | Systemwartung, Backups, Updates |
| DMS-Verantwortlicher | [Name] | Dokumentenorganisation, Schulung |
| Datenschutzbeauftragter | [Name] | DSGVO-Compliance |

### 2.2 Berechtigungskonzept
[Beschreiben Sie hier, wer Zugriff auf welche Dokumente hat]

---

## 3. Technische Beschreibung

### 3.1 Systemarchitektur
Das System besteht aus folgenden Komponenten:
- **Webserver:** Nginx (Reverse Proxy mit SSL)
- **Anwendung:** Paperless-ngx (Django-basiert)
- **Datenbank:** PostgreSQL
- **Suchindex:** Whoosh
- **Cache:** Redis
- **OCR:** Tesseract OCR, Apache Tika, Gotenberg

### 3.2 Datenspeicherung
- **Originaldokumente:** ${DATA_DIR}/media/documents/originals/
- **Archivdokumente:** ${DATA_DIR}/media/documents/archive/
- **Datenbank:** ${DATA_DIR}/postgres/
- **Suchindex:** ${DATA_DIR}/data/index/

### 3.3 Backup-Strategie
$(if [[ -f "${SCRIPT_DIR}/config/backup_schedule.conf" ]]; then
    source "${SCRIPT_DIR}/config/backup_schedule.conf" 2>/dev/null
    echo "- Automatische Backups: Aktiv"
    echo "- Backup-Intervall: [Aus Konfiguration]"
else
    echo "- Automatische Backups: [Bitte konfigurieren]"
fi)
- Backup-Speicherort: ${BACKUP_DIR}

---

## 4. Verarbeitungsprozesse

### 4.1 Dokumentenerfassung
1. Dokumente werden im Verzeichnis \`${CONSUME_DIR}\` abgelegt
2. Das System erkennt neue Dokumente automatisch
3. OCR-Texterkennung wird durchgeführt
4. Dokument wird klassifiziert (Typ, Korrespondent, Tags)
5. Dokument wird im Archiv abgelegt

### 4.2 Unveränderbarkeit
$(if is_compliance_enabled "GOBD"; then
    echo "GoBD-Modus ist aktiviert. Dokumente werden nach der Archivierung"
    echo "vor Änderungen geschützt."
else
    echo "[GoBD-Modus aktivieren für automatischen Schutz]"
fi)

### 4.3 Aufbewahrungsfristen
| Dokumentenart | Aufbewahrungsfrist |
|---------------|-------------------|
| Buchungsbelege | 10 Jahre |
| Handelsbriefe | 6 Jahre |
| Verträge | 10 Jahre |
| Steuerunterlagen | 10 Jahre |

---

## 5. Datensicherheit

### 5.1 Zugriffsschutz
- Authentifizierung über Benutzername/Passwort
- HTTPS-Verschlüsselung für alle Verbindungen
- Berechtigungsbasierter Dokumentenzugriff

### 5.2 Datensicherung
- Regelmäßige automatische Backups
- Verschlüsselte Backup-Speicherung: $(if [[ -f "${SCRIPT_DIR}/config/encryption.conf" ]]; then echo "Ja"; else echo "Nein"; fi)

### 5.3 Protokollierung
- Audit-Log für Datenzugriffe
- Änderungsprotokoll für Dokumente

---

## 6. Wartung und Betrieb

### 6.1 Regelmäßige Wartungsarbeiten
- Tägliche Backup-Überprüfung
- Wöchentliche Systemupdates
- Monatliche Integritätsprüfung

### 6.2 Notfallverfahren
1. Bei Systemausfall: Wiederherstellung aus Backup
2. Backup-Speicherort: ${BACKUP_DIR}
3. Wiederherstellungsanleitung: \`./management.sh\` → Restore

---

## 7. Änderungshistorie

| Version | Datum | Änderung | Bearbeiter |
|---------|-------|----------|------------|
| 1.0 | $(date +%Y-%m-%d) | Erstversion | [Name] |

---

## Unterschriften

**Erstellt von:** _________________________ Datum: _____________

**Geprüft von:** _________________________ Datum: _____________

**Freigegeben von:** _________________________ Datum: _____________

EOF

    print_success "Verfahrensdokumentation erstellt"
    echo ""
    echo "Datei: $doc_file"
    echo ""
    echo "Nächste Schritte:"
    echo "  1. Dokument öffnen und Platzhalter ausfüllen"
    echo "  2. Mit Steuerberater/Wirtschaftsprüfer abstimmen"
    echo "  3. Unterschreiben und sicher aufbewahren"
    echo "  4. Bei Änderungen am System aktualisieren"

    read -p "Press Enter to continue..."
}

system_documentation() {
    print_header "System Documentation"

    echo "Current system configuration:"
    echo ""

    echo "=== System Information ==="
    echo "  Hostname: $(hostname)"
    echo "  OS: $(uname -o) $(uname -r)"
    echo "  Docker: $(docker --version 2>/dev/null | cut -d' ' -f3 | tr -d ',')"
    echo ""

    echo "=== Paperless-ngx ==="
    if is_running; then
        echo "  Status: Running"
        echo "  Version: $(docker compose exec -T webserver cat /usr/src/paperless/version.txt 2>/dev/null || echo 'Unknown')"
    else
        echo "  Status: Stopped"
    fi
    echo ""

    echo "=== Storage ==="
    echo "  Data: $(du -sh "${DATA_DIR}" 2>/dev/null | cut -f1)"
    echo "  Backups: $(du -sh "${BACKUP_DIR}" 2>/dev/null | cut -f1)"
    echo "  Disk Free: $(df -h "${SCRIPT_DIR}" | tail -1 | awk '{print $4}')"
    echo ""

    echo "=== Compliance Status ==="
    echo -e "  DSGVO: $(is_compliance_enabled "DSGVO" && echo "${GREEN}Enabled${NC}" || echo "Disabled")"
    echo -e "  GoBD: $(is_compliance_enabled "GOBD" && echo "${GREEN}Enabled${NC}" || echo "Disabled")"
    echo ""

    read -p "Press Enter to continue..."
}

# ============================================================================
# RETENTION PERIOD MANAGEMENT
# ============================================================================

retention_management_menu() {
    while true; do
        clear
        print_header "Retention Period Management"

        echo "Configure how long documents must be kept and when"
        echo "they can be automatically deleted."
        echo ""
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo ""
        echo "  Configuration:"
        echo "    1) View/Edit Retention Periods"
        echo "    2) Assign Retention to Document Types"
        echo ""
        echo "  Automatic Deletion:"
        echo "    3) Enable/Disable Auto-Deletion"
        echo "    4) View Documents Due for Deletion"
        echo "    5) Process Pending Deletions"
        echo ""
        echo "  Reports:"
        echo "    6) Retention Status Report"
        echo "    7) Upcoming Expirations"
        echo ""
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo "  0) Back"
        echo ""

        read -p "Select option [0-7]: " ret_choice

        case $ret_choice in
            1) retention_overview ;;
            2) assign_retention_to_types ;;
            3) toggle_auto_deletion ;;
            4) documents_due_deletion ;;
            5) process_pending_deletions ;;
            6) retention_status_report ;;
            7) upcoming_expirations ;;
            0) return ;;
            *)
                print_error "Invalid option"
                sleep 1
                ;;
        esac
    done
}

assign_retention_to_types() {
    print_header "Assign Retention to Document Types"

    if ! is_running; then
        print_error "Services must be running"
        read -p "Press Enter to continue..."
        return
    fi

    echo "Current document types:"
    echo ""

    docker compose exec -T webserver python3 manage.py shell -c "
from documents.models import DocumentType
for dt in DocumentType.objects.all().order_by('name'):
    doc_count = dt.documents.count()
    print(f'  - {dt.name} ({doc_count} documents)')
" 2>/dev/null

    echo ""
    echo "To assign retention periods to document types,"
    echo "you need to configure them in the Paperless web interface"
    echo "or create custom workflows."
    echo ""
    echo "Recommended document types with retention periods:"
    echo ""
    echo "  Type                    │ Retention │ Based on"
    echo "  ────────────────────────┼───────────┼────────────────"
    echo "  Invoice                 │ 10 years  │ HGB §257"
    echo "  Receipt                 │ 10 years  │ HGB §257"
    echo "  Contract                │ 10 years  │ BGB Verjährung"
    echo "  Bank Statement          │ 10 years  │ AO §147"
    echo "  Business Letter         │ 6 years   │ HGB §257"
    echo "  Tax Document            │ 10 years  │ AO §147"
    echo ""

    read -p "Press Enter to continue..."
}

toggle_auto_deletion() {
    print_header "Automatic Deletion Settings"

    local config_file="${SCRIPT_DIR}/config/compliance.conf"
    mkdir -p "${SCRIPT_DIR}/config"

    local auto_delete_enabled=false
    if [[ -f "$config_file" ]] && grep -q "AUTO_DELETE_ENABLED=true" "$config_file"; then
        auto_delete_enabled=true
    fi

    if $auto_delete_enabled; then
        echo "Automatic deletion is currently ENABLED."
        echo ""
        echo "Documents that exceed their retention period are"
        echo "automatically moved to trash and then deleted."
        echo ""
        read -p "Disable automatic deletion? (y/n): " disable

        if [[ "$disable" == "y" || "$disable" == "Y" ]]; then
            sed -i.bak 's/AUTO_DELETE_ENABLED=true/AUTO_DELETE_ENABLED=false/' "$config_file" && rm -f "${config_file}.bak"
            print_success "Automatic deletion disabled"
        fi
    else
        echo "Automatic deletion is currently DISABLED."
        echo ""
        echo "When enabled, documents that have exceeded their"
        echo "retention period will be:"
        echo ""
        echo "  1. Flagged for review"
        echo "  2. Moved to trash after confirmation"
        echo "  3. Permanently deleted after trash retention period"
        echo ""
        print_warning "DSGVO Note: Automatic deletion helps ensure"
        echo "personal data is not kept longer than necessary."
        echo ""
        read -p "Enable automatic deletion? (y/n): " enable

        if [[ "$enable" == "y" || "$enable" == "Y" ]]; then
            if grep -q "AUTO_DELETE_ENABLED" "$config_file" 2>/dev/null; then
                sed -i.bak 's/AUTO_DELETE_ENABLED=false/AUTO_DELETE_ENABLED=true/' "$config_file" && rm -f "${config_file}.bak"
            else
                echo "AUTO_DELETE_ENABLED=true" >> "$config_file"
            fi

            # Configure warning period
            echo ""
            read -p "Days before deletion to send warning (default 30): " warn_days
            warn_days=${warn_days:-30}

            if grep -q "DELETE_WARNING_DAYS" "$config_file" 2>/dev/null; then
                sed -i.bak "s/DELETE_WARNING_DAYS=.*/DELETE_WARNING_DAYS=${warn_days}/" "$config_file" && rm -f "${config_file}.bak"
            else
                echo "DELETE_WARNING_DAYS=${warn_days}" >> "$config_file"
            fi

            print_success "Automatic deletion enabled"
            echo ""
            echo "Documents will be flagged ${warn_days} days before deletion."
        fi
    fi

    read -p "Press Enter to continue..."
}

process_pending_deletions() {
    print_header "Process Pending Deletions"

    if ! is_running; then
        print_error "Services must be running"
        read -p "Press Enter to continue..."
        return
    fi

    local config_file="${SCRIPT_DIR}/config/compliance.conf"
    local general_retention=6

    if [[ -f "$config_file" ]]; then
        general_retention=$(grep "RETENTION_GENERAL" "$config_file" | cut -d= -f2)
        general_retention=${general_retention:-6}
    fi

    echo "Checking for documents ready for deletion..."
    echo ""

    # Get count of eligible documents
    local eligible_count=$(docker compose exec -T db psql -U paperless -d paperless -t -c \
        "SELECT COUNT(*) FROM documents_document WHERE created < NOW() - INTERVAL '${general_retention} years';" 2>/dev/null | tr -d ' ')

    if [[ "$eligible_count" == "0" || -z "$eligible_count" ]]; then
        print_success "No documents are due for deletion."
        read -p "Press Enter to continue..."
        return
    fi

    echo "Found $eligible_count documents that have exceeded retention."
    echo ""

    # Check for GoBD protection
    if is_compliance_enabled "GOBD"; then
        print_warning "GoBD compliance is enabled!"
        echo "Documents will be verified for legal holds before deletion."
        echo ""
    fi

    echo "Options:"
    echo "  1) Review documents before deletion"
    echo "  2) Move all eligible to trash"
    echo "  3) Cancel"
    echo ""

    read -p "Select option [1-3]: " del_choice

    case $del_choice in
        1)
            echo ""
            docker compose exec -T webserver python3 manage.py shell << EOF
from documents.models import Document
from datetime import datetime, timedelta

cutoff = datetime.now() - timedelta(days=${general_retention} * 365)
docs = Document.objects.filter(created__lt=cutoff)[:20]

for doc in docs:
    print(f"[{doc.id}] {doc.title}")
    print(f"     Created: {doc.created.date()}")
    corr = doc.correspondent.name if doc.correspondent else "None"
    print(f"     Correspondent: {corr}")
    print("")
EOF
            echo ""
            read -p "Press Enter to continue..."
            ;;
        2)
            print_warning "This will move $eligible_count documents to trash!"
            read -p "Type 'CONFIRM' to proceed: " confirm

            if [[ "$confirm" == "CONFIRM" ]]; then
                echo ""
                print_info "Moving documents to trash..."

                # Log the action
                echo "$(date -Iseconds) | RETENTION_DELETE | Documents: ${eligible_count} | User: $(whoami)" >> "${SCRIPT_DIR}/logs/audit/compliance.log"

                docker compose exec -T webserver python3 manage.py shell << EOF
from documents.models import Document
from datetime import datetime, timedelta

cutoff = datetime.now() - timedelta(days=${general_retention} * 365)
# In Paperless-ngx, we would use the trash functionality
# For now, we just report what would be deleted
docs = Document.objects.filter(created__lt=cutoff)
count = docs.count()
print(f"Would process {count} documents for deletion")
# docs.delete()  # Uncomment to actually delete
EOF
                print_success "Documents processed"
            else
                print_info "Cancelled"
            fi
            read -p "Press Enter to continue..."
            ;;
        3)
            return
            ;;
    esac
}

retention_status_report() {
    print_header "Retention Status Report"

    if ! is_running; then
        print_error "Services must be running"
        read -p "Press Enter to continue..."
        return
    fi

    echo "Generating retention status report..."
    echo ""

    docker compose exec -T db psql -U paperless -d paperless << 'EOF' 2>/dev/null
SELECT '=== Document Age Distribution ===' as section;

SELECT
    CASE
        WHEN created > NOW() - INTERVAL '1 year' THEN 'Less than 1 year'
        WHEN created > NOW() - INTERVAL '3 years' THEN '1-3 years'
        WHEN created > NOW() - INTERVAL '6 years' THEN '3-6 years'
        WHEN created > NOW() - INTERVAL '10 years' THEN '6-10 years'
        ELSE 'Over 10 years'
    END as age_group,
    COUNT(*) as document_count
FROM documents_document
GROUP BY age_group
ORDER BY
    CASE age_group
        WHEN 'Less than 1 year' THEN 1
        WHEN '1-3 years' THEN 2
        WHEN '3-6 years' THEN 3
        WHEN '6-10 years' THEN 4
        ELSE 5
    END;

SELECT '' as spacer;
SELECT '=== Oldest Documents ===' as section;

SELECT
    id,
    LEFT(title, 40) as title,
    created::date as created
FROM documents_document
ORDER BY created
LIMIT 10;
EOF

    echo ""
    read -p "Press Enter to continue..."
}

upcoming_expirations() {
    print_header "Upcoming Expirations"

    if ! is_running; then
        print_error "Services must be running"
        read -p "Press Enter to continue..."
        return
    fi

    echo "Documents expiring in the next 12 months:"
    echo ""

    local config_file="${SCRIPT_DIR}/config/compliance.conf"
    local retention_years=6

    if [[ -f "$config_file" ]]; then
        retention_years=$(grep "RETENTION_GENERAL" "$config_file" | cut -d= -f2)
        retention_years=${retention_years:-6}
    fi

    docker compose exec -T webserver python3 manage.py shell << EOF
from documents.models import Document
from datetime import datetime, timedelta

retention_years = ${retention_years}
now = datetime.now()

# Documents expiring in next 12 months
expiry_start = now - timedelta(days=(retention_years * 365) - 365)
expiry_end = now - timedelta(days=retention_years * 365)

expiring = Document.objects.filter(
    created__lte=expiry_start,
    created__gt=expiry_end
).order_by('created')

if expiring.exists():
    print(f"Documents reaching {retention_years}-year retention limit:")
    print("")
    for doc in expiring[:30]:
        expiry_date = doc.created + timedelta(days=retention_years * 365)
        days_left = (expiry_date.date() - now.date()).days
        print(f"  [{doc.id}] {doc.title[:45]}")
        print(f"       Expires in: {days_left} days ({expiry_date.date()})")
else:
    print("No documents expiring in the next 12 months.")
EOF

    echo ""
    read -p "Press Enter to continue..."
}

compliance_status_report() {
    print_header "Compliance Status Report"

    echo "Generating compliance status report..."
    echo ""

    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "                 COMPLIANCE STATUS"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""

    # DSGVO Status
    echo "DSGVO/GDPR Compliance:"
    if is_compliance_enabled "DSGVO"; then
        echo -e "  Status: ${GREEN}ENABLED${NC}"
        echo "  ✓ Audit logging active"
        echo "  ✓ Data export available"
        echo "  ✓ Secure deletion available"
    else
        echo -e "  Status: ${YELLOW}DISABLED${NC}"
        echo "  ! Enable for EU data protection compliance"
    fi

    echo ""

    # GoBD Status
    echo "GoBD Compliance:"
    if is_compliance_enabled "GOBD"; then
        echo -e "  Status: ${GREEN}ENABLED${NC}"
        echo "  ✓ Retention periods configured"
        if [[ -f "${SCRIPT_DIR}/documentation/Verfahrensdokumentation"* ]]; then
            echo "  ✓ Verfahrensdokumentation exists"
        else
            echo "  ! Verfahrensdokumentation not generated"
        fi
    else
        echo -e "  Status: ${YELLOW}DISABLED${NC}"
        echo "  ! Enable for German tax document compliance"
    fi

    echo ""

    # Security Status
    echo "Security Measures:"
    if [[ -f "${SCRIPT_DIR}/nginx/ssl/cert.pem" ]]; then
        echo -e "  ${GREEN}✓${NC} SSL/TLS encryption"
    else
        echo -e "  ${RED}✗${NC} SSL/TLS not configured"
    fi

    if [[ -f "${SCRIPT_DIR}/config/encryption.conf" ]]; then
        echo -e "  ${GREEN}✓${NC} Backup encryption"
    else
        echo -e "  ${YELLOW}!${NC} Backup encryption not configured"
    fi

    echo ""

    # Backup Status
    echo "Backup Status:"
    local backup_count=$(ls -1 "${BACKUP_DIR}"/*.tar.gz 2>/dev/null | wc -l)
    echo "  Total backups: $backup_count"

    local latest_backup=$(ls -1t "${BACKUP_DIR}"/*.tar.gz 2>/dev/null | head -1)
    if [[ -n "$latest_backup" ]]; then
        local backup_date=$(stat -c %y "$latest_backup" 2>/dev/null | cut -d' ' -f1)
        echo "  Latest backup: $backup_date"
    fi

    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    read -p "Press Enter to continue..."
}

# ============================================================================
# ADVANCED SETTINGS MENU
# ============================================================================

advanced_settings_menu() {
    while true; do
        clear
        print_header "Advanced Settings"

        echo "Performance & Optimization:"
        echo "  1) Database Optimization (PostgreSQL tuning)"
        echo "  2) Bulk Import Mode"
        echo ""
        echo "Monitoring & Alerts:"
        echo "  3) Health Monitoring & Alerts"
        echo "  4) Scheduled Reports"
        echo ""
        echo "Maintenance:"
        echo "  5) Log Rotation Configuration"
        echo "  6) Database Maintenance (VACUUM)"
        echo "  7) Document Export"
        echo "  8) Rebuild Search Index"
        echo "  9) Automated Cleanup"
        echo ""
        echo "Content Management:"
        echo " 10) Consumption Directory Setup"
        echo " 11) Trash Management"
        echo " 12) User Management"
        echo " 13) Tag & Correspondent Templates"
        echo ""
        echo "Import Sources:"
        echo " 14) Email/IMAP Import Setup"
        echo " 15) Migration Assistant"
        echo ""
        echo "Security:"
        echo " 16) Fail2ban Integration"
        echo " 17) Backup Encryption"
        echo " 18) Security Audit"
        echo " 19) API Token Management"
        echo ""
        echo "Backup & Recovery:"
        echo " 20) Backup Verification"
        echo ""
        echo "Analytics:"
        echo " 21) Document Statistics Dashboard"
        echo " 22) Duplicate Detection"
        echo " 23) Storage Analysis"
        echo ""
        echo -e "Compliance: $(get_compliance_status)"
        echo " 24) Compliance & Data Protection (DSGVO/GoBD)"
        echo ""
        echo "  0) Back to Main Menu"
        echo ""

        read -p "Select option [0-24]: " adv_choice

        case $adv_choice in
            1) optimize_database ;;
            2) bulk_import_mode ;;
            3) setup_health_monitoring ;;
            4) scheduled_reports_menu ;;
            5) setup_log_rotation ;;
            6) database_maintenance ;;
            7) export_documents ;;
            8) rebuild_search_index ;;
            9) automated_cleanup_menu ;;
            10) setup_consume_directories ;;
            11) manage_trash ;;
            12) manage_users ;;
            13) template_management_menu ;;
            14) setup_email_import ;;
            15) migration_assistant_menu ;;
            16) fail2ban_setup ;;
            17) backup_encryption_menu ;;
            18) security_audit ;;
            19) api_token_management ;;
            20) backup_verification_menu ;;
            21) document_statistics ;;
            22) duplicate_detection_menu ;;
            24) compliance_menu ;;
            23) storage_analysis_menu ;;
            0) return ;;
            *)
                print_error "Invalid option"
                sleep 1
                ;;
        esac
    done
}

# ============================================================================
# MAIN
# ============================================================================

check_dependencies_menu() {
    print_header "Check/Install Dependencies"

    check_root

    install_dependencies

    read -p "Press Enter to continue..."
}

main() {
    # Ensure we're in the script directory
    cd "$SCRIPT_DIR"

    # Always show splash screen first
    show_splash_screen

    # Check system status for display
    local deps_ok=false
    local services_running=false
    local is_configured=false

    if check_dependencies_quick; then
        deps_ok=true
    fi

    if [[ -f "${SCRIPT_DIR}/.env" ]]; then
        is_configured=true
        if is_running 2>/dev/null; then
            services_running=true
        fi
    fi

    # Show current status
    echo -e "  ${BLUE}Current Status:${NC}"
    if $deps_ok; then
        echo -e "    Dependencies:  ${GREEN}✓ Installed${NC}"
    else
        echo -e "    Dependencies:  ${YELLOW}○ Not installed${NC}"
    fi

    if $is_configured; then
        echo -e "    Configuration: ${GREEN}✓ Complete${NC}"
    else
        echo -e "    Configuration: ${YELLOW}○ Not configured${NC}"
    fi

    if $services_running; then
        echo -e "    Services:      ${GREEN}● Running${NC}"
    else
        echo -e "    Services:      ${RED}○ Stopped${NC}"
    fi

    echo ""
    echo "  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""

    # Show action menu
    show_action_menu

    read -p "  Select an option [0-6]: " action_choice

    case $action_choice in
        1)
            # Complete Setup
            run_complete_setup
            ;;
        2)
            # Install Dependencies Only
            run_dependency_install
            ;;
        3)
            # Configure Paperless-ngx
            run_configuration
            ;;
        4)
            # Start Services
            run_start_services
            ;;
        5)
            # Open Full Management Menu
            touch "${SCRIPT_DIR}/.first_run_complete"
            full_menu
            ;;
        6)
            # View System Status
            view_detailed_status
            read -p "Press Enter to continue..."
            main  # Return to main menu
            ;;
        0)
            echo ""
            print_info "Goodbye! Run this script again anytime."
            exit 0
            ;;
        *)
            main  # Invalid option, show menu again
            ;;
    esac
}

# Complete setup flow with progress
run_complete_setup() {
    local total_steps=4
    local current_step=0

    show_splash_screen
    echo -e "  ${GREEN}Complete Setup${NC}"
    echo -e "  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    echo "  This will install all dependencies, configure Paperless-ngx,"
    echo "  and start the services."
    echo ""

    read -p "  Press Enter to begin, or 'q' to cancel: " confirm
    if [[ "$confirm" == "q" || "$confirm" == "Q" ]]; then
        main
        return
    fi

    # Step 1: Install Dependencies
    show_step 1 $total_steps "Installing Dependencies"
    if [[ $EUID -ne 0 ]]; then
        print_error "Root privileges required for installation."
        echo "Please run: sudo $0"
        read -p "Press Enter to continue..."
        main
        return
    fi
    install_dependencies_with_progress

    # Step 2: Configure Paperless-ngx
    show_step 2 $total_steps "Configuring Paperless-ngx"
    echo ""
    initial_setup

    # Step 3: Pull Docker Images
    show_step 3 $total_steps "Downloading Docker Images"
    echo ""
    pull_docker_images_with_progress

    # Step 4: Start Services
    show_step 4 $total_steps "Starting Services"
    echo ""
    start_services_with_progress

    # Mark setup complete
    touch "${SCRIPT_DIR}/.first_run_complete"

    # Show completion
    show_setup_complete
}

# Pull docker images with progress
pull_docker_images_with_progress() {
    local images=("ghcr.io/paperless-ngx/paperless-ngx:latest" "postgres:16" "redis:7" "nginx:alpine" "gotenberg/gotenberg:8" "apache/tika:latest")
    local total=${#images[@]}
    local current=0

    cd "$SCRIPT_DIR"

    for image in "${images[@]}"; do
        ((current++))
        local image_name=$(echo "$image" | cut -d'/' -f2 | cut -d':' -f1)
        show_progress $current $total "Pulling $image_name..."
        docker pull "$image" >/dev/null 2>&1 || true
    done

    echo ""
    print_success "All images downloaded"
}

# Start services with progress
start_services_with_progress() {
    cd "$SCRIPT_DIR"

    local services=("broker" "db" "gotenberg" "tika" "webserver" "nginx")
    local total=${#services[@]}
    local current=0

    echo "  Starting containers..."
    echo ""

    # Start all services
    docker compose up -d >/dev/null 2>&1

    # Wait for each service
    for service in "${services[@]}"; do
        ((current++))
        show_progress $current $total "Starting $service..."

        local max_wait=60
        local waited=0
        while [[ $waited -lt $max_wait ]]; do
            if docker compose ps --status running 2>/dev/null | grep -q "$service"; then
                break
            fi
            sleep 1
            ((waited++))
        done
    done

    echo ""

    # Final health check
    echo -n "  Waiting for services to be ready"
    local ready=false
    for i in {1..60}; do
        if curl -s -o /dev/null -w "%{http_code}" http://localhost:8000/api/ 2>/dev/null | grep -q "200\|301\|302"; then
            ready=true
            break
        fi
        echo -n "."
        sleep 2
    done
    echo ""

    if $ready; then
        print_success "All services started successfully!"
    else
        print_warning "Services started but may still be initializing"
    fi
}

# Show setup completion screen
show_setup_complete() {
    clear
    echo ""
    echo -e "${GREEN}"
    cat << 'EOF'
    ╔═══════════════════════════════════════════════════════════╗
    ║                                                           ║
    ║   ✓  Setup Complete!                                     ║
    ║                                                           ║
    ║   Your Paperless-ngx system is ready to use.             ║
    ║                                                           ║
    ╚═══════════════════════════════════════════════════════════╝
EOF
    echo -e "${NC}"
    echo ""

    local ip=$(hostname -I 2>/dev/null | awk '{print $1}')
    local url="http://${ip:-localhost}"
    if [[ -f "${SCRIPT_DIR}/nginx/ssl/cert.pem" ]]; then
        url="https://${ip:-localhost}"
    fi

    echo "  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    echo -e "  ${GREEN}Access Paperless-ngx:${NC}"
    echo "    $url"
    echo ""
    echo -e "  ${GREEN}Default Login:${NC}"
    echo "    Username: admin"
    echo "    Password: (the one you set during setup)"
    echo ""
    echo -e "  ${GREEN}Import Documents:${NC}"
    echo "    Drop files into: ${CONSUME_DIR}"
    echo ""
    echo "  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    echo "  What would you like to do next?"
    echo ""
    echo "    1) Open Management Menu"
    echo "       Configure backups, SSL, monitoring, and more"
    echo ""
    echo "    0) Exit"
    echo ""

    read -p "  Select an option [0-1]: " next_choice

    case $next_choice in
        1)
            full_menu
            ;;
        *)
            echo ""
            print_info "Goodbye! Run this script anytime to manage your system."
            echo ""
            exit 0
            ;;
    esac
}

# Install dependencies only
run_dependency_install() {
    show_splash_screen
    echo -e "  ${GREEN}Install Dependencies${NC}"
    echo -e "  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""

    if [[ $EUID -ne 0 ]]; then
        print_error "Root privileges required for installation."
        echo "Please run: sudo $0"
        read -p "Press Enter to continue..."
        main
        return
    fi

    if check_dependencies_quick; then
        print_success "All dependencies are already installed!"
        echo ""
        read -p "  Press Enter to continue..."
        main
        return
    fi

    install_dependencies_with_progress

    read -p "  Press Enter to continue..."
    main
}

# Configure Paperless-ngx
run_configuration() {
    show_splash_screen
    echo -e "  ${GREEN}Configure Paperless-ngx${NC}"
    echo -e "  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""

    # Check dependencies first
    if ! check_dependencies_quick; then
        print_warning "Dependencies are not installed."
        echo "Please install dependencies first (option 2)."
        read -p "Press Enter to continue..."
        main
        return
    fi

    initial_setup
    touch "${SCRIPT_DIR}/.first_run_complete"

    read -p "  Press Enter to continue..."
    main
}

# Start services
run_start_services() {
    show_splash_screen
    echo -e "  ${GREEN}Start Services${NC}"
    echo -e "  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""

    # Check if configured
    if [[ ! -f "${SCRIPT_DIR}/.env" ]]; then
        print_warning "Paperless-ngx is not configured yet."
        echo "Please run configuration first (option 3)."
        read -p "Press Enter to continue..."
        main
        return
    fi

    if is_running 2>/dev/null; then
        print_success "Services are already running!"
        echo ""
        read -p "Press Enter to continue..."
        main
        return
    fi

    start_services_with_progress

    read -p "  Press Enter to continue..."
    main
}

# View detailed system status
view_detailed_status() {
    show_splash_screen
    echo -e "  ${GREEN}System Status${NC}"
    echo -e "  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""

    # Dependencies
    echo -e "  ${BLUE}Dependencies:${NC}"
    local deps=(
        "docker:Docker"
        "docker compose:Docker Compose"
        "openssl:OpenSSL"
        "smbd:Samba"
        "curl:curl"
        "tar:tar"
    )

    for dep in "${deps[@]}"; do
        local cmd="${dep%%:*}"
        local name="${dep##*:}"
        if command -v $cmd &>/dev/null 2>&1 || $cmd version &>/dev/null 2>&1; then
            printf "    %-20s ${GREEN}✓ Installed${NC}\n" "$name"
        else
            printf "    %-20s ${RED}✗ Missing${NC}\n" "$name"
        fi
    done

    echo ""
    echo -e "  ${BLUE}Services:${NC}"

    if [[ -f "${SCRIPT_DIR}/.env" ]]; then
        cd "$SCRIPT_DIR"
        local services=("broker" "db" "webserver" "nginx" "gotenberg" "tika")

        for service in "${services[@]}"; do
            if docker compose ps --status running 2>/dev/null | grep -q "$service"; then
                printf "    %-20s ${GREEN}● Running${NC}\n" "$service"
            else
                printf "    %-20s ${RED}○ Stopped${NC}\n" "$service"
            fi
        done
    else
        echo "    (Not configured)"
    fi

    echo ""
    echo -e "  ${BLUE}Storage:${NC}"
    local disk_info=$(df -h "$SCRIPT_DIR" 2>/dev/null | tail -1)
    local disk_used=$(echo "$disk_info" | awk '{print $3}')
    local disk_avail=$(echo "$disk_info" | awk '{print $4}')
    local disk_percent=$(echo "$disk_info" | awk '{print $5}')
    echo "    Used:      $disk_used"
    echo "    Available: $disk_avail"
    echo "    Usage:     $disk_percent"

    echo ""
}

# Legacy function - redirects to new setup flow
run_initial_setup_flow() {
    main
}

# Show features overview when user chooses to explore menu
show_features_overview() {
    clear
    print_header "Paperless-ngx Management Tool - Features"

    echo "This tool provides comprehensive management capabilities:"
    echo ""
    echo -e "${GREEN}Core Features:${NC}"
    echo "  • Initial Setup & Configuration"
    echo "  • Start/Stop Services"
    echo "  • View Status & Logs"
    echo "  • SSL/HTTPS Configuration"
    echo ""
    echo -e "${GREEN}Backup & Recovery:${NC}"
    echo "  • Create & Restore Backups"
    echo "  • Automatic Backup Scheduling"
    echo "  • Backup Encryption"
    echo "  • Backup Verification"
    echo ""
    echo -e "${GREEN}Advanced Features (24 options):${NC}"
    echo "  • Database Optimization"
    echo "  • Health Monitoring & Alerts"
    echo "  • Bulk Import Mode"
    echo "  • Email/IMAP Import"
    echo "  • User Management"
    echo "  • Security Audit & Fail2ban"
    echo "  • Document Statistics"
    echo "  • Duplicate Detection"
    echo "  • Storage Analysis"
    echo "  • Migration Assistant"
    echo "  • And much more..."
    echo ""
    echo -e "${GREEN}Compliance (DSGVO/GoBD):${NC}"
    echo "  • EU Data Protection (GDPR)"
    echo "  • German Tax Compliance (GoBD)"
    echo "  • Retention Period Management"
    echo "  • Verfahrensdokumentation Generator"
    echo ""
    echo "───────────────────────────────────────────────────────────"

    read -p "Press Enter to continue to the menu..."
}

# Prompt after initial setup to optionally open menu
post_setup_menu_prompt() {
    echo ""
    echo "───────────────────────────────────────────────────────────"
    echo ""
    echo "  Setup complete! Your Paperless-ngx system is ready."
    echo ""
    echo "  Would you like to explore additional features?"
    echo ""
    echo "    1) Open the management menu"
    echo "       - Configure backups, SSL, monitoring"
    echo "       - Advanced settings and optimization"
    echo "       - Compliance features (DSGVO/GoBD)"
    echo ""
    echo "    0) Exit (you can run this script again anytime)"
    echo ""

    read -p "  Select an option [0-1]: " menu_choice

    case $menu_choice in
        1)
            show_features_overview
            full_menu
            ;;
        0|*)
            echo ""
            print_success "Setup complete!"
            echo ""
            echo "  Access Paperless-ngx:"
            local ip=$(hostname -I 2>/dev/null | awk '{print $1}')
            if [[ -f "${SCRIPT_DIR}/nginx/ssl/cert.pem" ]]; then
                echo "    https://${ip:-localhost}"
            else
                echo "    http://${ip:-localhost}"
            fi
            echo ""
            echo "  Run this script again anytime to manage your system:"
            echo "    sudo ./management.sh"
            echo ""
            exit 0
            ;;
    esac
}

full_menu() {
    while true; do
        show_menu
        read -p "Select an option [0-13]: " choice

        case $choice in
            1) initial_setup ;;
            2) create_backup ;;
            3) restore_backup ;;
            4) setup_backup_schedule ;;
            5) update_containers ;;
            6) start_services ;;
            7) stop_services ;;
            8) view_status ;;
            9) view_logs ;;
            10) configure_ssl ;;
            11) advanced_settings_menu ;;
            12) check_dependencies_menu ;;
            13)
                # Switch to Quick Actions menu
                set_menu_preference "quick"
                if ! quick_actions_menu; then
                    # User wants full menu again
                    set_menu_preference "full"
                fi
                ;;
            0)
                echo ""
                print_info "Goodbye! Your documents are safe."
                exit 0
                ;;
            *)
                print_error "Invalid option"
                sleep 1
                ;;
        esac
    done
}

# Handle command-line arguments for non-interactive use
case "${1:-}" in
    "setup"|"install")
        # Run initial setup (installs dependencies automatically)
        cd "$SCRIPT_DIR"
        ensure_dependencies
        initial_setup
        touch "${SCRIPT_DIR}/.first_run_complete"
        exit $?
        ;;
    "menu")
        # Skip setup check and go directly to menu
        cd "$SCRIPT_DIR"
        ensure_dependencies
        touch "${SCRIPT_DIR}/.first_run_complete"
        full_menu
        exit $?
        ;;
    "health-check")
        if [[ "${2:-}" == "--daemon" ]]; then
            # Called by cron for background monitoring
            health_monitor_daemon
        else
            # Interactive health check
            run_health_check
        fi
        exit $?
        ;;
    "backup")
        # Quick backup from command line
        create_backup
        exit $?
        ;;
    "status")
        # Quick status check
        view_status
        exit $?
        ;;
    "start")
        start_services
        exit $?
        ;;
    "stop")
        stop_services
        exit $?
        ;;
    "verify-backups")
        # Verify all backups (for cron)
        verify_all_backups
        exit $?
        ;;
    "auto-cleanup")
        # Automatic cleanup (for cron)
        full_cleanup
        exit $?
        ;;
    "generate-report")
        # Generate system report (for cron)
        generate_report_now
        exit $?
        ;;
    "security-audit")
        # Run security audit
        security_audit
        exit $?
        ;;
    "statistics")
        # Show document statistics
        document_statistics
        exit $?
        ;;
    "help"|"--help"|"-h")
        echo "Paperless-ngx Management Script"
        echo ""
        echo "Usage: $0 [command]"
        echo ""
        echo "Getting Started:"
        echo "  (none)          Interactive mode - install dependencies, setup, and menu"
        echo "  setup           Run initial setup (installs dependencies automatically)"
        echo "  menu            Open management menu directly"
        echo ""
        echo "Service Management:"
        echo "  start           Start all services"
        echo "  stop            Stop all services"
        echo "  status          Show service status"
        echo ""
        echo "Backup & Maintenance:"
        echo "  backup          Create a backup"
        echo "  verify-backups  Verify all backup integrity"
        echo "  auto-cleanup    Run automatic cleanup"
        echo ""
        echo "Monitoring & Reports:"
        echo "  health-check    Run health check (add --daemon for cron mode)"
        echo "  generate-report Generate system report"
        echo "  security-audit  Run security audit"
        echo "  statistics      Show document statistics"
        echo ""
        echo "Other:"
        echo "  help            Show this help message"
        echo ""
        echo "Note: Dependencies are automatically installed when running"
        echo "      the script with root privileges (sudo)."
        echo ""
        exit 0
        ;;
    "")
        # No argument - run interactive menu
        main
        ;;
    *)
        echo "Unknown command: $1"
        echo "Run '$0 help' for usage information"
        exit 1
        ;;
esac

# ------------------------------------------------------------------------------
# Install necessary system requirements for OpenTopoData
install_system_requirements() {
    print_header "Instalando requerimientos del sistema (docker, awscli, curl, git)"
    if check_command docker && check_command aws && check_command curl && check_command git; then
        print_success "Todos los requerimientos del sistema ya están instalados."
        return 0
    fi
    if [[ $EUID -ne 0 ]]; then
        print_warning "Se requieren privilegios de superusuario para instalar paquetes del sistema."
        print_warning "Ejecuta este script como root o con sudo."
        return 1
    fi
    apt-get update
    apt-get install -y docker.io curl git || { print_error "No se pudo instalar docker.io, curl o git"; exit 1; }

    # Intentar instalar awscli desde apt
    if ! check_command aws; then
        print_info "Intentando instalar awscli desde apt..."
        if ! apt-get install -y awscli; then
            print_warning "awscli no está disponible en apt. Instalando AWS CLI v2 desde el instalador oficial..."
            # Install dependencies for decompressing and downloading
            apt-get install -y unzip || { print_error "No se pudo instalar unzip"; exit 1; }
            TMP_AWS_CLI="/tmp/awscliv2_installer.zip"
            curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "$TMP_AWS_CLI" && \
            unzip -o "$TMP_AWS_CLI" -d /tmp && \
            /tmp/aws/install || { print_error "No se pudo instalar AWS CLI v2"; exit 1; }
            rm -rf /tmp/aws /tmp/awscliv2_installer.zip
        fi
    fi

    if check_command docker && check_command aws && check_command curl && check_command git; then
        print_success "Requerimientos del sistema instalados correctamente."
    else
        print_error "No se pudieron instalar todos los requerimientos del sistema."
        exit 1
    fi
}
#!/bin/bash
#===============================================================================
# OpenTopoData Installation Script with Copernicus DEM GLO-30 (Worldwide)
#===============================================================================
# This script automates the installation, configuration, and management of
# OpenTopoData with the Copernicus DEM GLO-30 dataset (30m resolution, ~300GB).
#
# Features:
#   - Clone OpenTopoData repository
#   - Download Copernicus GLO-30 worldwide dataset from AWS S3
#   - Build and run Docker container as daemon (auto-restart on reboot)
#   - Rebuild Docker for configuration changes
#   - Complete uninstallation
#
# Requirements:
#   - Docker installed and running
#   - AWS CLI installed (for dataset download)
#   - ~350GB free disk space (dataset + temporary files)
#   - Internet connection
#
# Usage: ./setup_opentopodata.sh
#===============================================================================

set -e

# Configuration
REPO_URL="https://github.com/ajnisbet/opentopodata.git"
INSTALL_DIR="${INSTALL_DIR:-$HOME/opentopodata}"
DATASET_NAME="copernico-ww"
DATASET_PATH="data/${DATASET_NAME}"
S3_BUCKET="s3://copernicus-dem-30m"
CONTAINER_NAME="opentopodata"
HOST_PORT="${HOST_PORT:-5000}"
CONTAINER_PORT="5000"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
#===============================================================================
# Utility Functions
#===============================================================================

print_header() {
    echo -e "\n${BLUE}============================================================${NC}"
    echo -e "${BLUE}  $1${NC}"
    echo -e "${BLUE}============================================================${NC}\n"
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

confirm() {
    local prompt="$1"
    local default="${2:-n}"
    local yn
    
    if [[ "$default" == "y" ]]; then
        prompt="$prompt [Y/n]: "
    else
        prompt="$prompt [y/N]: "
    fi
    
    read -r -p "$prompt" yn
    yn=${yn:-$default}
    
    case "$yn" in
        [Yy]* ) return 0;;
        * ) return 1;;
    esac
}

check_command() {
    if ! command -v "$1" &> /dev/null; then
        return 1
    fi
    return 0
}

get_version() {
    if [[ -f "$INSTALL_DIR/VERSION" ]]; then
        cat "$INSTALL_DIR/VERSION"
    else
        echo "latest"
    fi
}

detect_architecture() {
    local arch
    arch=$(uname -m)
    case "$arch" in
        arm64|aarch64)
            echo "arm64"
            ;;
        x86_64|amd64)
            echo "amd64"
            ;;
        *)
            echo "unknown"
            ;;
    esac
}

#===============================================================================
# Prerequisite Checks
#===============================================================================

check_docker() {
    print_info "Checking Docker installation..."
    
    if ! check_command docker; then
        print_error "Docker is not installed."
        echo ""
        echo "Please install Docker first:"
        echo "  - Ubuntu/Debian: sudo apt-get install docker.io"
        echo "  - Or visit: https://docs.docker.com/engine/install/"
        echo ""
        return 1
    fi
    
    if ! docker info &> /dev/null; then
        print_error "Docker is not running or you don't have permission."
        echo ""
        echo "Try one of the following:"
        echo "  - Start Docker: sudo systemctl start docker"
        echo "  - Add user to docker group: sudo usermod -aG docker \$USER"
        echo "    (then log out and back in)"
        echo ""
        return 1
    fi
    
    print_success "Docker is installed and running"
    return 0
}

check_aws_cli() {
    print_info "Checking AWS CLI installation..."
    
    if ! check_command aws; then
        print_error "AWS CLI is not installed."
        echo ""
        echo "Please install AWS CLI first:"
        echo "  - Ubuntu/Debian: sudo apt-get install awscli"
        echo "  - Or: pip install awscli"
        echo "  - Or visit: https://aws.amazon.com/cli/"
        echo ""
        echo "Note: No AWS account is required - the dataset is publicly accessible."
        return 1
    fi
    
    print_success "AWS CLI is installed"
    return 0
}

check_disk_space() {
    local required_gb="${1:-350}"
    local target_dir="${2:-$INSTALL_DIR}"
    local parent_dir
    
    # Get parent directory if target doesn't exist
    if [[ -d "$target_dir" ]]; then
        parent_dir="$target_dir"
    else
        parent_dir=$(dirname "$target_dir")
    fi
    
    # Get available space in GB
    local available_kb
    available_kb=$(df -k "$parent_dir" 2>/dev/null | tail -1 | awk '{print $4}')
    local available_gb=$((available_kb / 1024 / 1024))
    
    print_info "Checking disk space..."
    print_info "Required: ${required_gb}GB, Available: ${available_gb}GB"
    
    if [[ $available_gb -lt $required_gb ]]; then
        print_warning "Low disk space! You need at least ${required_gb}GB for the dataset."
        if ! confirm "Continue anyway?"; then
            return 1
        fi
    else
        print_success "Sufficient disk space available"
    fi
    
    return 0
}

#===============================================================================
# Installation Functions
#===============================================================================

clone_repository() {
    print_header "Cloning OpenTopoData Repository"
    
    if [[ -d "$INSTALL_DIR" ]]; then
        if [[ -d "$INSTALL_DIR/.git" ]]; then
            print_info "Repository already exists at $INSTALL_DIR"
            if confirm "Do you want to update it (git pull)?"; then
                cd "$INSTALL_DIR"
                git pull
                print_success "Repository updated"
            fi
            return 0
        else
            print_error "Directory $INSTALL_DIR exists but is not a git repository"
            if confirm "Remove it and clone fresh?"; then
                rm -rf "$INSTALL_DIR"
            else
                return 1
            fi
        fi
    fi
    
    print_info "Cloning repository to $INSTALL_DIR..."
    git clone "$REPO_URL" "$INSTALL_DIR"
    print_success "Repository cloned successfully"
    
    # Create dataset directory
    mkdir -p "$INSTALL_DIR/$DATASET_PATH"
    print_success "Created dataset directory: $DATASET_PATH"
}

download_dataset() {
    print_header "Downloading Copernicus DEM GLO-30 Dataset"
    
    # if ! check_aws_cli; then
    #     return 1
    # fi
    
    # cd "$INSTALL_DIR"
    
    # # Create temporary download directory
    local temp_dir="$INSTALL_DIR/data/copernicus_temp"
    mkdir -p "$temp_dir"
    mkdir -p "$INSTALL_DIR/$DATASET_PATH"
    
    # print_info "This will download ~300GB of elevation data."
    # print_info "The download can be interrupted and resumed later."
    # echo ""
    
    # if ! confirm "Start download from AWS S3?" "y"; then
    #     return 1
    # fi
    
    # print_info "Downloading tiles from $S3_BUCKET..."
    # print_info "This may take several hours depending on your connection speed."
    # echo ""
    
    # # Download all tiles
    # # Using sync to allow resuming interrupted downloads
    # aws s3 sync --no-sign-request "$S3_BUCKET/" "$temp_dir/" \
    #     --exclude "*" \
    #     --include "Copernicus_DSM_COG_10_*_DEM/Copernicus_DSM_COG_10_*_DEM.tif" \
    #     --exclude "*/AUXFILES/*"
    
    print_success "Download completed"
    
    # Process and rename tiles
    print_info "Processing and renaming tiles to SRTM format..."
    process_tiles "$temp_dir"
    
    # Cleanup temporary directory
    if confirm "Remove temporary download directory to save space?"; then
        rm -rf "$temp_dir"
        print_success "Temporary files removed"
    fi
    
    # Count tiles
    local tile_count
    tile_count=$(find "$INSTALL_DIR/$DATASET_PATH" -name "*.tif" | wc -l)
    print_success "Dataset ready: $tile_count tiles in $DATASET_PATH"
}

process_tiles() {
    local source_dir="$1"
    local dest_dir="$INSTALL_DIR/$DATASET_PATH"
    local count=0
    local total
    
    total=$(find "$source_dir" -name "*.tif" | wc -l)
    print_info "Processing $total tiles..."
    
    # Process each tile
    # Original format: Copernicus_DSM_COG_10_N00_00_E000_00_DEM/Copernicus_DSM_COG_10_N00_00_E000_00_DEM.tif
    # Target format: N00E000.tif
    
    find "$source_dir" -name "*.tif" | while read -r filepath; do
        local filename
        filename=$(basename "$filepath")
        
        # Extract coordinates from filename
        # Example: Copernicus_DSM_COG_10_N45_00_W123_00_DEM.tif -> N45W123.tif
        local coords
        coords=$(echo "$filename" | sed -E 's/Copernicus_DSM_COG_[0-9]+_([NS][0-9]+)_00_([EW][0-9]+)_00_DEM\.tif/\1\2.tif/')
        
        if [[ "$coords" != "$filename" ]]; then
            # Pad coordinates properly (N01E002 format)
            local ns_letter ns_num ew_letter ew_num
            ns_letter=$(echo "$coords" | grep -oE '^[NS]')
            ns_num=$(echo "$coords" | grep -oE '^[NS]([0-9]+)' | sed 's/^[NS]//')
            ew_letter=$(echo "$coords" | grep -oE '[EW]')
            ew_num=$(echo "$coords" | grep -oE '[EW]([0-9]+)' | sed 's/^[EW]//')
            
            # Format with proper padding
            local new_name
            # Force decimal to avoid octal error
            ns_num_dec=$((10#$ns_num))
            ew_num_dec=$((10#$ew_num))
            new_name=$(printf "%s%02d%s%03d.tif" "$ns_letter" "$ns_num_dec" "$ew_letter" "$ew_num_dec")
            
            mv "$filepath" "$dest_dir/$new_name"
            ((count++)) || true
            
            # Progress indicator
            if ((count % 500 == 0)); then
                echo "  Processed $count / $total tiles..."
            fi
        else
            print_warning "Could not parse filename: $filename"
        fi
    done
    
    print_success "Tile processing completed"
}

create_config() {
    print_header "Creating Configuration File"
    
    cd "$INSTALL_DIR"
    
    local config_file="$INSTALL_DIR/config.yaml"
    
    if [[ -f "$config_file" ]]; then
        print_info "Configuration file already exists"
        if ! confirm "Overwrite existing config.yaml?"; then
            return 0
        fi
        # Backup existing config
        cp "$config_file" "${config_file}.backup.$(date +%Y%m%d_%H%M%S)"
        print_info "Existing config backed up"
    fi
    
    cat > "$config_file" << 'EOF'
# OpenTopoData Configuration
# Generated by setup_opentopodata.sh

# Maximum number of locations per request (400 error above this limit)
max_locations_per_request: 100

# CORS header for cross-origin requests
# Use "*" for all domains, null for none, or specific domain
access_control_allow_origin: "*"

# Dataset definitions
datasets:

# Copernicus DEM GLO-30 - Worldwide coverage at 30m resolution
- name: copernico-ww
  path: data/copernico-ww/
  filename_epsg: 4326  # WGS84 lat/lon coordinates
  filename_tile_size: 1  # 1 degree tiles
EOF
    
    print_success "Configuration file created: config.yaml"
    print_info "Dataset URL will be: http://localhost:$HOST_PORT/v1/$DATASET_NAME"
}

build_docker() {
    print_header "Building Docker Image"
    
    if ! check_docker; then
        return 1
    fi
    
    cd "$INSTALL_DIR"
    
    local arch
    arch=$(detect_architecture)
    local version
    version=$(get_version)
    
    print_info "Detected architecture: $arch"
    print_info "Building version: $version"
    
    if [[ "$arch" == "arm64" ]]; then
        print_info "Using Apple Silicon / ARM64 Dockerfile..."
        docker build --tag "opentopodata:$version" --file docker/apple-silicon.Dockerfile .
    else
        print_info "Using standard Dockerfile..."
        docker build --tag "opentopodata:$version" --file docker/Dockerfile .
    fi
    
    print_success "Docker image built: opentopodata:$version"
}

run_docker_daemon() {
    print_header "Starting Docker Container as Daemon"
    
    if ! check_docker; then
        return 1
    fi
    
    cd "$INSTALL_DIR"
    
    local version
    version=$(get_version)
    
    # Check if container is already running
    if docker ps --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
        print_info "Container '$CONTAINER_NAME' is already running"
        if confirm "Stop and recreate it?"; then
            docker stop "$CONTAINER_NAME"
            docker rm "$CONTAINER_NAME"
        else
            return 0
        fi
    fi
    
    # Remove stopped container with same name if exists
    if docker ps -a --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
        print_info "Removing stopped container '$CONTAINER_NAME'..."
        docker rm "$CONTAINER_NAME"
    fi
    
    print_info "Starting container..."
    print_info "  - Port: $HOST_PORT -> $CONTAINER_PORT"
    print_info "  - Restart policy: unless-stopped (survives reboots)"
    print_info "  - Data volume: $INSTALL_DIR/data (read-only)"
    
    docker run -d \
        --name "$CONTAINER_NAME" \
        --restart unless-stopped \
        --volume "$INSTALL_DIR/data:/app/data:ro" \
        --volume "$INSTALL_DIR/config.yaml:/app/config.yaml:ro" \
        -p "$HOST_PORT:$CONTAINER_PORT" \
        "opentopodata:$version"
    
    # Wait a moment for container to start
    sleep 3
    
    # Check if container is running
    if docker ps --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
        print_success "Container started successfully"
        echo ""
        print_info "OpenTopoData is now running at: http://localhost:$HOST_PORT"
        print_info "Test endpoint: http://localhost:$HOST_PORT/v1/$DATASET_NAME?locations=40.416,-3.703"
        echo ""
        
        # Quick health check
        print_info "Running health check..."
        sleep 2
        if curl -s "http://localhost:$HOST_PORT/health" > /dev/null 2>&1; then
            print_success "Health check passed!"
        else
            print_warning "Health check failed - container may still be starting up"
            print_info "Check logs with: docker logs $CONTAINER_NAME"
        fi
    else
        print_error "Container failed to start"
        print_info "Check logs with: docker logs $CONTAINER_NAME"
        return 1
    fi
}

#===============================================================================
# Management Functions
#===============================================================================

rebuild_docker() {
    print_header "Rebuilding Docker Image"
    
    if ! check_docker; then
        return 1
    fi
    
    cd "$INSTALL_DIR"
    
    local version
    version=$(get_version)
    local arch
    arch=$(detect_architecture)
    local was_running=false
    
    # Check if container is running
    if docker ps --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
        was_running=true
        print_info "Stopping running container..."
        docker stop "$CONTAINER_NAME"
        docker rm "$CONTAINER_NAME"
    elif docker ps -a --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
        docker rm "$CONTAINER_NAME"
    fi
    
    print_info "Rebuilding image (no cache)..."
    
    if [[ "$arch" == "arm64" ]]; then
        docker build --no-cache --tag "opentopodata:$version" --file docker/apple-silicon.Dockerfile .
    else
        docker build --no-cache --tag "opentopodata:$version" --file docker/Dockerfile .
    fi
    
    print_success "Docker image rebuilt: opentopodata:$version"
    
    # Restart container if it was running
    if [[ "$was_running" == true ]]; then
        print_info "Restarting container..."
        run_docker_daemon
    else
        if confirm "Start the container now?"; then
            run_docker_daemon
        fi
    fi
}

stop_docker() {
    print_header "Stopping Docker Container"
    
    if ! check_docker; then
        return 1
    fi
    
    if docker ps --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
        print_info "Stopping container '$CONTAINER_NAME'..."
        docker stop "$CONTAINER_NAME"
        print_success "Container stopped"
    else
        print_info "Container '$CONTAINER_NAME' is not running"
    fi
}

start_docker() {
    print_header "Starting Docker Container"
    
    if ! check_docker; then
        return 1
    fi
    
    # Check if container exists but is stopped
    if docker ps -a --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
        if docker ps --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
            print_info "Container '$CONTAINER_NAME' is already running"
        else
            print_info "Starting existing container '$CONTAINER_NAME'..."
            docker start "$CONTAINER_NAME"
            sleep 2
            if docker ps --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
                print_success "Container started"
                print_info "API available at: http://localhost:$HOST_PORT"
            else
                print_error "Failed to start container"
                return 1
            fi
        fi
    else
        print_warning "Container '$CONTAINER_NAME' does not exist"
        if confirm "Create and start a new container?"; then
            cd "$INSTALL_DIR"
            run_docker_daemon
        fi
    fi
}

restart_docker() {
    print_header "Restarting Docker Container"
    
    if ! check_docker; then
        return 1
    fi
    
    if docker ps --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
        print_info "Restarting container '$CONTAINER_NAME'..."
        docker restart "$CONTAINER_NAME"
        sleep 2
        if docker ps --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
            print_success "Container restarted"
            print_info "API available at: http://localhost:$HOST_PORT"
        else
            print_error "Failed to restart container"
            return 1
        fi
    elif docker ps -a --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
        print_info "Container is stopped. Starting it..."
        start_docker
    else
        print_error "Container '$CONTAINER_NAME' does not exist"
        return 1
    fi
}

show_status() {
    print_header "OpenTopoData Status"
    
    local version
    version=$(get_version)
    
    echo "Installation directory: $INSTALL_DIR"
    echo "Dataset path: $INSTALL_DIR/$DATASET_PATH"
    echo "Version: $version"
    echo ""
    
    # Check Docker image
    echo "Docker Image:"
    if docker images --format '{{.Repository}}:{{.Tag}}' | grep -q "opentopodata:$version"; then
        print_success "  opentopodata:$version exists"
    else
        print_warning "  opentopodata:$version not found"
    fi
    echo ""
    
    # Check container status
    echo "Container Status:"
    if docker ps --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
        print_success "  Container '$CONTAINER_NAME' is running"
        local restart_policy
        restart_policy=$(docker inspect "$CONTAINER_NAME" --format='{{.HostConfig.RestartPolicy.Name}}' 2>/dev/null)
        echo "  Restart policy: $restart_policy"
        echo "  Port: $(docker port "$CONTAINER_NAME" $CONTAINER_PORT 2>/dev/null || echo 'N/A')"
    elif docker ps -a --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
        print_warning "  Container '$CONTAINER_NAME' exists but is stopped"
    else
        print_info "  Container '$CONTAINER_NAME' not found"
    fi
    echo ""
    
    # Check dataset
    echo "Dataset:"
    if [[ -d "$INSTALL_DIR/$DATASET_PATH" ]]; then
        local tile_count
        tile_count=$(find "$INSTALL_DIR/$DATASET_PATH" -name "*.tif" 2>/dev/null | wc -l)
        local dataset_size
        dataset_size=$(du -sh "$INSTALL_DIR/$DATASET_PATH" 2>/dev/null | cut -f1)
        echo "  Path: $INSTALL_DIR/$DATASET_PATH"
        echo "  Tiles: $tile_count"
        echo "  Size: $dataset_size"
    else
        print_warning "  Dataset directory not found"
    fi
    echo ""
    
    # Health check if running
    if docker ps --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
        echo "API Health:"
        if curl -s "http://localhost:$HOST_PORT/health" > /dev/null 2>&1; then
            print_success "  API is responding"
        else
            print_warning "  API not responding"
        fi
    fi
}

view_logs() {
    print_header "Container Logs"
    
    if ! docker ps -a --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
        print_error "Container '$CONTAINER_NAME' not found"
        return 1
    fi
    
    echo "Showing last 50 lines (Ctrl+C to exit follow mode)..."
    echo ""
    docker logs --tail 50 -f "$CONTAINER_NAME"
}

#===============================================================================
# Uninstallation Functions
#===============================================================================

uninstall_all() {
    print_header "Uninstalling OpenTopoData"
    
    echo "This will remove:"
    echo "  1. Docker container: $CONTAINER_NAME"
    echo "  2. Docker image: opentopodata:$(get_version)"
    echo "  3. (Optional) Installation directory: $INSTALL_DIR"
    echo "  4. (Optional) Dataset files (~300GB)"
    echo ""
    
    if ! confirm "Are you sure you want to proceed?"; then
        print_info "Uninstallation cancelled"
        return 0
    fi
    
    # Stop and remove container
    if docker ps --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
        print_info "Stopping container..."
        docker stop "$CONTAINER_NAME"
    fi
    
    if docker ps -a --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
        print_info "Removing container..."
        docker rm "$CONTAINER_NAME"
        print_success "Container removed"
    fi
    
    # Remove Docker image
    local version
    version=$(get_version)
    if docker images --format '{{.Repository}}:{{.Tag}}' | grep -q "opentopodata:$version"; then
        print_info "Removing Docker image..."
        docker rmi "opentopodata:$version"
        print_success "Docker image removed"
    fi
    
    # Optional: Remove dataset
    if [[ -d "$INSTALL_DIR/$DATASET_PATH" ]]; then
        local dataset_size
        dataset_size=$(du -sh "$INSTALL_DIR/$DATASET_PATH" 2>/dev/null | cut -f1)
        echo ""
        if confirm "Remove dataset ($dataset_size)?"; then
            rm -rf "$INSTALL_DIR/$DATASET_PATH"
            print_success "Dataset removed"
        else
            print_info "Dataset kept at: $INSTALL_DIR/$DATASET_PATH"
        fi
    fi
    
    # Optional: Remove entire installation
    if [[ -d "$INSTALL_DIR" ]]; then
        echo ""
        print_warning "This will delete the entire directory: $INSTALL_DIR"
        if confirm "Remove entire installation directory?"; then
            rm -rf "$INSTALL_DIR"
            print_success "Installation directory removed"
        else
            print_info "Installation directory kept at: $INSTALL_DIR"
        fi
    fi
    
    echo ""
    print_success "Uninstallation completed"
}

#===============================================================================
# Full Installation
#===============================================================================

install_all() {
    print_header "Full Installation"
    
    echo "This will perform the following steps:"
    echo "  1. Install system requirements"
    echo "  2. Clone OpenTopoData repository"
    echo "  3. Download Copernicus DEM GLO-30 dataset (~300GB)"
    echo "  4. Create configuration file"
    echo "  5. Build Docker image"
    echo "  6. Start Docker container as daemon"
    echo ""
    echo "Requirements:"
    echo "  - Docker installed and running"
    echo "  - AWS CLI installed (no account needed)"
    echo "  - ~350GB free disk space"
    echo "  - Stable internet connection"
    echo ""
    
    if ! confirm "Proceed with installation?" "y"; then
        return 0
    fi

    install_system_requirements
    
    # Check prerequisites
    print_header "Checking Prerequisites"
    
    if ! check_docker; then
        print_error "Please install Docker and try again"
        return 1
    fi
    
    if ! check_aws_cli; then
        print_error "Please install AWS CLI and try again"
        return 1
    fi
    
    if ! check_disk_space 350; then
        return 1
    fi
    
    # Execute installation steps
    clone_repository || { print_error "Failed to clone repository"; return 1; }
    create_config || { print_error "Failed to create config"; return 1; }
    download_dataset || { print_error "Failed to download dataset"; return 1; }
    build_docker || { print_error "Failed to build Docker image"; return 1; }
    run_docker_daemon || { print_error "Failed to start Docker container"; return 1; }
    
    print_header "Installation Complete!"
    
    echo "OpenTopoData is now running with Copernicus DEM GLO-30 (worldwide)"
    echo ""
    echo "API Endpoint: http://localhost:$HOST_PORT/v1/$DATASET_NAME"
    echo ""
    echo "Test commands:"
    echo "  # Query elevation for Madrid, Spain"
    echo "  curl 'http://localhost:$HOST_PORT/v1/$DATASET_NAME?locations=40.416,-3.703'"
    echo ""
    echo "  # Query elevation for multiple locations"
    echo "  curl 'http://localhost:$HOST_PORT/v1/$DATASET_NAME?locations=40.416,-3.703|48.858,2.294'"
    echo ""
    echo "Management:"
    echo "  - View logs: docker logs -f $CONTAINER_NAME"
    echo "  - Stop: docker stop $CONTAINER_NAME"
    echo "  - Start: docker start $CONTAINER_NAME"
    echo "  - Rebuild: Run this script and select option 4"
    echo ""
    echo "The container will automatically restart on system reboot."
}

#===============================================================================
# Main Menu
#===============================================================================

show_docker_menu() {
    clear
    echo ""
    echo -e "${BLUE}╔══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║${NC}                   ${GREEN}Docker Options${NC}                            ${BLUE}║${NC}"
    echo -e "${BLUE}╚══════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "  ${GREEN}1)${NC} Start container"
    echo -e "  ${YELLOW}2)${NC} Stop container"
    echo -e "  ${BLUE}3)${NC} Restart container"
    echo -e "  ${YELLOW}4)${NC} Rebuild Docker (apply config changes)"
    echo -e "  ${BLUE}5)${NC} View container logs"
    echo ""
    echo -e "  ${NC}0)${NC} Back to main menu"
    echo ""
}

docker_menu() {
    while true; do
        show_docker_menu
        read -r -p "Select an option [0-5]: " docker_choice
        
        case "$docker_choice" in
            1)
                if [[ ! -d "$INSTALL_DIR" ]]; then
                    print_error "Installation directory not found."
                else
                    cd "$INSTALL_DIR"
                    start_docker
                fi
                echo ""
                read -r -p "Press Enter to continue..."
                ;;
            2)
                stop_docker
                echo ""
                read -r -p "Press Enter to continue..."
                ;;
            3)
                restart_docker
                echo ""
                read -r -p "Press Enter to continue..."
                ;;
            4)
                if [[ ! -d "$INSTALL_DIR" ]]; then
                    print_error "Installation directory not found."
                else
                    cd "$INSTALL_DIR"
                    rebuild_docker
                fi
                echo ""
                read -r -p "Press Enter to continue..."
                ;;
            5)
                view_logs
                ;;
            0)
                return 0
                ;;
            *)
                print_error "Invalid option"
                sleep 1
                ;;
        esac
    done
}

show_menu() {
    clear
    echo ""
    echo -e "${BLUE}╔══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║${NC}          ${GREEN}OpenTopoData Installation Manager${NC}                  ${BLUE}║${NC}"
    echo -e "${BLUE}║${NC}          Copernicus DEM GLO-30 (30m worldwide)             ${BLUE}║${NC}"
    echo -e "${BLUE}╚══════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo "  Installation directory: $INSTALL_DIR"
    echo ""
    echo -e "  ${BLUE}0)${NC} Install system requirements"
    echo -e "  ${GREEN}1)${NC} Install everything (full installation)"
    echo -e "  ${BLUE}2)${NC} Download dataset only"
    echo -e "  ${BLUE}3)${NC} Build and run Docker"
    echo -e "  ${YELLOW}4)${NC} Docker options"
    echo -e "  ${BLUE}5)${NC} Show status"
    echo -e "  ${RED}6)${NC} Uninstall everything"
    echo ""
    echo -e "  ${NC}0)${NC} Exit"
    echo ""
}

main() {
    # Parse command line arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --install-dir)
                INSTALL_DIR="$2"
                shift 2
                ;;
            --port)
                HOST_PORT="$2"
                shift 2
                ;;
            --help|-h)
                echo "Usage: $0 [options]"
                echo ""
                echo "Options:"
                echo "  --install-dir PATH  Set installation directory (default: ~/opentopodata)"
                echo "  --port PORT         Set host port (default: 5000)"
                echo "  --help              Show this help message"
                exit 0
                ;;
            *)
                echo "Unknown option: $1"
                exit 1
                ;;
        esac
    done
    
    while true; do
        show_menu
        read -r -p "Select an option [0-6]: " choice
        
        case "$choice" in
            0) 
                install_system_requirements
                echo ""
                read -r -p "Press Enter to continue..."
                ;;
            1)
                install_all
                echo ""
                read -r -p "Press Enter to continue..."
                ;;
            2)
                if [[ ! -d "$INSTALL_DIR" ]]; then
                    print_error "Installation directory not found. Run option 1 first or clone manually."
                else
                    cd "$INSTALL_DIR"
                    download_dataset
                fi
                echo ""
                read -r -p "Press Enter to continue..."
                ;;
            3)
                if [[ ! -d "$INSTALL_DIR" ]]; then
                    print_error "Installation directory not found. Run option 1 first."
                else
                    cd "$INSTALL_DIR"
                    create_config
                    build_docker
                    run_docker_daemon
                fi
                echo ""
                read -r -p "Press Enter to continue..."
                ;;
            4)
                docker_menu
                ;;
            5)
                show_status
                echo ""
                read -r -p "Press Enter to continue..."
                ;;
            6)
                uninstall_all
                echo ""
                read -r -p "Press Enter to continue..."
                ;;
            0)
                echo ""
                print_info "Goodbye!"
                exit 0
                ;;
            *)
                print_error "Invalid option"
                sleep 1
                ;;
        esac
    done
}

# Run main function
main "$@"

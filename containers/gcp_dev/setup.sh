#!/bin/bash

# Configurable Variables
# ----------------------
# Conda and Python Configuration
PYTHON_VERSION="3.12"
CONDA_INSTALL_DIR="/opt/conda"
# Repository Configuration
GITHUB_REPO="ml-dev-bench/OpenHands"
GITHUB_BRANCH="ml-dev-bench-v0.21.1"

# Workspace and Application Configuration
APP_BASE_DIR="/app/"
WORKSPACE_DIR="/app/workspace"

# Build and Dependency Configuration
INSTALL_PACKAGES=(
    "sudo"
    "git"
    "docker.io"
    "make"
    "gcc"
    "g++"
    "python3-dev"
    "netcat-traditional"
    "curl"
)

CONDA_PACKAGES=(
    "python=${PYTHON_VERSION}"
    "nodejs"
    "poetry"
)

# Strict mode: exit on error, treat unset variables as error
set -euo pipefail

# Log function for consistent output
log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] $*"
}

# Check if required environment variables are set
check_env_vars() {
    local required_vars=("GITHUB_TOKEN")
    for var in "${required_vars[@]}"; do
        if [[ -z "${!var:-}" ]]; then
            log "Error: $var environment variable is not set"
            exit 1
        fi
    done
}

# Update and install system dependencies
install_system_deps() {
    log "Updating system and installing dependencies..."
    sudo apt-get update
    sudo apt-get install -y "${INSTALL_PACKAGES[@]}"
}

# Install Miniforge (Conda alternative)
install_miniforge() {
    if [[ -d "${CONDA_INSTALL_DIR}" ]]; then
        log "Miniforge is already installed at ${CONDA_INSTALL_DIR}. Skipping installation."
        return
    fi
    log "Installing Miniforge..."
    local arch=$(uname -m)
    local os=$(uname)
    local miniforge_script="Miniforge3-${os}-${arch}.sh"

    curl -L -O "https://github.com/conda-forge/miniforge/releases/latest/download/${miniforge_script}"
    sudo bash "${miniforge_script}" -b -p "${CONDA_INSTALL_DIR}"
    rm "${miniforge_script}"

    # Add conda to PATH
    export PATH="${CONDA_INSTALL_DIR}/bin:${PATH}"

    conda init bash

    # Add conda PATH and activate base to .bashrc
    echo "export PATH=\"${CONDA_INSTALL_DIR}/bin:\$PATH\"" | sudo tee -a /etc/profile > /dev/null
    echo "conda activate base" | sudo tee -a /etc/profile > /dev/null
}

# Install Python and development tools
setup_development_env() {
    log "Setting up development environment..."
    mamba install -y "${CONDA_PACKAGES[@]}" -c conda-forge
}

# Clone repository with GitHub token
clone_repository() {
    log "Cloning repository..."
    sudo mkdir -p "${APP_BASE_DIR}"
    sudo chown -R $USER:ml-dev-bench-users ${APP_BASE_DIR}

    sudo chmod -R 775 ${APP_BASE_DIR}
    sudo chmod g+s ${APP_BASE_DIR}  # Optional
    cd "${APP_BASE_DIR}"

    # git config --global user.name "${GITHUB_USER}"
    # git config --global user.email "${GITHUB_EMAIL}"
    git config --global credential.helper cache

    # git clone "https://${GITHUB_TOKEN}@github.com/${GITHUB_REPO}.git"
    git clone "https://github.com/${GITHUB_REPO}.git"
    cd "$(basename "${GITHUB_REPO}")"
    git checkout "${GITHUB_BRANCH}"
}

# Setup Docker authentication for GCP
pull_runtime_image() {
    log "Configuring Docker for GCP..."
    gcloud auth configure-docker
    docker pull gcr.io/deduction-poc/ml-dev-bench-runtime:latest
    docker tag gcr.io/deduction-poc/ml-dev-bench-runtime:latest ml-dev-bench-runtime:latest
}

push_runtime_image() {
    log "Pushing runtime image..."
    poetry run python3 openhands/runtime/utils/runtime_build.py --base_image nikolaik/python-nodejs:python3.12-nodejs22 --build_folder containers/runtime
    # replace all instances of ./code/ with empty string
    sed -i 's/.\/code\//\//g' containers/runtime/Dockerfile
    docker build -t ml-dev-bench-runtime:latest -f containers/runtime/Dockerfile .
    gcloud auth configure-docker
    docker tag ml-dev-bench-runtime:latest gcr.io/deduction-poc/ml-dev-bench-runtime:latest
    docker push gcr.io/deduction-poc/ml-dev-bench-runtime:latest
}

# Main setup function
main() {
    # Check required environment variables first
    # check_env_vars

    # Check if the group 'ml-dev-bench-users' exists
    if ! getent group ml-dev-bench-users > /dev/null; then
        log "Creating group ml-dev-bench-users"
        sudo groupadd ml-dev-bench-users
        sudo usermod -aG ml-dev-bench-users harshith2794
        sudo usermod -aG ml-dev-bench-users dinkarjuyal
    fi

    # Perform setup steps
    install_system_deps
    install_miniforge

    sudo chown -R $USER:ml-dev-bench-users ${CONDA_INSTALL_DIR}
    sudo chmod -R 775 ${CONDA_INSTALL_DIR}

    # # # Initialize conda/mamba
    eval "$("${CONDA_INSTALL_DIR}/bin/conda" shell.bash hook)"

    setup_development_env
    clone_repository


    # # # Create workspace directory
    sudo mkdir -p "${WORKSPACE_DIR}"
    sudo chown -R $USER:ml-dev-bench-users ${WORKSPACE_DIR}
    sudo chmod -R 775 ${WORKSPACE_DIR}

    # # Set working directory
    cd "${APP_BASE_DIR}/$(basename "${GITHUB_REPO}")"

    # # Run build command
    make deploy-build

    sudo systemctl start docker
    sudo systemctl enable docker
    sudo usermod -aG docker harshith2794
    sudo usermod -aG docker dinkarjuyal
    # Export the function to the environment so it can be recognized in new shell
    export -f pull_runtime_image
    export -f push_runtime_image

    # Use newgrp to run pull_runtime_image with the new group permissions
    newgrp docker <<EOF
        pull_runtime_image
EOF
    log "Setup completed successfully!"
}

# Allow sourcing the script or running directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
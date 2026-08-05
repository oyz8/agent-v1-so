#!/bin/sh

GITHUB_REPO="oyz8/agent-v1-so"
INSTALL_DIR="/opt/worker"
SERVICE_NAME="app-worker"

red='\033[0;31m'
green='\033[0;32m'
yellow='\033[0;33m'
plain='\033[0m'

err() {
    printf "${red}%s${plain}\n" "$*" >&2
}

success() {
    printf "${green}%s${plain}\n" "$*"
}

info() {
    printf "${yellow}%s${plain}\n" "$*"
}

sudo() {
    myEUID=$(id -ru)
    if [ "$myEUID" -ne 0 ]; then
        if command -v sudo > /dev/null 2>&1; then
            command sudo "$@"
        else
            err "ERROR: sudo is not installed, please run as root."
            exit 1
        fi
    else
        "$@"
    fi
}

deps_check() {
    _missing=""
    for dep in curl python3 jq; do
        if ! command -v "$dep" >/dev/null 2>&1; then
            _missing="${_missing} $dep"
        fi
    done
    if [ -n "$_missing" ]; then
        err "Missing dependencies:$_missing. Please install them first."
        exit 1
    fi
}

read_config() {
    # 兼容 NZ_ 前缀
    [ -n "$NZ_SERVER" ] && SERVER="$NZ_SERVER"
    [ -n "$NZ_CLIENT_SECRET" ] && CLIENT_SECRET="$NZ_CLIENT_SECRET"
    [ -n "$NZ_UUID" ] && UUID="$NZ_UUID"
    [ -n "$NZ_TLS" ] && TLS="$NZ_TLS"

    if [ -z "$SERVER" ]; then
        printf "Enter server address (domain:443): "
        read SERVER
    fi
    if [ -z "$CLIENT_SECRET" ]; then
        printf "Enter secret: "
        read CLIENT_SECRET
    fi
    if [ -z "$UUID" ]; then
        UUID=$(python3 -c "import uuid; print(uuid.uuid4())")
        info "Generated UUID: $UUID"
    fi
    TLS=${TLS:-true}
    REPORT_DELAY=${REPORT_DELAY:-4}
    SILENT=${SILENT:-true}
}

detect_env() {
    PY_VER=$(python3 -c "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}')")
    info "Python version: $PY_VER"
    _mach=$(uname -m)
    case "$_mach" in
        x86_64|amd64) ARCH="amd64" ;;
        aarch64|arm64) ARCH="arm64" ;;
        *) err "Unsupported architecture: $_mach"; exit 1 ;;
    esac
    info "Architecture: $ARCH"
}

install_deps() {
    if ! python3 -c "import grpc" 2>/dev/null; then
        info "Installing Python dependencies..."
        pip install grpcio protobuf pyyaml psutil requests flask || {
            err "Failed to install Python packages"
            exit 1
        }
    else
        info "Python dependencies already installed"
    fi
}

download_so() {
    _tag=$(curl -sS "https://api.github.com/repos/${GITHUB_REPO}/tags" | \
           jq -r '.[].name' | \
           grep "^main\.so-py${PY_VER}-" | \
           sort -t'-' -k3 -nr | \
           head -1)

    if [ -z "$_tag" ]; then
        err "No prebuilt .so for Python $PY_VER found"
        exit 1
    fi
    info "Release: $_tag"

    _dl_url=$(curl -sS "https://api.github.com/repos/${GITHUB_REPO}/releases/tags/$_tag" | \
              jq -r --arg arch "$ARCH" '.assets[] | select(.name == "main-\($arch).so") | .browser_download_url')

    if [ -z "$_dl_url" ]; then
        err "No $ARCH .so found in this release"
        exit 1
    fi
    info "Downloading $_dl_url"
    sudo mkdir -p "$INSTALL_DIR"
    sudo curl -L -o "${INSTALL_DIR}/main.so" "$_dl_url" || { err "Download failed"; exit 1; }
    success "main.so downloaded"
}

generate_files() {
    sudo tee "${INSTALL_DIR}/config.yml" > /dev/null <<EOF
server: "${SERVER}"
client_secret: "${CLIENT_SECRET}"
uuid: "${UUID}"
tls: ${TLS}
report_delay: ${REPORT_DELAY}
silent: ${SILENT}
EOF

    sudo tee "${INSTALL_DIR}/run.py" > /dev/null <<'PYEOF'
import sys
from main import WorkerApp

if __name__ == "__main__":
    app = WorkerApp(config_path="config.yml")
    sys.exit(app.run())
PYEOF

    sudo chmod 644 "${INSTALL_DIR}/config.yml"
    sudo chmod 755 "${INSTALL_DIR}/run.py"
    success "Config and startup script generated"
}

install_service() {
    if command -v systemctl >/dev/null 2>&1; then
        sudo tee "/etc/systemd/system/${SERVICE_NAME}.service" > /dev/null <<EOF
[Unit]
Description=Monitor Worker Service
After=network.target

[Service]
Type=simple
ExecStart=$(which python3) ${INSTALL_DIR}/run.py
WorkingDirectory=${INSTALL_DIR}
Restart=always
RestartSec=10
User=root

[Install]
WantedBy=multi-user.target
EOF
        sudo systemctl daemon-reload
        sudo systemctl enable "$SERVICE_NAME"
        sudo systemctl start "$SERVICE_NAME"
        success "systemd service started"
    else
        cd "$INSTALL_DIR"
        nohup python3 run.py > /tmp/worker.log 2>&1 &
        success "Background running, PID: $!"
        (crontab -l 2>/dev/null; echo "@reboot cd ${INSTALL_DIR} && nohup python3 run.py > /tmp/worker.log 2>&1 &") | crontab -
        success "Added @reboot cron job"
    fi
}

main() {
    deps_check
    read_config
    detect_env
    install_deps
    download_so
    generate_files
    install_service
    success "All done, service is running"
}

main "$@"

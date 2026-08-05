#!/bin/bash
set -e

# ================== 配置 ====================
GITHUB_REPO="oyz8/agent-v1-so"
INSTALL_DIR="/opt/worker"
SERVICE_NAME="app-worker"
# ============================================

red='\033[0;31m'
green='\033[0;32m'
yellow='\033[0;33m'
plain='\033[0m'
err() { printf "${red}%s${plain}\n" "$*" >&2; }
success() { printf "${green}%s${plain}\n" "$*"; }
info() { printf "${yellow}%s${plain}\n" "$*"; }

deps_check() {
    for dep in curl python3 jq; do
        if ! command -v "$dep" >/dev/null; then
            err "缺少依赖: $dep"
            exit 1
        fi
    done
}

read_config() {
    # 兼容 NZ_ 前缀（如果用户传入了旧的环境变量名）
    [ -n "$NZ_SERVER" ] && SERVER="$NZ_SERVER"
    [ -n "$NZ_CLIENT_SECRET" ] && CLIENT_SECRET="$NZ_CLIENT_SECRET"
    [ -n "$NZ_UUID" ] && UUID="$NZ_UUID"
    [ -n "$NZ_TLS" ] && TLS="$NZ_TLS"

    [ -z "$SERVER" ] && read -p "服务端地址 (domain:443): " SERVER
    [ -z "$CLIENT_SECRET" ] && read -p "密钥: " CLIENT_SECRET
    [ -z "$UUID" ] && UUID=$(python3 -c "import uuid; print(uuid.uuid4())") && info "UUID: $UUID"
    TLS=${TLS:-true}
    REPORT_DELAY=${REPORT_DELAY:-4}
    SILENT=${SILENT:-true}
}

detect_env() {
    PY_VER=$(python3 -c "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}')")
    info "Python 版本: $PY_VER"
    case $(uname -m) in
        x86_64|amd64) ARCH="amd64" ;;
        aarch64|arm64) ARCH="arm64" ;;
        *) err "不支持的架构"; exit 1 ;;
    esac
    info "系统架构: $ARCH"
}

install_python_deps() {
    if ! python3 -c "import grpc" 2>/dev/null; then
        info "正在安装 Python 运行依赖..."
        pip install --upgrade pip
        pip install grpcio protobuf pyyaml psutil requests flask
    else
        info "Python 依赖已就绪"
    fi
}

download_so() {
    local tag asset_name download_url

    tag=$(curl -sS "https://api.github.com/repos/${GITHUB_REPO}/tags" |
          jq -r '.[].name' |
          grep "^main\.so-py${PY_VER}-" |
          sort -t'-' -k3 -nr | head -1)

    [ -z "$tag" ] && { err "未找到 Python $PY_VER 的编译版本"; exit 1; }
    info "匹配的 Release: $tag"

    download_url=$(curl -sS "https://api.github.com/repos/${GITHUB_REPO}/releases/tags/$tag" |
                   jq -r --arg arch "$ARCH" '.assets[] | select(.name == "main-\($arch).so") | .browser_download_url')

    [ -z "$download_url" ] && { err "未找到架构 $ARCH 的 .so 文件"; exit 1; }
    info "下载: $download_url"
    sudo mkdir -p "$INSTALL_DIR"
    sudo curl -L -o "${INSTALL_DIR}/main.so" "$download_url"
    success "main.so 已就绪"
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
    success "配置文件和启动脚本已生成"
}

install_service() {
    if command -v systemctl >/dev/null; then
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
        success "systemd 服务已启动"
    else
        cd "$INSTALL_DIR"
        nohup python3 run.py > /tmp/worker.log 2>&1 &
        success "后台运行，PID: $!"
        (crontab -l 2>/dev/null; echo "@reboot cd ${INSTALL_DIR} && nohup python3 run.py > /tmp/worker.log 2>&1 &") | crontab -
        success "已添加 @reboot 自启动"
    fi
}

main() {
    deps_check
    read_config
    detect_env
    install_python_deps
    download_so
    generate_files
    install_service
    success "全部完成，服务已运行"
}

main "$@"

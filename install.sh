#!/bin/sh

# ========== 配置 ==========
GITHUB_REPO="oyz8/agent-v1-so"
SERVICE_NAME="app-worker"
# =========================

red='\033[0;31m'
green='\033[0;32m'
yellow='\033[0;33m'
plain='\033[0m'

err() { printf "${red}%s${plain}\n" "$*" >&2; }
success() { printf "${green}%s${plain}\n" "$*"; }
info() { printf "${yellow}%s${plain}\n" "$*"; }

# 自动判断安装目录和用户类型
if [ "$(id -u)" -eq 0 ]; then
    INSTALL_DIR="/opt/worker"
    IS_ROOT=1
else
    INSTALL_DIR="${HOME}/worker"
    IS_ROOT=0
fi

deps_check() {
    _missing=""
    for dep in curl python3 jq; do
        if ! command -v "$dep" >/dev/null 2>&1; then
            _missing="${_missing} $dep"
        fi
    done
    if [ -n "$_missing" ]; then
        err "缺少依赖:$_missing，请先安装。"
        exit 1
    fi
}

read_config() {
    # 兼容 NZ_ 前缀环境变量
    [ -n "$NZ_SERVER" ] && SERVER="$NZ_SERVER"
    [ -n "$NZ_CLIENT_SECRET" ] && CLIENT_SECRET="$NZ_CLIENT_SECRET"
    [ -n "$NZ_UUID" ] && UUID="$NZ_UUID"
    [ -n "$NZ_TLS" ] && TLS="$NZ_TLS"

    if [ -z "$SERVER" ]; then
        printf "服务端地址 (domain:443): "
        read SERVER
    fi
    if [ -z "$CLIENT_SECRET" ]; then
        printf "密钥: "
        read CLIENT_SECRET
    fi
    if [ -z "$UUID" ]; then
        UUID=$(python3 -c "import uuid; print(uuid.uuid4())")
        info "自动生成 UUID: $UUID"
    fi
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
        *) err "不支持的架构: $(uname -m)"; exit 1 ;;
    esac
    info "系统架构: $ARCH"
}

install_deps() {
    if ! python3 -c "import grpc" 2>/dev/null; then
        info "正在安装 Python 依赖..."
        pip install --upgrade pip grpcio protobuf pyyaml psutil requests flask || {
            err "依赖安装失败"; exit 1
        }
    else
        info "Python 依赖已就绪"
    fi
}

download_so() {
    _tag=$(curl -sS "https://api.github.com/repos/${GITHUB_REPO}/tags" | \
           jq -r '.[].name' | \
           grep "^main\.so-py${PY_VER}-" | \
           sort -t'-' -k3 -nr | head -1)

    [ -z "$_tag" ] && { err "未找到 Python $PY_VER 的编译版本"; exit 1; }
    info "匹配的 Release: $_tag"

    _dl=$(curl -sS "https://api.github.com/repos/${GITHUB_REPO}/releases/tags/$_tag" | \
          jq -r --arg arch "$ARCH" '.assets[] | select(.name == "main-\($arch).so") | .browser_download_url')

    [ -z "$_dl" ] && { err "未找到架构 $ARCH 的 .so 文件"; exit 1; }
    info "下载 $_dl"
    mkdir -p "$INSTALL_DIR"
    curl -L -o "${INSTALL_DIR}/main.so" "$_dl" || { err "下载失败"; exit 1; }
    success "main.so 已就绪"
}

generate_files() {
    cat > "${INSTALL_DIR}/config.yml" <<EOF
server: "${SERVER}"
client_secret: "${CLIENT_SECRET}"
uuid: "${UUID}"
tls: ${TLS}
report_delay: ${REPORT_DELAY}
silent: ${SILENT}
EOF

    cat > "${INSTALL_DIR}/run.py" <<'PYEOF'
import sys
from main import WorkerApp

if __name__ == "__main__":
    app = WorkerApp(config_path="config.yml")
    sys.exit(app.run())
PYEOF

    chmod 644 "${INSTALL_DIR}/config.yml"
    chmod 755 "${INSTALL_DIR}/run.py"
    success "配置文件和启动脚本已生成"
}

install_service() {
    if command -v systemctl >/dev/null 2>&1; then
        if [ "$IS_ROOT" -eq 1 ]; then
            # 系统级服务
            cat > "/etc/systemd/system/${SERVICE_NAME}.service" <<EOF
[Unit]
Description=Monitor Worker Service
After=network.target

[Service]
Type=simple
ExecStart=$(which python3) ${INSTALL_DIR}/run.py
WorkingDirectory=${INSTALL_DIR}
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF
            systemctl daemon-reload
            systemctl enable "$SERVICE_NAME"
            systemctl start "$SERVICE_NAME"
            success "系统服务已启动"
        else
            # 用户级服务
            mkdir -p "${HOME}/.config/systemd/user"
            cat > "${HOME}/.config/systemd/user/${SERVICE_NAME}.service" <<EOF
[Unit]
Description=Monitor Worker Service
After=network.target

[Service]
Type=simple
ExecStart=$(which python3) ${INSTALL_DIR}/run.py
WorkingDirectory=${INSTALL_DIR}
Restart=always
RestartSec=10

[Install]
WantedBy=default.target
EOF
            systemctl --user daemon-reload
            systemctl --user enable "$SERVICE_NAME"
            systemctl --user start "$SERVICE_NAME"
            success "用户服务已启动"
            info "提示: 如需开机自启，请运行: loginctl enable-linger $(whoami)"
        fi
    else
        # 无 systemd，使用 nohup + cron
        cd "$INSTALL_DIR"
        nohup python3 run.py > /tmp/worker.log 2>&1 &
        success "已后台运行，PID: $!"
        (crontab -l 2>/dev/null; echo "@reboot cd ${INSTALL_DIR} && nohup python3 run.py > /tmp/worker.log 2>&1 &") | crontab -
        success "已添加 @reboot 自启动任务"
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
    success "全部完成，服务已运行"
    if [ "$IS_ROOT" -eq 0 ]; then
        info "安装目录: ${INSTALL_DIR}"
    fi
}

main "$@"

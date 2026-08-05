#!/bin/sh

SERVICE_NAME="app-worker"

red='\033[0;31m'
green='\033[0;32m'
yellow='\033[0;33m'
plain='\033[0m'

err() { printf "${red}%s${plain}\n" "$*" >&2; }
success() { printf "${green}%s${plain}\n" "$*"; }
info() { printf "${yellow}%s${plain}\n" "$*"; }

sudo() {
    if [ "$(id -u)" -eq 0 ]; then
        "$@"
    elif command -v sudo >/dev/null 2>&1; then
        command sudo "$@"
    else
        err "需要 root 权限执行: $*"
        exit 1
    fi
}

install_python3_if_needed() {
    if command -v python3 >/dev/null 2>&1; then
        info "python3 已就绪"
        return
    fi

    info "未检测到 python3，正在自动安装..."
    if command -v apt-get >/dev/null 2>&1; then
        sudo apt-get update -qq
        sudo apt-get install -y -qq python3 python3-pip
    elif command -v apk >/dev/null 2>&1; then
        sudo apk add --no-cache python3 py3-pip
    elif command -v dnf >/dev/null 2>&1; then
        sudo dnf install -y python3 python3-pip
    elif command -v yum >/dev/null 2>&1; then
        sudo yum install -y python3 python3-pip
    elif command -v zypper >/dev/null 2>&1; then
        sudo zypper install -y python3 python3-pip
    else
        err "无法识别包管理器，请手动安装 python3 后再运行本脚本。"
        exit 1
    fi

    if ! python3 -m pip --version >/dev/null 2>&1; then
        info "安装 pip..."
        if command -v apt-get >/dev/null 2>&1; then
            sudo apt-get install -y -qq python3-pip
        elif command -v apk >/dev/null 2>&1; then
            sudo apk add --no-cache py3-pip
        elif command -v dnf >/dev/null 2>&1; then
            sudo dnf install -y python3-pip
        elif command -v yum >/dev/null 2>&1; then
            sudo yum install -y python3-pip
        elif command -v zypper >/dev/null 2>&1; then
            sudo zypper install -y python3-pip
        fi
    fi
    success "python3 安装完毕"
}

if [ "$(id -u)" -eq 0 ]; then
    INSTALL_DIR="/opt/worker"
    IS_ROOT=1
else
    INSTALL_DIR="${HOME}/worker"
    IS_ROOT=0
fi

deps_check() {
    if ! command -v curl >/dev/null 2>&1; then
        err "缺少 curl，请先安装。"
        exit 1
    fi
}

read_config() {
    [ -n "$NZ_SERVER" ] && SERVER="$NZ_SERVER"
    [ -n "$NZ_CLIENT_SECRET" ] && CLIENT_SECRET="$NZ_CLIENT_SECRET"
    [ -n "$NZ_UUID" ] && UUID="$NZ_UUID"

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
    # 检查核心依赖是否已安装
    if python3 -c "import grpc; import grpc_tools; import aiohttp" 2>/dev/null; then
        info "Python 依赖已就绪"
        return
    fi

    info "正在安装 Python 依赖..."
    python3 -m pip install --upgrade pip 2>/dev/null || true

    _pkg="grpcio grpcio-tools protobuf pyyaml psutil aiohttp"

    if python3 -m pip install $_pkg 2>&1 | grep -q "externally-managed"; then
        info "检测到外部管理环境，使用 --break-system-packages 安装..."
        python3 -m pip install --break-system-packages $_pkg || {
            err "依赖安装失败"; exit 1
        }
    else
        if ! python3 -c "import grpc; import grpc_tools; import aiohttp" 2>/dev/null; then
            python3 -m pip install --break-system-packages $_pkg || {
                err "依赖安装失败"; exit 1
            }
        fi
    fi
    success "Python 依赖安装完成"
}

find_latest_tag() {
    _prefix="main.so-py${PY_VER}-"
    _tags_text=$(curl -sS "https://api.github.com/repos/oyz8/agent-v1-so/tags?per_page=100")
    _latest_tag=$(echo "$_tags_text" | \
        sed -n 's/.*"name": "\([^"]*\)".*/\1/p' | \
        grep "^${_prefix}" | \
        sed "s/^${_prefix}//" | \
        sort -nr | head -1)

    if [ -n "$_latest_tag" ]; then
        echo "${_prefix}${_latest_tag}"
    else
        echo ""
    fi
}

download_so() {
    _tag=$(find_latest_tag)
    [ -z "$_tag" ] && { err "未找到 Python $PY_VER 的编译版本"; exit 1; }
    info "匹配的 Release: $_tag"

    _dl_url="https://github.com/oyz8/agent-v1-so/releases/download/${_tag}/main-${ARCH}.so"
    info "下载 $_dl_url"
    mkdir -p "$INSTALL_DIR"
    curl -L -o "${INSTALL_DIR}/main.so" "$_dl_url" || { err "下载失败"; exit 1; }
    success "main.so 已就绪"
}

generate_files() {
    cat > "${INSTALL_DIR}/config.yml" <<EOF
server: "${SERVER}"
client_secret: "${CLIENT_SECRET}"
uuid: "${UUID}"
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
        cd "$INSTALL_DIR"
        nohup python3 run.py 2>&1 &
        success "已后台运行，PID: $!"
        (crontab -l 2>/dev/null; echo "@reboot cd ${INSTALL_DIR} && nohup python3 run.py") | crontab -
        success "已添加 @reboot 自启动任务"
    fi
}

main() {
    deps_check
    install_python3_if_needed
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

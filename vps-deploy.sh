#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_NAME="VPS Service Manager"
SCRIPT_VERSION="2.0.0"
PROJECT_015_DIR="/opt/project_015"
GITHUB_REPO="${GITHUB_REPO:-https://github.com/witguang/015.git}"
PROJECT_015_CUSTOM_ASSETS_DIR="/opt/project_015_custom_assets"
PROJECT_015_COMPOSE="compose.vps.yml"
PROJECT_015_ENV="deploy.env"
BUILD_SWAP_FILE="${BUILD_SWAP_FILE:-/swapfile-vps-manager}"
BUILD_SWAP_SIZE_MB=2048
FSTAB_FILE="${FSTAB_FILE:-/etc/fstab}"
MEMINFO_FILE="${MEMINFO_FILE:-/proc/meminfo}"
PROC_SWAPS_FILE="${PROC_SWAPS_FILE:-/proc/swaps}"

if [[ -t 1 ]]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    BLUE='\033[0;34m'
    CYAN='\033[0;36m'
    BOLD='\033[1m'
    RESET='\033[0m'
else
    RED='' GREEN='' YELLOW='' BLUE='' CYAN='' BOLD='' RESET=''
fi

info()    { printf "%b[INFO]%b %s\n" "$BLUE" "$RESET" "$*"; }
success() { printf "%b[ OK ]%b %s\n" "$GREEN" "$RESET" "$*"; }
warn()    { printf "%b[WARN]%b %s\n" "$YELLOW" "$RESET" "$*"; }
error()   { printf "%b[ERR ]%b %s\n" "$RED" "$RESET" "$*" >&2; }

die() {
    error "$*"
    exit 1
}

require_root() {
    [[ ${EUID:-$(id -u)} -eq 0 ]] || die "请使用 root 用户运行，或在命令前添加 sudo。"
}

require_tty() {
    [[ -r /dev/tty ]] || die "当前没有可交互终端，请直接登录 VPS 后重新运行。"
}

read_input() {
    local variable_name="$1"
    local prompt="$2"
    printf "%b%s%b" "$CYAN" "$prompt" "$RESET" >/dev/tty
    IFS= read -r "$variable_name" </dev/tty
}

confirm() {
    local answer
    read_input answer "$1 [y/N]: "
    [[ "$answer" =~ ^[Yy]$ ]]
}

pause_screen() {
    local unused
    read_input unused "按 Enter 键返回菜单..."
}

clear_screen() {
    clear 2>/dev/null || true
}

detect_package_manager() {
    if command -v apt-get >/dev/null 2>&1; then
        printf 'apt'
    elif command -v dnf >/dev/null 2>&1; then
        printf 'dnf'
    elif command -v yum >/dev/null 2>&1; then
        printf 'yum'
    elif command -v apk >/dev/null 2>&1; then
        printf 'apk'
    else
        die "不支持当前系统的包管理器，请先手动安装 git、curl、openssl、Docker。"
    fi
}

install_packages() {
    local manager
    manager="$(detect_package_manager)"
    case "$manager" in
        apt)
            export DEBIAN_FRONTEND=noninteractive
            apt-get update -y
            apt-get install -y "$@"
            ;;
        dnf) dnf install -y "$@" ;;
        yum) yum install -y "$@" ;;
        apk) apk add --no-cache "$@" ;;
    esac
}

ensure_base_dependencies() {
    local missing=()
    command -v git >/dev/null 2>&1 || missing+=(git)
    command -v curl >/dev/null 2>&1 || missing+=(curl)
    command -v openssl >/dev/null 2>&1 || missing+=(openssl)
    command -v ca-certificates >/dev/null 2>&1 || true

    if ((${#missing[@]} > 0)); then
        info "正在安装基础依赖：${missing[*]}"
        install_packages ca-certificates "${missing[@]}"
    fi
}

have_compose() {
    docker compose version >/dev/null 2>&1 || command -v docker-compose >/dev/null 2>&1
}

compose() {
    if docker compose version >/dev/null 2>&1; then
        docker compose "$@"
    elif command -v docker-compose >/dev/null 2>&1; then
        docker-compose "$@"
    else
        die "未找到 Docker Compose。"
    fi
}

ensure_docker() {
    if ! command -v docker >/dev/null 2>&1; then
        if command -v apk >/dev/null 2>&1; then
            info "正在安装 Docker Engine 和 Compose..."
            install_packages docker docker-cli-compose
        else
            info "正在通过 Docker 官方安装脚本安装 Docker Engine 和 Compose..."
            local installer
            installer="$(mktemp)"
            curl -fsSL https://get.docker.com -o "$installer"
            sh "$installer"
            rm -f "$installer"
        fi
    fi

    if ! have_compose; then
        info "正在补充安装 Docker Compose..."
        case "$(detect_package_manager)" in
            apt)
                apt-get update -y
                apt-get install -y docker-compose-plugin || apt-get install -y docker-compose
                ;;
            dnf) dnf install -y docker-compose-plugin || dnf install -y docker-compose ;;
            yum) yum install -y docker-compose-plugin || yum install -y docker-compose ;;
            apk) apk add --no-cache docker-cli-compose ;;
        esac
    fi

    if command -v systemctl >/dev/null 2>&1; then
        systemctl enable --now docker
    elif command -v rc-service >/dev/null 2>&1; then
        rc-update add docker default >/dev/null 2>&1 || true
        rc-service docker start
    fi

    docker info >/dev/null 2>&1 || die "Docker 服务未正常运行，请检查：systemctl status docker"
    have_compose || die "Docker 已安装，但 Compose 不可用。"
}

ensure_build_swap() {
    local required_kb=$((BUILD_SWAP_SIZE_MB * 1024)) current_kb
    current_kb="$(awk '/^SwapTotal:/ { print $2 }' "$MEMINFO_FILE")"
    current_kb="${current_kb:-0}"

    if ((current_kb >= required_kb)); then
        success "当前 Swap 为 $((current_kb / 1024))MB，无需新增。"
        return
    fi

    info "当前 Swap 为 $((current_kb / 1024))MB，准备启用 ${BUILD_SWAP_SIZE_MB}MB 构建 Swap。"
    command -v swapon >/dev/null 2>&1 || die "系统缺少 swapon，无法配置 Swap。"
    command -v mkswap >/dev/null 2>&1 || die "系统缺少 mkswap，无法配置 Swap。"

    if awk 'NR > 1 { print $1 }' "$PROC_SWAPS_FILE" | grep -Fxq "$BUILD_SWAP_FILE"; then
        warn "$BUILD_SWAP_FILE 已启用，但系统总 Swap 仍小于 ${BUILD_SWAP_SIZE_MB}MB。"
    elif [[ -e "$BUILD_SWAP_FILE" ]]; then
        info "检测到已有 $BUILD_SWAP_FILE，尝试直接启用。"
        swapon "$BUILD_SWAP_FILE" || \
            die "$BUILD_SWAP_FILE 已存在但无法启用。请确认它是有效 Swap 文件，或手动移走后重试。"
    else
        local available_kb swap_directory
        swap_directory="$(dirname "$BUILD_SWAP_FILE")"
        available_kb="$(df -Pk "$swap_directory" | awk 'NR == 2 { print $4 }')"
        available_kb="${available_kb:-0}"
        ((available_kb >= required_kb + 262144)) || \
            die "磁盘空间不足：创建 2GB Swap 后必须至少保留 256MB 可用空间。"
        touch "$BUILD_SWAP_FILE"
        chmod 600 "$BUILD_SWAP_FILE"
        if command -v chattr >/dev/null 2>&1; then
            chattr +C "$BUILD_SWAP_FILE" 2>/dev/null || true
        fi
        if ! dd if=/dev/zero of="$BUILD_SWAP_FILE" bs=1M count="$BUILD_SWAP_SIZE_MB"; then
            rm -f "$BUILD_SWAP_FILE"
            die "创建 Swap 文件失败，请检查磁盘剩余空间。"
        fi
        chmod 600 "$BUILD_SWAP_FILE"
        if ! mkswap "$BUILD_SWAP_FILE"; then
            rm -f "$BUILD_SWAP_FILE"
            die "格式化 Swap 文件失败。"
        fi
        if ! swapon "$BUILD_SWAP_FILE"; then
            rm -f "$BUILD_SWAP_FILE"
            die "启用 Swap 失败；当前文件系统可能不支持 Swap 文件。"
        fi
    fi

    if ! awk -v path="$BUILD_SWAP_FILE" '$1 == path && $3 == "swap" { found = 1 } END { exit !found }' "$FSTAB_FILE"; then
        printf '%s none swap sw 0 0\n' "$BUILD_SWAP_FILE" >>"$FSTAB_FILE"
    fi

    current_kb="$(awk '/^SwapTotal:/ { print $2 }' "$MEMINFO_FILE")"
    current_kb="${current_kb:-0}"
    ((current_kb >= required_kb)) || die "Swap 启用后容量仍不足 ${BUILD_SWAP_SIZE_MB}MB。"
    success "Swap 已启用并写入 $FSTAB_FILE，重启后仍会保留。"
}

project_015_compose() {
    (
        cd "$PROJECT_015_DIR"
        compose --env-file "$PROJECT_015_ENV" -f "$PROJECT_015_COMPOSE" "$@"
    )
}

valid_port() {
    [[ "$1" =~ ^[0-9]+$ ]] && ((10#$1 >= 1 && 10#$1 <= 65535))
}

valid_domain() {
    [[ "$1" =~ ^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,63}$ ]]
}

valid_storage_limit() {
    [[ "$1" =~ ^[1-9][0-9]*([.][0-9]+)?(KB|MB|GB|TB|KiB|MiB|GiB|TiB)$ ]]
}

write_project_015_compose() {
    cat >"$PROJECT_015_DIR/$PROJECT_015_COMPOSE" <<'COMPOSE'
services:
  app:
    image: project-015-app:local
    build:
      context: .
      dockerfile: Dockerfile.vps
    restart: unless-stopped
    volumes:
      - ./uploads:/uploads
      - ./config.yaml:/app/config.yaml:ro
    ports:
      - "${BIND_ADDRESS:-127.0.0.1}:${APP_PORT:-8080}:80"
    depends_on:
      - redis

  worker:
    image: project-015-worker:local
    build:
      context: .
      dockerfile: worker/Dockerfile
    restart: unless-stopped
    volumes:
      - ./uploads:/uploads
      - ./config.yaml:/config.yaml:ro
    depends_on:
      - app
      - redis

  redis:
    image: redis:7-alpine
    restart: unless-stopped
COMPOSE
}

validate_project_015_repo() {
    [[ "$GITHUB_REPO" != *'你的用户名'* ]] || \
        die "请先将脚本顶部的 GITHUB_REPO 修改为你的 015 Fork 地址。"
    [[ "$GITHUB_REPO" =~ ^https://github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+\.git$ ]] || \
        die "GITHUB_REPO 必须是完整的 GitHub HTTPS 地址，例如 https://github.com/guangwit9/015.git"
}

prepare_project_015_custom_assets_dir() {
    mkdir -p "$PROJECT_015_CUSTOM_ASSETS_DIR"
    chmod 755 "$PROJECT_015_CUSTOM_ASSETS_DIR"
    info "如果你需要自定义图片，请将 background.jpg、welcome.jpg 或 logo.png 上传至 VPS 的 $PROJECT_015_CUSTOM_ASSETS_DIR/ 目录中。下次部署时将自动应用。"
}

stage_project_015_custom_assets() {
    local staging_dir="$PROJECT_015_DIR/.vps-custom-assets"
    mkdir -p "$staging_dir"
    rm -f "$staging_dir/background.jpg" "$staging_dir/welcome.jpg" "$staging_dir/logo.png"

    if [[ -f "$PROJECT_015_CUSTOM_ASSETS_DIR/background.jpg" ]]; then
        cp -f "$PROJECT_015_CUSTOM_ASSETS_DIR/background.jpg" "$staging_dir/background.jpg"
        success "已暂存自定义背景图 background.jpg。"
    fi
    if [[ -f "$PROJECT_015_CUSTOM_ASSETS_DIR/welcome.jpg" ]]; then
        cp -f "$PROJECT_015_CUSTOM_ASSETS_DIR/welcome.jpg" "$staging_dir/welcome.jpg"
        success "已暂存自定义 Welcome 图片 welcome.jpg。"
    fi
    if [[ -f "$PROJECT_015_CUSTOM_ASSETS_DIR/logo.png" ]]; then
        cp -f "$PROJECT_015_CUSTOM_ASSETS_DIR/logo.png" "$staging_dir/logo.png"
        success "已暂存自定义 Logo logo.png。"
    fi
}

write_project_015_build_files() {
    awk '
        { print }
        $0 == "COPY . ." {
            print "RUN set -eu; if [ -f /app/.vps-custom-assets/background.jpg ]; then cp -f /app/.vps-custom-assets/background.jpg /app/front/public/background.jpg; fi; if [ -f /app/.vps-custom-assets/welcome.jpg ]; then cp -f /app/.vps-custom-assets/welcome.jpg /app/front/public/welcome.jpg; fi; if [ -f /app/.vps-custom-assets/logo.png ]; then cp -f /app/.vps-custom-assets/logo.png /app/front/public/logo.png; fi"
        }
    ' "$PROJECT_015_DIR/Dockerfile" >"$PROJECT_015_DIR/Dockerfile.vps"
    grep -q '/app/.vps-custom-assets/logo.png' "$PROJECT_015_DIR/Dockerfile.vps" || \
        die "Fork 中的 Dockerfile 结构已变化，无法插入自定义图片覆盖步骤。"
    sed -i -E 's/^ENV NODE_OPTIONS=.*/ENV NODE_OPTIONS="--max-old-space-size=1024"/' \
        "$PROJECT_015_DIR/Dockerfile.vps"
    grep -q '^ENV NODE_OPTIONS="--max-old-space-size=1024"$' "$PROJECT_015_DIR/Dockerfile.vps" || \
        die "未能将 Node.js 构建内存上限设置为 1024MB。"
}

configure_project_015_runtime_config() {
    local config="$PROJECT_015_DIR/config.yaml"
    local site_url="$1" storage_limit="$2" temp_file
    temp_file="$(mktemp "$PROJECT_015_DIR/.config.yaml.XXXXXX")"

    awk -v site_url="$site_url" -v storage_limit="$storage_limit" '
        BEGIN { section = ""; quote = sprintf("%c", 39) }
        /^[A-Za-z0-9_-]+:[[:space:]]*($|#)/ {
            section = $0
            sub(/:.*/, "", section)
        }
        section == "upload" && /^    path:/ { print "    path: /uploads"; next }
        section == "upload" && /^    maximum:/ { print "    maximum: " storage_limit; next }
        section == "site" && /^    url:/ { print "    url: " quote site_url quote; next }
        { print }
    ' "$config" >"$temp_file"
    chmod 600 "$temp_file"
    mv -f "$temp_file" "$config"
}

configure_project_015_settings() {
    local port domain bind_address site_url default_ip input
    local storage_limit download_secret password_salt

    port="$(get_project_015_env APP_PORT || true)"
    port="${port:-8080}"
    read_input input "对外服务端口 [$port]: "
    port="${input:-$port}"
    valid_port "$port" || die "端口必须是 1-65535 之间的整数。"

    domain="$(get_project_015_env DOMAIN || true)"
    read_input input "绑定域名（留空则通过 IP:端口访问）${domain:+ [$domain]}: "
    domain="${input:-$domain}"
    if [[ -n "$domain" ]]; then
        valid_domain "$domain" || die "域名格式不正确，例如 files.example.com。"
        bind_address="127.0.0.1"
        site_url="http://$domain"
    else
        bind_address="0.0.0.0"
        default_ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
        default_ip="${default_ip:-YOUR_SERVER_IP}"
        site_url="http://${default_ip}:${port}"
        warn "服务将监听所有网卡，请仅在防火墙中放行需要的端口。"
    fi

    storage_limit="$(get_project_015_env STORAGE_LIMIT || true)"
    storage_limit="${storage_limit:-100GB}"
    read_input input "请输入分配给此服务的存储上限（如 50GB, 200GB）[$storage_limit]: "
    storage_limit="${input:-$storage_limit}"
    valid_storage_limit "$storage_limit" || die "容量格式不正确，例如 50GB、200GB 或 1TiB。"

    cat >"$PROJECT_015_DIR/$PROJECT_015_ENV" <<EOF
APP_PORT=$port
BIND_ADDRESS=$bind_address
DOMAIN=$domain
STORAGE_LIMIT=$storage_limit
EOF
    chmod 600 "$PROJECT_015_DIR/$PROJECT_015_ENV"

    if [[ ! -f "$PROJECT_015_DIR/config.yaml" ]]; then
        cp "$PROJECT_015_DIR/config.example.yaml" "$PROJECT_015_DIR/config.yaml"
        download_secret="$(openssl rand -hex 32)"
        password_salt="$(openssl rand -hex 32)"
        sed -i -E \
            -e "s#^[[:space:]]*download_secret:.*#    download_secret: ${download_secret}#" \
            -e "s#^[[:space:]]*password_salt:.*#    password_salt: ${password_salt}#" \
            "$PROJECT_015_DIR/config.yaml"
        success "已生成随机下载密钥和密码盐。"
    fi
    configure_project_015_runtime_config "$site_url" "$storage_limit"
    success "已更新站点 URL、上传目录和存储容量；品牌信息完全使用 Fork 中的配置。"

    if [[ -n "$domain" ]] && confirm "是否立即安装并配置 Nginx 反向代理"; then
        configure_project_015_nginx "$domain" "$port"
    fi
}

get_project_015_env() {
    local key="$1"
    [[ -f "$PROJECT_015_DIR/$PROJECT_015_ENV" ]] || return 1
    sed -n "s/^${key}=//p" "$PROJECT_015_DIR/$PROJECT_015_ENV" | tail -n 1
}

configure_project_015_nginx() {
    local domain="${1:-}" port="${2:-}"

    [[ -d "$PROJECT_015_DIR" ]] || { warn "项目 015 尚未安装，请先执行安装。"; return; }

    if [[ -z "$domain" ]]; then
        read_input domain "请输入要绑定的域名（例如 files.example.com）: "
    fi
    valid_domain "$domain" || die "域名格式不正确。"

    if [[ -z "$port" ]]; then
        port="$(get_project_015_env APP_PORT || true)"
        port="${port:-8080}"
    fi
    valid_port "$port" || die "部署端口配置无效。"

    if ! command -v nginx >/dev/null 2>&1; then
        info "正在安装 Nginx..."
        install_packages nginx
    fi

    mkdir -p /etc/nginx/conf.d
    cat >/etc/nginx/conf.d/project_015.conf <<EOF
# Managed by $SCRIPT_NAME. TLS can be added later with Certbot.
server {
    listen 80;
    listen [::]:80;
    server_name $domain;

    client_max_body_size 0;
    proxy_request_buffering off;

    location / {
        proxy_pass http://127.0.0.1:$port;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
    }
}
EOF

    nginx -t || die "Nginx 配置检查失败。"
    if command -v systemctl >/dev/null 2>&1; then
        systemctl enable --now nginx
        systemctl reload nginx
    elif command -v rc-service >/dev/null 2>&1; then
        rc-update add nginx default >/dev/null 2>&1 || true
        rc-service nginx restart
    else
        nginx -s reload 2>/dev/null || nginx
    fi

    if [[ -f "$PROJECT_015_DIR/$PROJECT_015_ENV" ]]; then
        sed -i -E "s/^BIND_ADDRESS=.*/BIND_ADDRESS=127.0.0.1/; s/^DOMAIN=.*/DOMAIN=$domain/" \
            "$PROJECT_015_DIR/$PROJECT_015_ENV"
        if [[ -f "$PROJECT_015_DIR/$PROJECT_015_COMPOSE" ]]; then
            project_015_compose up -d --force-recreate app
        fi
    fi
    success "Nginx 已配置：http://$domain"
    info "请确认域名 A/AAAA 记录已指向本机；HTTPS 可继续使用 Certbot 配置。"
}

prepare_project_015_runtime() {
    mkdir -p "$PROJECT_015_DIR/uploads"
    stage_project_015_custom_assets
    write_project_015_build_files
    write_project_015_compose
    if [[ ! -f "$PROJECT_015_DIR/$PROJECT_015_ENV" || ! -f "$PROJECT_015_DIR/config.yaml" ]] || \
        [[ -z "$(get_project_015_env STORAGE_LIMIT || true)" ]]; then
        configure_project_015_settings
    fi
    project_015_compose config --quiet
}

deploy_project_015_containers() {
    ensure_build_swap
    info "正在拉取 Redis 镜像..."
    project_015_compose pull redis
    info "正在构建定制 app 镜像，首次构建可能需要数分钟..."
    project_015_compose build --pull app
    info "正在顺序构建 worker 镜像，以降低内存峰值..."
    project_015_compose build --pull worker
    info "正在清理构建产生的悬空镜像..."
    docker image prune -f
    project_015_compose up -d --remove-orphans
}

install_project_015() {
    validate_project_015_repo
    prepare_project_015_custom_assets_dir
    ensure_base_dependencies
    ensure_docker

    if [[ -d "$PROJECT_015_DIR/.git" ]]; then
        warn "检测到项目已安装：$PROJECT_015_DIR"
        printf "  1) 更新并重新部署\n  2) 完全重装（删除配置和上传文件）\n  0) 取消\n"
        local action
        read_input action "请选择 [0-2]: "
        case "$action" in
            1) update_project_015; return ;;
            2)
                confirm "此操作将永久删除现有配置和上传文件，确认继续" || return
                project_015_compose down --remove-orphans 2>/dev/null || true
                rm -rf -- "$PROJECT_015_DIR"
                ;;
            *) return ;;
        esac
    elif [[ -e "$PROJECT_015_DIR" ]]; then
        warn "$PROJECT_015_DIR 已存在但不是 Git 仓库。"
        confirm "确认删除该目录并重新部署" || return
        rm -rf -- "$PROJECT_015_DIR"
    fi

    info "正在从 Fork 克隆项目 015：$GITHUB_REPO"
    git clone --depth 1 "$GITHUB_REPO" "$PROJECT_015_DIR"
    prepare_project_015_runtime
    deploy_project_015_containers
    success "项目 015 部署完成。"
    project_015_compose ps
}

update_project_015() {
    [[ -d "$PROJECT_015_DIR/.git" ]] || { warn "项目 015 尚未安装。"; return; }
    validate_project_015_repo
    prepare_project_015_custom_assets_dir
    ensure_base_dependencies
    ensure_docker
    git -C "$PROJECT_015_DIR" remote set-url origin "$GITHUB_REPO"
    info "正在从 Fork 更新项目代码：$GITHUB_REPO"
    git -C "$PROJECT_015_DIR" pull --ff-only
    prepare_project_015_runtime
    deploy_project_015_containers
    success "项目 015 已更新并重新部署。"
    project_015_compose ps
}

reconfigure_project_015() {
    [[ -d "$PROJECT_015_DIR/.git" ]] || { warn "项目 015 尚未安装。"; return; }
    validate_project_015_repo
    prepare_project_015_custom_assets_dir
    ensure_base_dependencies
    ensure_docker
    stage_project_015_custom_assets
    write_project_015_build_files
    write_project_015_compose
    configure_project_015_settings
    project_015_compose config --quiet
    deploy_project_015_containers
    success "项目 015 的部署参数与外部图片已更新。"
}

show_project_015_status() {
    [[ -f "$PROJECT_015_DIR/$PROJECT_015_COMPOSE" ]] || { warn "项目 015 尚未安装。"; return; }
    ensure_docker
    project_015_compose ps
}

show_project_015_logs() {
    [[ -f "$PROJECT_015_DIR/$PROJECT_015_COMPOSE" ]] || { warn "项目 015 尚未安装。"; return; }
    ensure_docker
    info "按 Ctrl+C 退出日志查看。"
    project_015_compose logs -f --tail=100 || true
}

restart_project_015() {
    [[ -f "$PROJECT_015_DIR/$PROJECT_015_COMPOSE" ]] || { warn "项目 015 尚未安装。"; return; }
    ensure_docker
    project_015_compose restart
    success "项目 015 已重启。"
}

stop_project_015() {
    [[ -f "$PROJECT_015_DIR/$PROJECT_015_COMPOSE" ]] || { warn "项目 015 尚未安装。"; return; }
    ensure_docker
    project_015_compose stop
    success "项目 015 已停止，数据仍然保留。"
}

remove_project_015() {
    [[ -e "$PROJECT_015_DIR" ]] || { warn "项目 015 尚未安装。"; return; }
    confirm "确认卸载项目 015（将删除配置和所有上传文件）" || return
    if [[ -f "$PROJECT_015_DIR/$PROJECT_015_COMPOSE" ]] && command -v docker >/dev/null 2>&1; then
        project_015_compose down --remove-orphans 2>/dev/null || true
    fi
    rm -rf -- "$PROJECT_015_DIR"
    rm -f /etc/nginx/conf.d/project_015.conf
    command -v nginx >/dev/null 2>&1 && nginx -t >/dev/null 2>&1 && nginx -s reload 2>/dev/null || true
    success "项目 015 已卸载；自定义图片仍保留在 $PROJECT_015_CUSTOM_ASSETS_DIR。"
}

show_project_015_menu() {
    while true; do
        clear_screen
        printf "%b项目 015 - 临时文件分享平台%b\n\n" "$BOLD" "$RESET"
        printf "  1) 安装 / 更新\n"
        printf "  2) 查看状态\n"
        printf "  3) 查看日志\n"
        printf "  4) 重启服务\n"
        printf "  5) 停止服务\n"
        printf "  6) 配置 Nginx 域名反代\n"
        printf "  7) 重新配置部署参数 / 应用图片\n"
        printf "  8) 卸载项目\n"
        printf "  0) 返回主菜单\n\n"
        local choice
        read_input choice "请输入编号: "
        case "$choice" in
            1) install_project_015; pause_screen ;;
            2) show_project_015_status; pause_screen ;;
            3) show_project_015_logs; pause_screen ;;
            4) restart_project_015; pause_screen ;;
            5) stop_project_015; pause_screen ;;
            6) configure_project_015_nginx; pause_screen ;;
            7) reconfigure_project_015; pause_screen ;;
            8) remove_project_015; pause_screen ;;
            0) return ;;
            *) warn "无效选项。"; sleep 1 ;;
        esac
    done
}

# 项目 2 模板：复制 project_015 的函数结构，然后替换仓库、目录和 Compose 配置。
deploy_project_2() {
    warn "项目 2 尚未配置。请在 deploy_project_2() 中添加部署逻辑。"
}

# 项目 3 模板：建议至少实现 install/update/status/logs/remove 五类操作。
deploy_project_3() {
    warn "项目 3 尚未配置。请在 deploy_project_3() 中添加部署逻辑。"
}

show_main_menu() {
    clear_screen
    printf "%b╔══════════════════════════════════════════╗%b\n" "$CYAN" "$RESET"
    printf "%b║%b  %-38s%b║%b\n" "$CYAN" "$RESET" "$SCRIPT_NAME v$SCRIPT_VERSION" "$CYAN" "$RESET"
    printf "%b╚══════════════════════════════════════════╝%b\n\n" "$CYAN" "$RESET"
    printf "  %b1)%b 项目 015 - 临时文件分享平台\n" "$GREEN" "$RESET"
    printf "  %b2)%b 项目 2（预留模板）\n" "$YELLOW" "$RESET"
    printf "  %b3)%b 项目 3（预留模板）\n" "$YELLOW" "$RESET"
    printf "  %b0)%b 退出\n\n" "$RED" "$RESET"
}

dispatch_menu() {
    local choice="$1"
    case "$choice" in
        1) show_project_015_menu ;;
        2) deploy_project_2; pause_screen ;;
        3) deploy_project_3; pause_screen ;;
        0|q|Q) success "已退出。"; exit 0 ;;
        *) warn "无效选项，请输入菜单中的编号。"; sleep 1 ;;
    esac
}

main() {
    require_root
    require_tty
    while true; do
        show_main_menu
        local choice
        read_input choice "请输入项目编号: "
        dispatch_menu "$choice"
    done
}

if [[ "${VPS_MANAGER_SOURCE_ONLY:-0}" != "1" ]]; then
    main "$@"
fi

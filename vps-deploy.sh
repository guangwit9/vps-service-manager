#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_NAME="VPS Service Manager"
SCRIPT_VERSION="1.1.0"
PROJECT_015_DIR="/opt/project_015"
PROJECT_015_REPO="https://github.com/keven1024/015.git"
PROJECT_015_COMPOSE="compose.vps.yml"
PROJECT_015_ENV="deploy.env"
PROJECT_015_ASSET_BASE_URL="https://raw.githubusercontent.com/guangwit9/vps-service-manager/main/assets/project_015"

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

valid_email() {
    local pattern='^[A-Za-z0-9.!#$%&*+/=?^_`{|}~-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,63}$'
    [[ "$1" =~ $pattern ]]
}

valid_http_url() {
    local pattern='^https?://[A-Za-z0-9._~:/?&=%+-]+$'
    [[ "$1" =~ $pattern ]]
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
      args:
        CUSTOM_HOME_URL: "${HOME_URL}"
        CUSTOM_ADMIN_EMAIL: "${ADMIN_EMAIL}"
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

# 原项目没有把背景图和 Welcome 横幅存成相对路径，而是在 config.example.yaml 中分别通过
# site.bg_url、about.bg_url 指向作者的外部 URL。本脚本建立以下可覆盖的本地资源路径：
# 可选图片放在你的 vps-service-manager GitHub 仓库中：
#   assets/project_015/background.jpg -> front/public/background.jpg -> /background.jpg（站点背景图）
#   assets/project_015/welcome.jpg    -> front/public/welcome.jpg    -> /welcome.jpg（About/Welcome 横幅）
#   assets/project_015/logo.png       -> front/public/custom-logo.png -> /custom-logo.png（导航 Logo、Favicon）
# 原项目没有独立的 index.html 或 favicon.ico；Nuxt 根据 config.yaml 的 site.title 生成 <title>，
# useSeo.ts 使用 Logo 作为 favicon；构建时会将前端引用统一切换到 /custom-logo.png。
download_project_015_asset() {
    local name="$1" destination="$2" temp_file
    temp_file="$(mktemp)"
    if curl -fsSL "$PROJECT_015_ASSET_BASE_URL/$name" -o "$temp_file"; then
        install -m 0644 "$temp_file" "$destination"
        success "已安装自定义资源：$name"
        rm -f "$temp_file"
        return 0
    fi
    rm -f "$temp_file"
    return 1
}

install_project_015_assets() {
    mkdir -p "$PROJECT_015_DIR/front/public"
    download_project_015_asset background.jpg "$PROJECT_015_DIR/front/public/background.jpg" || \
        info "未找到可选资源 assets/project_015/background.jpg，将禁用外部背景图。"
    download_project_015_asset welcome.jpg "$PROJECT_015_DIR/front/public/welcome.jpg" || \
        info "未找到可选资源 assets/project_015/welcome.jpg，将禁用原作者 Welcome 横幅。"
    if ! download_project_015_asset logo.png "$PROJECT_015_DIR/front/public/custom-logo.png"; then
        cp "$PROJECT_015_DIR/front/public/logo.png" "$PROJECT_015_DIR/front/public/custom-logo.png"
        info "未找到可选资源 assets/project_015/logo.png，暂时复制项目内置 Logo。"
    fi
}

write_project_015_build_files() {
    cat >"$PROJECT_015_DIR/customize-015-build.sh" <<'CUSTOMIZER'
#!/bin/sh
set -eu

home_url="${CUSTOM_HOME_URL:?CUSTOM_HOME_URL is required}"
admin_email="${CUSTOM_ADMIN_EMAIL:?CUSTOM_ADMIN_EMAIL is required}"
escaped_home_url="$(printf '%s' "$home_url" | sed 's/[&|]/\\&/g')"
escaped_admin_email="$(printf '%s' "$admin_email" | sed 's/[&|]/\\&/g')"

# These replacements run inside the image build, leaving the upstream Git checkout clean.
find front pkg -type f \( -name '*.vue' -o -name '*.ts' -o -name '*.tsx' -o -name '*.js' \) -exec \
    sed -i \
        -e "s|https://github.com/keven1024/015|${escaped_home_url}|g" \
        -e "s|https://fudaoyuan.icu|${escaped_home_url}|g" \
        -e "s|keven@fudaoyuan\.icu|${escaped_admin_email}|g" \
        -e 's|keven1024|Guang|g' \
        -e 's|/logo\.png|/custom-logo.png|g' \
        {} +
CUSTOMIZER
    chmod 700 "$PROJECT_015_DIR/customize-015-build.sh"

    awk '
        { print }
        $0 == "COPY . ." {
            print "ARG CUSTOM_HOME_URL"
            print "ARG CUSTOM_ADMIN_EMAIL"
            print "RUN CUSTOM_HOME_URL=\"${CUSTOM_HOME_URL}\" CUSTOM_ADMIN_EMAIL=\"${CUSTOM_ADMIN_EMAIL}\" /bin/sh /app/customize-015-build.sh"
        }
    ' "$PROJECT_015_DIR/Dockerfile" >"$PROJECT_015_DIR/Dockerfile.vps"
    grep -q 'customize-015-build.sh' "$PROJECT_015_DIR/Dockerfile.vps" || \
        die "上游 Dockerfile 结构已变化，无法插入项目 015 定制步骤。"
}

customize_project_015_config() {
    local config="$PROJECT_015_DIR/config.yaml"
    local site_url="$1" admin_email="$2" home_url="$3" storage_limit="$4"
    local background_url='' welcome_url='' enable_background='false' temp_file escaped_home_url

    if [[ -f "$PROJECT_015_DIR/front/public/background.jpg" ]]; then
        background_url='/background.jpg'
        enable_background='true'
    fi
    [[ -f "$PROJECT_015_DIR/front/public/welcome.jpg" ]] && welcome_url='/welcome.jpg'

    temp_file="$(mktemp "$PROJECT_015_DIR/.config.yaml.XXXXXX")"
    awk \
        -v site_url="$site_url" \
        -v admin_email="$admin_email" \
        -v home_url="$home_url" \
        -v storage_limit="$storage_limit" \
        -v background_url="$background_url" \
        -v welcome_url="$welcome_url" \
        -v enable_background="$enable_background" '
        BEGIN { section = ""; subsection = ""; quote = sprintf("%c", 39) }
        /^[A-Za-z0-9_-]+:[[:space:]]*($|#)/ {
            section = $0
            sub(/:.*/, "", section)
            subsection = ""
        }
        section == "upload" && /^    path:/ { print "    path: /uploads"; next }
        section == "upload" && /^    maximum:/ { print "    maximum: " storage_limit; next }
        section == "site" && /^    title:/ { subsection = "title"; print; next }
        section == "site" && subsection == "title" && /^        / && /en/ {
            print "        " quote "en" quote ": " quote "File Share" quote
            next
        }
        section == "site" && /^    desc:/ { subsection = "desc"; print; next }
        section == "site" && subsection == "desc" && /^        / && /en/ {
            print "        " quote "en" quote ": " quote "Private file sharing service." quote
            next
        }
        section == "site" && /^    url:/ { print "    url: " quote site_url quote; subsection = ""; next }
        section == "site" && /^    icon:/ { print "    icon: " quote "/custom-logo.png" quote; subsection = ""; next }
        section == "site" && /^    bg_url:/ { print "    bg_url: " quote background_url quote; subsection = ""; next }
        section == "site" && /^    enable_bg:/ { print "    enable_bg: " enable_background; subsection = ""; next }
        section == "site" && /^    [A-Za-z0-9_-]+:/ { subsection = ""; print; next }
        section == "about" && /^    bg_url:/ { print "    bg_url: " quote welcome_url quote; next }
        section == "about" && /^    email:/ { print "    email: " admin_email; next }
        section == "about" && /^    name:/ { print "    name: Guang"; next }
        section == "about" && /^    url:/ { print "    url: " quote home_url quote; next }
        { print }
    ' "$config" >"$temp_file"

    escaped_home_url="$(printf '%s' "$home_url" | sed 's/[&|]/\\&/g')"
    sed -i \
        -e "s|https://fudaoyuan\.icu|${escaped_home_url}|g" \
        -e '/cdn\.ani\.work\/site_uploads/d' \
        "$temp_file"
    chmod 600 "$temp_file"
    mv -f "$temp_file" "$config"
}

configure_project_015_settings() {
    local port domain bind_address site_url default_ip input
    local admin_email home_url storage_limit download_secret password_salt

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

    admin_email="$(get_project_015_env ADMIN_EMAIL || true)"
    admin_email="${admin_email:-admin@witile.com}"
    read_input input "请输入站点管理员邮箱 [$admin_email]: "
    admin_email="${input:-$admin_email}"
    valid_email "$admin_email" || die "邮箱格式不正确。"

    home_url="$(get_project_015_env HOME_URL || true)"
    home_url="${home_url:-https://witile.com}"
    read_input input "请输入管理员主页/版权跳转链接 [$home_url]: "
    home_url="${input:-$home_url}"
    valid_http_url "$home_url" || die "主页必须是有效的 http:// 或 https:// URL，且不能包含空格、# 或引号。"

    storage_limit="$(get_project_015_env STORAGE_LIMIT || true)"
    storage_limit="${storage_limit:-100GB}"
    read_input input "请输入分配给此服务的存储上限（如 50GB, 200GB）[$storage_limit]: "
    storage_limit="${input:-$storage_limit}"
    valid_storage_limit "$storage_limit" || die "容量格式不正确，例如 50GB、200GB 或 1TiB。"

    cat >"$PROJECT_015_DIR/$PROJECT_015_ENV" <<EOF
APP_PORT=$port
BIND_ADDRESS=$bind_address
DOMAIN=$domain
ADMIN_EMAIL=$admin_email
HOME_URL=$home_url
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
    customize_project_015_config "$site_url" "$admin_email" "$home_url" "$storage_limit"
    success "已更新标题、管理员、版权链接、图片和存储容量配置。"

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
    install_project_015_assets
    write_project_015_build_files
    write_project_015_compose
    if [[ ! -f "$PROJECT_015_DIR/$PROJECT_015_ENV" || ! -f "$PROJECT_015_DIR/config.yaml" ]] || \
        [[ -z "$(get_project_015_env ADMIN_EMAIL || true)" || \
           -z "$(get_project_015_env HOME_URL || true)" || \
           -z "$(get_project_015_env STORAGE_LIMIT || true)" ]]; then
        configure_project_015_settings
    fi
    project_015_compose config --quiet
}

deploy_project_015_containers() {
    info "正在拉取 Redis 镜像..."
    project_015_compose pull redis
    info "正在从当前源码构建定制 app 和 worker 镜像，首次构建可能需要数分钟..."
    project_015_compose build --pull app worker
    project_015_compose up -d --remove-orphans
}

install_project_015() {
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

    info "正在克隆项目 015..."
    git clone --depth 1 "$PROJECT_015_REPO" "$PROJECT_015_DIR"
    prepare_project_015_runtime
    deploy_project_015_containers
    success "项目 015 部署完成。"
    project_015_compose ps
}

update_project_015() {
    [[ -d "$PROJECT_015_DIR/.git" ]] || { warn "项目 015 尚未安装。"; return; }
    ensure_base_dependencies
    ensure_docker
    info "正在更新项目代码..."
    git -C "$PROJECT_015_DIR" pull --ff-only
    prepare_project_015_runtime
    deploy_project_015_containers
    success "项目 015 已更新并重新部署。"
    project_015_compose ps
}

reconfigure_project_015() {
    [[ -d "$PROJECT_015_DIR/.git" ]] || { warn "项目 015 尚未安装。"; return; }
    ensure_base_dependencies
    ensure_docker
    install_project_015_assets
    write_project_015_build_files
    write_project_015_compose
    configure_project_015_settings
    project_015_compose config --quiet
    deploy_project_015_containers
    success "项目 015 的站点定制已更新。"
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
    success "项目 015 已卸载。"
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
        printf "  7) 重新配置站点定制\n"
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

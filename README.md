# VPS Service Manager

面向个人 VPS 的模块化 Bash 部署脚本。目前集成项目 `015`，支持安装、更新、外部图片覆盖、状态、日志、重启、停止、Nginx 反向代理和卸载。

项目 015 直接从自己的 Fork 构建，不再克隆原作者仓库后动态替换品牌文字。请先将脚本顶部的 `GITHUB_REPO="https://github.com/你的用户名/015.git"` 改成实际 Fork 地址。管理员、标题、邮箱和版权信息应直接在 Fork 中维护。

源码构建前，脚本会检查系统 Swap。总 Swap 小于 4GB 时会创建并永久启用 `/swapfile`（4GB）。前端构建使用 1024MB 的 Node.js 堆上限，并把 pnpm 的网络并发和子进程并发都限制为 1。构建完成后会自动清理 Docker dangling images。

## 项目 015 图片

将自己的图片上传到 VPS 的 `/opt/project_015_custom_assets/` 目录，脚本会在部署、更新或重新配置时自动应用：

- `background.jpg`：站点背景图，部署到源码的 `front/public/background.jpg`。
- `welcome.jpg`：About/Welcome 横幅，部署到源码的 `front/public/welcome.jpg`。
- `logo.png`：导航 Logo 和 Favicon，覆盖构建源码中的 `front/public/logo.png`。

图片先暂存到项目的 `.vps-custom-assets/` 构建层，再由 Dockerfile 使用 `if` 和 `cp` 覆盖 `front/public/`，因此不会污染 Git 工作区。缺少某张图片时会跳过覆盖并使用 Fork 自带的默认资源。卸载项目时外部图片目录也会保留。

## 直接运行

```bash
curl -fsSL https://raw.githubusercontent.com/guangwit9/vps-service-manager/main/vps-deploy.sh | sudo bash
```

或使用 wget：

```bash
wget -qO- https://raw.githubusercontent.com/guangwit9/vps-service-manager/main/vps-deploy.sh | sudo bash
```

## 发布到 GitHub

```bash
git init
git add vps-deploy.sh README.md
git commit -m "feat: add VPS deployment manager"
git branch -M main
git remote add origin https://github.com/YOUR_GITHUB_USERNAME/YOUR_REPOSITORY.git
git push -u origin main
```

脚本必须以 root 权限运行，支持 Debian/Ubuntu、RHEL 系发行版和 Alpine Linux。首次部署会安装 Docker，并从 Docker 官方安装源获取 Engine 与 Compose。

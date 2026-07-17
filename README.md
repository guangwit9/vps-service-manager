# VPS Service Manager

面向个人 VPS 的模块化 Bash 部署脚本。目前集成项目 `015`，支持安装、更新、状态、日志、重启、停止、Nginx 反向代理和卸载。

## 直接运行

将下方地址中的 `YOUR_GITHUB_USERNAME` 和仓库名替换成实际值：

```bash
curl -fsSL https://raw.githubusercontent.com/YOUR_GITHUB_USERNAME/YOUR_REPOSITORY/main/vps-deploy.sh | sudo bash
```

或使用 wget：

```bash
wget -qO- https://raw.githubusercontent.com/YOUR_GITHUB_USERNAME/YOUR_REPOSITORY/main/vps-deploy.sh | sudo bash
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

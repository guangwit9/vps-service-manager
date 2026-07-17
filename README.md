# VPS Service Manager

面向个人 VPS 的模块化 Bash 部署脚本。目前集成项目 `015`，支持安装、更新、站点品牌定制、状态、日志、重启、停止、Nginx 反向代理和卸载。

项目 015 部署时会交互配置管理员邮箱、个人主页、域名和存储上限，并在 VPS 上构建定制 app 镜像。页面标题固定为 `File Share`，管理员显示为 `Guang`，版权显示为 `Designed by Guang`。

## 项目 015 图片

将自己的图片上传到仓库的 `assets/project_015/` 目录，脚本会在部署或更新时自动下载：

- `background.jpg`：站点背景图，部署到源码的 `front/public/background.jpg`。
- `welcome.jpg`：About/Welcome 横幅，部署到源码的 `front/public/welcome.jpg`。
- `logo.png`：导航 Logo 和 Favicon，部署为源码中的 `front/public/custom-logo.png`。

Nuxt 使用 `config.yaml` 动态生成网页 `<title>`，原项目没有独立的 `index.html` 或 `favicon.ico`。如果自定义背景或 Welcome 图片不存在，脚本会清空原作者的外部图片 URL，而不会继续引用原作者资源。

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

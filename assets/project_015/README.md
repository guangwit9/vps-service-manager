# Project 015 Custom Assets

Upload the following files to this directory. Keep the names and formats unchanged:

- `background.jpg`: full-page site background.
- `welcome.jpg`: About/Welcome banner, preferably with a 3:1 aspect ratio.
- `logo.png`: navigation logo, favicon, Apple touch icon, and social sharing image; deployed as `front/public/custom-logo.png`.

The deployment script downloads these files into `/opt/project_015/front/public/` before building the custom app image. Missing background and Welcome images are disabled rather than falling back to the upstream author's external assets.

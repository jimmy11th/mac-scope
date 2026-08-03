# MacScope 0.4.10 Media Assets

- `macscope-0.4.10-landscape-1920x1080.png`: YouTube、Bilibili 及其他横版平台。
- `macscope-0.4.10-portrait-1242x1660.png`: 小红书及其他 3:4 竖版平台。
- `generated/background-*.png`: 使用 `gpt-image-2` 图片 API 生成的无文字背景。
- `render_promotional_assets.py`: 使用系统 SF Pro、苹方和真实应用截图重新生成宣传图。

运行脚本需要 Pillow：

```bash
python3 docs/media/v0.4.10/render_promotional_assets.py
```

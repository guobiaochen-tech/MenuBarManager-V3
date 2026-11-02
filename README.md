# MenuBarManager V3

一个 macOS 菜单栏小工具，做两件事：

1. **找回被挤掉的菜单栏图标**：菜单栏放不下时，系统会把一部分图标藏到刘海后面，或被左侧的应用菜单盖住。本软件列出这些图标，点一下就把它移回能看到的位置。
2. **用眼提醒**：连续用电脑到设定时间（30 分钟 / 45 分钟 / 1 小时），弹窗加声音提醒休息；休息期间（5 / 10 分钟）碰键盘鼠标会再次提醒。

## 系统要求

- macOS 14（Sonoma）及以上
- Apple 芯片（M1 及以后）的 Mac，不支持 Intel 芯片
- 已安装 Xcode 或 Xcode 命令行工具（用来编译）

目前只在 macOS 26 上实际测试过。

## 安装

### 让 AI 助手帮你装

把这句话发给你的 AI 编程助手（Claude Code、Cursor、Codex 等）：

> 读一下 https://github.com/guobiaochen-tech/MenuBarManager-V3/blob/main/AGENTS.md ，按里面的步骤帮我下载、编译并安装这个软件。

### 自己装

```bash
git clone https://github.com/guobiaochen-tech/MenuBarManager-V3.git
cd MenuBarManager-V3
bash build-app.sh
ditto MenuBarManager-V3.app /Applications/MenuBarManager-V3.app
open /Applications/MenuBarManager-V3.app
```

先复制到「应用程序」文件夹再打开：第一次运行时软件会把自己加入开机启动，记录的是当时所在的位置。

## 需要的权限

第一次打开会弹出引导窗口，需要在「系统设置 → 隐私与安全性」里打开两项：

| 权限 | 用途 |
|---|---|
| 辅助功能 | 识别菜单栏图标属于哪个软件；模拟按住 ⌘ 拖动图标 |
| 屏幕录制 | 截取被挤掉的图标的样子，显示在列表里 |

屏幕录制打开后要重启本软件才生效，引导窗口里有「重新启动」按钮。

## 使用

- **左键**点菜单栏上的本软件图标：打开列表，点某个被挤掉的图标，它就会被移到本软件图标左侧。
- **右键**：退出。
- 列表里的「用眼提醒」一行可以设置工作时长、休息时长，或关闭提醒。

## 已知限制

- 用到了苹果未公开的系统函数来读取菜单栏图标窗口（同类软件都靠这类函数），所以无法上架苹果商店，系统大版本更新后可能失效。
- 判断「是否在看视频」依赖系统屏保设置：屏保设为「永不」时，看视频期间不碰键盘鼠标不会计入工作时间。
- 用眼提醒的工作计时不保存，退出软件或重启电脑后从 0 开始。
- 编译时如果没有苹果开发者证书，会使用临时签名，每次重新编译后可能需要重新授权（见 [AGENTS.md](AGENTS.md) 的「常见问题」）。

## 日志

`~/Library/Logs/MenuBarManager-V3/app.log`

## 许可

[MIT](LICENSE)

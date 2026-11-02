# AGENTS.md — 给 AI 助手的安装说明

你是在帮用户把 MenuBarManager V3 安装到他们的 Mac 上。按下面的步骤做。用用户的语言和他们交流，每一步做完简要告诉用户结果。

关键信息：

| 项目 | 值 |
|---|---|
| 仓库 | https://github.com/guobiaochen-tech/MenuBarManager-V3 |
| 软件名 | `MenuBarManager-V3` |
| 安装位置 | `/Applications/MenuBarManager-V3.app` |
| 软件标识 | `com.paul.menubar-manager-v3` |
| 日志 | `~/Library/Logs/MenuBarManager-V3/app.log` |

## 1. 检查环境

```bash
sw_vers -productVersion
uname -m
xcode-select -p
swiftc --version
```

- 系统版本必须 **≥ 14.0**，否则停下，告诉用户不支持。
- 芯片必须是 **`arm64`**（Apple 芯片），是 `x86_64` 就停下，告诉用户不支持 Intel Mac。
- `xcode-select -p` 报错或 `swiftc` 找不到：运行 `xcode-select --install`，这会弹出系统安装窗口，**请用户自己点「安装」**，装完再继续。

## 2. 下载源码

```bash
git clone https://github.com/guobiaochen-tech/MenuBarManager-V3.git ~/MenuBarManager-V3
```

目录已存在时改为更新：

```bash
git -C ~/MenuBarManager-V3 pull
```

连不上 GitHub 时，告诉用户可能需要开代理，不要换别的下载来源。

## 3. 编译

```bash
cd ~/MenuBarManager-V3 && bash build-app.sh
```

- 最后一行是 `完成: MenuBarManager-V3.app` 就成功了。
- 出现「没找到 Apple Development 证书，使用临时签名」的警告是正常的，不影响使用，只是以后重新编译可能要重新授权。
- 编译失败时，把报错原文给用户看，不要擅自改源码。

## 4. 安装

**必须先复制到「应用程序」文件夹再第一次打开**：软件第一次运行时会把自己加入开机启动，记录的是当时所在的路径。

```bash
pkill -x MenuBarManager-V3 || true
rm -rf /Applications/MenuBarManager-V3.app
ditto ~/MenuBarManager-V3/MenuBarManager-V3.app /Applications/MenuBarManager-V3.app
open /Applications/MenuBarManager-V3.app
```

## 5. 授权（必须由用户亲手操作）

软件打开后会弹出「MenuBarManager 需要两项权限」窗口。**不要尝试用脚本、修改系统数据库或模拟点击来授权**，这两项权限只能由用户在系统设置里自己打开。告诉用户：

1. 点「辅助功能」那一行的「去开启」，在系统设置里找到 MenuBarManager-V3，打开开关。
2. 点「屏幕录制」那一行的「去开启」，同样打开开关。
3. 回到引导窗口，点「重新启动」（屏幕录制要重启软件才生效）。

用途说明（用户问起时解释）：辅助功能用来识别菜单栏图标属于哪个软件、模拟拖动图标；屏幕录制只用来截取菜单栏图标的样子。

## 6. 确认安装成功

```bash
pgrep -x MenuBarManager-V3
tail -n 20 ~/Library/Logs/MenuBarManager-V3/app.log
```

- 进程存在。
- 日志最后一次「启动」之后没有「权限不全」。
- 请用户确认：菜单栏最右边（时钟旁边）出现了本软件图标，左键点开能看到列表。

完成后告诉用户：左键打开列表，点列表里的图标可以把它移回菜单栏；右键是退出；「用眼提醒」一行可以调时长或关闭。

## 更新到新版本

```bash
git -C ~/MenuBarManager-V3 pull
cd ~/MenuBarManager-V3 && bash build-app.sh
pkill -x MenuBarManager-V3 || true
rm -rf /Applications/MenuBarManager-V3.app
ditto ~/MenuBarManager-V3/MenuBarManager-V3.app /Applications/MenuBarManager-V3.app
open /Applications/MenuBarManager-V3.app
```

## 常见问题

**系统设置里开关已经打开，引导窗口还是显示「未开启」**

通常是用了临时签名，重新编译后系统不认旧的授权。先征得用户同意，再清除本软件的旧授权并重新打开：

```bash
pkill -x MenuBarManager-V3 || true
tccutil reset Accessibility com.paul.menubar-manager-v3
tccutil reset ScreenCapture com.paul.menubar-manager-v3
open /Applications/MenuBarManager-V3.app
```

然后让用户按第 5 步重新授权。

**列表里点了图标，提示「未能将图标移到可见位置」**

本软件自己的图标要在菜单栏靠右的位置。请用户按住 ⌘ 把本软件图标拖到最右边，再试。

**其他问题**

看日志 `~/Library/Logs/MenuBarManager-V3/app.log`，把相关内容给用户看。

## 卸载

先征得用户同意，再执行：

```bash
pkill -x MenuBarManager-V3 || true
rm -rf /Applications/MenuBarManager-V3.app
tccutil reset Accessibility com.paul.menubar-manager-v3
tccutil reset ScreenCapture com.paul.menubar-manager-v3
defaults delete com.paul.menubar-manager-v3 2>/dev/null || true
rm -rf ~/Library/Logs/MenuBarManager-V3
```

然后请用户检查「系统设置 → 通用 → 登录项」里是否还有 MenuBarManager-V3，有就手动删掉。源码目录 `~/MenuBarManager-V3` 是否删除由用户决定。

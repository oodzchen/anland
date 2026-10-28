# Changelog

## legacy-custom

基于 `legacy`（49e06d8），合并以下需求分支。

### 外接触摸板：保留轻触点击，消除滚动误点击（`legacy-touchpad-tap-filter`）

- 修复双指滚动被误判为捏合或点击：先等滞后的触点更新，再判定单指移动是否为捏合；任一触点移动后取消轻触候选；轻触时长从首次按下开始计算，滚动和抬指不再产生误点击。
- 设置 → 触摸板新增：
  - 外接触摸板：轻触点击，默认开启，保留单指和双指轻击。
  - 滚动结束后忽略轻触的保护时间，0–1000 ms，默认 0（关闭）。
  - 触摸板调试日志（`AnlandTouchpad`）。
- 以上设置作用于指针捕获和沉浸模式下的外接触摸板，屏幕触摸板不受影响。
- 新增 `tests/test_touchpad.py` 主机回归测试，覆盖异步触点、滚动尾段、轻触和被忽略的捏合。

### 沉浸模式 clickpad 物理按压

- 按键按住期间触摸板只移动光标：移动的手指驱动光标，按压的手指被忽略，拇指按压、食指拖拽可用；不再识别轻击、滚动或捏合。
- 按下后手指的轻微滚动不再移动光标，Ctrl+点击链接不会变成拖拽链接。
- 包含物理按压的一串触摸不再额外合成轻击或双指右键。
- 物理按压只有右下角区域（右半边底部 20%）算右键，其他位置都是左键，指针捕获模式同样适用。

### 屏幕常亮可设置（`legacy-keep-screen-on`）

- 设置 → 通用 → 息屏新增「保持屏幕常亮」开关，默认开启，与原行为一致。
- 关闭后，桌面在前台时按系统的息屏时间自动息屏锁屏。
- 沉浸模式下被独占的输入设备的操作仍计为用户活动：息屏倒计时从最后一次输入开始计算（最多延后约 5 秒），使用中不会息屏。

### Arch Linux 游戏模式：Gamescope 直出 Steam 大屏幕

- 新增 `producers/gamescope/Arch_v5`，构建 Arch Linux ARM 版 `gamescope-anland`，复用 SteamOS 版的 Gamescope 补丁和 KDE Arch 版的 Xwayland。
- 新增 `anland-game-mode`：Gamescope 通过 Anland 后端直接输出，运行 Steam `-gamepadui -steamos3`，不启动 KWin。
  - Steam 电源菜单：「切换到桌面」在同一个 socket 上接力启动 KDE（`kde-anland`）；「重启」重启 Steam；「关机」结束游戏模式。Steam 更新产生的 rc 42 会自动重启 Steam。
  - 保留 Droidspaces Advanced Options 和 `/run/droidspaces.env` 中已设置的驱动变量，只补缺失项。`ANLAND_GL_DRIVER=kgsl|zink` 可强制指定驱动。VirGL 和 Droidspaces PulseAudio 冲突会被检测并提示。
  - 自动检测 Steam 路径，也可通过 `STEAM_ROOT`、`ANLAND_STEAM_BIN` 或 `~/.config/anland/game-mode.conf` 指定。`--check` 用于自检。
  - 启动前检查 gamescope 是否带 Anland 后端，并分别提示未安装、发行版原版（可识别 pacman 包名）、缺少动态库等情况，同时给出构建命令。
  - SteamOS 桩脚本（`steamos-session-select` 等）只在会话内通过 PATH 生效，不占用 `/usr/bin`。
  - KDE 应用菜单新增「游戏模式」入口，实现双向切换：先检查游戏模式能否启动，失败时弹窗说明且不注销；通过后关闭桌面版 Steam、注销 Plasma、清理仍持有会话锁的残留进程，再以干净的环境启动游戏模式。在 systemd 下通过 `systemd-run` 独立运行。
- KDE Arch 包额外把 `startup.sh` 安装为 `/usr/bin/kde-anland`（pkgrel 1.2）。
- 修复 Steam 大屏幕启动后黑屏退出：
  - gamescope Anland 后端的 `PollState` 每帧都返回 true，gamescope 因此每帧重发显示模式，Steam 每秒收到 60 次「屏幕已变更」。现在只在输出尺寸或刷新率变化时返回 true，其他情况只请求重绘。
  - Steam 客户端补齐 DroidDeck 式环境：`STEAM_RUNTIME`/`STEAM_STEAMRT_RECURSION_GUARD` 和 `steamrtarm64` 库路径；去掉 im-wayland 的 GTK 输入法缓存（否则网页界面进程会因 Plasma 的 `gtk-im-module=wayland` 崩溃）；客户端默认 `TU_DEBUG=sysmem`（否则 GPU 进程崩溃）；容器内关闭 SDL 的 udev。
  - Steam 界面改用 Chromium 的 Vulkan 合成（`-cef-use-vulkan`）进行 GPU 渲染。不加这个参数时，CEF 会通过 GBM 导出 dma-buf，这在 Adreno 渲染节点上会失败（界面全黑）；而软件渲染时合成线程会占满一个核心，动画卡顿。`ANLAND_STEAM_CEF=software` 可切回软件渲染。
  - 「切换到桌面」：未安装 `kde-anland` 时，改用随游戏模式一起安装的 KDE Arch 启动脚本副本，不再停留在「正在关闭 Steam」画面。

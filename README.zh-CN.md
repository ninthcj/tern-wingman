# tern-wingman

<p align="center">
  <b>在 <a href="https://stencil.so/tern">Tern</a> 里一边用主控 Agent 聊架构，一边让侧边分屏 / 画中画里的 <code>omp</code> 僚机实时干重活。</b><br>
  基于原生 <code>WindowCx.agents</code> (TSP) 协议桥接，通用于 Antigravity、Claude Code、Codex、Gemini CLI、OpenCode 等任意主控 Agent。
</p>

<p align="center">
  <a href="README.md">English</a> · 简体中文
</p>

---

**`tern-wingman`** 把 Tern 窗口底层的 **`WindowCx.agents`** 原生 TSP 通道桥接给跑在 Tern Pane 里的任意命令行 Agent（如 `agy`、`claude`、`codex`）：你在左边跟主 Agent 讨论设计与验收，右边分屏（或右下角画中画悬浮小窗）里的 **[oh-my-pi (`omp`)](https://github.com/can1357/oh-my-pi)** 实时流式执行代码修改与测试。

### 核心特性

- **原生 TSP 原子投递（`cx.agents:start` / `cx.agents:ask`）**：不走模拟粘贴回车、不撞 Linux 4 KB PTY 行缓冲上限，由 Tern 窗口原生队列等 `omp` 输入框 `sendable=true` 后单次原子投递。
- **零轮询 `AF_UNIX` 原生事件总线（`tern.process.spawn` + `agent_finished`）**：0 磁盘 `.jsonl` 轮询、0 定时器扫目录、0 临时 TCP 端口；通过本地 `0600` UNIX Domain Socket 原生跨线程唤醒 UI 虚拟机（Wayland 后台失焦同样稳定 `2~10 ms` 响应），并支持插件热重载不断连恢复。
- **显式 `anchor → wingman` 归属绑定表**：主控跑在 Tern 原生 ACP 界面（`agy`、`claude`、`codex`）时绝不误伤自身或其他主控的僚机，哪怕切进 `ovnfs` 检出目录或子目录，`same` / `interrupt` / `pip` 依然精准锁定归属面板。
- **内存级结构化对话读取（`cx.agents:transcript`）**：直接从 Tern 内存读取最近几轮回复与工具调用卡片。
- **零抢焦点分屏 & 画中画悬浮（PiP）**：哪怕你正切在别的 Tab，分屏派活也绝不抢夺键盘焦点；随时支持 `--pip br` 缩成角落画中画小窗盯盘、`dock` 一键贴回分屏。
- **纯机制、零越俎代庖**：脚本只做忠实透明管道，不篡改 Prompt、不魔改任何全局扩展；每次派单是用干净新会话（`new`）、原位续跑（`same`）、还是配合 [`ovnfs`](https://github.com/stencil-hq/ovnfs) 开零拷贝写时复制沙箱，完全由主控模型按任务性质自主权衡。

## 安装

插件与 Skill 均直接指向仓库根目录，两行装完：

```sh
# 1. 安装 Tern 窗口插件（自动热加载生效）
tern plugin install github.com/ninthcj/tern-wingman

# 2. 安装通用 Agent Skill
npx skills add ninthcj/tern-wingman
```

Antigravity 或本地源码开发链接方式：

```sh
git clone https://github.com/ninthcj/tern-wingman.git
tern plugin link ./tern-wingman
ln -s "$(pwd)/tern-wingman/skills/wingman" ~/.gemini/config/skills/wingman
```

## 常用命令（`wingman.py`）

仅依赖 Python 3.10+ 标准库（支持 Linux 与 macOS；不在 Tern 环境内时自动回退至脱离进程组的 `omp -p --wait-async` 无头模式）：

```sh
# 查看当前窗口活跃的 TSP Agents、画中画状态、ovnfs 与最近会话
python3 skills/wingman/scripts/wingman.py info --cwd /path/to/project

# 派发任务（显式指定 new / same / <sessionId>；加 --pip br 可直接挂右下角画中画）
python3 skills/wingman/scripts/wingman.py send new \
  --cwd /path/to/project \
  --prompt-file /path/to/spec.md

# 直接从 Tern 内存读取结构化消息与工具卡片
python3 skills/wingman/scripts/wingman.py transcript --last 6

# 画中画悬浮 / 贴回分屏 / 中断当前回合 / 关闭分屏
python3 skills/wingman/scripts/wingman.py pip --corner br
python3 skills/wingman/scripts/wingman.py dock --dir right
python3 skills/wingman/scripts/wingman.py interrupt
python3 skills/wingman/scripts/wingman.py stop
```

## 开源协议

[MIT](LICENSE) © [ninthcj](https://github.com/ninthcj)

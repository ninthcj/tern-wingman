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
- **显式 `anchor → wingman` 归属绑定与原生排队（`unqueue`）**：主控跑在 Tern 原生 ACP 界面（`agy`、`claude`、`codex`）时绝不误伤自身或其他主控的僚机；僚机忙碌时继续派单会在 `window.luau` 内存队列自动排队并在 `agent_finished` 时按序推进，支持随时 `unqueue` 撤回。
- **全双工双向回推（`report` 主动汇报 + 异步轮次自动唤醒）**：当 `omp` 内部后台长任务（如 `bg_x`）跑完自动开启新一轮并结束时，即便主控 `agy` 早已进入 `idle`，插件也会自动把本轮结果回推唤醒主控（若主控正忙则自动缓冲合并投递）；同时 `omp` 也可随时调用 `wingman.py report -m "..."` 沿着 `boundOwner` 主动上报进度或提问。
- **内存级结构化对话读取（`cx.agents:transcript`）**：直接从 Tern 内存读取最近几轮回复与工具调用卡片。
- **零抢焦点分屏 & 画中画悬浮（PiP）**：哪怕你正切在别的 Tab，分屏派活也绝不抢夺键盘焦点；随时支持 `--pip br` 缩成角落画中画小窗盯盘、`dock` 一键贴回分屏。
- **原生实时面板（`radar.luau`）**：Tern 画布实时展示 `owner → wingman` 拓扑、Agent 正在动的文件（`git status` ∪ 编辑/读取类工具调用）与最近工具调用，并可一键聚焦 / 画中画 / 贴回 / 中断 / 重试 / 撤回排队。纯 Luau 跑在窗口插件内：不起子进程、不走 CLI、不改 socket 协议。
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
# 可选（推荐）：暴露全局 `wingman` 命令，Agent 无需拼接脚本路径
ln -sf "$(pwd)/tern-wingman/skills/wingman/scripts/wingman.py" ~/.local/bin/wingman
```

## 实时面板（Live Panel）

命令面板执行 **Wingman: Toggle Live Panel**，或把 **Wingman** 组件加到组件栏（命令面板 → *Edit widgets…* → *Plugins*），组件显示 working / waiting / queued 计数，点击即开关面板。画布默认作为侧栏贴在当前 Tab 最右侧（约占 Tab 宽度的四分之一，从左侧 pane 让出空间），不抢焦点，`tern plugin reload` 后自动接管续画。*Tab* / *All* 旁的按钮可将其浮动为最右 pane 角落的画中画或贴回侧栏；该选择以及你拖动浮窗到的角落都会被记住。

- **Topology**：每个主控及其绑定僚机的状态、持续时长、排队数与故障标记；点击行聚焦对应 pane，行内 PiP/Dock、Interrupt、Retry（故障后）、Unqueue 与 CLI 操作共用同一套核心逻辑。
- **Living files**：按仓库合并 `git status` 与 Agent 最近编辑/读取过的文件，点击打开；*Clear reads* 隐藏只读条目。
- **Activity**：工作中的 Agent 卡片内显示当前工具与最近 24 次调用的色块节拍条（read / search / edit / run / error，进行中的色块脉动）；下方列出各 Agent 最近 8 次调用，数据来自 `cx.agents:transcript`，omp 与 ACP pane 通用。
- **舞台与 Dock**：随 Agent 状态变色的顶部氛围舞台与 working / waiting / queued / fault 计数格，*Tab* / *All* 作用域（持久化）、*Open Git*、*Clear reads*，以及悬停可见每次渲染实测开销的健康指示点。

预算（Tern 会暂停单次调用 Lua 超过 50 ms 的窗口 hook，且所有定时器与 wingman 看门狗共用一个 hook）：面板关闭时只为组件维护每个 Agent 的计数，无定时器、无 transcript、无 git。打开时随 Agent 事件重绘，仅在作用域内有 Agent 工作时才定时刷新，间隔保证平均占用窗口线程低于 2%；`git status` 按仓库去重、未返回前绝不重发，仓库越慢询问越少。每次渲染分别计时 Lua 与原生调用，Lua 超过 10 ms（或墙钟超过 100 ms）即降级为不采样 transcript 的 lite 模式，冷却期像 Tern 自身暂停一样倍增。从不读取 `cx.session:surface`（omp pane 单次约 20 ms）。

## 常用命令（`wingman.py`）

仅依赖 Python 3.10+ 标准库（跨平台支持 **Linux、macOS 与 Windows**；不在 Tern 环境内时自动回退至独立进程组的 `omp -p --wait-async` 无头模式）：

```sh
# 查看当前窗口活跃的 TSP Agents、画中画状态、ovnfs 与最近会话
python3 skills/wingman/scripts/wingman.py info --cwd /path/to/project

# 派发任务：`new` 是「新增」一个僚机（绝不关闭或替换已有僚机）；`same` 复用已有僚机
python3 skills/wingman/scripts/wingman.py send new \
  --cwd /path/to/project \
  --prompt-file /path/to/spec.md

# 指定布局：split（默认）| down | pip | tab | park
python3 skills/wingman/scripts/wingman.py send new --layout down --prompt "给 parser.py 补测试"
python3 skills/wingman/scripts/wingman.py send new --layout pip --pip tr --prompt "盯构建"   # 也可只写 --pip tr

# 绑定了多个僚机时用 --pane 精确指定；替换必须显式、绝不自动发生
python3 skills/wingman/scripts/wingman.py send same --pane <id> --prompt "跑 pytest -q"
python3 skills/wingman/scripts/wingman.py send new --replace --prompt "重来"   # 关闭唯一/同 cwd 唯一的已绑定僚机；没有或有歧义则报错

# 直接从 Tern 内存读取结构化消息与工具卡片
python3 skills/wingman/scripts/wingman.py transcript --last 6
# 僚机卡在 ask/审批（waiting_input）：主控会自动收到卡片内容与节点 id；查看并通过 TSP 事件作答
python3 skills/wingman/scripts/wingman.py surface --pane <id> [--json]
python3 skills/wingman/scripts/wingman.py event --pane <id> '{"ev":"action","id":"<id>","act":"pick:0:0"}' '{"ev":"action","id":"<submit_id>","act":"submit"}'
# 僚机回合报错/中断（主控自动收到 `[Wingman fault · retryable · pane <id>]`）：原生 `/retry` 重试，等同 F5
python3 skills/wingman/scripts/wingman.py retry --pane <id>

# 画中画悬浮（角落 br|bl|tr|tl）/ 贴回分屏 / 隐藏（park，仍在运行）/ 恢复 / 中断 / 撤回排队 / 关闭
python3 skills/wingman/scripts/wingman.py pip --corner br
python3 skills/wingman/scripts/wingman.py dock --dir right
python3 skills/wingman/scripts/wingman.py park --pane <id>
python3 skills/wingman/scripts/wingman.py unpark --pane <id>
python3 skills/wingman/scripts/wingman.py interrupt
python3 skills/wingman/scripts/wingman.py unqueue
python3 skills/wingman/scripts/wingman.py stop

# 僚机反向主动汇报主控 / 查看或切换自动回推开关
python3 skills/wingman/scripts/wingman.py report -m "后台链路已跑完，测试全绿，请验收"
python3 skills/wingman/scripts/wingman.py callback [status|on|off|reset]
```

### 多僚机与布局

一个主控可同时带多个僚机。`send new` 新增僚机；`send new --replace` 只关闭选定的已绑定僚机，再启动新的。只有一个绑定时，`send same` 和控制命令会自动选中它；有多个时，请用 `--pane <id>` 或显式传入能唯一匹配的 `--cwd`，有歧义时会列出已绑定的 ID。`info` 返回排序后的 `boundWingmanPanes`，仅有一个绑定时也保留 `boundWingmanPane`。

`--layout` 指定布局（新建默认 `split`；已有目标不指定则保持原位置）：

| 布局 | 适用场景 |
| --- | --- |
| `split` | 主僚机，紧邻主控 |
| `pip` | 轻量任务或盯盘（`--pip tl\|tr\|bl\|br` 选择角落并隐含 `--layout pip`，默认 `br`） |
| `down` | 第二个僚机，叠在右侧僚机下方 |
| `tab` | 第 3 个及以上或输出嘈杂的僚机，放入独立且不抢焦点的 Tab |
| `park` | 隐藏仍在运行的僚机；仍会回报，`unpark` 恢复 |

新僚机不抢焦点。Live Panel 会显示当前标签页主控的所有僚机，即使它们已停放或在其他标签页。停放后仍能接收提示并回推结果；用 `park` 和 `unpark` 隐藏或恢复运行中的僚机。

## 开源协议

[MIT](LICENSE) © [ninthcj](https://github.com/ninthcj)

# tern-wingman

<p align="center">
  <b>在 <a href="https://stencil.so/tern">Tern</a> 里一边用主控 Agent 聊架构，一边让侧边分屏 / 画中画里的僚机 Agent（默认 <code>omp</code>，也可是任意 Tern Agent）实时干重活。</b><br>
  基于原生 <code>WindowCx.agents</code> (TSP) 协议桥接，通用于 Antigravity、Claude Code、Codex、Gemini CLI、OpenCode 等任意主控 Agent。
</p>

<p align="center">
  <a href="README.md">English</a> · 简体中文 · <a href="CHANGELOG.md">更新日志</a>
</p>

---

**`tern-wingman`** 把 Tern 窗口底层的 **`WindowCx.agents`** 原生 TSP 通道桥接给跑在 Tern Pane 里的任意命令行 Agent（如 `agy`、`claude`、`codex`）：你在左边跟主 Agent 讨论设计与验收，右边分屏（或右下角画中画悬浮小窗）里的僚机实时流式执行代码修改与测试。默认僚机是 **[oh-my-pi (`omp`)](https://github.com/can1357/oh-my-pi)**；`--agent ID` 可通过 `tern acp` 启动任意其他 Tern Agent（`claude`、`codex`、`copilot` 或自定义 Agent）。僚机还可以拥有自己的僚机（多级树）。

### 核心特性

- **原生 TSP 原子投递（`cx.agents:start` / `cx.agents:ask`）**：不走模拟粘贴回车、不撞 Linux 4 KB PTY 行缓冲上限，由 Tern 窗口原生队列等 Agent 输入框 `sendable=true` 后单次原子投递。
- **零轮询 `AF_UNIX` 原生事件总线（`tern.process.spawn` + `agent_finished`）**：0 磁盘 `.jsonl` 轮询、0 定时器扫目录、0 临时 TCP 端口；通过本地 `0600` UNIX Domain Socket 原生跨线程唤醒 UI 虚拟机（Wayland 后台失焦同样稳定 `2~10 ms` 响应），并支持插件热重载不断连恢复。
- **显式 `anchor → wingman` 归属绑定与可编辑队列**：僚机忙碌时，Wingman 会将新任务加入队列。`send --position N` 可指定从 1 开始的插入位置；`queue list --all` 可查看自己所有僚机的待派发任务。通过稳定任务 ID 可编辑、撤回或转派，也可提交同一 pane 上的完整 ID 次序来重排。绑定自身或祖先会在产生任何副作用之前被拒绝。
- **全双工双向回推（`report` 主动汇报 + 异步轮次自动唤醒）**：当僚机内部后台长任务（如 `bg_x`）跑完自动开启新一轮并结束时，即便主控早已进入 `idle`，插件也会自动把本轮结果回推唤醒主控（若主控正忙则自动缓冲合并投递；超过 3,600 字节时会按 UTF-8 边界安全截断并附带 `wingman transcript` 提示）；同时僚机也可随时调用 `wingman report -m "..."`（或 `-m -` 从标准输入管道读取）沿着 `boundOwner` 主动上报进度或提问。
- **内存级结构化对话读取（`cx.agents:transcript`）**：直接从 Tern 内存读取最近几轮回复与工具调用卡片，并在 `waiting_input` 时原生提取 ACP `layer` 弹窗摘要。
- **零抢焦点分屏 & 动态画中画悬浮（PiP）**：哪怕你正切在别的 Tab，分屏派活也绝不抢夺键盘焦点；多个右侧分屏自动垂直叠放，画中画按主控 Tab 占比与同类浮窗数量动态缩放并自动挑空角落（`br → tr → bl → tl`），`unpark` 恢复回主控身旁而不误切实时面板。
- **原生实时面板（`radar.luau` + `radar_view.luau`）**：Tern 画布实时展示 `owner → wingman` 拓扑、文件动态与最近工具调用，并可一键聚焦 / 画中画 / 贴回 / 中断 / 重试 / 撤回排队。拖拽侧栏宽度会自动记忆（`sidebar_share`），浮窗尺寸随不同系统与分辨率按比例自适应，文件动态与活动流预算随面板宽高与负载动态调节。
- **纯机制、零越俎代庖**：脚本只做忠实透明管道，不篡改 Prompt、不魔改任何全局扩展；每次派单是用干净新会话（`new`）、原位续跑（`same`）、还是配合 [`ovnfs`](https://github.com/stencil-hq/ovnfs) 开零拷贝写时复制沙箱，完全由主控模型按任务性质自主权衡。

## 安装

插件与 Skill 均直接指向仓库根目录，两行装完：

```sh
# 1. 安装 Tern 窗口插件（自动热加载生效）
tern plugin install github.com/ninthcj/tern-wingman

# 2. 安装通用 Agent Skill
npx skills add ninthcj/tern-wingman
```

自定义 Agent（`omp`/`claude`/`codex`/`copilot` 之外的 id，例如 `agy`）不由本插件安装：使用 `--agent <id>` 前，请先在 Tern **Settings › Agents** 中添加（id、名称、命令、参数、环境变量）。

Antigravity 或本地源码开发链接方式：

```sh
git clone https://github.com/ninthcj/tern-wingman.git
tern plugin link ./tern-wingman
ln -s "$(pwd)/tern-wingman/skills/wingman" ~/.gemini/config/skills/wingman
# 可选（推荐）：暴露全局 `wingman` 命令，Agent 无需拼接脚本路径
ln -sf "$(pwd)/tern-wingman/skills/wingman/scripts/wingman.py" ~/.local/bin/wingman
```

## 实时面板（Live Panel）

命令面板执行 **Wingman: Toggle Live Panel**，或把 **Wingman** 组件加到组件栏（命令面板 → *Edit widgets…* → *Plugins*），组件显示 working / waiting / queued 计数，点击即开关面板。画布默认作为侧栏贴在当前 Tab 最右侧，不抢焦点，`tern plugin reload` 后自动接管续画；手动拖动侧栏分隔线会自动记住你的偏好宽度（`radar_v1.sidebar_share`）。*Tab* / *All* 旁的按钮可将其浮动为按 Tab 比例自适应缩放的角落画中画或贴回侧栏，浮窗模式与拖动到的角落均会跨分辨率持久化记住。

- **Topology**：每个主控及其绑定僚机的状态、持续时长、排队数与故障标记；点击行聚焦对应 pane，行内 PiP/Dock、Interrupt、Retry（故障后）、Unqueue 与 CLI 操作共用同一套核心逻辑。
- **Living files**：按仓库合并 `git status` 与 Agent 最近编辑（含仓库外编辑）或读取过的文件，跨 macOS / Linux / Windows 规范化路径，点击即打开；只读条目上限随面板可用高度与活跃负载动态调节，超出折叠为 `… N more`，*Clear reads* 可一键隐藏只读条目。
- **Activity**：工作中的 Agent 卡片内显示当前工具与色块节拍条（read / search / edit / run / error，进行中的色块脉动），节拍条长度与下方跨 Agent 近期调用条数随面板宽高占比动态调节（数据来自 `cx.agents:transcript`，`omp` 与 ACP pane 通用）。
- **舞台与 Dock**：随 Agent 状态变色的顶部氛围舞台与 working / waiting / queued / fault 计数格，*Tab* / *All* 作用域（持久化）、*Open Git*、*Clear reads*，以及悬停可见每次渲染实测开销的健康指示点。

### Subagent 面板（需手动开启）

默认关闭。可在命令面板使用 **Wingman: Toggle Subagent Panes**、**Wingman: Cycle Subagent Pane Limit**，也可通过实时面板底栏控制。窗口级上限按 **3 → 2 → 4 → 不限 → 1** 循环。子代理运行满 1.5 秒后在父 pane 下方打开，不抢焦点；完成后保留 20 秒，新任务可原位复用未固定槽位。**Pin** 保留面板并计入上限，**+N more** 切换溢出任务，**Close** 关闭当前任务且不会自动重开。

插件按职责拆成无环 Luau 模块：`window.luau` 处理 RPC 和轮次，`queue.luau` 管理待派发任务，`state.luau` 管理归属及配置，`tsp.luau` 提供 transcript 工具。`radar.luau` 负责原生采样和 UI 预算；`radar_view.luau`、`subagents.luau` 和 `subagents_view.luau` 将渲染与弹出策略和宿主隔离。

实时面板与子代理面板共用同一套 transcript 采样。实时面板关闭后，仅在作用域内有 Agent 工作时继续采样；结束事件补读一次，已完成面板由一次性定时器清理。只开子代理面板不查询 Git。采样沿用 10 ms Lua / 100 ms 墙钟保护阈值，低于 Tern 的 50 ms Lua hook 预算。

## 常用命令（`wingman.py`）

仅依赖 Python 3.10+ 标准库（跨平台支持 **Linux、macOS 与 Windows**；不在 Tern 环境内时自动回退至独立进程组的 `omp -p --wait-async` 无头模式，该回退仅支持 `omp`）：

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

# 任意 Tern Agent 作僚机（以 `tern acp <id>` 启动）；模型 / 显式续接 / latest（= 原生 --continue）
python3 skills/wingman/scripts/wingman.py send new --agent claude --model <model> --prompt "审查 diff"
python3 skills/wingman/scripts/wingman.py send <session-id> --agent codex --prompt "继续"   # Wingman 向 Agent 传原生 --resume <session-id>
python3 skills/wingman/scripts/wingman.py send latest --agent claude --prompt "接着上次继续"

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

# 画中画悬浮（角落 br|bl|tr|tl）/ 贴回分屏 / 隐藏（park；omp 仍运行）/ 恢复 / 中断 / 撤回排队 / 关闭
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

### Agent 与限制

`send --agent ID` 默认 `omp`。其他 Agent 以 `tern acp <id>` 启动，可带 `--model`；位置参数会话 ID（`send <session-id> --agent claude …`）会作为原生 `--resume <session-id>` 传给 Agent（Wingman 自身没有 `--resume` 参数），`latest` 对应原生 `--continue`，`new` 为全新会话。工作目录取自 pane 布局（`--cwd`）。对非 `omp` Agent 会直接拒绝而非模拟：`--mode headless`、`--thinking`，以及 `omp` 专有的 `--takeover-idle` / `--allow-fork`。自定义 id 须为小写字母、数字、`.`、`_`、`-`（≤64 字符，不以 `-` 开头）。`same` 与控制命令复用或接管同一标签页内任意存活且无主的 Agent（优先 cwd 匹配），与 `--agent` 无关。`info` 会返回各 Agent 的 `kind`。调用方本身是 Tern Agent 时，`send` / `retry` 默认异步；`retry` 是 `omp` 的 `/retry` 故障恢复路径。

**隐藏的 ACP Agent：** Tern 0.9.30 上，被隐藏（停放或位于后台标签页）的 ACP Agent 会接收提示，但在其 pane 被显示或 `unpark` 之前一直排队。ACP Agent 需要无人值守执行与回推时，请在当前标签页使用 `split`、`down` 或 `pip`；期望排队的 ACP 提示或回推送达前，先 `unpark` / 显示该 pane。`omp` 在停放期间仍会继续运行并响应。

### 多僚机与布局

一个主控可同时带多个僚机，僚机也可以再带僚机。`send new` 新增僚机；`send new --replace` 只关闭选定的已绑定僚机，再启动新的。只有一个绑定时，`send same` 和控制命令会自动选中它；有多个时，请用 `--pane <id>` 或显式传入能唯一匹配的 `--cwd`，有歧义时会列出已绑定的 ID。`info` 返回排序后的 `boundWingmanPanes`，仅有一个绑定时也保留 `boundWingmanPane`。

`--layout` 指定布局（新建默认 `split`；已有目标不指定则保持原位置）：

| 布局 | 适用场景 |
| --- | --- |
| `split` | 主僚机，紧邻主控；新增 `split` / `dock` 僚机自动在右侧列垂直叠放 |
| `pip` | 轻量任务或盯盘，按主控 Tab 占比动态缩放（`--pip tl\|tr\|bl\|br` 固定角落并隐含 `--layout pip`；省略角落时自动选择首个空闲角落 `br → tr → bl → tl`） |
| `down` | 第二个僚机，叠在右侧僚机下方 |
| `tab` | 第 3 个及以上或输出嘈杂的僚机，放入独立且不抢焦点的 Tab |
| `park` | 隐藏僚机；`omp` 停放期间继续运行并响应，但被隐藏的 ACP Agent 会让提示排队直到 `unpark` |

新僚机不抢焦点。Live Panel 会显示当前标签页主控的所有僚机，即使它们已停放或在其他标签页。用 `park` 和 `unpark` 隐藏或恢复运行中的僚机。

## 开源协议

[MIT](LICENSE) © [ninthcj](https://github.com/ninthcj)

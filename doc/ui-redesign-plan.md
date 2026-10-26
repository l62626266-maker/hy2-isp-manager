# HY2 管理面板 TUI 重做方案

> 目标：把当前「whiptail 蓝色弹窗 + 层层子菜单」改成「一屏 ASCII 仪表盘 + 单键操作」，功能不减少，破坏性不变。

## 一、当前问题（基于 `hy2-manager` 实测）

1. `main_menu()` (`hy2-manager:1064`) 用 `choose()` 弹 whiptail，每次进出子菜单都要重绘整屏，视觉上永远是同一个蓝底对话框，看不出层级。

2. 信息密度低：`dashboard()` (`hy2-manager:972`) 把节点状态塞进 whiptail 的提示文字区，纯文本无对齐，多节点时错位。

3. 操作步数多：看一个节点的链接要 首页→管理节点→选节点→查看详情→再确认一次，5 次交互。

4. 缺少最常用的动作：**启动 / 停止 / 重启节点** 在菜单里根本没有入口（只有创建、改端口、删除）。

5. 每次操作完 `menu_action()` (`hy2-manager:951`) 都要 `pause_menu` 按 Enter，来回 3 次按键。

6. 颜色常量 `C_BLUE/C_GREEN/...` (`hy2-manager:32`) 已定义，但 whiptail 里完全用不上，终端能力浪费。

## 二、目标形态

一屏常驻的 ASCII 面板，不调用 whiptail：

```
┌──────────────────────────────────────────────────────────────┐
│ HY2 ISP Manager 0.3.0-dev        root.jtsghrz.kdns.fr        │
│ 网络 normal   证书 89 天 ████████░░   ISP 出口 1.2.3.4        │
├──────────────────────────────────────────────────────────────┤
│  #  节点            状态      内部/公网      流量             │
│  1  HY2-Direct      ● 运行中  443/443       1.2G ↓ 3.4G ↑     │
│  2  HY2-ISP-Full    ○ 已停止  8443/8443     —                 │
│  3  HY2-ISP-HK      ● 运行中  9443/9443     240M ↓ 1.1G ↑     │
├──────────────────────────────────────────────────────────────┤
│ [1-9] 选节点  [a] 添加  [c] 证书  [d] 诊断  [s] 设置  [q] 退出│
└──────────────────────────────────────────────────────────────┘
选中节点 2 后可执行：  [v] 看链接/二维码  [p] 改端口  [r] 换 ISP
                       [t] 启动/停止  [x] 删除  [Esc] 返回
```

要点：

- 面板常驻，不闪屏、不重绘，只刷新数据区。
- 单键操作，不用回车确认菜单。
- 状态用 `●` / `○` + 颜色，一眼分辨。
- 数字键直接选节点，进去后同一个面板下方多一行操作提示。

## 三、技术方案

### 3.1 渲染层

新增 `ui_render()`，纯 `printf` + ANSI，不用 whiptail：

- 用 `tput cup` 定位光标，只重画变化行（避免整屏闪烁）。
- 宽度取 `tput cols`，最小 70，超过 100 截断；窄屏降级为两行式布局。
- 检测 `NO_COLOR` 和 `TERM=dumb`，降级为无色纯文本。
- 检测 `[[ -t 1 ]]`，非终端（管道/日志）时退化为逐行打印，保持现有脚本可用性。

### 3.2 输入层

新增 `ui_readkey()`，`read -rsn1` 读单键：

- 方向键映射为 `\x1b[A/B/C/D`，Esc 单独处理。
- 数字键 1-9 直接选中对应节点。
- 字母键映射到动作。
- 保留 `:menu` 文本输入作为无 TTY 时的兜底。

### 3.3 保留的兼容路径

- `is_tty()` 为假时，**完全退回现有的 `choose()`/`ask()` 数字菜单**，不做任何改动，保证 SSH 非交互、CI、管道场景不坏。
- whiptail 路径保留但不再作为主路径，可用 `HY2M_UI=whiptail` 强制启用。

### 3.4 文件结构

`hy2-manager` 已经 1122 行，继续加会失控。建议拆分：

| 文件 | 职责 |
| --- | --- |
| `hy2-manager` | 入口、`main()` 分发、安装/节点/证书等业务逻辑（不动） |
| `lib/ui-tui.sh` | 新 TUI：渲染、按键、面板、颜色 |
| `lib/ui-plain.sh` | 现有 whiptail + 数字菜单，原样搬过去 |
| `lib/ui.sh` | 门面：根据 `HY2M_UI` 和 TTY 状态 source 上面之一，导出统一接口 |

统一接口（两个实现都必须提供）：

```bash
ui_panel <state-file-or-nothing>       # 渲染主面板
ui_select_node -> 节点 id              # 选节点，取消返回 20
ui_action_menu <node-id> -> 动作码     # 节点操作菜单
ui_prompt <title> <prompt> [default] -> 字符串
ui_confirm <prompt> -> 0/1
ui_message <text>                      # 替代 pause_menu，按键继续
```

`main_menu()` 等上层函数只调这些接口，不直接碰 whiptail。

## 四、分期实施

### 第 1 期：拆文件 + 门面（不改任何行为）

1. 新建 `lib/ui-plain.sh`，把 `ask/ask_valid/ask_secret/choose/confirm/is_tty/has_whiptail/pause_menu` 原样搬过去。
2. 新建 `lib/ui.sh` 做门面，默认 source `ui-plain.sh`。
3. `hy2-manager` 顶部 source 门面，删掉原函数。
4. `tests/run.sh` 和 `tests/ui-test.sh` 全绿，证明零行为变化。
5. 提交。

### 第 2 期：新 TUI 骨架（能跑但功能不全）

1. 新建 `lib/ui-tui.sh`，实现 `ui_panel` 渲染 + `ui_readkey`。
2. 面板只显示节点列表、证书天数、域名，底部固定操作栏。
3. 只接「选节点」和「退出」两个动作，其余按键显示「未实现」。
4. 新增 `tests/tui-test.sh`：用 PTY 驱动，断言面板里出现节点名、状态符号、域名。
5. 提交。

### 第 3 期：把动作接进面板

按优先级接：

1. 启动 / 停止 / 重启节点（**新增能力**，当前完全没有）。
2. 查看链接 + 二维码（复用 `show_managed_node`，去掉二次确认，改为面板内嵌显示）。
3. 改端口（复用 `change_node_port`）。
4. 换 ISP（复用 `replace_isp`）。
5. 删除节点（复用 `remove_node`，保留确认）。
6. 添加节点、证书、诊断、设置走子面板，复用现有函数。

每个动作接完补一条 `tests/tui-test.sh` 断言。

### 第 4 期：视觉细节

1. 状态符号 + 颜色（`●` 绿 / `○` 灰 / `●` 红故障）。
2. 证书剩余天数进度条。
3. 窄屏（<80 列）降级布局。
4. `NO_COLOR` / `TERM=dumb` 降级。
5. 流量统计：从 `systemctl show <svc> -p ActiveEnterTimestamp` 和 `/proc/<pid>/net/dev` 取，做不出来就先显示运行时长。

### 第 5 期：收尾

1. `doc/ui-optimization.md` 更新为新形态。
2. `README.md` 补截图（用 tmux capture 生成文本图）。
3. 全量 `bash tests/run.sh && bash tests/ui-test.sh && bash tests/tui-test.sh`。
4. `shellcheck -x` 全绿。

## 五、风险与不做的事

1. **不做真 GUI**（ncurses / dialog / 网页），仍是纯 bash + ANSI，保持零依赖。
2. **不改任何业务逻辑**：节点创建、端口事务、证书、防火墙全部原样调用，只换交互层。
3. **不破坏非 TTY 场景**：CI、管道、`hy2 status` 等子命令输出格式不变。
4. **不引入新依赖**：只用 bash 内建 + `tput` + `stty`。
5. 窄屏和 `TERM=dumb` 必须降级而不是报错。

## 六、验收标准

1. `hy2` 进入后一屏看到所有节点、状态、域名、证书天数，无需按键。
2. 数字键 1 秒内选中节点，Esc 返回。
3. 启动/停止节点从按键到生效不超过 2 次交互。
4. `bash tests/run.sh`、`ui-test.sh`、`tui-test.sh` 全绿。
5. `HY2M_UI=plain hy2` 能退回旧界面，行为完全一致。
6. 非 TTY 下 `hy2 status` 输出与现在逐字节一致。

# Nice Process Scheduler

通用 Linux 进程 CPU 调度管理框架。对任意用户进程自动维持目标 nice 值，
使其在系统空闲时全速运行，满载时自动让出 CPU 给交互式操作。

## 目录

- [快速开始](#快速开始)
- [工作原理](#工作原理)
- [命令参考](#命令参考)
- [配置参数](#配置参数)
- [使用案例](#使用案例)
- [监控面板](#监控面板)
- [文件结构](#文件结构)
- [故障排查](#故障排查)

---

## 快速开始

### 1. 文件清单

```
Documents/nice_process_scheduling/
├── README.md                 # 本文档
├── nice-scheduler.sh         # 调度守护脚本（核心）
├── nice-mgr.sh               # 管理 CLI
├── nice-monitor.sh           # 实时监控面板
├── nice-scheduler@.service   # systemd 模板单元
└── tmp/                      # 作业配置存储
    └── <job-name>.conf
```

### 2. 创建第一个作业

以 VS Code 的 Jupyter kernel 进程为例：

```bash
cd ~/Documents/nice_process_scheduling

# 创建并启动作业
./nice-mgr.sh start jupyter-kernel \
    --pattern "ipykernel_launcher" \
    --desc "VS Code Jupyter kernel processes"
```

这个命令做了四件事：
1. 在 `tmp/jupyter-kernel.conf` 中写入配置
2. 将 `nice-scheduler@.service` 复制到 `~/.config/systemd/user/`
3. 启用 systemd 服务
4. 立即启动服务

### 3. 验证生效

```bash
# 查看作业状态
./nice-mgr.sh status jupyter-kernel

# 启动监控面板
./nice-monitor.sh jupyter-kernel

# 查看服务日志
journalctl --user -u nice-scheduler@jupyter-kernel.service -f
```

---

## 工作原理

```
┌──────────────┐     ┌──────────────────┐     ┌─────────────────┐
│ nice-mgr.sh  │────▶│ systemd --user    │────▶│ nice-scheduler  │
│ (管理CLI)    │     │ nice-scheduler@   │     │ .sh (守护进程)  │
│              │     │ <name>.service    │     │                 │
│ start/stop/  │     │                  │     │ while true:     │
│ kill/status/ │     │ Restart=on-fail  │     │   pgrep pattern │
│ list/edit    │     │ RestartSec=10    │     │   renice if < N │
└──────────────┘     └──────────────────┘     │   sleep 10      │
                                              └─────────────────┘
```

守护进程 (`nice-scheduler.sh`) 每 N 秒扫描一次匹配 `PROCESS_PATTERN` 的进程，
将 nice 值低于 `NICE_TARGET` 的进程用 `renice` 提升到目标值。

由于 `renice` 只需要降低优先级（提高 nice 值），全程不需要 root 权限。

### 自适应行为

nice 19 在 CFS（完全公平调度器）中权重为 15，对比默认权重 1024：

| 场景 | 行为 |
|------|------|
| 有空闲核心 | CFS 自动将进程迁移到空闲核心，吃满 100% |
| 所有核心满载 | 仅分到 ~1.4% CPU，对交互操作几乎透明 |
| 部分核心繁忙 | 在空闲核心全速，不干扰繁忙核心 |

---

## 命令参考

### 作业管理

```bash
# 创建并启动作业
./nice-mgr.sh start <name> --pattern <pgrep-pattern> [选项]

# 停止作业（保留配置文件）
./nice-mgr.sh stop <name>

# 彻底删除作业（停止服务 + 删除配置）
./nice-mgr.sh kill <name>

# 查看作业状态
./nice-mgr.sh status <name>

# 列出所有作业
./nice-mgr.sh list

# 编辑作业配置
./nice-mgr.sh edit <name>
```

### start 选项

| 选项 | 必需 | 默认值 | 说明 |
|------|------|--------|------|
| `--pattern <str>` | 是 | — | `pgrep -f` 匹配模式 |
| `--nice <1-19>` | 否 | 19 | 目标 nice 值 |
| `--interval <sec>` | 否 | 10 | 扫描间隔（秒） |
| `--desc <str>` | 否 | "" | 作业描述 |

### 手动管理 systemd 服务

```bash
# 查看服务状态
systemctl --user status nice-scheduler@<name>.service

# 手动重启
systemctl --user restart nice-scheduler@<name>.service

# 查看日志
journalctl --user -u nice-scheduler@<name>.service -f

# 禁用自启
systemctl --user disable nice-scheduler@<name>.service
```

---

## 配置参数

配置文件位于 `tmp/<name>.conf`，格式为 Bash sourceable 的 key=value：

```bash
PROCESS_PATTERN="ipykernel_launcher"   # pgrep -f 匹配模式
NICE_TARGET=19                         # 目标 nice 值 (1-19)
SCAN_INTERVAL=10                       # 扫描间隔秒数
DESCRIPTION="Jupyter kernel"           # 可读描述
```

| 参数 | 说明 | 建议值 |
|------|------|--------|
| `PROCESS_PATTERN` | pgrep -f 用的正则。只匹配命令行中包含该字符串的进程 | 选一个能唯一定位目标进程的字符串 |
| `NICE_TARGET` | 目标 nice 值。19=最激进让路，10=折中，5=温和 | 后台任务建议 19 |
| `SCAN_INTERVAL` | 两次扫描间隔。越小越及时但也越频繁 | 5-30s，默认 10s |

---

## 使用案例

### 案例 1：VS Code Jupyter Kernel（本教程原生案例）

```bash
./nice-mgr.sh start jupyter-kernel \
    --pattern "ipykernel_launcher" \
    --desc "VS Code Jupyter kernel processes"
```

### 案例 2：模型训练脚本

```bash
./nice-mgr.sh start model-train \
    --pattern "runrun_model" \
    --nice 19 \
    --desc "Model training (cjr's scripts)"
```

### 案例 3：数据预处理

```bash
./nice-mgr.sh start data-prep \
    --pattern "preprocess_data.py" \
    --nice 10 \
    --interval 5 \
    --desc "Hourly data preprocessing batch"
```

### 案例 4：匹配当前用户的所有 Python 脚本

```bash
./nice-mgr.sh start all-python \
    --pattern "python.*\.py" \
    --nice 15 \
    --desc "All Python scripts by current user"
```

---

## 监控面板

### 启动

```bash
# 监控所有作业
./nice-monitor.sh

# 监控指定作业
./nice-monitor.sh jupyter-kernel model-train

# 自定义刷新间隔
./nice-monitor.sh --interval 5
```

### 界面说明

```
╔══════════════════════════════════════════════════════════════════════╗
║  CPU Scheduler Monitor   2026-06-29 01:23:45                       ║
╠══════════════════════════════════════════════════════════════════════╣
║  Load: 21.34 21.16 21.34  |  Cores: 48                             ║
║  us:  5.2%  sy:  2.1%  ni: 45.3%  id: 47.1%  wa:  0.3%           ║
╚══════════════════════════════════════════════════════════════════════╝

┌─ Job: jupyter-kernel ●  target_nice=19  pattern='ipykernel_launcher'
│  VS Code Jupyter kernel processes
│
│  PID      NICE   %CPU   %MEM STAT  TIME     COMMAND
│  ──────────────────────────────────────────────────────────
│  2474437    19    0.0    0.0 Sl    00:12:34 ipykernel_launch
│  2475002    19    1.4    0.2 Sl    00:15:22 ipykernel_launch
└─────────────────────────────────────────────────────────────────────

  Refresh: 2s  |  q: quit  |  r: refresh now  |  +/-: adjust interval
```

### 按键操作

| 键 | 功能 |
|----|------|
| `q` | 退出 |
| `r` | 立即刷新 |
| `+` | 增加刷新间隔 |
| `-` | 减少刷新间隔 |
| `Ctrl+C` | 退出 |

---

## 文件结构

```
Documents/nice_process_scheduling/
│
├── README.md                     # 本文档
│
├── nice-scheduler.sh             # 守护脚本
│   └── 由 systemd 调用，从 tmp/<name>.conf 读取配置
│       轮询匹配进程并维持目标 nice 值
│
├── nice-scheduler@.service       # systemd 模板
│   └── 安装到 ~/.config/systemd/user/
│       实例化：nice-scheduler@<name>.service
│       %i  = 作业名称
│
├── nice-mgr.sh                   # 管理 CLI
│   ├── start  <name> [opts]     创建配置 + 启用服务
│   ├── stop   <name>            停止服务（保留配置）
│   ├── kill   <name>            停止 + 删除配置
│   ├── status <name>            查看详情
│   ├── list                     列出所有作业
│   └── edit   <name>            编辑配置文件
│
├── nice-monitor.sh               # 实时监控面板
│   └── 系统负载 + 每作业进程详情
│       支持键盘交互（q/r/+/-）
│
└── tmp/                          # 运行时数据
    ├── jupyter-kernel.conf       作业配置示例
    └── ...
```

---

## 故障排查

### 服务启动失败

```bash
# 查看完整日志
journalctl --user -u nice-scheduler@<name>.service -e --no-pager

# 常见原因：
# 1. 配置文件不存在 → nice-mgr.sh start 会自动创建
# 2. PROCESS_PATTERN 为空 → 编辑 tmp/<name>.conf 补全
```

### 进程的 nice 值没有变化

```bash
# 确认服务在运行
systemctl --user status nice-scheduler@<name>.service

# 手动执行守护脚本看是否有报错
cd ~/Documents/nice_process_scheduling
./nice-scheduler.sh <name>
# Ctrl+C 退出

# 检查 pgrep 是否能匹配到进程
source tmp/<name>.conf
pgrep -f "$PROCESS_PATTERN"
```

### pgrep 匹配太多或太少

```bash
# 测试匹配效果
pgrep -f -l "your_pattern"

# 精确匹配：使用更具体的字符串
--pattern "/path/to/script.py"       # 匹配绝对路径
--pattern "python.*my_train.py"      # 正则匹配
```

### 权限问题

`renice` 提高 nice 值（降低优先级）不需要 root 权限。如果遇到权限错误：

```bash
# 确认你不是在尝试降低 nice 值
# ❌ renice -n 10 -p <pid>  → -10 是降低（提高优先级），需要 root
# ✅ renice -n 19 -p <pid>  → 19 是提高（降低优先级），不需要 root
```

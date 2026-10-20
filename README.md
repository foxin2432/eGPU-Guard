# eGPU-Guard

Scheduled shutdown and automatic startup of a USB4 / Thunderbolt eGPU on Windows.

Windows-only PowerShell. No dependencies, no install footprint, no background CPU cost when
no eGPU is attached.

[中文说明](#中文说明) &nbsp;|&nbsp; [Design notes](docs/DESIGN.md) &nbsp;|&nbsp; [MIT License](LICENSE)

---

## The problem it solves

A dorm or shared flat has scheduled power cuts. A desktop-class GPU in an external dock is
still powered on when that happens, and an abrupt power loss on a live PCIe device is a good
way to end up with a corrupted driver state, a `Code 43`, or a boot that hangs on the GPU.

So the GPU has to be cleanly stopped *before* the power goes away, and brought back up
automatically afterwards — without having to remember to do either.

`eGPU-Guard` registers a small set of Windows scheduled tasks that do exactly that:

* **23:50** — a reminder window appears in the bottom-right corner with a sound, and closes
  itself after a few seconds.
* **23:55** — the eGPU is disabled cleanly (`pnputil /disable-device`), and the desktop moves
  to the integrated GPU.
* **On every boot** — the eGPU is enabled automatically as early as Windows allows, and the
  watcher **exits as soon as it is running**. There is no permanent background process: once
  the GPU is up there is nothing left to do.

Every part of it can be turned off or retimed. It is a scheduler around `pnputil`, nothing
more.

## Requirements

| | |
|---|---|
| OS | Windows 10 1809+ / Windows 11 |
| PowerShell | 5.1 (in-box) or PowerShell 7+ |
| Privileges | Administrator, for installing, and for the actions themselves |
| Hardware | Any eGPU that Windows exposes as a PCI device |

Verified on a ThinkBook 14+ 2024 (TGX / USB4 port) with a Minisforum DEG1 dock and an RTX 4070
SUPER. It should work with any dock, but the device-matching defaults are NVIDIA-specific —
see [Adapting to other hardware](#adapting-to-other-hardware).

## Install

Clone anywhere — the scripts locate their companions relative to themselves.

```powershell
git clone https://github.com/foxin2432/eGPU-Guard.git
cd eGPU-Guard
```

Open an **elevated** PowerShell and register the tasks:

```powershell
# Register with the defaults: 23:50 warning, 23:55 disable, Sunday-Thursday
.\install-eGPU-Guard.ps1

# Or pick your own times and nights
.\install-eGPU-Guard.ps1 -NotifyTime 23:40 -DisableTime 23:45 `
                         -Days Monday,Tuesday,Wednesday,Thursday,Friday
```

Elevation is not optional: one task runs as `SYSTEM`, and Windows refuses to register a
`SYSTEM` principal without administrator rights.

## Usage

```powershell
# Stop the GPU now (manual: the watcher is allowed to bring it back)
.\eGPU-Guard.ps1 -Action Disable

# Stop it and keep it down until the next boot
.\eGPU-Guard.ps1 -Action Disable -Force -StayDown

# Bring it up now, and cancel any stay-down window
.\eGPU-Guard.ps1 -Action Resume

# Show what Windows currently thinks
.\eGPU-Guard.ps1 -Action Status
```

### Actions

| Action | What it does |
|---|---|
| `Disable` | `pnputil /disable-device` on the matching eGPU |
| `Enable` | Scans the bus and enables the device if present but not started |
| `Resume` | Clears the stay-down window and enables the device — no reboot needed |
| `Restart` | Removes the node and rescans. **Manual use only** — see below |
| `Status` | Prints the device state, whether a monitor is attached, and why it is not restartable |

### Switches

| Switch | Effect |
|---|---|
| `-Force` | Waives the *external display is attached* warning. The *only active display adapter* guard is **never** waivable |
| `-StayDown` | Keeps the device down until the next boot (this is what the nightly task uses) |
| `-Toast` | Shows the result in the bottom-right reminder window |
| `-LogFile <path>` | Overrides the log location |

### Exit codes

| Code | Meaning |
|---|---|
| 0 | OK, or nothing to do |
| 2 | Device not present |
| 3 | Device already in the requested state |
| 4 | Operation failed |
| 5 | Refused by a safety check |

## Uninstall

```powershell
.\uninstall-eGPU-Guard.ps1              # removes the tasks and the state directory
.\uninstall-eGPU-Guard.ps1 -KeepLogs    # keeps C:\ProgramData\eGPU-Guard for inspection
```

The installer never touches the registry or the device state, so removal is complete. Nothing
is left behind except the log directory, and only if you ask for it.

## Logs

Everything is appended to `C:\ProgramData\eGPU-Guard\eGPU-Guard.log`, one line per event, with
the decision and its reason:

```
2026-10-15 09:50:09 [INFO] Enable ----- start (pid=17316, user=DESKTOP-XXXXXXX$)
2026-10-15 09:50:10 [INFO] Watch state -> Disconnected [PCI\VEN_10DE&DEV_2783&...]
2026-10-15 09:50:10 [INFO] Watch tunnel still coming up - waiting, node left intact
```

## How it works

Three scripts, four tasks.

| Script | Role |
|---|---|
| `eGPU-Guard.ps1` | All actions. Runs and exits. |
| `eGPU-Watch.ps1` | Boot-time helper: enables the device, then exits. |
| `eGPU-Notify.ps1` | The 23:50 reminder window. |

| Task | Trigger | Principal |
|---|---|---|
| `eGPU-Guard-2350-Notify` | Weekly, Sun–Thu 23:50 | interactive user |
| `eGPU-Guard-2355-Disable` | Weekly, Sun–Thu 23:55 | `SYSTEM` |
| `eGPU-Guard-Boot-Enable` | At boot +20 s, at logon +5 s | `SYSTEM` |
| `eGPU-Guard-Watch` | At boot +10 s, at logon +5 s, resident | `SYSTEM` |

### Design notes

These are the non-obvious decisions, each one the result of a failure that is documented in
the code. The full reasoning is in [docs/DESIGN.md](docs/DESIGN.md).

**The watcher only ever enables. It never removes a device node.** An earlier version answered
a failed device start with `remove-device` + `scan-devices`. That is actively harmful: if the
USB4 tunnel has not finished training, removing the node makes the GPU disappear for the rest
of the boot. Enabling is safe and reversible; deleting a node is neither. A device that
genuinely failed to start needs a physical dock power cycle, so the watcher waits and leaves
the node alone.

**A deliberate stop is not the same as a fault.** The nightly disable and the watcher have
opposite goals — one stops the GPU, the other exists to start it. Without coordination the
watcher undoes the disconnect within seconds. `-StayDown` writes a marker recording the boot
time it was created in, so it expires by itself on the next boot and a manual disable still
gets recovered automatically.

**Retries escalate: 5, 10, 20, 30, 60 s.** Not one flat 10-minute nap. A single failed attempt
used to cost 600 s of sleeping while the GPU had long since become usable, which is what made
reconnecting after a boot feel slow.

**Single instance via an exclusive file handle.** A PID-in-a-file lock is unsafe because PIDs
are reused: a stale PID then blocks the watcher forever. An exclusive `FileShare.None` handle
is released by the kernel when the process dies, so it can never go stale.

**No child processes.** Every action is one in-process `pnputil` call. Spawning
`powershell.exe` per attempt is what made boot feel heavy.

**Absence costs one registry read.** With no eGPU attached, nothing but a registry lookup runs.
A machine without the dock sees no measurable load.

**`pnputil` output is parsed language-independently.** Only the status *values* are stable
across locales; the labels are not. The parser matches value tokens plus numeric problem codes,
and falls back to a code-point table, so it works on an English or a Chinese Windows alike.

## Adapting to other hardware

The matching defaults live in `eGPU-Guard.ps1` and are overridable:

```powershell
.\eGPU-Guard.ps1 -Action Status -MatchDescription 'RX 7900' -MatchDeviceId 'DEV_744C'
```

Find your own IDs with:

```powershell
pnputil /enum-devices /class Display
```

`DEV_2783` is the RTX 4070 SUPER. `DEV_xxxx` is the PCI device ID of yours. Note that
`eGPU-Watch.ps1` keeps its own copy of the match prefix (`$DeviceKeyPrefix`) because it is
deliberately dependency-free — update it there too, or set the installer's defaults.

### Tuning the watcher

`eGPU-Watch.ps1` exposes its cadence as parameters:

| Parameter | Default | Meaning |
|---|---|---|
| `-IntervalSeconds` | 4 | Steady-state poll once the device is up |
| `-BurstSeconds` | 120 | Fast-poll window right after the watcher starts |
| `-IdleIntervalSeconds` | 20 | Poll cadence while no eGPU is attached |
| `-AbsentScanSeconds` | 300 | Rescan interval once fully idle |
| `-BackoffSeconds` | 5,10,20,30,60 | Escalating delay after a failed enable |
| `-TransientGraceSeconds` | 45 | How long to wait before logging that a dock power cycle is needed |
| `-StopWhenRunning` | on | Exit as soon as the GPU is up instead of staying resident |
| `-IdleExitMinutes` | 30 | Hard cap on how long it stays resident if the GPU never appears |

The installer passes none of these, so edit the defaults or change the task arguments.

`eGPU-Notify.ps1` (the 23:50 reminder) takes `-Seconds` (how long the window stays up,
default 5), `-NoSound`, and `-Title` / `-Body` for the text.

## Troubleshooting

**The GPU does not come back after boot.**
Make sure the dock's PSU switch is left **on**. This is a hardware constraint, not a software
one — see the next section. Then check the log for the last `state ->` line.

**The nightly disconnect does not happen.**
Check that the task arguments end with `-Force -StayDown`. Without `-Force` the preflight sees
the monitor attached to the GPU and refuses (exit 5) — silently, from the scheduler's point of
view.

**The GPU disappears from Device Manager entirely.**
A `remove-device` was issued while the tunnel was not up. Power-cycle the dock (PSU off for at
least 10 s) and, if this happened without you running `-Action Restart`, please open an issue:
the watcher is not supposed to be able to do that.

**`Code 43` (`CM_PROB_FAILED_POST_START`).**
Not fixable in software. Neither a rescan nor an enable will clear it; only a dock power cycle
or a full cold boot will. If it recurs, suspect the dock, its power supply, or the cable.

### Why "hot-plug" and "auto-start on boot" do not work

Worth understanding before you file a bug, because it is the single most common expectation:

A USB4 eGPU is reached through a PCIe tunnel that has to be trained. The dock in this setup has
no standby power before its PSU is switched on (`ATX PS_ON`), so the host cannot see it during
POST — there is nothing to enumerate yet. By the time the tunnel is up, firmware has long since
finished, and no software can retroactively make the firmware wait.

The reliable arrangement is therefore:

* keep the dock's PSU switch **on**, so the tunnel trains during POST;
* let `eGPU-Guard` do the enabling when Windows is ready.

The physical press of the power button cannot be removed in software.

## Contributing

Issues and pull requests are welcome. The most useful bug report includes the relevant part of
`C:\ProgramData\eGPU-Guard\eGPU-Guard.log` (it records the decision and its reason) plus your
Windows build.

CI runs a syntax check on every script. The scripts are deliberately **pure ASCII** — localized
strings are built from code points — so please keep it that way; a non-ASCII literal written
into these files has broken parsing before.

## License

[MIT](LICENSE) © 2026 foxin2432

---

# 中文说明

在 Windows 上按计划断开 USB4 / 雷电外接显卡，并在开机后自动恢复。

纯 PowerShell，无第三方依赖，不装驱动、不改注册表；**没接显卡时后台开销为零**。

## 解决什么问题

宿舍或合租房会定时断电。断电时扩展坞里的台式显卡还在通电，而 PCIe 设备被直接断电很容易
导致驱动状态损坏、`Code 43`，甚至开机卡在显卡上。

所以必须在断电**之前**干净地停掉显卡，断电之后再自动恢复——而且这两件事都不能靠人记得。

`eGPU-Guard` 注册几个 Windows 计划任务来完成：

* **23:50** — 右下角弹出提醒窗口并播放提示音，几秒后自动关闭。
* **23:55** — 用 `pnputil /disable-device` 干净地禁用外接显卡，桌面自动回到核显。
* **每次开机** — 显卡已接上但未启动时，Windows 一允许就自动启用；**显卡起来后看门狗立即
  退出**，不留下常驻进程——显卡正常运行后它已无事可做。

所有时间点都可通过参数修改，也可以随时关掉。它本质上是 `pnputil` 外面套了一层调度。

## 环境要求

| | |
|---|---|
| 系统 | Windows 10 1809+ / Windows 11 |
| PowerShell | 5.1（系统自带）或 PowerShell 7+ |
| 权限 | 安装与执行动作都需要管理员权限 |
| 硬件 | 任何被 Windows 识别为 PCI 设备的外接显卡 |

已在 ThinkBook 14+ 2024（TGX / USB4 口）+ Minisforum DEG1 扩展坞 + RTX 4070 SUPER 上验证。
原则上任何扩展坞都可用，但设备匹配的默认值是 NVIDIA 专用的，见
[适配其他硬件](#适配其他硬件)。

## 安装

clone 到任意位置即可——脚本按自身所在目录定位同目录文件，不依赖绝对路径。

```powershell
git clone https://github.com/foxin2432/eGPU-Guard.git
cd eGPU-Guard
```

用**管理员** PowerShell 注册计划任务：

```powershell
# 使用默认值：23:50 提醒、23:55 断开、周日到周四
.\install-eGPU-Guard.ps1

# 或自定义时间和星期
.\install-eGPU-Guard.ps1 -NotifyTime 23:40 -DisableTime 23:45 `
                         -Days Monday,Tuesday,Wednesday,Thursday,Friday
```

管理员权限是必需的：其中一个任务以 `SYSTEM` 身份运行，而 Windows 不允许非管理员注册
`SYSTEM` 主体。

## 用法

```powershell
# 立即停掉显卡（手动操作：看门狗之后可以把它拉回来）
.\eGPU-Guard.ps1 -Action Disable

# 停掉并保持到下个开机
.\eGPU-Guard.ps1 -Action Disable -Force -StayDown

# 立即恢复，并取消"保持断开"
.\eGPU-Guard.ps1 -Action Resume

# 查看 Windows 当前的状态判断
.\eGPU-Guard.ps1 -Action Status
```

### 动作

| 动作 | 作用 |
|---|---|
| `Disable` | 对匹配到的外接显卡执行 `pnputil /disable-device` |
| `Enable` | 扫描总线，若设备存在但未启动则启用 |
| `Resume` | 取消"保持断开"并立即启用显卡，**无需重启** |
| `Restart` | 移除设备节点并重新扫描。**仅供人工使用**，原因见下 |
| `Status` | 打印设备状态、是否接了显示器、以及为什么无法重启 |

### 开关

| 开关 | 作用 |
|---|---|
| `-Force` | 豁免"接着外接显示器"的警告。但"这是唯一的活动显示适配器"这道保护**永远不可豁免** |
| `-StayDown` | 保持断开直到下次开机（夜间任务用的就是这个） |
| `-Toast` | 用右下角提醒窗口显示结果 |
| `-LogFile <路径>` | 自定义日志路径 |

### 退出码

| 码 | 含义 |
|---|---|
| 0 | 成功，或无需操作 |
| 2 | 设备不存在 |
| 3 | 设备已是目标状态 |
| 4 | 操作失败 |
| 5 | 被安全检查拒绝 |

## 卸载

```powershell
.\uninstall-eGPU-Guard.ps1              # 删除任务与状态目录
.\uninstall-eGPU-Guard.ps1 -KeepLogs    # 保留 C:\ProgramData\eGPU-Guard 以便排查
```

安装脚本从不改动注册表或设备状态，因此卸载是彻底的——只有在你主动要求时才留下日志目录。

## 日志

所有事件都追加到 `C:\ProgramData\eGPU-Guard\eGPU-Guard.log`，每行一条，包含决策及其原因：

```
2026-10-15 09:50:09 [INFO] Enable ----- start (pid=17316, user=DESKTOP-XXXXXXX$)
2026-10-15 09:50:10 [INFO] Watch state -> Disconnected [PCI\VEN_10DE&DEV_2783&...]
2026-10-15 09:50:10 [INFO] Watch tunnel still coming up - waiting, node left intact
```

## 工作原理

三个脚本、四个任务。

| 脚本 | 职责 |
|---|---|
| `eGPU-Guard.ps1` | 全部动作，执行完即退出 |
| `eGPU-Watch.ps1` | 开机时的辅助进程：把显卡启用后即退出 |
| `eGPU-Notify.ps1` | 23:50 的提醒窗口（含提示音） |

| 任务 | 触发器 | 身份 |
|---|---|---|
| `eGPU-Guard-2350-Notify` | 每周 周日–周四 23:50 | 当前用户 |
| `eGPU-Guard-2355-Disable` | 每周 周日–周四 23:55 | `SYSTEM` |
| `eGPU-Guard-Boot-Enable` | 开机后 20 秒、登录后 5 秒 | `SYSTEM` |
| `eGPU-Guard-Watch` | 开机后 10 秒、登录后 5 秒，常驻 | `SYSTEM` |

### 设计取舍

以下每一条都对应一次真实故障，代码里也都有注释说明。完整推导见
[docs/DESIGN.md](docs/DESIGN.md)。

**看门狗只会启用，绝不删除设备节点。** 早期版本在设备启动失败时用
`remove-device` + `scan-devices` 处理。这个做法有害：USB4 隧道还没训练完时删掉节点，
会导致整次开机显卡都消失。启用是安全且可逆的，删节点不是。真正启动失败的设备只能靠
**物理给扩展坞断电重启**，所以看门狗选择等待，不动节点。

**"有意断开"不等于"故障"。** 夜间断开任务和看门狗的目标正好相反——一个要停显卡，一个
的天职就是把它启动起来。不做协调的话，看门狗会在几秒内把断开操作撤销。
`-StayDown` 会写一个记录"创建时的开机时间"的标记，因此它会在下次开机时自动失效，
而手动禁用仍然会被自动恢复。

**重试间隔递进：5、10、20、30、60 秒。** 不是固定睡 10 分钟。以前一次失败就要等 600 秒，
而显卡早就可用了——这正是"开机后连接很慢"的真正原因。

**用独占文件句柄保证单实例。** 把 PID 写进文件的锁不安全，因为 PID 会被复用：一个陈旧的
PID 会让看门狗永久无法启动。独占的 `FileShare.None` 句柄由内核在进程死亡时释放，
不可能变陈旧。

**不产生子进程。** 每个动作都是一次进程内的 `pnputil` 调用。每次尝试都启动一个
`powershell.exe` 正是开机变卡的原因。

**没接显卡时只读一次注册表。** 未接扩展坞时除了查一次注册表什么都不做，所以没接显卡的
机器上感受不到任何负载。

**`pnputil` 输出按语言无关方式解析。** 只有状态**值**在各语言下是稳定的，标签不是。
解析器匹配值标记加数字错误码，并有码点兜底表，因此中英文 Windows 都可用。

## 适配其他硬件

匹配默认值在 `eGPU-Guard.ps1` 里，可以覆盖：

```powershell
.\eGPU-Guard.ps1 -Action Status -MatchDescription 'RX 7900' -MatchDeviceId 'DEV_744C'
```

用下面的命令查你自己的 ID：

```powershell
pnputil /enum-devices /class Display
```

`DEV_2783` 是 RTX 4070 SUPER。`DEV_xxxx` 换成你的 PCI 设备 ID。注意
`eGPU-Watch.ps1` 为了不依赖其他脚本，**保留了自己的一份匹配前缀**
（`$DeviceKeyPrefix`）——两处都要改，或者直接改安装脚本里的默认值。

### 调参

`eGPU-Watch.ps1` 把节奏都做成了参数：

| 参数 | 默认 | 含义 |
|---|---|---|
| `-IntervalSeconds` | 4 | 显卡正常后的常规轮询间隔 |
| `-BurstSeconds` | 120 | 看门狗刚启动后的快速轮询窗口 |
| `-IdleIntervalSeconds` | 20 | 未接显卡时的轮询间隔 |
| `-AbsentScanSeconds` | 300 | 完全空闲后的重扫描间隔 |
| `-BackoffSeconds` | 5,10,20,30,60 | 启用失败后的递进延迟 |
| `-TransientGraceSeconds` | 45 | 等待多久后提示需要物理断电重启扩展坞 |
| `-StopWhenRunning` | on | 显卡启动成功后立即退出，不做常驻进程 |
| `-IdleExitMinutes` | 30 | 硬性上限：等不到显卡时最多驻留多少分钟 |

安装脚本不传这些参数，所以要么改默认值，要么改任务的参数。

`eGPU-Notify.ps1`（23:50 提醒）有 `-Seconds`（窗口停留秒数，默认 5）、`-NoSound`，以及
`-Title` / `-Body` 用于自定义文字。

## 排查

**开机后显卡没回来。**
确认扩展坞的电源开关保持**常开**。这是硬件限制，不是软件问题——见下一节。然后看日志里
最后一条 `state ->`。

**夜间没有断开。**
检查任务参数是否以 `-Force -StayDown` 结尾。缺 `-Force` 时，预检查会因为显卡上接着显示器
而拒绝执行（退出码 5），而从计划任务的角度看这是静默失败。

**显卡从设备管理器里彻底消失了。**
说明隧道没起来时被发了 `remove-device`。给扩展坞断电重启（关电源至少 10 秒）。如果这发生在
你没运行 `-Action Restart` 的情况下，请提 issue：看门狗不应该能做到这件事。

**`Code 43`（`CM_PROB_FAILED_POST_START`）。**
软件无法修复。重新扫描和启用都无效，只有给扩展坞断电或彻底冷启动才行。如果反复出现，
请怀疑扩展坞、它的电源或线材。

### 为什么"热插拔"和"开机自动启动"行不通

提 issue 之前值得先理解这一点，因为它是最常见的预期落差：

USB4 外接显卡是通过一条需要训练的 PCIe 隧道访问的。这套配置里的扩展坞在电源开启
（`ATX PS_ON`）之前**没有待机供电**，所以主机在 POST 阶段根本看不到它——那时还没有东西
可以枚举。等隧道起来时，固件早已结束，没有任何软件能让固件回头再等。

因此可靠的安排是：

* 让扩展坞电源开关保持**常开**，使隧道在 POST 阶段完成训练；
* 剩下的交给 `eGPU-Guard`，等 Windows 就绪后启用。

物理按下电源开关这一步，软件无法消除。

## 贡献

欢迎 issue 和 PR。最有用的 bug 报告请附上 `C:\ProgramData\eGPU-Guard\eGPU-Guard.log` 中
相关片段（日志记录了决策及其原因），以及你的 Windows 版本号。

CI 会对每个脚本做语法检查。脚本刻意保持**纯 ASCII**——本地化字符串由码点构造——请保持
这一点：往这些文件里写非 ASCII 字面量曾经直接破坏过解析。

## 许可证

[MIT](LICENSE) © 2026 foxin2432

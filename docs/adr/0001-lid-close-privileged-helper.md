# 0001 — 合盖防休眠采用独立 root LaunchDaemon + 租约恢复

- **状态**：Accepted（已确认 2026-11-18）
- **日期**：2026-11-18
- **决策者**：fb0sh
- **关联**：Phase 3（满杯 / 合盖）

## 背景

TriCup 需要三种状态：空杯（允许休眠）、半杯（系统与显示器保持唤醒、允许合盖休眠）、满杯（合盖后继续运行）。满杯是本项目的核心价值，也是唯一需要特权的能力。

已确认的技术事实：

- IOKit 电源断言（`kIOPMAssertionTypePreventUserIdleSystemSleep` / `kIOPMAssertionTypePreventUserIdleDisplaySleep`）只能阻止**空闲**睡眠，无法阻止**合盖**触发的睡眠。
- 在 Apple Silicon 上，阻止合盖睡眠的唯一可行机制是系统级 `pmset -a disablesleep 1`；它需要 root，是**全局、跨重启**的设置，必须显式复位，否则会残留。
- 项目不购买 Apple Developer 会员，MVP 使用 ad-hoc 签名与 CI 构建；而 `SMAppService` 注册特权 LaunchDaemon 要求 App 与 helper 使用**真实证书且同 Team ID**，ad-hoc 下不可用。
- KeepingYouAwake 等纯电源断言工具无法解决合盖场景，印证了上述约束。

## 决策

1. **独立特权 Helper**：使用 SwiftPM 管理两个 executable target——`TriCup`（用户态菜单栏应用）与 `TriCupHelper`（root 的独立 LaunchDaemon）。Helper 仅负责：合盖防休眠、权限校验、租约管理、电源状态恢复。菜单栏 UI、两态电源断言、登录项、低电量判断均在 App 侧，不经 Helper。

2. **安装 / 升级 / 卸载**（App 侧发起）：
   - 首次进入满杯时，通过一次系统管理员授权（`do shell script … with administrator privileges`，底层即 Authorization Services）执行安装脚本。
   - helper 二进制 → `/Library/PrivilegedHelperTools/com.fb0sh.tricup.helper`（`root:wheel`、`0755`）。
   - 启动配置 → `/Library/LaunchDaemons/com.fb0sh.tricup.helper.plist`（`root:wheel`、`0644`）。
   - 状态目录 → `/Library/Application Support/TriCup/`（`root:wheel`、`0700`），租约文件 `0700`/`0600`。
   - **安装安全**：特权脚本必须正确转义所有参数、只用固定的绝对目标路径、对二进制/plist/状态目录显式设置 `root:wheel` 与权限，并在写入前检查是否存在符号链接/路径穿越（拒绝通过符号链接替换目标）；**仅对 Helper 必要文件最小范围处理 `com.apple.quarantine` 属性**，绝不全局关闭 Gatekeeper。
   - 安装脚本**幂等**、支持安全升级（先停止旧服务、覆盖、再加载）；任一步失败则清理不完整产物并回报失败。
   - 卸载：先释放租约、恢复电源设置并验证，再 `launchctl bootout`、删除 plist/二进制/状态文件。右键菜单仅在 Helper 已安装时显示 `Uninstall Helper`。

3. **IPC 与安全**：
   - Unix domain socket（`/var/run/com.fb0sh.tricup.sock`）+ **长连接租约模型**。
   - 仅暴露 `enable` / `disable` / `status` 三个固定操作。**禁止**客户端传入任意命令、shell 脚本、可执行文件路径或 `pmset` 参数。
   - 使用绝对路径 `/usr/bin/pmset`，以参数数组直接 `posix_spawn`/`Process` 调用，不经 shell。
   - 校验客户端 UID（`getpeereid`）与 PID（`LOCAL_PEERPID`）；socket 以受限权限（`0600`，属主为控制台用户）创建。
   - `proc_pidpath` 路径检查**仅作辅助**（确认对端是可执行文件而非伪造连接），明确**同 UID 进程即同一信任域**的边界，**不把用户可写路径当作可信身份凭证**。
   - 安装目标目录、二进制、plist、状态文件均设置正确 root 所有权与权限，写入时避免跟随符号链接（`O_NOFOLLOW` / 显式 `install -o root`），防止符号链接攻击与文件替换。
   - **异常断开**：App 在满杯期间监听 socket 连接；Helper 崩溃或连接断开时，App 立即更新 UI（降为空杯）并提示异常，**禁止自动重新申请满杯租约**。

4. **电源设置所有权与租约恢复**：
   - 进入满杯前读取并记录原始 `SleepDisabled` 值。
   - **修改系统设置之前**先将 TriCup 租约及恢复信息持久化到状态目录。
   - 成功执行 `pmset` 并**回读验证**实际状态后，才允许 UI 切换为满杯。
   - App 正常退出、崩溃、`kill -9`、Socket 断开时，Helper 恢复原始状态。
   - Helper 由 launchd `KeepAlive` 守护；自身崩溃后自动重启并检查未完成租约；系统重启后同样执行恢复检查（启动时先复位）。
   - **只恢复 TriCup 自己修改过的**电源设置，避免无条件覆盖其它软件或用户的设置。
   - 同一时间只允许**一个**有效满杯租约；第二个连接请求 `enable` 时被拒绝。
   - App 启动默认空杯，**禁止**自动恢复上次满杯状态。
   - 授权取消、安装失败、启用失败时保持原有状态，图标必须反映实际生效结果。
   - 恢复操作必须验证结果；失败时记录错误并有限重试。**若恢复失败，必须保留持久化租约记录**（不清除），供后续重试与 Helper 重启恢复使用；**仅在确认恢复成功后**才清除该记录。重复恢复必须**幂等**。

5. **登录时启动**：优先实现 Apple 官方 `SMAppService.mainApp`，用 ad-hoc 签名的 CI 产物在真机验证；若无法稳定工作，再改用用户级 `LaunchAgent` 作为替代，**不同时维护两套**。

6. **低电量保护**：仅在使用电池且电量 ≤20% 时禁止进入满杯；已处于满杯时自动切换为空杯并通知用户。台式机无电池不触发。

## 理由

- 只有 root + `pmset disablesleep` 能真正阻止合盖休眠，这是满杯需求的硬性前提，没有无 root 替代。
- 手工安装 LaunchDaemon 不依赖开发者证书，符合“无付费账号 + ad-hoc”的约束；SMAppService 特权 Helper 在本项目签名条件下不可用。
- 租约模型把“系统全局设置”绑定到“App 存活”这一明确的所有权关系上，并配合持久化租约与崩溃/重启恢复检查，把残留风险降到最低。
- 固定操作白名单 + 绝对路径 + 无 shell + 受限 socket，把 root Helper 的攻击面控制到最小，保持实现精简（KISS）。

## 影响与残余风险

- **全局电源设置**：`pmset disablesleep` 是系统级、跨重启设置。Helper 以租约 + 启动恢复 + 回读验证降低风险，但极端情况（整机断电、Helper 被杀到重启之间的窗口、用户在终端手动改 `pmset`、其它软件并发修改）无法绝对保证立即复位。README 提供手动恢复方法：`sudo pmset -a disablesleep 0`。
- **ad-hoc 签名分发**：应用未经 Developer ID 签名与公证，首次运行需在“系统设置 → 隐私与安全性”中手动放行（Gatekeeper）。不提供、不鼓励关闭系统安全保护；未来签名策略变化可能影响分发。
- **同 UID 信任边界**：同一登录用户会话内的进程被视为同一信任域。Helper 的 UID/PID/路径校验用于拒绝跨用户及明显异常连接，但**不防御已被攻陷的同 UID 进程**。
- **特权 Helper**：root daemon 增大攻击面，属敏感组件；通过固定白名单、绝对路径、无 shell、严格文件权限与所有权收窄风险，仍需持续审计。
- **未来 macOS 兼容性**：手装 LaunchDaemon 与 `pmset disablesleep` 均非 Apple 官方长期支持接口，未来系统版本可能改变行为或收紧；这是选型的既定代价。
- **散热/硬件**：合盖 + 电池持续运行可能导致积热与降频，不在软件可完全控制范围内。合盖运行主要面向桌面上的后台任务；**README 必须提醒用户避免把持续运行的 MacBook 放入背包**。
- **测试边界**：CI 不执行任何真实电源修改；合盖、断电、崩溃恢复必须由 M4 Air 真机验收。

## 备选方案

- **SMAppService 特权 Helper**：官方推荐，但要求真实证书 / 同 Team ID，违背“无付费账号”约束 → 否决。
- **纯 IOKit 电源断言**：无法阻止合盖休眠，不满足满杯需求 → 否决。
- **Apple 官方合盖模式（clamshell）**：需电源 + 外接显示器/键鼠，不满足“合盖拔电仍运行” → 否决。
- **每次切换都弹管理员授权**：违背“首次授权后免密” → 否决。

## 验收标准

- **M4 Air 真机**：满杯后合盖、拔电仍运行；正常退出、强制退出、`kill -9`、Helper 崩溃、系统重启后 `SleepDisabled` 均恢复为进入前的值；Helper 崩溃/断开时 UI 及时降级且不自动重试；低电量 ≤20% 自动退出满杯；授权取消 / 安装失败保持原状态。
- **CI**：`swift build` / `swift test` 通过，产出可安装的 ARM64 `TriCup.app.zip`，且不执行任何真实 `pmset`。

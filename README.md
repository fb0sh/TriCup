# TriCup

一个极简的 macOS 菜单栏防休眠工具，用一个咖啡杯图标的填充程度表示三种工作状态。

| 状态 | 图标 | 行为 |
| --- | --- | --- |
| Sleep（空杯） | 空杯 | 允许系统、显示器与合盖休眠 |
| Awake（半杯） | 半杯 | 系统与显示器保持唤醒，允许合盖休眠 |
| Always Awake（满杯） | 满杯 | 系统持续运行，合盖也不休眠 |

- **左键**点击图标：空杯 → 半杯 → 满杯 → 空杯 循环切换。
- **右键**：直接选择状态、登录时启动、卸载 Helper、退出。
- **悬停**：显示当前状态与说明。
- 无主窗口、无 Dock 图标、无设置页面、无第三方运行时依赖。
- 最低 macOS 15，仅 Apple Silicon（arm64）。默认以空杯启动。

## 安装（ad-hoc 签名）

从 GitHub Actions 的构建产物或 Release 下载 `TriCup.app.zip`：

1. 解压后把 `TriCup.app` 拖入 `/Applications`。
2. 首次打开会被 Gatekeeper 拦截：在 **系统设置 → 隐私与安全性** 中点击"仍要打开"（或右键 App → 打开）。**不要关闭系统安全保护**。
3. 应用没有 Dock 图标，只在菜单栏出现一个咖啡杯。

> 本应用使用 ad-hoc 签名、未做 Developer ID 公证，这是"无需付费开发者账号"的代价；未来签名策略变化可能影响分发。

## 使用

- **满杯（合盖不休眠）**：首次进入会请求一次系统管理员授权以安装特权 Helper；之后切换不再输密码。
- **低电量保护**：电池供电且电量 ≤20% 时禁止进入满杯；若已在满杯会自动降为空杯并通知。
- **登录时启动**：右键菜单开关（`SMAppService.mainApp`）。

## 卸载与手动恢复

- 右键菜单 **"卸载 Helper…"**：会先释放租约、恢复电源设置，再停止并删除 LaunchDaemon 与相关文件（仅在已安装时显示）。
- 若出现任何异常，可随时手动恢复系统休眠设置：

  ```sh
  sudo pmset -a disablesleep 0
  ```

- 手动卸载 Helper（等效）：

  ```sh
  sudo launchctl bootout system/com.fb0sh.tricup.helper 2>/dev/null || true
  sudo rm -f /Library/LaunchDaemons/com.fb0sh.tricup.helper.plist
  sudo rm -f /Library/PrivilegedHelperTools/com.fb0sh.tricup.helper
  sudo rm -rf "/Library/Application Support/TriCup"
  ```

## 安全与信任边界

- 特权 Helper 是独立 root LaunchDaemon，**仅**接受 `enable` / `disable` / `status` 三个固定操作，使用绝对路径 `/usr/bin/pmset`、无 shell、参数数组调用；拒绝任何客户端命令/脚本/路径/参数注入。
- Unix Domain Socket 权限受限（0600，属主为控制台用户），并校验客户端 UID/PID；`proc_pidpath` 仅作辅助校验。
- **同 UID 信任边界**：同一登录用户会话内的进程被视为同一信任域；Helper 的校验用于拒绝跨用户/异常连接，但**不防御已被攻陷的同 UID 进程**。
- 安装脚本固定绝对目标路径、显式 `root:wheel` 所有权与权限、写前检查符号链接、仅对 Helper 二进制最小范围清除 quarantine，且**从不关闭 Gatekeeper**。

## 全局电源设置与残余风险

- 满杯依赖系统级 `pmset -a disablesleep 1`，它是**全局、跨重启**设置。Helper 通过"租约模型 + 启动/崩溃恢复 + 回读验证 + 失败保留记录重试"尽量保证恢复；极端情况（断电、Helper 被杀到重启之间的窗口、终端手动改 pmset、其它软件并发修改）无法绝对保证立即复位。请用上面的手动恢复命令兜底。
- **散热**：合盖运行主要面向**桌面上的后台任务**。请勿把合盖持续运行的 MacBook 放入背包，以免积热/降频。
- 手装 LaunchDaemon 与 `pmset disablesleep` 均非 Apple 官方长期支持接口，未来 macOS 版本可能改变行为或收紧。

更多设计细节见 [ADR-0001](docs/adr/0001-lid-close-privileged-helper.md)。

## 稳定性与安全（Post-MVP 审核修复）

- **电源恢复可验证**：半杯/空杯会强制释放合盖租约；释放失败会明确报错，绝不把状态伪装成"允许休眠"。每次切换后回读真实 `SleepDisabled`；无法确认时标记"不确定"并在悬停提示/弹窗给出 `sudo pmset -a disablesleep 0` 手动恢复指引。回滚失败也会显式报告。
- **卸载安全**：仅当 `SleepDisabled` 确认为 0 且无活跃租约时才允许卸载 Helper；否则保留 Helper 与唯一租约恢复记录并提示手动恢复，避免丢失恢复能力。
- **租约持久化严格化**：空文件 / 损坏 JSON / 不支持的版本都会报错并阻止新租约；仅在回读验证恢复成功后删除记录。
- **Socket 健壮性**：SO_NOSIGPIPE 防止写已关闭连接杀死进程；处理 EINTR/部分读写/EOF；读写超时避免主线程无限阻塞；连接数上限与请求长度上限；写响应失败即断开并释放租约。
- **pmset 严格解析**：`pmset -g` 缺失或格式异常一律报错（不再默认 false）；子进程 5 秒超时。
- **电池状态区分**：读取失败与"无电池设备"不再伪装成 AC/100%；仅在有可用电池数据且 ≤20% 时触发保护。
- **版本与产物**：`CFBundleShortVersionString` 从 tag 去除前缀 `v` 并强制为数字版本；CI 校验签名/资源/ZIP 完整性，并上传真正的 `TriCup.app.zip`（与 Release 一致）。CI 构建只读权限，仅 tag 发布任务具备写权限。

## 开发与 CI

- SwiftPM + AppKit + IOKit + 独立 Privileged Helper。本地无需 Xcode/付费账号。
- GitHub Actions（`macos-26`，arm64）执行 `swift build`、`swift test`、Release 打包（ad-hoc 签名）并上传 `TriCup.app.zip`；推 `v*` tag 自动创建 Release。
- CI 不执行任何真实 `pmset`，也不安装特权 LaunchDaemon。

手动构建（仅在 macOS 上）：

```sh
swift build
swift test
bash scripts/package.sh   # 产出 tmp/build/TriCup.app.zip
```

## 真机验收清单（M4 Air）

- [ ] 空杯：合盖休眠正常。
- [ ] 半杯：`pmset -g assertions` 可见 TriCup 的系统/显示器断言。
- [ ] 满杯：首次安装 Helper 后合盖、拔电仍继续运行。
- [ ] 正常退出 → `SleepDisabled` 恢复为进入前值。
- [ ] 强制退出 / `kill -9` → 恢复。
- [ ] Helper 崩溃（`sudo kill -9` Helper 进程）→ 应用降为空杯并提示，且不自动重试；Helper 重启后恢复。
- [ ] 系统重启 → 恢复（`pmset -g | grep SleepDisabled` 为 0）。
- [ ] 电池 ≤20% → 无法进入满杯；满杯中降到 20% 自动退出。
- [ ] 授权取消/安装失败 → 保持原状态、图标如实反映。

## 图标与许可

咖啡杯图标复用自 [KeepingYouAwake](https://github.com/newmarcel/KeepingYouAwake)（MIT，© Marcel Dierkes），并新增半杯样式。详见 [LICENSE](LICENSE) 与 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。

本项目以 MIT 协议开源。

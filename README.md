# TriCup

一个极简的 macOS 菜单栏防休眠工具，用一个咖啡杯图标的填充程度表示三种工作状态。

| 状态 | 图标 | 行为 |
| --- | --- | --- |
| Sleep（空杯） | 空杯 | 允许系统、显示器与合盖休眠 |
| Awake（半杯） | 半杯 | 系统与显示器保持唤醒，允许合盖休眠 |
| Always Awake（满杯） | 满杯 | 系统持续运行，合盖也不休眠 |

- 左键点击图标：空杯 → 半杯 → 满杯 → 空杯 循环切换。
- 右键：直接选择状态、登录时启动、卸载 Helper、退出。
- 悬停：显示当前状态。
- 无主窗口、无 Dock 图标、无设置页面、无第三方运行时依赖。

## 状态（当前进度）

> ⚠️ **T1 骨架阶段**：菜单栏 UI 与状态机已就绪，但**电源功能尚未生效**。真实 IOKit 断言与合盖 Helper 将在后续 Ticket 实现。

## 开发与构建

- SwiftPM + AppKit + IOKit，最低系统 macOS 15，仅 Apple Silicon（arm64）。
- 本地无需 Xcode / 付费开发者账号；CI（GitHub Actions `macos-26`）负责编译、测试、打包与发布。
- 手动构建：

  ```sh
  swift build
  swift test
  bash scripts/package.sh   # 产出 tmp/build/TriCup.app.zip（ad-hoc 签名）
  ```

每次 CI 构建都会上传可下载的 `TriCup.app.zip` artifact。

## 图标与许可

咖啡杯图标复用自 [KeepingYouAwake](https://github.com/newmarcel/KeepingYouAwake)（MIT，© Marcel Dierkes），并新增半杯样式。详见 `LICENSE` 与 `THIRD_PARTY_NOTICES.md`。

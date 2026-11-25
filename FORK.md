# Taylent fork

基于上游 [kai-wu-cortex/AirSIM](https://github.com/kai-wu-cortex/AirSIM) `v0.9.8.25`，分支 `taylent`。

## 改动

| 部分 | 改动 |
| --- | --- |
| Android | Root/Shizuku 发短信前关闭 AppOps 运行时采样（`AppOpsSamplingGuard`）。HyperOS 上发送成功后会抛 NPE，结果变成“未确认”，iPhone 不保存发送记录 |
| Android | Android 13+ 短信能力检测：出厂 API < 33 的升级机型只声明 `android.hardware.telephony` 也算支持 |
| Relay | `sim_account` 与 SIM 槽 id 允许 `\n`（安卓 PhoneAccountHandle 键用换行拼接） |
| iOS | 包名 `com.taylent.airsim`，中转 `https://airsim.taylent.com`，去掉需审批的默认通话/短信 entitlement 和 App Group |
| Relay | 短信事件可带 `attachments`（≤3 个 https 附件：彩信图片 / 语音留言），`send_sms` 可带 `media_ids`（有图时正文可空） |
| iOS | voip.ms 线路（agent_kind `voipms`，桥接在 `~/airsim-voipms`）：气泡内显示彩信图片（QuickLook 预览）和语音留言播放；会话输入栏可选图发彩信，图片先上传到 `<relay>/voipms/media` |
| iOS | 界面换成新外壳（首页 / 通话 / 短信 / 我的，`WarmShellViews.swift`），设计稿由 Codex 出（`docs/design/warm-2026-11-20/`），2026-11-25 视觉改为中性系统灰、首页改为线路表（`REVISION-2026-11-25.md`）；原上游五标签界面已删除。主题（暖橙 / 墨绿 / 天蓝）只切换这套界面的强调色 |
| iOS | voip.ms 来电接听不再等本地路由（云端专用线路直接走 Relay 媒体） |
| Android | 远端静默模式来电不亮屏（不再发全屏 intent / turnScreenOn）；通话期间的应用唤醒由 root/Shizuku 助手熄回（需 `dumpsys power` 有 `mLastWakeReason`，K40 的 Android 13 没有，按设计不动作）。移植自 2020cqyd 的 PR `codex/300-network-call-sms-followup` |
| iOS | 短信会话行带头像（联系人照片 › 服务号图标 › 姓名首字 › 人形）。服务号图标与号码表自 v0.9.8.26 起用上游的 `SMSCarrierBrand` / `SMSServiceAssets`（来源见 `docs/SMSCarrierIcons.md`），本仓库只加了中文品牌名给 VoiceOver |
| iOS | 网络诊断页（我的 › 网络诊断）：本机网络 / VPN、Relay 往返延迟、各线路 Relay 心跳、局域网直连、通知权限、最近来电 / 短信推送及短信到达耗时，一键重连并同步短信（参考同一 PR，基于本仓库已有接口重写） |

## 上游同步记录

- 2026-11-21 合并上游 develop `1a97137`（= v0.9.8.26 + PR #46 同网 VoWLAN 优先）。冲突处理：
  - Relay SIM 标识校验改用上游更严格的 `validSIMAccountID`（与本仓库之前放开 `\n` 的修复等价，voip.ms 单行 id 照常通过）。
  - PushKit 回调采用上游同步上报 CallKit 的崩溃修复，只补回网络诊断的推送计时。
  - 上游改的旧版拨号盘 / 最近通话 / 短信列表在本仓库已删除，保留删除；上游的通话界面（蓝灰）和“收起通话 / 返回通话”接进新外壳，返回条改为把页面下推而不是盖住标题。
  - 小组件保留本仓库“小/中尺寸不放切换按钮”，加上上游的分卡信号条。
  - Root 发短信改为上游的逐段系统回执确认；`AppOpsSamplingGuard`（HyperOS NPE）仍在 `RootSmsMain` 中生效。
  - 上游 `android-standalone/test.sh` 的版本断言没跟着改（仍是 140），这里改成 141 / 0.9.8.26。

## 合并上游 / 改路由后的验收（必须做完才算完成）

本仓库同时跑两类线路：安卓 Agent（K40，局域网 / 蓝牙 / 云端）和纯云端线路（voip.ms）。上游只测单台安卓，凡是“只认当前绑定设备”或“局域网可用就跳过云端”的逻辑，都会让 voip.ms 线路静默失效（2026-11-21：合并 PR #46 后 voip.ms 的通话、短信不再进记录）。

1. 自动测试：`sh android-standalone/test.sh`、`cd push-relay-worker && npm test`、iOS `AirSIMTests` 全量 + `AirSIMUITests`（已知 3 个老失败见下）。`CloudCatchUpPolicyTests` 锁定“每条线路都要能补拉”的规则。
2. 真机：iPhone 在家（与 K40 同一 Wi-Fi）时，分别对 **K40 线路** 和 **voip.ms 线路** 各打一通电话、收一条短信，然后跑 `sh ~/.config/airsim/tools/airsim_history_check.sh`，确认两条线路都有新记录。
3. 改了云端 / 局域网路由选择的，再在蜂窝网络（离开家里 Wi-Fi）下重复第 2 步。
4. 发短信走 Root 的改动：用 `python3 -I ~/.config/airsim/tools/k40_sms_test.py <号码> <内容>` 经 Relay 让 K40 发一条到自己的 voip.ms 号码，看 K40 日志 `sms_privileged_resolved result=ok` 且 iPhone 收到。

已知与本仓库无关的失败：`testBLEPushAdoptionPreservesPresentationAndUsesOnlyBLEBackend`、`testWatchDialOwnsSourceAndBlocksSecondPhoneDial`（上游基线）、`testOverlayControlAndPCMUseSystemRoutingNotWiFiOrWiredEthernet`（Mac 在 192.168.1.x 网段时）。

- 2026-11-24 合并上游 develop `0be80a0`（v0.9.8.27）。冲突处理：
  - 上游按其用户要求把 PhoneViews／RootView／SMSNavigationUITests 整份回退到 `991162c`（撤回 PR #47 界面，删掉收起通话和服务号图标）。核对后这三个文件在上游只有回退、没有功能改动，全部保留本仓库版本；上游删除的 `SMSServiceArtwork.swift` 与 `SMSServiceAssets.xcassets` 及其工程引用恢复。
  - 设置页同时保留本仓库的设备备注名和上游新增的“删除端点”。
  - 上游让设备列表保留本机保存过的已配对设备（离线也显示），导致按设备数计数的测试互相污染：`PairedDeviceRecordsIsolation` 隔离两个单元测试，界面测试夹具每次启动清空已保存设备。
  - 采纳：端点管理、IMS SIP/TEL 来电号码规范化、按 SIM 显示号码和信号、设备数量不设上限、PR #46 日期比较的运行时兼容修复。
- 2026-11-25 上游无新版本（仍是 v0.9.8.27）。合并社区 PR #52（Mr-KIDBK，上游未合并）：
  - 在 iPhone 上接听后，Watch 立即收起响铃。
  - 自动模式在确知没有 Wi-Fi 时不再空等局域网。Tailscale（100.64/10）、TLS 域名和走 VPN 验证过的地址仍算候选，所以存着 K40 的 Tailscale 地址时照旧会等。
  - 冲突只在 `AppModel` 接听处：保留本仓库"纯云端线路（voip.ms）不等局域网"的条件，同时采用 PR 的新等待参数。
  - 作者没有 Xcode。在本仓库补跑了全部单元测试，含 PR 新增的 8 项；Watch 脚本测试分别为 359、8、155 项断言；局域网优先脚本测试 13 项。
  - `testWatchDialOwnsSourceAndBlocksSecondPhoneDial` 合并前后都时过时不过，与 PR 无关。

## 构建

```sh
sh android-standalone/test.sh                      # 全量测试
set -a; . ~/.config/airsim/android-release.env; set +a
AIRSIM_ANDROID_BUILD_VARIANT=release sh android-standalone/build.sh
# 产物: android-standalone/build/android/AirSIM-Android-Standalone-release.apk
```

签名密钥与官方不同，安装前需先卸载官方版。Relay 与 App 必须用同一个版本的源码。

## 同步上游

```sh
git fetch upstream --tags
git rebase <新tag>   # 在 taylent 分支上
```

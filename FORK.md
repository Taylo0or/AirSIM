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

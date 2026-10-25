<div align="center">

<img src="https://cdn.jsdelivr.net/gh/sunset5277/SuchMusic@main/assets/images/Such_music_sxt.svg" alt="SuchMusic Logo" width="260">

## SuchMusic

![GitHub Release](https://img.shields.io/badge/release-v1.2.0-blue?logo=github) ![License](https://img.shields.io/badge/License-AGPL%20v3-red?logo=gnu) ![Flutter](https://img.shields.io/badge/Flutter-3.x-02569B?logo=flutter&logoColor=white) ![Dart](https://img.shields.io/badge/Dart-3.12-0175C2?logo=dart&logoColor=white) ![Platform](https://img.shields.io/badge/Platform-Android-3DDC84?logo=android&logoColor=white) ![PRs Welcome](https://img.shields.io/badge/PRs-welcome-brightgreen.svg)

**一款基于 Flutter 开发的网易云音乐第三方 Android 客户端，简洁美观，支持在线播放与本地音乐。**

基于 Flutter 构建，接入网易云音乐 API，支持后台播放、本地音乐扫描与应用内更新。

</div>

---

## ⚖️ 法律声明

> **本软件为音乐播放工具**  
> **基于开源网易云音乐 API 实现，不直接存储、提供任何音乐源文件。**  
> 音乐相关数据均来自网易云音乐平台，版权归原平台及权利人所有。  
> 本项目仅供学习交流与技术实践使用，请于下载后 24 小时内自行删除。  
> 使用本软件产生的一切后果由使用者自行承担，请支持正版音乐。

---

## 📦 技术架构

| 技术栈 | 说明 |
|--------|------|
| **Flutter / Dart** | 跨平台 UI 框架与开发语言 |
| **netease_music_api** | 网易云音乐 API 封装（基于 [flutter-netease-music-api](https://github.com/flytreeleft/flutter-netease-music-api)） |
| **just_audio** | 音频播放核心 |
| **audio_service** | 后台播放与系统媒体控制 |
| **audio_session** | 音频会话管理，处理与其他应用的共存播放 |
| **on_audio_query** | 本地音乐扫描（MediaStore 查询 / 权限管理） |
| **dio + cookie_jar** | 网络请求与登录态 Cookie 管理 |
| **shared_preferences** | 本地设置持久化（播放开关等） |
| **qr_flutter** | 扫码登录二维码生成 |
| **package_info_plus + open_filex** | 应用内检查更新与 APK 安装 |

---

## 📲 下载安装

前往发布渠道下载最新 APK：

- **GitHub Releases**：[such-music-update](https://github.com/sunset5277/such-music-update/releases)
- **Gitee Releases**：[such-music-update](https://gitee.com/Sunset_5277/such-music-update/releases)

下载后直接安装 APK 即可，应用内置检查更新功能，后续版本可在应用内一键升级。

---

## 🚀 快速开始

### 环境要求

- Flutter SDK >= 3.x（Dart SDK ^3.12.2）
- Android 开发环境（Android SDK、JDK）

> ⚠️ 项目依赖本地的 `netease_music_api` 包，克隆后请根据 `pubspec.yaml` 中的路径配置调整，或将其改为 git 依赖。

### 安装与运行

```bash
# 克隆项目
git clone https://github.com/sunset5277/SuchMusic.git
cd SuchMusic

# 安装依赖
flutter pub get

# 运行（连接设备或启动模拟器）
flutter run
```

---

## 🛠️ 开发指南

### 项目结构

```
SuchMusic/
├── lib/                # Dart 源码（主要业务逻辑）
├── android/            # Android 平台配置
├── web/                # Web 平台入口
├── assets/images/      # 图片资源（Logo、图标等）
├── test/               # 单元测试
├── update.json         # 应用内更新配置
└── pubspec.yaml        # 依赖与资源声明
```

### 常用命令

```bash
flutter run            # 运行调试版本
flutter build apk      # 构建 APK
flutter analyze        # 静态代码检查
flutter test           # 运行测试
```

### 构建发布包

```bash
flutter build apk --release
```

构建产物输出至 `build/app/outputs/flutter-apk/app-release.apk`。

---

## 🤝 贡献指南

欢迎提交 Issue 和 Pull Request。

在提交 PR 前，请确保：

- 代码通过 `flutter analyze` 检查
- 遵循 Dart 官方代码规范
- 新增功能附有必要说明

---

## 👥 开发者

- **夕落** — 开发
- **小风** — UI

---

## 📄 开源协议

本项目采用 [GNU Affero General Public License v3.0 (AGPL-3.0)](https://github.com/sunset5277/SuchMusic/blob/main/LICENSE) 开源协议。

> [!IMPORTANT]
> - 个人学习、交流使用：遵循 AGPL-3.0 协议即可，衍生项目须同样开源并保留本项目的许可和版权信息
> - **禁止将本项目或其修改版用于商业销售**
> - 禁止在二开项目中修改程序原版权信息（可添加二开作者信息）

---

## 💬 交流与反馈

如有问题或建议，欢迎通过 [GitHub Issues](https://github.com/sunset5277/SuchMusic/issues) 反馈。  
也可在应用内「联系我们」入口加入 QQ 群交流。

---

## 🙏 致谢

- [flutter-netease-music-api](https://github.com/flytreeleft/flutter-netease-music-api) — 网易云音乐 API
- [just\_audio](https://pub.dev/packages/just_audio) / [audio\_service](https://pub.dev/packages/audio_service) — 音频播放与后台服务
- [Flutter](https://flutter.dev) — 跨平台应用框架

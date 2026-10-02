# 部署与排错手册

交付版本：v0.2.0（Build 2）。源码包解压后打开其中的 Xcode 工程；不是可直接安装的 IPA，需要自己的开发团队签名。

## 环境
- Mac：Xcode（本项目开发环境为 27）、Python 3.10+；Python 服务使用标准库。
- 手机：工程最低 iOS 26，实际用户测试为 iPhone 15 Pro / iOS 27.0.1。低于已测版本或不同系统资源状态需重新验收。
- OpenAI API 账户及可用模型权限；可选高德 Web 服务 Key。ChatGPT 订阅与 API 配置不是同一件事。
- 手机与 Mac 可在局域网互通；Mac 可访问所选外部 API。

## 安装手机端
1. 打开根目录 `WhaleCompanion.xcodeproj`，选择 TARGETS → WhaleCompanion → Signing & Capabilities。
2. 启用自动签名并选择自己的开发团队。工程中的 Team 是开发者本机设置，其他人必须替换。
3. 选择真实 iPhone；按系统要求开启开发者模式、信任电脑及开发证书。不要为排错随意删除 App，否则本地记录会丢失。
4. 若签名要求更换 Bundle Identifier，同时核对 `Info.plist` 的后台任务允许标识和 `WhaleApp.swift` 中 `ai.whale.companion.job.` 前缀，保持一致。
5. ▶️ 安装并运行。授予完整日历权限和本地网络权限。App 使用「日常事务」日历，必要时自动创建；若账户不允许创建，可先手动建同名可写日历。

## 启动服务和保存密钥
双击 `server/start.command`。首次隐藏输入 OpenAI Key，回答 `y` 可保存到 Mac 登录钥匙串。后续启动读取环境变量或钥匙串；未配置时才询问输入。

双击 `server/configure.command`，选择 OpenAI / 高德，再选择保存、更换或删除。高德请选择「Web 服务」，不是 iOS SDK 或 Web JS 类型。改动密钥后需重启运行中的服务。不要把密钥贴进聊天、截图、README 或提交记录。

配置优先级：进程环境变量优先于钥匙串。密钥经 stdin 传给 Security 框架辅助程序，不放入命令参数；读取结果由启动器捕获。运行时仍在网关进程环境/内存中，不承诺防御本机已被控制的情形。Keychain 访问可能出现系统提示。

服务打印 `http://<Mac-IP>:8765`。将其填入手机「设置 → Mac 模型服务」。更换 Wi-Fi 后重新核对 IP。地址检测使用 en0；有线网卡或其他接口请在 Mac 网络设置核对。

环境变量示例见 `server/.env.example`，程序不会自动解析该文件。使用脚本启动即可，不需要安装 pip 依赖。

## 更新与演示运行
- 只改 Swift：Xcode 更新手机 App，服务不必重启。
- 改 Python 或 Key：旧终端 Control+C，再运行 start.command；保存过 Key 后无需重复输入。
- 正常执行无需 USB，但仍依赖 Mac 开机、服务运行和网络互通。
- 脱离调试器：Xcode 停止按钮结束运行，随后从手机桌面打开鲸伴，再提交任务。仅看到 Build Succeeded 不足以证明调试已脱离。
- 调试器停止后再次点 Xcode ▶️，通常又进入调试运行；录制时不要这样启动。

## 验证命令
在仓库根目录运行：
```sh
python3 -m unittest discover -s tests -p 'test_*.py'
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swiftc WhaleCompanion/Planner.swift tests/main.swift -o /tmp/whale-planner-tests
/tmp/whale-planner-tests
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project WhaleCompanion.xcodeproj -scheme WhaleCompanion -sdk iphoneos -configuration Debug -derivedDataPath build CODE_SIGNING_ALLOWED=NO build
```
最后一条仅检查编译，生成物未签名，不能直接作为真机安装包。真机安装用 Xcode 自动签名构建。

## 常见问题
| 现象 | 排查 |
|---|---|
| 手机连接超时 | 确认服务运行、新网络下的 Mac IP、本地网络权限、Wi-Fi 隔离和防火墙；VPN 规则可能影响局域网访问 |
| GET /health 返回 501 | 可能运行着旧服务，停止后启动当前仓库版本；健康检查只验证网关，不验证模型 Key |
| cancelled / 后台结束 | 看任务卡片中的阶段、耗时和是否可能写入；系统到期与网络取消有区分，但不能保证识别系统的具体取消原因 |
| 模型服务失败 | 看 Mac 日志中的错误类型/HTTP 状态、模型权限和网络；不要输出完整 Authorization 或请求 URL |
| 日历冲突 | 核对出发预留、所有参与检查的日历；只读节假日默认按名称排除，可手动调整 |
| 高德搜索成功但路线为空 | 注意夜间运营、模式、起终点及接口与高德 App 的差异；空结果与不能完整解析的结果有不同提示 |
| 证书提示未信任，但手机已验证 | 先尝试从手机桌面打开，保持解锁；若仍失败，读取 Xcode Show Details，而非直接删 App |
| 结果待核对 | 先查系统日历；不要一键重试导致重复写入 |

目前允许局域网 HTTP，网关没有用户鉴权、限流或云部署；上线前必须单独设计 HTTPS、鉴权、密钥隔离、持久队列及监控。

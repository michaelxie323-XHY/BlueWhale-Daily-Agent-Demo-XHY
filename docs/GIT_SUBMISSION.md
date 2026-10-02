# GitHub 提交步骤

项目目标仓库：https://github.com/michaelxie323-XHY/BlueWhale-Daily-Agent-Demo-XHY 。本机工作目录已是 Git 仓库。交付 ZIP 不包含 .git；如果从 ZIP 解压开始，请先在解压目录运行 `git init`。以下保留首次提交和后续更新的操作参考；已连接仓库时无需重复初始化或添加 origin。

1. 在 GitHub 创建一个空仓库，例如 `whale-companion`。可用私有仓库并邀请评审获得权限；不要额外初始化 README，避免首次推送历史冲突。
2. 在 Mac 终端进入项目并检查待提交内容：
```sh
cd '/Users/xiehuiyi/Documents/ChatGPT/蓝色鲸鱼agent开发'
# 从 ZIP 解压使用时，改为解压目录，并先执行 git init
git status --short
git add .gitignore README.md WhaleCompanion WhaleCompanion.xcodeproj server tests docs
git diff --cached --stat
git diff --cached --name-only
```
3. 检查暂存区没有真实 Key、.env、截图、签名证书、手机数据或 build 产物。源文件中出现 `MODEL_API_KEY` 是变量名，不等于泄露；`.env.example` 只能包含占位符。
4. 提交并设置远程，将示例 URL 替换为自己真实的仓库地址：
```sh
git commit -m "feat: add iOS calendar and travel assistant prototype"
git branch -M main
git remote add origin https://github.com/YOUR_USERNAME/whale-companion.git
git push -u origin main
```
若提示缺少 Git 身份，配置自己的 `git config user.name` 与 `git config user.email` 后重试。认证使用 GitHub 支持的凭据流程，不把访问令牌写进 URL 或仓库。

后续更新：再次检查、add、commit，然后 `git push`。不要伪造拆分的早期开发提交来表示不存在的历史；首个提交可以直接完整提交已验收原型。

提交给评审：仓库链接、1–2分钟演示视频、README。私有仓库必须确认对方有权限。

## 排除项
.gitignore 排除构建目录、用户工作区状态、Python 缓存、环境密钥文件和常见证书私钥文件。Keychain 位于仓库外。个人开发 Team 标识不是 Key，仍需评审在 Xcode 选择自己的 Team。不要提交开发者签名证书来帮助他人安装。

自动模式扫描不能证明没有任何秘密。若真实 Key 曾经提交过，仅删除文件不够：先吊销/轮换 Key，再处理 Git 历史。

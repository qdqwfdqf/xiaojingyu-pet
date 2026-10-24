# 小鲸鱼桌宠 · Xiaojingyu Desktop Pet

一只住在 Windows 桌面上的小鲸鱼女仆。会走、会坐、会被戳生气、会聊天，还会看你正在干什么然后说一句合适的话。

## 下载

见 [Releases](../../releases)：解压后双击 `小鲸鱼桌宠.exe`。
Windows 10 / 11，不需要安装任何东西。

## 这一版有什么

- **800 条台词 / 36 个池**：断网也能说话，不依赖 API
- **6 种表情 + 14 个姿势**
- **46 项可调设置**（32 滑块 + 14 开关），右键「设置…」即可
- **窗口感知**：只读前台窗口标题和进程名，不读内容、不上传
- **聊天后端四选一**：DeepSeek / 硅基流动 / OpenRouter / 本机 Ollama
- 用量看板、余额提醒、番茄钟、久坐提醒、工具模式

## 技术栈

纯 Windows PowerShell 5.1 + WinForms 分层窗口（每像素透明），无第三方依赖、无需编译。
`源码/` 里就是全部**代码**（PowerShell 模块 + 配置 + 台词 + 人设），改完直接运行 `启动桌宠.vbs` 即可。
图片素材（`pet.png`、`assets\sprites`）体积大，**不在仓库里**，在 [Releases](../../releases) 的 zip 内。

## 隐私

台词、设置、聊天记录**只存本机**；API Key 用 Windows DPAPI 加密；窗口感知只读标题/进程名。

## 许可

代码 MIT。美术素材（角色形象）版权归作者所有，请勿单独商用或再分发。

## 致谢

- 视频 BGM：Ikson - With You (iksonmusic.com)
- 本地推理（可选）：llama.cpp (MIT) / Qwen (Apache-2.0)
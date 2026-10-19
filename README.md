# note0 for iPad（原生笔记本版）

纯 Swift 重写的 GoodNotes 形态笔记应用：书架 → 笔记本 → 固定尺寸的页面，Apple Pencil 手写由 PencilKit 原生渲染，不再经过 WebView。

## 当前功能（v2.0.0，build 36）

- 书架：左侧分类栏——最近 / 全部笔记 / 收藏 / 未分类 / 课程与文件夹（可设颜色和图标，可以嵌套，比如“大二上 › 线性代数”）/ 回收站；右侧是该分类的封面，顶部有路径。新建笔记本（空白 / 横线 / 方格 / 点阵）、导入 PDF 课件（可一次选多个）时，会直接放进正在看的文件夹
- 整理：长按封面 → 收藏 / 移动到… / 重命名 / 移到回收站；把封面拖到左边的文件夹、未分类、收藏或回收站上；“选择”后可以一次移动、收藏、删除多本；按修改时间 / 创建时间 / 名称排序；搜索标题和文件夹名
- 回收站：删除的笔记保留 30 天，可以恢复或永久删除；删除文件夹时里面的笔记也进回收站
- 页面编辑：顶部一行精简工具栏——笔 / 荧光笔 / 橡皮 / 套索、颜色、尺子；再点一下当前工具打开它的设置：6 种笔型（钢笔、圆珠笔、书法笔、铅笔、水彩、蜡笔）、粗细、整笔/局部擦除和橡皮大小；颜色有常用色和任意颜色。窄窗口下收成三个按钮。Apple Pencil 双击 / 捏一下按系统设置切换橡皮、切回上一个工具或打开设置。“…”里可以改用苹果原生工具栏。默认只认 Apple Pencil 书写
- **图形识别**：画直线、圆、椭圆、三角形、矩形、五边形、六边形、折线、箭头，画完笔尖停住约半秒，页面上会出现虚线预览，抬笔就变成规整的图形（可撤销；在笔的设置里可关闭）
- **中英文**：界面跟随 iPad 系统语言（简体中文 / English），AI 默认用同一种语言回答。中文是源语言，英文在 `Note0/en.lproj/Localizable.strings`；新写界面文字时用 `L("中文")`，再在英文文件里加一行翻译
- **套索问 AI**：用原生套索圈住内容后，页面底部出现“问 AI 选中的内容”，或直接点 ✦，就把圈住的部分发给 AI（选中菜单里也会尝试加“询问 AI”）
- 手指翻页：单指左右滑翻页（只认手指，笔写字不会误翻；放大时左右滑是平移），拉到页底继续上推进入下一页、在页顶继续下拉回到上一页（停在上一页底部）；开启“用手指写字”后改为双指左右滑。分屏左右两边都支持
- 页面管理：缩略图侧栏、加页（插在当前页后面）、删页、拖动排序（"整理"）
- **分屏**：工具栏"分屏"把另一个笔记本（课件 PDF 或其他笔记）打开在左边，右边写当前笔记；**两边都能写字、都能框选问 AI**，共用同一套笔和颜色；中间分隔条可拖动，每个笔记本记住左边打开的是哪本、看到第几页。从文件打开的 PDF 会自动变成书架上的一个笔记本
- **AI 助手（右侧聊天窗口）**：顶部的对话按钮打开右侧聊天栏，写笔记时一直可见，可拖动左边缘调宽窄。点 ✦ 框选或用套索圈住内容后，截图自动放进输入框，可点“讲解 / 整理成笔记 / 出复习题”或直接打字，支持连续追问；回答可复制、重新回答、“放到页面上”变成截图旁边的卡片（可拖动、长按复制或删除，导出 PDF 时一起导出）。每本笔记的对话单独保存，右上角可开新对话
- **多窗口**：书架里长按笔记本 →"在新窗口中打开"，可以和另一本并排或在台前调度里同时开多个；同一本笔记同时只能在一个窗口里编辑
- 自动保存：停笔 0.8 秒、翻页、离开笔记本、App 进入后台时保存
- 导出 PDF：原 PDF 课件保持矢量，手写以 2 倍分辨率叠加

## 账号与 AI

“问 AI”按下面的顺序找可用的连接：

1. **自己的 AI Key**：书架左上角“连接 AI” → 打开“使用自己的 AI Key”，选服务商（OpenAI / 通义千问 / OpenRouter / 其他兼容 OpenAI 的地址），填 API Key，点“测试连接”。Key 只存在本机钥匙串。模型要能看图（默认 OpenAI 用 `gpt-5-mini`，通义千问用 `qwen-vl-max`）
2. **内置代理**（给所有用户免配置用）：部署 `server/ai-proxy-worker.js` 到 Cloudflare Workers，真实 Key 只放在 Cloudflare；然后在 `ios/Info.plist` 填 `Note0AIProxyURL`（如 `https://note0-ai.xxx.workers.dev/v1`）、`Note0AIProxyToken`（与 Worker 的 `APP_TOKEN` 相同）、`Note0AIProxyModel`。填好后用户打开 App 就能用 AI，不需要登录。注意 Token 打包在 App 里，Worker 里用 `ALLOWED_MODELS` 限制模型，并在服务商后台设每月额度上限
3. **note0 账号**：登录 `Note0APIBaseURL`（默认 `https://api.dim0.net`）上的后端，走 `/ai/llm/stream`。当前默认账号服务仍依赖这个地址；独立代码仓库不会改变已安装 App 的服务器配置

## 技术选型

| 层 | 选型 |
|---|---|
| 界面 | SwiftUI（书架、侧栏）+ UIKit（`PageEditorController`） |
| 手写 | PencilKit，一页一个 `PKDrawing`，坐标为页面坐标（PDF 点） |
| 页面背景 | `CATiledLayer`，缩放时按分块重新渲染，PDF 保持清晰 |
| 数据 | SwiftData（`Notebook`、`Page`、`PageCard`），字段按 CloudKit 兼容方式定义 |
| PDF | PDFKit / CoreGraphics；导入的 PDF 文件存放在 Application Support/PDFs |

## 目录

```
./
  ios/project.yml            XcodeGen 工程定义（唯一来源；Note0.xcodeproj 由它生成，不要手改）
  ios/Info.plist             服务器地址、AI 中转配置
  app.json / eas.json        TestFlight 上传（EAS）
  scripts/                   生成 Xcode 工程
  server/ai-proxy-worker.js  Cloudflare AI 中转（可选，未部署）
  Note0/App                  入口、多窗口、“一本笔记只在一个窗口打开”
  Note0/Models               Notebook / Page / PageCard / Folder、纸张样式
  Note0/Services             页面增删排序、文件夹与回收站、渲染缩略图和卡片、导出 PDF、PDF 文件存放
  Note0/Services/AI          AIPrompt（提示词、流式解析）、AIConfig（账号、钥匙串）、AIDirect（自己的 Key / 中转）、AIClient（网络请求）
  Note0/Features/Library     书架：分类栏、文件夹、移动、回收站、封面
  Note0/Features/Notebook    笔记本：顶部工具条、分屏、页面列表、右侧 AI 栏的布局
  Note0/Features/Page        手写页面：画布、精简工具栏、图形识别、背景和卡片
  Note0/Features/AI          AI 聊天栏（AIChat 数据 + 界面）、连接 AI 设置
  Note0Tests                 单元测试
```

## 构建

本仓库在 Windows 上开发，构建全部在云端完成：

- **CI**：推送到 GitHub 后，`.github/workflows/note0-ios-ci.yml` 在 macOS 上生成工程、编译并在 iPad 模拟器上跑单元测试。
- **TestFlight**：在仓库根目录运行 `npx eas-cli build --platform ios --profile production --auto-submit`。Windows 上运行前，需先从 CI 的 `Note0-xcodeproj` 产物取得本地工程。
- **外部测试凭证**：设置环境变量 `ASC_KEY_ID`、`ASC_ISSUER_ID`、`ASC_KEY_PATH`，指向具有 App Manager 权限的 App Store Connect API Key；不要把 `.p8` 文件提交到仓库。
- **外部测试发布**：上传后运行 `node scripts/testflight-external.cjs [build号] [--notes "测试内容"]`；省略 build 号时读取 `app.json`，脚本等待 Apple 处理并加入所有外部组、提交测试版审核（中文测试内容写入 `zh-Hans`，英文写入 `en-US`）。

> 仓库已独立，但现有发布配置仍使用 bundle id `com.dim0.canvas` 和原 App Store Connect 记录，以便现有用户继续更新。若要作为全新 App 与旧版并存，需要另行更换 bundle id 并创建新的 App Store Connect 记录。

## 下一步

1. 真机验收：书写延迟、缩放清晰度、PDF 大文件导入速度、分屏拖动、多窗口
2. AI 卡片支持数学公式渲染（目前公式按纯文本显示）
3. 页面模板与封面、笔记本文件夹（按课程分组）
4. iCloud 同步（CloudKit）

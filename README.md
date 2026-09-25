# 截图打码（工作名）

端侧自动识别截图里的敏感信息并打码。全部用系统自带的 Vision / Core Image，不联网、不上传、不收集数据。

## 结构

```
Package.swift            RedactKit（核心库，iOS 17+ / macOS 14+）
Sources/RedactKit/
  Rules/                 文本规则：归一化（全角、O→0、分组空格）+ 校验（身份证校验码、Luhn）+ 关键词定位
  Detection/             Vision（OCR / 人脸 / 条码，长截图分段）+ 聊天布局分析（头像 / 昵称 / 标题 / 系统消息）
  Render/                Core Image 打码 + 无元数据导出
Sources/ChatSynth/       合成仿微信聊天截图（带精确标注），用来量化头像 / 昵称的召回率
Sources/redact-cli/      macOS 命令行：批量识别、输出标注图 / 打码图、跑评估
Tests/                   规则、渲染（贴边模糊、叠加翻出、抹除残留、元数据）、布局回归
App/Redact.xcodeproj     iOS App：选图 → 自动识别 → 审核（点框开关、按类别开关、手动补框、换样式）→ 保存 / 分享
testdata/                本地测试图（不入库）
```

## 常用命令

```bash
swift test                                              # 单元测试
swift build -c release
.build/release/chat-synth testdata/synthetic 60         # 生成 60 张合成聊天截图
.build/release/redact-cli eval testdata/synthetic       # 头像 / 昵称 / 标题 / 系统消息的召回率与精确率
.build/release/redact-cli detect 某张截图.png --out testdata/out   # 输出 .overlay.png 和 .redacted.png
```

iOS App：用 Xcode 打开 `App/Redact.xcodeproj`，或

```bash
xcodebuild -project App/Redact.xcodeproj -scheme Redact -sdk iphonesimulator \
  -destination 'generic/platform=iOS Simulator' build
```

## 关键设计

- **效果可选**：自动 / 抹除文字 / 色块 / 杂讯色块 / 像素化 / 模糊 / 彩虹条 / 彩虹格，色块类可选颜色，
  选择会被记住；长按单个框可以单独换效果（优先级：单处 > 全局 > 类别默认）。
  色块、杂讯色块、彩虹条、彩虹格只由区域位置和颜色生成，不读原图——有测试保证两张不同原图打码后区域像素完全相同。
- **打码不可逆且不泄露**：文字默认"抹除"——背景够纯就用背景中位色填平，否则大块像素化（块 ≥ 半个字高）；
  每处都从当前结果取像素（后加的效果不会翻出先前的遮挡）；`clampedToExtent()` 防止贴边模糊透出原图。
- **号码写法**：两遍扫描（保留 / 去掉数字间分隔符），既能命中 `6222 0212 3456 7894`，又能拆开相邻的两个号码；
  折行的邮箱、单号把上下两行拼起来再扫。
- **头像**：带状搜索——枚举"离边缘 s、宽 bw"的竖带，找高≈宽、带内前景过半、内侧间隙是背景的行段。
  不依赖分割，所以头像和气泡粘在一起、有弹窗 / 卡片干扰时也能找到。
- **昵称**：头像右侧、顶部对齐、落在页面背景上（不在气泡里）的 OCR 行；
  另有"昵称列"推断和像素兜底，OCR 漏掉短而淡的昵称时也能补上。
- **权限**：选图用系统选择器（无需相册权限），保存只申请"仅添加"。

## 已知限制 / 下一步

- 分享扩展、App Intent（"打码最新截图"，可绑定轻点背面）、批量处理的进度与取消
- 朋友圈点赞 / 评论区里的名字；被导航栏遮住一半的头像
- 截图外面套了设备边框的宣传图（页面背景色估计会错）
- 审核页双指缩放；保存后可选删除原图
- 真实截图测试集太小（网上的聊天截图大多已打码），需要自己补充

// swift-tools-version: 6.0
// RedactKit：端侧敏感信息识别 + 打码核心库（iOS App / 分享扩展 / macOS 命令行共用）
import PackageDescription

let package = Package(
    name: "RedactKit",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "RedactKit", targets: ["RedactKit"]),
    ],
    targets: [
        // 核心：规则引擎、Vision 识别、聊天布局分析、Core Image 打码
        .target(name: "RedactKit"),
        // 合成聊天截图（带标注），用于评估头像 / 昵称识别
        .target(name: "ChatSynth"),
        // macOS 命令行：批量识别、输出标注图 / 打码图、对合成数据跑召回率
        .executableTarget(name: "redact-cli", dependencies: ["RedactKit", "ChatSynth"]),
        .executableTarget(name: "chat-synth", dependencies: ["ChatSynth"]),
        .testTarget(name: "RedactKitTests", dependencies: ["RedactKit", "ChatSynth"]),
    ],
    swiftLanguageModes: [.v5]
)

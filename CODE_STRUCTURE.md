# ClearX 代码结构

## 顶层目录

- `ClearX/App/`：应用入口、SwiftUI Scene 和依赖组装。
- `ClearX/Domain/`：不依赖 SwiftUI 的值类型、状态、协议和错误。
- `ClearX/Services/`：扫描树、会话缓存、来源发现、全局调度与性能诊断服务。
- `ClearX/Features/SourceSelection/`：扫描源选择页面及状态模型。
- `ClearX/Features/Results/`：独立结果窗口、多列浏览器及状态模型。
- `ClearX/Shared/`：格式化和通用 SwiftUI 组件。
- `ClearX/Resources/`：本地化与资源。
- `ClearXTests/`：领域、服务和状态模型测试。

## 状态流

`SourceSelectionView` 创建或选择 `ScanSource` 后，经 `ClearXApp` 打开对应的独立结果窗口。`ResultWindowSession` 先从 `InMemoryScanCache` 读取当前会话的完整结果；未命中时，调用 `ScanCoordinator` 调度 `FileTreeScanner`。扫描器直接写入一个共享 `ScanTreeStore`，`InMemorySnapshotColumnLoader` 从同一 actor 按页读取当前可见列，`ScanProgress` 仅触发可见列失效刷新。窗口消失时取消其扫描任务，最后一个使用该来源的窗口关闭时释放完整会话缓存。

重新完整扫描会创建独立候选 `ScanTreeStore`。已有完整结果继续显示到候选完整结束；候选取消、不完整或失败时释放候选并保留旧快照。首次扫描没有旧快照时，可浏览不完整的候选结果，但它不会进入缓存。

`ResultWindowView` 在窗口级 `@State` 中按浏览深度保存列宽。每列右边界独立调整左侧列，宽度在同一窗口内跨目录导航和重新扫描保留，关闭窗口后恢复默认值。

持久化、GRDB、FSEvents 流重放和分支刷新不在当前代码中，统一作为后续 TODO 保留。

## 主要类型

- `ClearXApp`：应用和依赖入口。
- `ResultWindowSession`：结果窗口的会话缓存加载、完整扫描与进度协调。
- `InMemoryScanCache`：按扫描根路径复用当前应用进程内的完整结果。
- `DisplayedScanSnapshot`：结果窗口当前显示的快照引用，可在旧完整树与候选树之间切换。
- `ScanTreeStore`：单次扫描的唯一节点所有者，维护节点定位与父子 ID 索引，提供分页查询、惰性排序、聚合和轻量进度失效。
- `ScanSource`、`ScanNodeSummary`、`ScanPresentationState`：领域模型。
- `FileTreeScanner`：文件系统遍历与大小聚合。
- `ProgressPublisher`：独立于扫描 worker，每 2 秒从扫描 actor 拉取一次计数与变化 ID，并负责首帧、末帧即时发布。
- `ScanPerformanceDiagnostics`：按需采集扫描阶段耗时、队列积压、进度发布与 250ms 峰值物理内存，并通过统一日志输出；不记录扫描路径或文件名。
- `ScanCoordinator`：所有窗口共享的最多 4 个元数据任务调度器。

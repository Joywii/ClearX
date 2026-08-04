# ClearX 代码结构

## 顶层目录

- `ClearX/App/`：应用入口、SwiftUI Scene 和依赖组装。
- `ClearX/Domain/`：不依赖 SwiftUI 的值类型、状态、协议和错误。
- `ClearX/Services/`：扫描、来源发现、全局调度与事件校验服务。
- `ClearX/Features/SourceSelection/`：扫描源选择页面及状态模型。
- `ClearX/Features/Results/`：独立结果窗口、多列浏览器及状态模型。
- `ClearX/Shared/`：格式化和通用 SwiftUI 组件。
- `ClearX/Resources/`：本地化与资源。
- `ClearXTests/`：领域、服务和状态模型测试。

## 状态流

`SourceSelectionView` 创建或选择 `ScanSource` 后，经 `ClearXApp` 打开对应的独立结果窗口。`ResultWindowSession` 先从 `InMemoryScanCache` 读取当前会话的完整结果；未命中时，调用 `ScanCoordinator` 调度 `FileTreeScanner`。扫描中的节点增量写入 `LiveScanTree`，并由 `InMemorySnapshotColumnLoader` 向当前可见列提供部分结果；窗口消失时取消其扫描任务，最后一个使用该来源的窗口关闭时释放完整会话缓存。

`ResultWindowView` 在窗口级 `@State` 中按浏览深度保存列宽。每列右边界独立调整左侧列，宽度在同一窗口内跨目录导航和重新扫描保留，关闭窗口后恢复默认值。

当前 `EventValidator` 与 `ScanCoordinator` 已作为独立服务并有测试覆盖；FSEvents 流重放和分支刷新接入由后续增量同步阶段负责。

## 主要类型

- `ClearXApp`：应用和依赖入口。
- `ResultWindowSession`：结果窗口的会话缓存加载、完整扫描与进度协调。
- `InMemoryScanCache`：按扫描根路径复用当前应用进程内的完整结果。
- `LiveScanTree`：单次扫描的可浏览增量树；不完整结果不会进入会话缓存。
- `ScanSource`、`ScanNodeSummary`、`ScanPresentationState`：领域模型。
- `FileTreeScanner`：文件系统遍历与大小聚合。
- `ProgressPublisher`：独立于扫描 worker，每 2 秒从扫描 actor 拉取一次增量并负责首帧、末帧即时发布。
- `ScanPerformanceDiagnostics`：按需采集扫描阶段耗时、队列积压、进度发布和进程内存，并通过统一日志输出；不记录扫描路径或文件名。
- `EventValidator`：FSEvents 检查点与缓存有效性判定。
- `ScanCoordinator`：全局有界扫描调度。

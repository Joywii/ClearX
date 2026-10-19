# ClearX 代码结构

## 顶层目录

- `ClearX/App/`：应用入口、SwiftUI Scene 和依赖组装。
- `ClearX/Domain/`：不依赖 SwiftUI 的值类型、状态、协议和错误。
- `ClearX/Services/`：扫描树、会话缓存、来源发现、全局调度与性能诊断服务。
- `ClearX/Features/SourceSelection/`：从文件菜单按需打开的扫描源选择页面及状态模型。
- `ClearX/Features/Results/`：独立结果窗口、多列浏览器及状态模型。
- `ClearX/Shared/`：格式化和通用 SwiftUI 组件。
- `ClearX/Resources/`：本地化与资源。
- `ClearXTests/`：领域、服务和状态模型测试。
- `Tools/ScanBenchmark.swift`：独立编译的优化构建基准入口，生成固定磁盘目录、测量真实扫描及百万节点缓存首列查询；不进入 App target。

## 状态流

`ClearXApp` 的默认 Scene 为本机磁盘结果窗口。`MachineDiskModel` 异步调用 `SourceCatalog.machineDiskSource()` 校验并解析固定根 URL `/`，成功后由 `MachineDiskContainer` 创建 `ResultWindowContainer` 自动扫描；失败显示重试，不回退其他来源。`ScanSourceCommands` 从文件菜单打开本机窗口或按需打开 `SourceSelectionView`，后者创建或选择 `ScanSource` 后打开对应的独立结果窗口。托管 XCTest 不创建这些扫描界面，避免宿主启动全盘扫描。

`ResultWindowSession` 先从 `InMemoryScanCache` 读取当前会话的完整结果；未命中时，调用 `ScanCoordinator` 调度 `FileTreeScanner`。扫描器直接写入一个共享 `ScanTreeStore`，`InMemorySnapshotColumnLoader` 从同一 actor 按页读取当前可见列，`ScanProgress` 仅触发可见列失效刷新。窗口消失时取消其扫描任务，最后一个使用该来源的窗口关闭时释放完整会话缓存。

首列由 `ResultWindowSession` 在显示快照就绪后加载，`ResultWindowView` 不再独立启动重复的初始查询。根目录 worker 将第一层条目写入并完成枚举状态后，立即发布轻量进度，再入队子目录；首列不等待 2 秒周期或后代大小计算。来源校验、初始首列和子列加载期间保持空白布局，不显示骨架或准备页。`SnapshotBrowserColumn.showsEmptyFolder` 仅在确认完整、可读且总子项数为零时显示空目录提示。`FileTreeScannerTests` 覆盖真实临时目录经共享快照到浏览模型的首列发布顺序、待计算目录和空根目录；`ScanPresentationTests` 覆盖未完成或不可读列不误报为空。

重新完整扫描会创建独立候选 `ScanTreeStore`。已有完整结果继续显示到候选完整结束；候选取消、不完整或失败时释放候选并保留旧快照。首次扫描没有旧快照时，可浏览不完整的候选结果，但它不会进入缓存。

`ResultWindowView` 在窗口级 `@State` 中按浏览深度保存列宽。每列右边界独立调整左侧列，宽度在同一窗口内跨目录导航和重新扫描保留，关闭窗口后恢复默认值。

只有点击当前最后一列中的目录才通过 `BrowserColumnRevealState` 创建一次性横向定位请求；资格按点击瞬间的列数判断，不按视口最右可见列或导航截断后的列数判断。点击前面的列或非目录项会取消旧请求，不发起新定位。子列加载完成且布局中的父节点 ID 匹配后，仅在遮挡时最小距离滚动；超宽子列左对齐，不改变列宽。`BrowserColumnFramesKey` 仅收集列边界，不保存额外节点。`BrowserHorizontalScrollInput` 在浏览器内部观察横向滚轮、触控板及横向滚动条输入，取消待执行定位，卸载时移除事件监听；扫描刷新、分页和列宽变化不会独立发起定位。`BrowserColumnRevealTests` 覆盖末列触发限制、可见性、超宽列、请求失效及输入优先级；快速连续选择由模型的查询代次隔离。

点击导航前，`BrowserViewportRetention` 根据首列位置与视口宽度保留最小内容宽度，避免分支缩短时滚动容器自动回退；右侧仅留布局空白，不保留已移除列及其页面。下一次点击按当时位置重算，导航清空或视图卸载时释放。`ResultBrowserModel.select` 在首次异步等待前一次性发布子列加载槽位，不先删列再追加；重复选择同一目录复用紧邻子列的已加载前缀并截断更深导航，加载失败移除占位并允许重试。子列内部滚动视图以父节点 ID 标识，切换目录重置纵向位置，同目录刷新保持位置。模型测试覆盖挂起加载、过期请求与分页保留；托管 SwiftUI 窗口测试通过行按钮验证切换目录和文件后横向偏移不变。

分隔线手势在固定浏览器视口的命名坐标系中计算位移，`BrowserColumnResizeDrag` 固定起始宽度并进行限宽，避免分隔线自身移动反馈到拖动坐标。相同宽度在写入窗口状态前被过滤；手势结束提交末次位移，取消或移除时清理临时状态。列宽更新不触发扫描、快照查询或导航重置；拖动计算的连续更新、反向限宽和新手势起点由 `ResultBrowserModelTests` 覆盖。

扫描批次向祖先传播已知大小和不完整标记，使相关父子索引排序失效。浏览器刷新可见列的已加载前缀，按当前大小重排并以节点 ID 保持选中项；封存时刷新全部打开列以停止估算标记。重扫成功切换快照时重置旧节点导航，重扫不完整时保留旧导航。

持久化、GRDB、FSEvents 流重放和分支刷新不在当前代码中，统一作为后续 TODO 保留。

## 主要类型

- `ClearXApp`：应用和依赖入口。
- `MachineDiskModel`：本机来源解析的空闲、加载、成功与失败状态，防重复加载，支持显式重试和取消。`MachineDiskModelTests` 覆盖默认根与卷身份、重复加载、失败不回退、重试及取消。
- `SourceCatalog.machineDiskSource()`：校验启动根目录的目录类型、本地卷属性与文件系统身份，不依赖其他卷的发现顺序；已有扫描器挂载点规则不变。
- `ResultWindowSession`：结果窗口的会话缓存加载、完整扫描与进度协调。
- `ResultBrowserModel`：分页与导航状态、可见列刷新、当前结果是否为旧完整快照，以及全局异常提示策略。
- `ScanNodeRowView` / `ScanNodeRowPresentation`：紧凑单行、按扫描状态和节点类型统一着色，以及待计算、估算、不完整和硬链接的文字与无障碍语义。
- `ByteCountPresentation`：由 Foundation 选择和本地化字节单位，再从原始字节转换数值，最多显示一位小数；`ByteCountPresentationTests` 覆盖不同量级、本地化及避免二次舍入。
- `InMemoryScanCache`：按扫描根路径复用当前应用进程内的完整结果。
- `DisplayedScanSnapshot`：结果窗口当前显示的快照引用，可在旧完整树与候选树之间切换。
- `ScanTreeStore`：单次扫描的唯一节点所有者，维护节点定位与父子 ID 索引，提供分页查询、惰性排序、聚合和轻量进度失效。
- `ScanNodeSummary.allocatedSize` 是按路径累计的内容大小；`isHardLink` 只标记共享数据，不将后遇到的路径归零。`ScanTreeStore` 额外保留一个 `uniqueAllocatedSize` 标量，仅在全扫描汇总中按设备号和 inode 去重。诊断节点数组包含硬链接时必须显式提供去重汇总。
- `ScanSizeSummary` 在根分页查询中原子返回内容大小、去重大小和快照状态，经 `InMemorySnapshotColumnLoader` 存在首列；`ResultBrowserModel` 从首列派生摘要，`ResultWindowView` 的“大小统计”弹层按需展示口径与限制。旧结果重扫继续读取旧快照摘要，候选不混入。子列、进度和 `ScanResult` 不复制整树或增加第二套聚合树。
- `ScanSource`、`ScanNodeSummary`、`ScanPresentationState`：领域模型。
- `ScanNodeKind.symbolicLink`、`.mountPoint`：保留但不遍历的扫描边界；`ScanTreeStore.apply` 写入零大小叶节点，不创建目录任务。浏览器不为其加载下一列，行说明区分符号链接、挂载点和重复硬链接。测试覆盖根目录单层条目完整性、断链、循环链接与边界不计数、不调度。
- `FileTreeScanner`：文件系统遍历与大小聚合。
- `ScanMountPoints`（位于 `FileTreeScanner.swift`）：单次扫描共享的不可变挂载点 URL 集合，通过线程安全的 `getmntinfo_r_np` 读取，保留隐藏卷并统一目录尾斜杠表示。读取受全局扫描许可约束，失败抛出 `ScanMountTableError`，不降级为仅按设备号扫描。`ScanTreeStore.apply` 同时检查设备号和挂载点精确匹配；扫描根独立初始化，不被自己的挂载点条目拦截。测试覆盖同设备号边界、根目录例外、嵌套挂载点、路径精确匹配、并发读取和读取失败。
- `FileTreeScanner.directoryContents(at:)`：统一枚举和元数据读取的路径语义，去除目录 URL 的尾斜杠提示，避免 macOS `/.nofollow/` 被当作根目录别名；扫描器测试同时覆盖系统入口单层枚举和普通同名隐藏目录的父子关系。
- `DirectoryWork` / `DirectoryWorkQueue`：工作 URL 在构造时规范化一次，队列索引复用该 URL，并只在焦点切换时更新焦点路径字符串。
- `ProgressPublisher`：常规刷新独立于扫描 worker，每 2 秒从扫描 actor 拉取计数与变化 ID；根目录第一层枚举完成后由 worker 即时发布，末帧也即时发布，不逐目录强制刷新。
- `ScanPerformanceDiagnostics`：按需采集扫描阶段耗时、队列积压、进度发布与 250ms 峰值物理内存，并通过统一日志输出；不记录扫描路径或文件名。
- `ScanCoordinator`：所有窗口共享的最多 4 个元数据任务调度器。

扫描性能回归覆盖目录批次及祖先聚合、硬链接跨批次去重汇总与顺序无关的内容大小、取消不重复累计、隐藏文件与包目录，以及规范化路径下的焦点队列公平性。`ScanPresentationTests` 覆盖大小文本、硬链接共享说明与全局提示策略；`ResultBrowserModelTests` 覆盖动态排序、分页去重、选中项保持及封存后刷新；`InMemoryScanCacheTests` 覆盖摘要与显示快照一致、候选重扫不污染旧汇总和最后窗口释放。基准命令与测量结果见 `docs/TECHNICAL_DESIGN.md`。

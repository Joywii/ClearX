# ClearX 技术设计

ClearX 使用 SwiftUI、Swift Concurrency 和 Foundation/CoreServices FSEvents。长期持久化设计见 [2026-08-03-clearx-design.md](superpowers/specs/2026-08-03-clearx-design.md)。

## 执行原则

- MVP 默认使用 `InMemoryScanCache`，完整扫描结果只保留在当前进程内，不写 SQLite。
- 目录枚举使用焦点路径与普通 BFS 两个环形 FIFO 队列；焦点切换时按节点索引懒提升目标目录，随后发现的后代进入焦点队列。连续处理 8 个焦点目录后至少处理 1 个普通目录，避免后台任务饥饿。
- 文件大小仅累加到直接父目录；子目录完成后向父目录提交一次聚合大小。取消时对未完成目录进行一次自底向上的部分结果归并。
- 扫描器首帧立即发布；扫描 worker 只更新 `ScanAccumulator`，独立 reporter 每 2 秒从 actor 拉取一次节点增量，完成或取消时停止 reporter 并立即拉取末帧。进度链路不按目录提交，也不在 publisher 中反复合并 pending 数组；UI 仅合并当前可见列，扫描中不重排，目录完成后再按大小排序。
- 扫描和内存节点仅保存系统提供的已分配大小；不读取或聚合逻辑大小。
- 扫描与事件处理不运行在主 actor。
- 缓存仅在设备级 FSEvents 重放成功且无变更时直接采用；普通事件 ID 跳跃不代表事件丢失，只有流丢失、重置或回绕、UUID 不匹配和危险标志才完整重扫。

## 权限与性能

MVP 不启用 App Sandbox，仍尊重 macOS 文件权限和 TCC。会话缓存不写入 Application Support，也不会跨启动保留。跨启动持久化缓存的预算、淘汰与性能目标在该能力重新引入时确定。

设置环境变量 `CLEARX_SCAN_METRICS=1` 后，扫描器以 `CLEARX_SCAN` 为前缀输出性能诊断日志。诊断分别统计目录列举、逐项 `lstat`、全局许可等待、扫描 actor 应用与目录完成、队列调用、reporter 进度快照与 UI sink，并记录发布次数、快照节点数、队列峰值、最慢目录特征、最终吞吐和进程物理内存。兼容日志中的 `merge_ms` 和 `pending_nodes_max` 固定为零，用于确认逐目录合并链路未重新引入。日志仅包含扫描 ID、深度、数量和耗时，不记录扫描根路径、文件名或目录名。每个 worker 每完成 10000 个目录输出一次检查点，扫描结束输出完整汇总。

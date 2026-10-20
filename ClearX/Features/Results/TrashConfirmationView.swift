import SwiftUI

struct TrashConfirmationView: View {
    @ObservedObject var operation: TrashOperationModel
    let root: URL

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(operation.report == nil ? "移到废纸篓" : "操作结果").font(.headline)
            if let report = operation.report {
                Text("成功 \(report.succeeded.count) 项，失败 \(report.failures.count) 项，未处理 \(report.unprocessed) 项。")
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(Array(report.failures.enumerated()), id: \.offset) { _, failure in
                            Text(failure.url.path + "\n" + failure.reason).textSelection(.enabled)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
            } else if let error = operation.error {
                Text(error).foregroundStyle(.secondary).textSelection(.enabled)
            } else if operation.targets.isEmpty {
                ProgressView("正在检查项目…")
            } else {
                Text("将 \(operation.targets.count) 项移到废纸篓？")
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(operation.targets) { target in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(target.node.name).bold()
                                Text(target.node.url.path).foregroundStyle(.secondary).textSelection(.enabled)
                            }
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
                Text("目录将连同全部内容一起移动，包括未扫描或无法读取的内容。符号链接只移动链接本身。移到废纸篓不会立即释放磁盘空间。")
                    .font(.callout).foregroundStyle(.secondary)
            }
            if operation.isRunning {
                ProgressView(value: Double(operation.completedCount), total: Double(max(1, operation.targets.count)))
                Text("已处理 \(operation.completedCount) / \(operation.targets.count) 项")
                Button("停止剩余操作", action: operation.stop)
                Text("当前一项完成后停止，不撤销已完成操作。").font(.caption).foregroundStyle(.secondary)
            } else {
                HStack {
                    Spacer()
                    Button(operation.report == nil ? "取消" : "关闭", action: operation.dismiss)
                        .keyboardShortcut(.defaultAction)
                    if operation.report == nil, operation.error == nil, !operation.targets.isEmpty {
                        Button("将 \(operation.targets.count) 项移到废纸篓", role: .destructive) {
                            operation.confirm(root: root)
                        }
                    }
                }
            }
        }
        .padding(22)
        .frame(width: 540, height: 420)
        .interactiveDismissDisabled()
        .onExitCommand { operation.dismiss() }
    }
}

import SwiftUI

struct ScanNodeRowPresentation {
    let node: ScanNodeSummary
    let isEstimating: Bool
    let isPending: Bool

    func textColor(for colorScheme: ColorScheme) -> Color {
        if isEstimating || isPending { return .red }
        guard node.kind == .directory || node.kind == .mountPoint else { return .primary }
        return colorScheme == .dark
            ? Color(red: 0.45, green: 0.78, blue: 0.65)
            : Color(red: 0.16, green: 0.36, blue: 0.29)
    }

    var sizeText: String {
        if node.isIncomplete {
            return ByteCountPresentation.string(for: node.allocatedSize) + "+"
        }
        if isPending { return "" }
        return ByteCountPresentation.string(for: node.allocatedSize)
    }

    var sizeDescription: String {
        if node.isIncomplete {
            return node.allocatedSize == 0 ? "大小未知，结果不完整" : "至少 \(ByteCountPresentation.string(for: node.allocatedSize))，结果不完整"
        }
        if isPending { return "尚未开始计算" }
        if isEstimating { return "\(sizeText)，仍在计算" }
        if node.kind == .symbolicLink { return "符号链接，未跟随目标，不计入扫描大小" }
        if node.kind == .mountPoint { return "挂载点：本次未扫描其内容，不计入扫描大小" }
        if node.isHardLink { return "\(sizeText)，硬链接，共享同一文件数据；此处按路径计入内容大小" }
        return sizeText
    }
}

struct ScanNodeRowView: View {
    static let sizeColumnWidth: CGFloat = 64
    static let contentSpacing: CGFloat = 6
    static let horizontalInset: CGFloat = 4
    static let minimumSizeScale: CGFloat = 0.75

    @Environment(\.colorScheme) private var colorScheme
    let node: ScanNodeSummary
    let isSelected: Bool
    let isEstimating: Bool
    let isPending: Bool

    private var presentation: ScanNodeRowPresentation {
        ScanNodeRowPresentation(node: node, isEstimating: isEstimating, isPending: isPending)
    }

    var body: some View {
        HStack(spacing: Self.contentSpacing) {
            Text(presentation.sizeText)
                .monospacedDigit()
                .lineLimit(1)
                // Keep units and the incomplete suffix on one line without shifting names.
                .minimumScaleFactor(Self.minimumSizeScale)
                .frame(width: Self.sizeColumnWidth, alignment: .trailing)
            Text(node.name)
                .italic(node.kind == .symbolicLink)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
            if node.kind == .directory {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
            }
        }
        .font(.system(size: 12, design: .monospaced))
        .foregroundStyle(isSelected ? Color.white : presentation.textColor(for: colorScheme))
        .padding(.horizontal, Self.horizontalInset)
        .padding(.vertical, 3)
        .background(isSelected ? Color.accentColor : .clear)
        .contentShape(.rect)
        .help(node.name + "：" + presentation.sizeDescription)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(node.name)
        .accessibilityValue(presentation.sizeDescription)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

}

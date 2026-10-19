import Foundation

enum ByteCountPresentation {
    static func string(for byteCount: Int64, locale: Locale = .autoupdatingCurrent) -> String {
        var formatted = ByteCountFormatStyle(style: .file, spellsOutZero: false, locale: locale).attributed.format(byteCount)
        for run in formatted.runs {
            guard case let .unit(unit) = run.byteCount else { continue }
            let storageUnit: UnitInformationStorage
            switch unit {
            case .byte: storageUnit = .bytes
            case .kb: storageUnit = .kilobytes
            case .mb: storageUnit = .megabytes
            case .gb: storageUnit = .gigabytes
            case .tb: storageUnit = .terabytes
            case .pb: storageUnit = .petabytes
            case .eb: storageUnit = .exabytes
            case .zb: storageUnit = .zettabytes
            case .yb: storageUnit = .yottabytes
            @unknown default: return String(formatted.characters)
            }
            // Reformat from the original bytes, not the already rounded text.
            // Foundation still owns unit selection, conversion, and localization.
            let value = Measurement(value: Double(byteCount), unit: UnitInformationStorage.bytes)
                .converted(to: storageUnit).value
            let number = value.formatted(.number
                .precision(.fractionLength(0...1))
                .rounded(rule: .toNearestOrAwayFromZero)
                .locale(locale))
            if let valueRun = formatted.runs[\.byteCount].first(where: { $0.0 == .value }) {
                formatted.replaceSubrange(valueRun.1, with: AttributedString(number))
            }
            break
        }
        return String(formatted.characters)
    }
}

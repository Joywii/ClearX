import SwiftUI

struct ProgressFractionView: View {
    let fraction: Double

    var body: some View {
        GeometryReader { proxy in
            let clampedFraction = min(max(fraction, 0), 1)

            Capsule()
                .fill(.quaternary)
                .overlay(alignment: .leading) {
                    Capsule()
                        .fill(.tint)
                        .frame(width: proxy.size.width * clampedFraction)
                }
        }
        .frame(height: 4)
        .accessibilityValue(Text("\(Int(min(max(fraction, 0), 1) * 100))%"))
    }
}

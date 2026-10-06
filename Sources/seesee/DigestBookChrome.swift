import SwiftUI

enum DigestBookChrome {
    static let minColumnWidth: CGFloat = 232
    static let minActionHit: CGFloat = 22
    static let headerHorizontalPadding: CGFloat = 12
}

enum DigestBookHitKey: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]

    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, next in next })
    }
}

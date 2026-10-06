import AppKit

@main
struct DigestHoverCheck {
    static func main() {
        precondition(DigestBookChrome.minActionHit >= 22, "划线命中区须至少 22 点")
        precondition(DigestBookChrome.highlightMarkWidth == 2)
        precondition(DigestBookChrome.highlightTitle == "划线")
        precondition(DigestBookChrome.unhighlightTitle == "取消划线")
        precondition(DigestBookChrome.entryTitle(0) == "划线 0")
        precondition(DigestBookChrome.entryTitle(3) == "划线 3")

        precondition(
            DigestHoverTracking.options.contains(.activeAlways),
            "悬停须在非 key window 与自动化下同样触发"
        )
        precondition(DigestHoverTracking.options.contains(.mouseEnteredAndExited))
        precondition(DigestHoverTracking.options.contains(.inVisibleRect))
        precondition(
            !DigestHoverTracking.options.contains(.activeWhenFirstResponder),
            "不得要求第一响应者才追踪"
        )

        let view = DigestHoverProbeView()
        view.frame = NSRect(x: 0, y: 0, width: 240, height: 44)
        view.updateTrackingAreas()
        precondition(!view.trackingAreas.isEmpty, "必须装上追踪区域")
        let options = view.trackingAreas[0].options
        precondition(
            options.contains(.activeAlways),
            "探针追踪区域必须 activeAlways，实际 \(options.rawValue)"
        )

        print("digest_hover_check=passed")
    }
}

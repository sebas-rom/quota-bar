import Foundation
import CoreGraphics

// Lists on-screen QuotaBar windows: "<number>\t<width>x<height>".
// Used by scripts/capture-ui.sh to address windows without Accessibility APIs.

let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
guard let windows = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
    exit(1)
}
for window in windows {
    guard (window[kCGWindowOwnerName as String] as? String) == "QuotaBar" else { continue }
    let number = window[kCGWindowNumber as String] as? Int ?? 0
    let bounds = window[kCGWindowBounds as String] as? [String: Any] ?? [:]
    let width = bounds["Width"] as? Double ?? 0
    let height = bounds["Height"] as? Double ?? 0
    guard width > 40, height > 40 else { continue }
    print("\(number)\t\(Int(width))x\(Int(height))")
}

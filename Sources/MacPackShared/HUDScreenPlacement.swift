import CoreGraphics
import Foundation

public enum HUDScreenPlacement {
    public static func origin(
        visibleFrame: CGRect,
        windowSize: CGSize,
        margin: CGFloat
    ) -> CGPoint {
        let maximumX = visibleFrame.maxX - windowSize.width
        let maximumY = visibleFrame.maxY - windowSize.height
        let desiredX = maximumX - margin
        let desiredY = maximumY - margin

        return CGPoint(
            x: floor(clamp(desiredX, lower: visibleFrame.minX, upper: maximumX)),
            y: floor(clamp(desiredY, lower: visibleFrame.minY, upper: maximumY))
        )
    }

    private static func clamp(
        _ value: CGFloat,
        lower: CGFloat,
        upper: CGFloat
    ) -> CGFloat {
        guard upper >= lower else { return lower }
        return min(max(value, lower), upper)
    }
}

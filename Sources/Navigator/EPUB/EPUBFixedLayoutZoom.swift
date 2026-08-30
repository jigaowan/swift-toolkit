//
//  Copyright 2026 Readium Foundation. All rights reserved.
//  Use of this source code is governed by the BSD-style license
//  available in the top-level LICENSE file of the project.
//

import UIKit

/// The zoom state of the currently visible fixed-layout spread.
public struct EPUBFixedLayoutZoomState: Equatable, Sendable {
    /// The zoom scale relative to the fitted spread. A value of `1` is fit.
    public let scale: CGFloat

    /// Whether the spread is enlarged beyond its fitted size.
    public var isZoomed: Bool {
        scale > 1.001
    }
}

/// A rendered snapshot of the currently visible fixed-layout spread.
public struct EPUBFixedLayoutSnapshot {
    public let image: UIImage

    /// Frame of the snapshot in the navigator view's coordinate space.
    public let frame: CGRect
}

/// Public fixed-layout zoom operations supported by the EPUB navigator.
///
/// Coordinates are expressed in the navigator view's coordinate space. The
/// rendered spread remains the only zoomed object; pagination and surrounding
/// application UI are never transformed.
@MainActor public protocol EPUBFixedLayoutZooming: AnyObject {
    var fixedLayoutZoomState: EPUBFixedLayoutZoomState { get }

    /// Zooms the visible fixed-layout spread around `point`.
    func zoomFixedLayout(
        to scale: CGFloat,
        at point: CGPoint,
        animated: Bool
    )

    /// Restores the visible fixed-layout spread to its fitted size.
    func resetFixedLayoutZoom(animated: Bool)

    /// Installs an app-owned overlay which follows the fixed spread's zoom and
    /// pan geometry. Passing `nil` removes the overlay.
    func setFixedLayoutOverlayView(_ view: UIView?)

    /// Suspends one-finger page and content panning while an app-owned
    /// interaction, such as Live Text selection, is active. Pinch zoom remains
    /// available and can cancel the app-owned interaction.
    func setFixedLayoutContentInteractionSuspended(_ suspended: Bool)

    /// Captures the currently visible fixed-layout spread.
    func makeFixedLayoutSnapshot() async throws -> EPUBFixedLayoutSnapshot?
}

enum EPUBFixedLayoutZoomMath {
    static func targetRect(
        targetScale: CGFloat,
        contentPoint: CGPoint,
        viewportAnchor: CGPoint,
        visibleSize: CGSize
    ) -> CGRect {
        let targetScale = max(targetScale, 0.001)
        return CGRect(
            x: contentPoint.x - viewportAnchor.x / targetScale,
            y: contentPoint.y - viewportAnchor.y / targetScale,
            width: visibleSize.width / targetScale,
            height: visibleSize.height / targetScale
        )
    }

    static func fittedInsets(
        contentSize: CGSize,
        visibleSize: CGSize,
        fittedFrame: CGRect
    ) -> UIEdgeInsets {
        let horizontal = axisInsets(
            contentLength: contentSize.width,
            visibleLength: visibleSize.width,
            fittedOrigin: fittedFrame.minX,
            fittedLength: fittedFrame.width
        )
        let vertical = axisInsets(
            contentLength: contentSize.height,
            visibleLength: visibleSize.height,
            fittedOrigin: fittedFrame.minY,
            fittedLength: fittedFrame.height
        )
        return UIEdgeInsets(
            top: vertical.leading,
            left: horizontal.leading,
            bottom: vertical.trailing,
            right: horizontal.trailing
        )
    }

    private static func axisInsets(
        contentLength: CGFloat,
        visibleLength: CGFloat,
        fittedOrigin: CGFloat,
        fittedLength: CGFloat
    ) -> (leading: CGFloat, trailing: CGFloat) {
        let remainingSpace = max(visibleLength - contentLength, 0)
        guard remainingSpace > 0 else { return (0, 0) }

        let fittedSpace = max(visibleLength - fittedLength, 0)
        guard fittedSpace > 0.5 else {
            return (remainingSpace / 2, remainingSpace / 2)
        }

        let leadingRatio = min(max(fittedOrigin / fittedSpace, 0), 1)
        let leading = remainingSpace * leadingRatio
        return (leading, remainingSpace - leading)
    }
}

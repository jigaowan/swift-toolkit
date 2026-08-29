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
        currentScale: CGFloat,
        targetScale: CGFloat,
        contentOffset: CGPoint,
        anchor: CGPoint,
        visibleSize: CGSize
    ) -> CGRect {
        let currentScale = max(currentScale, 0.001)
        let targetScale = max(targetScale, 0.001)
        let contentPoint = CGPoint(
            x: (contentOffset.x + anchor.x) / currentScale,
            y: (contentOffset.y + anchor.y) / currentScale
        )
        let targetOffset = CGPoint(
            x: contentPoint.x * targetScale - anchor.x,
            y: contentPoint.y * targetScale - anchor.y
        )
        return CGRect(
            x: targetOffset.x / targetScale,
            y: targetOffset.y / targetScale,
            width: visibleSize.width / targetScale,
            height: visibleSize.height / targetScale
        )
    }

    static func clampedOffset(
        _ proposed: CGFloat,
        contentOrigin: CGFloat,
        contentLength: CGFloat,
        visibleLength: CGFloat,
        maximumOffset: CGFloat
    ) -> CGFloat {
        let pageBounded: CGFloat
        if contentLength <= visibleLength + 0.5 {
            pageBounded = contentOrigin + (contentLength - visibleLength) / 2
        } else {
            pageBounded = min(
                max(proposed, contentOrigin),
                contentOrigin + contentLength - visibleLength
            )
        }
        return min(max(pageBounded, 0), maximumOffset)
    }
}

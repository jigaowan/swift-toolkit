//
//  Copyright 2026 Readium Foundation. All rights reserved.
//  Use of this source code is governed by the BSD-style license
//  available in the top-level LICENSE file of the project.
//

import Foundation
import ReadiumShared
import UIKit
import WebKit

/// A view rendering a spread of resources with a fixed layout.
final class EPUBFixedSpreadView: EPUBSpreadView {
    private static let minimumZoomScale: CGFloat = 1
    private static let maximumZoomScale: CGFloat = 4
    private static let zoomTolerance: CGFloat = 0.001

    /// Whether the host wrapper page is loaded or not. The wrapper page contains the iframe that will display the resource.
    private var isWrapperLoaded = false
    /// URL to load in the iframe once the wrapper page is loaded.
    private var urlToLoad: URL?

    /// A page-scoped zoom surface. It contains only the rendered fixed spread,
    /// never the paginator or application chrome.
    private let zoomScrollView = UIScrollView()
    private let zoomContentView = UIView()
    private var pageContentFrame: CGRect?
    private var lastViewportSize = CGSize.zero
    private var isClampingContentOffset = false
    private var isContentInteractionSuspended = false
    private weak var overlayView: UIView?

    private static let fixedScript = loadScript(named: "readium-fixed")

    required init(
        viewModel: EPUBNavigatorViewModel,
        spread: EPUBSpread,
        scripts: [WKUserScript],
        animatedLoad: Bool
    ) {
        var scripts = scripts
        scripts.append(WKUserScript(source: Self.fixedScript, injectionTime: .atDocumentStart, forMainFrameOnly: false))

        super.init(viewModel: viewModel, spread: spread, scripts: scripts, animatedLoad: animatedLoad)
    }

    override func setupWebView() {
        super.setupWebView()

        clipsToBounds = true
        webView.clipsToBounds = true

        // WebKit still applies the publication's fitted viewport scale, but
        // all user zoom and pan happen in the page-scoped outer scroll view.
        // This avoids depending on WebKit's private zooming view.
        scrollView.clipsToBounds = true
        scrollView.bounces = false
        scrollView.bouncesZoom = false
        scrollView.panGestureRecognizer.isEnabled = false
        scrollView.pinchGestureRecognizer?.isEnabled = false

        zoomScrollView.frame = bounds
        zoomScrollView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        zoomScrollView.delegate = self
        zoomScrollView.minimumZoomScale = Self.minimumZoomScale
        zoomScrollView.maximumZoomScale = Self.maximumZoomScale
        zoomScrollView.bounces = false
        zoomScrollView.bouncesZoom = false
        zoomScrollView.alwaysBounceHorizontal = false
        zoomScrollView.alwaysBounceVertical = false
        zoomScrollView.showsHorizontalScrollIndicator = false
        zoomScrollView.showsVerticalScrollIndicator = false
        zoomScrollView.contentInsetAdjustmentBehavior = .never
        zoomScrollView.panGestureRecognizer.isEnabled = false

        zoomContentView.frame = bounds
        zoomScrollView.addSubview(zoomContentView)

        webView.removeFromSuperview()
        webView.frame = zoomContentView.bounds
        webView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        zoomContentView.addSubview(webView)
        addSubview(zoomScrollView)

        updateBackgroundColor(viewModel.settings.effectiveBackgroundColor.uiColor)

        // Loads the wrapper page into the web view.
        let spreadFile = "fxl-spread-\(viewModel.spreadEnabled ? "two" : "one")"
        if
            let wrapperPageURL = Bundle.module.url(forResource: spreadFile, withExtension: "html", subdirectory: "Assets"),
            var wrapperPage = try? String(contentsOf: wrapperPageURL, encoding: .utf8)
        {
            wrapperPage = wrapperPage.replacingOccurrences(
                of: "{{ASSETS_URL}}",
                with: viewModel.assetsBaseURL.string
            )

            // The publication's base URL is used to make sure we can access the resources through the iframe with JavaScript.
            webView.loadHTMLString(wrapperPage, baseURL: viewModel.publicationBaseURL.url)
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()

        let sizeChanged = zoomContentView.bounds.size != bounds.size
        if sizeChanged {
            zoomScrollView.setZoomScale(Self.minimumZoomScale, animated: false)
            zoomScrollView.contentOffset = .zero
            zoomScrollView.panGestureRecognizer.isEnabled = false
            zoomContentView.frame = CGRect(origin: .zero, size: bounds.size)
            zoomScrollView.contentSize = bounds.size
        } else if !fixedLayoutZoomState.isZoomed {
            zoomContentView.frame = CGRect(origin: .zero, size: bounds.size)
            zoomScrollView.contentSize = bounds.size
        }
        zoomScrollView.frame = bounds
        webView.frame = zoomContentView.bounds
        overlayView?.frame = webView.frame

        layoutSpread()
    }

    override func safeAreaInsetsDidChange() {
        super.safeAreaInsetsDidChange()
        layoutSpread()
    }

    func updateBackgroundColor(_ color: UIColor) {
        isOpaque = true
        backgroundColor = color
        zoomScrollView.isOpaque = true
        zoomScrollView.backgroundColor = color
        zoomContentView.isOpaque = true
        zoomContentView.backgroundColor = color
        webView.isOpaque = true
        webView.backgroundColor = color
        scrollView.backgroundColor = color
    }

    /// Layouts the resource to fit its content in the bounds.
    private func layoutSpread() {
        guard isWrapperLoaded else {
            return
        }

        var insets = delegate?.spreadViewContentInset(self) ?? .zero

        // Use the same insets on the left and right side (the largest one) to
        // keep the pages centered on the screen even if the notches are not
        // symmetrical.
        let horizontalInsets = max(insets.left, insets.right)
        insets.left = horizontalInsets
        insets.right = horizontalInsets

        let viewportSize = bounds.inset(by: insets).size
        let fitString = viewModel.settings.fit.rawValue
        let viewportChanged = viewportSize != lastViewportSize
        lastViewportSize = viewportSize

        webView.evaluateJavaScript("""
            spread.setViewport(
                {'width': \(Int(viewportSize.width)), 'height': \(Int(viewportSize.height))},
                {'top': \(Int(insets.top)), 'left': \(Int(insets.left)), 'bottom': \(Int(insets.bottom)), 'right': \(Int(insets.right))},
                '\(fitString)'
            );
        """) { [weak self] _, _ in
            DispatchQueue.main.async {
                self?.configureZoomAfterLayout(reset: viewportChanged)
            }
        }
    }

    override func loadSpread() {
        guard isWrapperLoaded else {
            return
        }
        // We call this directly on the web view on purpose, because this needs
        // to be executed before the spread is loaded.
        let spreadJSON = spread.jsonString(
            forBaseURL: viewModel.publicationBaseURL,
            readingProgression: viewModel.readingProgression
        )
        webView.evaluateJavaScript("spread.load(\(spreadJSON));")
    }

    override func spreadDidLoad() async {
        configureZoomAfterLayout(reset: true)
        for continuation in goToContinuations {
            continuation.resume()
        }
        goToContinuations.removeAll()
    }

    override func evaluateScript(_ script: String, inHREF href: AnyURL? = nil) async -> Result<Any, any Error> {
        let href = href?.string ?? ""
        let script = "spread.eval('\(href)', `\(script.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "`", with: "\\`")));"
        return await super.evaluateScript(script)
    }

    override func convertPointToNavigatorSpace(_ point: CGPoint) -> CGPoint {
        let pointAtFit = CGPoint(
            x: point.x * scrollView.zoomScale - scrollView.contentOffset.x + webView.frame.minX,
            y: point.y * scrollView.zoomScale - scrollView.contentOffset.y + webView.frame.minY
        )
        return CGPoint(
            x: pointAtFit.x * zoomScrollView.zoomScale - zoomScrollView.contentOffset.x + zoomScrollView.frame.minX,
            y: pointAtFit.y * zoomScrollView.zoomScale - zoomScrollView.contentOffset.y + zoomScrollView.frame.minY
        )
    }

    override func convertRectToNavigatorSpace(_ rect: CGRect) -> CGRect {
        var rect = rect
        rect.origin = convertPointToNavigatorSpace(rect.origin)
        let scale = scrollView.zoomScale * zoomScrollView.zoomScale
        rect.size = CGSize(
            width: rect.width * scale,
            height: rect.height * scale
        )
        return rect
    }

    override func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        super.webView(webView, didFinish: navigation)

        webView.removeDoubleTapGestureRecognizer()

        if !isWrapperLoaded {
            isWrapperLoaded = true
            layoutSpread()
            loadSpread()
        }
    }

    // MARK: - Fixed-layout viewport

    var fixedLayoutZoomState: EPUBFixedLayoutZoomState {
        let scale = zoomScrollView.zoomScale
        return EPUBFixedLayoutZoomState(
            scale: abs(scale - 1) <= Self.zoomTolerance ? 1 : scale
        )
    }

    func zoomFixedLayout(to scale: CGFloat, at point: CGPoint, animated: Bool) {
        let targetScale = min(
            max(scale, Self.minimumZoomScale),
            Self.maximumZoomScale
        )
        let currentScale = max(zoomScrollView.zoomScale, Self.minimumZoomScale)
        let pointInScrollView = convert(point, to: zoomScrollView)
        let targetRect = EPUBFixedLayoutZoomMath.targetRect(
            currentScale: currentScale,
            targetScale: targetScale,
            contentOffset: zoomScrollView.contentOffset,
            anchor: pointInScrollView,
            visibleSize: zoomScrollView.bounds.size
        )

        zoomScrollView.panGestureRecognizer.isEnabled = !isContentInteractionSuspended
            && targetScale > 1 + Self.zoomTolerance
        zoomScrollView.zoom(to: targetRect, animated: animated)
        if !animated {
            clampContentOffset()
            viewportDidChange()
        }
    }

    func resetFixedLayoutZoom(animated: Bool) {
        zoomScrollView.panGestureRecognizer.isEnabled = false
        zoomScrollView.setZoomScale(Self.minimumZoomScale, animated: animated)
        if !animated {
            clampContentOffset()
            viewportDidChange()
        }
    }

    func setContentInteractionSuspended(_ suspended: Bool) {
        isContentInteractionSuspended = suspended
        zoomScrollView.panGestureRecognizer.isEnabled = !suspended
            && fixedLayoutZoomState.isZoomed
    }

    func installFixedLayoutOverlayView(_ view: UIView?) {
        if overlayView !== view {
            overlayView?.removeFromSuperview()
        }
        overlayView = view
        guard let view else { return }

        if view.superview !== zoomContentView {
            view.removeFromSuperview()
            zoomContentView.addSubview(view)
        }
        view.transform = .identity
        view.frame = webView.frame
        zoomContentView.bringSubviewToFront(view)
    }

    func makeFixedLayoutSnapshot() async throws -> UIImage {
        let configuration = WKSnapshotConfiguration()
        configuration.afterScreenUpdates = true
        configuration.rect = webView.bounds
        return try await webView.takeSnapshot(configuration: configuration)
    }

    override func spreadViewForZooming(in scrollView: UIScrollView) -> UIView? {
        scrollView === zoomScrollView ? zoomContentView : nil
    }

    override func spreadScrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        guard scrollView === zoomScrollView else { return }
        viewportDidChange()
    }

    override func spreadScrollViewDidScroll(_ scrollView: UIScrollView) {
        guard scrollView === zoomScrollView else { return }
        clampContentOffset()
        viewportDidChange()
    }

    override func spreadScrollViewDidZoom(_ scrollView: UIScrollView) {
        guard scrollView === zoomScrollView else { return }
        if zoomScrollView.zoomScale < Self.minimumZoomScale {
            zoomScrollView.zoomScale = Self.minimumZoomScale
        }
        zoomScrollView.panGestureRecognizer.isEnabled = !isContentInteractionSuspended
            && fixedLayoutZoomState.isZoomed
        clampContentOffset()
        viewportDidChange()
    }

    override func spreadScrollViewDidEndZooming(_ scrollView: UIScrollView) {
        guard scrollView === zoomScrollView else { return }
        if !fixedLayoutZoomState.isZoomed {
            zoomScrollView.zoomScale = Self.minimumZoomScale
            zoomScrollView.panGestureRecognizer.isEnabled = false
        }
        clampContentOffset()
        viewportDidChange()
    }

    private func configureZoomAfterLayout(reset: Bool) {
        guard isWrapperLoaded else { return }
        zoomScrollView.minimumZoomScale = Self.minimumZoomScale
        zoomScrollView.maximumZoomScale = Self.maximumZoomScale
        zoomScrollView.bounces = false
        zoomScrollView.bouncesZoom = false
        if reset {
            zoomScrollView.setZoomScale(Self.minimumZoomScale, animated: false)
            zoomScrollView.contentOffset = .zero
            zoomScrollView.panGestureRecognizer.isEnabled = false
        }
        resolvePageContentFrame()
        clampContentOffset()
        viewportDidChange()
    }

    private func resolvePageContentFrame() {
        webView.evaluateJavaScript("""
            (function() {
                var frames = Array.from(document.querySelectorAll('iframe'))
                    .filter(function(frame) {
                        var style = window.getComputedStyle(frame.closest('.viewport') || frame);
                        return style.display !== 'none';
                    })
                    .map(function(frame) { return frame.getBoundingClientRect(); })
                    .filter(function(rect) { return rect.width > 1 && rect.height > 1; });
                if (!frames.length) { return null; }
                var left = Math.min.apply(null, frames.map(function(rect) { return rect.left; }));
                var top = Math.min.apply(null, frames.map(function(rect) { return rect.top; }));
                var right = Math.max.apply(null, frames.map(function(rect) { return rect.right; }));
                var bottom = Math.max.apply(null, frames.map(function(rect) { return rect.bottom; }));
                return {x: left, y: top, width: right - left, height: bottom - top};
            })();
        """) { [weak self] value, _ in
            guard let self else { return }
            DispatchQueue.main.async {
                self.pageContentFrame = Self.rect(fromJavaScriptValue: value)
                    .map(self.convertRectToFittedSpreadSpace)
                self.clampContentOffset()
                self.viewportDidChange()
            }
        }
    }

    private func convertRectToFittedSpreadSpace(_ rect: CGRect) -> CGRect {
        CGRect(
            x: rect.minX * scrollView.zoomScale - scrollView.contentOffset.x + webView.frame.minX,
            y: rect.minY * scrollView.zoomScale - scrollView.contentOffset.y + webView.frame.minY,
            width: rect.width * scrollView.zoomScale,
            height: rect.height * scrollView.zoomScale
        )
    }

    private func clampContentOffset() {
        guard !isClampingContentOffset, let pageContentFrame else { return }

        let scale = zoomScrollView.zoomScale
        let visibleSize = zoomScrollView.bounds.size
        let proposed = zoomScrollView.contentOffset
        let clamped = CGPoint(
            x: EPUBFixedLayoutZoomMath.clampedOffset(
                proposed.x,
                contentOrigin: pageContentFrame.minX * scale,
                contentLength: pageContentFrame.width * scale,
                visibleLength: visibleSize.width,
                maximumOffset: max(zoomContentView.bounds.width * scale - visibleSize.width, 0)
            ),
            y: EPUBFixedLayoutZoomMath.clampedOffset(
                proposed.y,
                contentOrigin: pageContentFrame.minY * scale,
                contentLength: pageContentFrame.height * scale,
                visibleLength: visibleSize.height,
                maximumOffset: max(zoomContentView.bounds.height * scale - visibleSize.height, 0)
            )
        )

        guard clamped != proposed else { return }
        isClampingContentOffset = true
        zoomScrollView.contentOffset = clamped
        isClampingContentOffset = false
    }

    private func viewportDidChange() {
        delegate?.spreadViewFixedLayoutViewportDidChange(self)
    }

    private static func rect(fromJavaScriptValue value: Any?) -> CGRect? {
        guard let values = value as? [String: Any] else { return nil }
        func number(_ key: String) -> CGFloat? {
            (values[key] as? NSNumber).map { CGFloat(truncating: $0) }
        }
        guard
            let x = number("x"),
            let y = number("y"),
            let width = number("width"),
            let height = number("height"),
            width > 1,
            height > 1
        else {
            return nil
        }
        return CGRect(x: x, y: y, width: width, height: height)
    }

    // MARK: - Location and progression

    private var goToContinuations: [CheckedContinuation<Void, Never>] = []

    override func go(to location: PageLocation, animated: Bool) async {
        // Fixed layout resources are always fully visible so we don't use the
        // location.

        if isSpreadLoaded {
            return
        } else {
            await withCheckedContinuation { continuation in
                goToContinuations.append(continuation)
            }
        }
    }
}

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
    /// Frame of the rendered iframe union in the fitted WKWebView coordinate
    /// space. The outer scroll view zooms only this rectangle.
    private var pageFrameInWebView: CGRect?
    private var lastBoundsSize = CGSize.zero
    private var lastViewportSize = CGSize.zero
    private var lastViewportInsets: UIEdgeInsets?
    private var lastFit: String?
    private var layoutRevision = 0
    private var pendingLayoutRevision: Int?
    private var fittedInnerZoomScale: CGFloat?
    private var fittedInnerContentOffset = CGPoint.zero
    private var isContentInteractionSuspended = false
    private weak var overlayView: UIView?
    private let diagnosticSpreadID = String(UUID().uuidString.prefix(4))
    private var diagnosticPanSequence = 0
    private var diagnosticZoomSequence = 0
    private var lastDiagnosticPanSample = TimeInterval.zero
    private var lastDiagnosticZoomSample = TimeInterval.zero
    private var lastDiagnosticRenderScale: CGFloat?

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
        lockInnerScrollViewInteraction()

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
        zoomScrollView.panGestureRecognizer.addTarget(
            self,
            action: #selector(handleDiagnosticPanState(_:))
        )
        zoomScrollView.pinchGestureRecognizer?.addTarget(
            self,
            action: #selector(handleDiagnosticZoomState(_:))
        )

        zoomContentView.frame = bounds
        zoomContentView.clipsToBounds = true
        zoomScrollView.addSubview(zoomContentView)

        webView.removeFromSuperview()
        webView.frame = zoomContentView.bounds
        webView.autoresizingMask = []
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

        let sizeChanged = lastBoundsSize != bounds.size
        lastBoundsSize = bounds.size
        zoomScrollView.frame = bounds

        if sizeChanged {
            log(
                .info,
                "fixed-zoom layout reset reason=boundsChanged new=\(diagnosticSize(bounds.size)) \(diagnosticGeometry())"
            )
            layoutRevision &+= 1
            pendingLayoutRevision = nil
            pageFrameInWebView = nil
            lastViewportSize = .zero
            lastViewportInsets = nil
            resetZoomForLayout()
            layoutZoomSurface(
                pageFrame: CGRect(origin: .zero, size: bounds.size)
            )
        }

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
            || lastViewportInsets != insets
        let fitChanged = lastFit != fitString

        guard viewportChanged || fitChanged
            || (pageFrameInWebView == nil && pendingLayoutRevision == nil)
        else {
            return
        }

        lastViewportSize = viewportSize
        lastViewportInsets = insets
        lastFit = fitString
        layoutRevision &+= 1
        let revision = layoutRevision
        pendingLayoutRevision = revision

        webView.evaluateJavaScript("""
            spread.setViewport(
                {'width': \(Int(viewportSize.width)), 'height': \(Int(viewportSize.height))},
                {'top': \(Int(insets.top)), 'left': \(Int(insets.left)), 'bottom': \(Int(insets.bottom)), 'right': \(Int(insets.right))},
                '\(fitString)'
            );
        """) { [weak self] _, _ in
            DispatchQueue.main.async {
                guard let self, revision == self.layoutRevision else { return }
                self.pendingLayoutRevision = nil
                self.configureZoomAfterLayout(
                    reset: viewportChanged || fitChanged,
                    revision: revision
                )
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
        layoutRevision &+= 1
        let revision = layoutRevision
        pendingLayoutRevision = revision
        configureZoomAfterLayout(reset: true, revision: revision)
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
        lockInnerScrollViewInteraction()

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
        restoreFittedInnerViewportIfNeeded(reason: "programmaticZoom")
        let contentPoint = zoomContentView.convert(point, from: self)
        let viewportAnchor = CGPoint(
            x: point.x - zoomScrollView.frame.minX,
            y: point.y - zoomScrollView.frame.minY
        )
        let targetRect = EPUBFixedLayoutZoomMath.targetRect(
            targetScale: targetScale,
            contentPoint: contentPoint,
            viewportAnchor: viewportAnchor,
            visibleSize: zoomScrollView.bounds.size
        )

        if animated {
            log(
                .info,
                "fixed-zoom programmatic action=zoom targetScale=\(diagnosticNumber(targetScale)) contentPoint=\(diagnosticPoint(contentPoint)) viewportAnchor=\(diagnosticPoint(viewportAnchor)) targetRect=\(diagnosticRect(targetRect)) \(diagnosticGeometry())"
            )
        }

        zoomScrollView.panGestureRecognizer.isEnabled = !isContentInteractionSuspended
            && targetScale > 1 + Self.zoomTolerance
        zoomScrollView.zoom(to: targetRect, animated: animated)
        if !animated {
            updateContentInsets()
            centerUnscrollableAxes()
            viewportDidChange()
        }
    }

    func resetFixedLayoutZoom(animated: Bool) {
        log(
            .info,
            "fixed-zoom programmatic action=reset animated=\(animated) \(diagnosticGeometry())"
        )
        restoreFittedInnerViewportIfNeeded(reason: "reset")
        zoomScrollView.panGestureRecognizer.isEnabled = false
        zoomScrollView.setZoomScale(Self.minimumZoomScale, animated: animated)
        if !animated {
            updateContentInsets()
            centerUnscrollableAxes()
            viewportDidChange()
        }
    }

    func setContentInteractionSuspended(_ suspended: Bool) {
        guard isContentInteractionSuspended != suspended else { return }
        log(
            .info,
            "fixed-zoom interaction suspended=\(suspended) previous=\(isContentInteractionSuspended) \(diagnosticGeometry())"
        )
        isContentInteractionSuspended = suspended
        zoomScrollView.panGestureRecognizer.isEnabled = !suspended
            && fixedLayoutZoomState.isZoomed
    }

    func installFixedLayoutOverlayView(_ view: UIView?) {
        if overlayView !== view {
            overlayView?.removeFromSuperview()
        }
        overlayView = view
        guard let view else {
            log(.info, "fixed-zoom overlay action=remove \(diagnosticGeometry())")
            return
        }

        if view.superview !== zoomContentView {
            view.removeFromSuperview()
            zoomContentView.addSubview(view)
        }
        view.transform = .identity
        view.frame = zoomContentView.bounds
        zoomContentView.bringSubviewToFront(view)
        let imageSize = (view as? UIImageView)?.image?.size ?? .zero
        log(
            .info,
            "fixed-zoom overlay action=install frame=\(diagnosticRect(view.frame)) bounds=\(diagnosticRect(view.bounds)) imageSize=\(diagnosticSize(imageSize)) \(diagnosticGeometry())"
        )
    }

    func makeFixedLayoutSnapshot() async throws -> (image: UIImage, frame: CGRect)? {
        guard let pageFrameInWebView else {
            log(.warning, "fixed-zoom snapshot event=skipped reason=pageFrameUnavailable \(diagnosticGeometry())")
            return nil
        }
        restoreFittedInnerViewportIfNeeded(reason: "snapshot")
        log(
            .info,
            "fixed-zoom snapshot event=begin webFrame=\(diagnosticRect(webView.frame)) webBounds=\(diagnosticRect(webView.bounds)) innerScale=\(diagnosticNumber(scrollView.zoomScale)) innerOffset=\(diagnosticPoint(scrollView.contentOffset)) \(diagnosticGeometry())"
        )
        let configuration = WKSnapshotConfiguration()
        configuration.afterScreenUpdates = true
        configuration.rect = pageFrameInWebView
        let image = try await webView.takeSnapshot(configuration: configuration)
        let frame = zoomContentView.convert(zoomContentView.bounds, to: self)
        log(
            .info,
            "fixed-zoom snapshot event=end imageSize=\(diagnosticSize(image.size)) imageScale=\(diagnosticNumber(image.scale)) navigatorFrame=\(diagnosticRect(frame)) \(diagnosticGeometry())"
        )
        return (image, frame)
    }

    override func spreadViewForZooming(in scrollView: UIScrollView) -> UIView? {
        scrollView === zoomScrollView ? zoomContentView : nil
    }

    override func spreadScrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        guard scrollView === zoomScrollView else { return }
        viewportDidChange()
    }

    override func spreadScrollViewWillBeginZooming(_ scrollView: UIScrollView) {
        guard scrollView === zoomScrollView else { return }
        restoreFittedInnerViewportIfNeeded(reason: "nativePinchBegan")
        delegate?.spreadViewFixedLayoutZoomWillBegin(self)
    }

    override func spreadScrollViewDidScroll(_ scrollView: UIScrollView) {
        guard scrollView === zoomScrollView else { return }
        viewportDidChange()
    }

    override func spreadScrollViewDidZoom(_ scrollView: UIScrollView) {
        guard scrollView === zoomScrollView else { return }
        if zoomScrollView.zoomScale < Self.minimumZoomScale {
            zoomScrollView.zoomScale = Self.minimumZoomScale
        }
        zoomScrollView.panGestureRecognizer.isEnabled = !isContentInteractionSuspended
            && fixedLayoutZoomState.isZoomed
        updateContentInsets()
        viewportDidChange()
    }

    override func spreadScrollViewDidEndZooming(_ scrollView: UIScrollView) {
        guard scrollView === zoomScrollView else { return }
        if !fixedLayoutZoomState.isZoomed {
            zoomScrollView.zoomScale = Self.minimumZoomScale
        }
        updateContentInsets()
        centerUnscrollableAxes()
        restoreFittedInnerViewportIfNeeded(reason: "nativePinchEnded")
        viewportDidChange()
        delegate?.spreadViewFixedLayoutZoomDidEnd(self)
    }

    private func configureZoomAfterLayout(reset: Bool, revision: Int) {
        guard isWrapperLoaded, revision == layoutRevision else { return }
        lockInnerScrollViewInteraction()
        zoomScrollView.minimumZoomScale = Self.minimumZoomScale
        zoomScrollView.maximumZoomScale = Self.maximumZoomScale
        zoomScrollView.bounces = false
        zoomScrollView.bouncesZoom = false
        if reset {
            log(
                .info,
                "fixed-zoom layout reset reason=viewportChanged viewport=\(diagnosticSize(lastViewportSize)) \(diagnosticGeometry())"
            )
            resetZoomForLayout()
        }
        resolvePageContentFrame(revision: revision, reset: reset)
    }

    private func resolvePageContentFrame(revision: Int, reset: Bool) {
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
        """) { [weak self] value, error in
            guard let self else { return }
            DispatchQueue.main.async {
                guard revision == self.layoutRevision else {
                    self.log(
                        .debug,
                        "fixed-zoom pageFrame event=discarded revision=\(revision) currentRevision=\(self.layoutRevision)"
                    )
                    return
                }
                self.pendingLayoutRevision = nil
                let previousFrame = self.pageFrameInWebView
                let resolvedFrame = Self.rect(fromJavaScriptValue: value)
                    .map(self.convertRectToFittedWebViewSpace)
                if !self.diagnosticRectsApproximatelyEqual(previousFrame, resolvedFrame) {
                    self.log(
                        .info,
                        "fixed-zoom pageFrame previous=\(previousFrame.map(self.diagnosticRect) ?? "nil") resolved=\(resolvedFrame.map(self.diagnosticRect) ?? "nil") jsError=\(error == nil ? "none" : "present") innerScale=\(self.diagnosticNumber(self.scrollView.zoomScale)) innerOffset=\(self.diagnosticPoint(self.scrollView.contentOffset)) \(self.diagnosticGeometry())"
                    )
                }
                guard let resolvedFrame else {
                    self.viewportDidChange()
                    return
                }
                self.fittedInnerZoomScale = self.scrollView.zoomScale
                self.fittedInnerContentOffset = self.scrollView.contentOffset
                self.lockInnerScrollViewInteraction()
                if reset || !self.diagnosticRectsApproximatelyEqual(previousFrame, resolvedFrame) {
                    self.resetZoomForLayout()
                    self.pageFrameInWebView = resolvedFrame
                    self.layoutZoomSurface(pageFrame: resolvedFrame)
                }
                self.viewportDidChange()
            }
        }
    }

    private func convertRectToFittedWebViewSpace(_ rect: CGRect) -> CGRect {
        CGRect(
            x: rect.minX * scrollView.zoomScale - scrollView.contentOffset.x,
            y: rect.minY * scrollView.zoomScale - scrollView.contentOffset.y,
            width: rect.width * scrollView.zoomScale,
            height: rect.height * scrollView.zoomScale
        )
    }

    private func resetZoomForLayout() {
        zoomScrollView.setZoomScale(Self.minimumZoomScale, animated: false)
        zoomScrollView.panGestureRecognizer.isEnabled = false
        updateContentInsets()
        centerUnscrollableAxes()
    }

    private func layoutZoomSurface(pageFrame: CGRect) {
        let pageSize = CGSize(
            width: max(pageFrame.width, 1),
            height: max(pageFrame.height, 1)
        )
        zoomContentView.bounds = CGRect(origin: .zero, size: pageSize)
        zoomContentView.frame = CGRect(origin: .zero, size: pageSize)

        // Keep WKWebView's viewport at the navigator size and translate it
        // behind a page-sized clipping surface. This makes UIScrollView's
        // native contentSize and pan boundaries equal the actual rendered page.
        webView.bounds = CGRect(origin: .zero, size: bounds.size)
        webView.center = CGPoint(
            x: bounds.width / 2 - pageFrame.minX,
            y: bounds.height / 2 - pageFrame.minY
        )
        overlayView?.frame = zoomContentView.bounds
        zoomScrollView.contentSize = pageSize
        updateContentInsets()
        centerUnscrollableAxes()
    }

    private func updateContentInsets() {
        let fittedFrame = pageFrameInWebView
            ?? CGRect(origin: .zero, size: zoomContentView.bounds.size)
        let insets = EPUBFixedLayoutZoomMath.fittedInsets(
            contentSize: zoomScrollView.contentSize,
            visibleSize: zoomScrollView.bounds.size,
            fittedFrame: fittedFrame
        )
        if zoomScrollView.contentInset != insets {
            zoomScrollView.contentInset = insets
        }
    }

    /// An axis with content smaller than the viewport has no valid pan range.
    /// Centering only those axes avoids fighting UIScrollView's native physics
    /// on axes where the page is scrollable.
    private func centerUnscrollableAxes() {
        var offset = zoomScrollView.contentOffset
        if zoomScrollView.contentSize.width <= zoomScrollView.bounds.width + 0.5 {
            offset.x = -zoomScrollView.contentInset.left
        }
        if zoomScrollView.contentSize.height <= zoomScrollView.bounds.height + 0.5 {
            offset.y = -zoomScrollView.contentInset.top
        }
        if offset != zoomScrollView.contentOffset {
            zoomScrollView.contentOffset = offset
        }
    }

    private func viewportDidChange() {
        delegate?.spreadViewFixedLayoutViewportDidChange(self)
    }

    /// Readium owns the fitted WebKit viewport scale. User zoom belongs only
    /// to `zoomScrollView`; otherwise both scroll views consume the same pinch
    /// and multiply their scale and offsets.
    private func lockInnerScrollViewInteraction() {
        scrollView.isScrollEnabled = false
        scrollView.panGestureRecognizer.isEnabled = false
        scrollView.pinchGestureRecognizer?.isEnabled = false
    }

    private func restoreFittedInnerViewportIfNeeded(reason: String) {
        guard let fittedInnerZoomScale else {
            lockInnerScrollViewInteraction()
            return
        }
        let scaleDrift = abs(scrollView.zoomScale - fittedInnerZoomScale)
        let offsetDrift = hypot(
            scrollView.contentOffset.x - fittedInnerContentOffset.x,
            scrollView.contentOffset.y - fittedInnerContentOffset.y
        )
        guard scaleDrift > 0.001 || offsetDrift > 0.5 else {
            lockInnerScrollViewInteraction()
            return
        }

        log(
            .error,
            "fixed-zoom invariant repaired reason=\(reason) fittedInnerScale=\(diagnosticNumber(fittedInnerZoomScale)) fittedInnerOffset=\(diagnosticPoint(fittedInnerContentOffset)) \(diagnosticGeometry())"
        )
        scrollView.setZoomScale(fittedInnerZoomScale, animated: false)
        scrollView.contentOffset = fittedInnerContentOffset
        lockInnerScrollViewInteraction()
    }

    @objc private func handleDiagnosticPanState(_ recognizer: UIPanGestureRecognizer) {
        let now = Date.timeIntervalSinceReferenceDate
        switch recognizer.state {
        case .began:
            diagnosticPanSequence &+= 1
            lastDiagnosticPanSample = now
            log(
                .info,
                "fixed-zoom pan event=began sequence=\(diagnosticPanSequence) \(diagnosticGeometry())"
            )
        case .changed:
            guard now - lastDiagnosticPanSample >= 0.12 else { return }
            lastDiagnosticPanSample = now
            log(
                .debug,
                "fixed-zoom pan event=changed sequence=\(diagnosticPanSequence) \(diagnosticGeometry())"
            )
        case .ended, .cancelled, .failed:
            log(
                .info,
                "fixed-zoom pan event=\(diagnosticGestureState(recognizer.state)) sequence=\(diagnosticPanSequence) \(diagnosticGeometry())"
            )
        case .possible:
            break
        @unknown default:
            log(
                .info,
                "fixed-zoom pan event=unknown sequence=\(diagnosticPanSequence) \(diagnosticGeometry())"
            )
        }
    }

    @objc private func handleDiagnosticZoomState(_ recognizer: UIPinchGestureRecognizer) {
        let now = Date.timeIntervalSinceReferenceDate
        switch recognizer.state {
        case .began:
            diagnosticZoomSequence &+= 1
            lastDiagnosticZoomSample = now
            lastDiagnosticRenderScale = zoomScrollView.zoomScale
            log(
                .info,
                "fixed-zoom nativePinch event=began sequence=\(diagnosticZoomSequence) centroid=\(diagnosticPoint(recognizer.location(in: self))) \(diagnosticGeometry())"
            )
            logDiagnosticRenderState(event: "began", includeDOM: true)
        case .changed:
            guard now - lastDiagnosticZoomSample >= 0.12 else { return }
            lastDiagnosticZoomSample = now
            log(
                .info,
                "fixed-zoom nativePinch event=changed sequence=\(diagnosticZoomSequence) recognizerScale=\(diagnosticNumber(recognizer.scale)) centroid=\(diagnosticPoint(recognizer.location(in: self))) \(diagnosticGeometry())"
            )
            if lastDiagnosticRenderScale.map({ abs($0 - zoomScrollView.zoomScale) >= 0.25 }) ?? true {
                lastDiagnosticRenderScale = zoomScrollView.zoomScale
                logDiagnosticRenderState(event: "changed", includeDOM: false)
            }
        case .ended, .cancelled, .failed:
            log(
                .info,
                "fixed-zoom nativePinch event=\(diagnosticGestureState(recognizer.state)) sequence=\(diagnosticZoomSequence) recognizerScale=\(diagnosticNumber(recognizer.scale)) centroid=\(diagnosticPoint(recognizer.location(in: self))) \(diagnosticGeometry())"
            )
            logDiagnosticRenderState(
                event: diagnosticGestureState(recognizer.state),
                includeDOM: true
            )
        case .possible:
            break
        @unknown default:
            log(
                .info,
                "fixed-zoom nativePinch event=unknown sequence=\(diagnosticZoomSequence) \(diagnosticGeometry())"
            )
        }
    }

    private func diagnosticGeometry() -> String {
        let recognizer = zoomScrollView.panGestureRecognizer
        return "spread=\(diagnosticSpreadID) scale=\(diagnosticNumber(zoomScrollView.zoomScale)) offset=\(diagnosticPoint(zoomScrollView.contentOffset)) inset=\(diagnosticInsets(zoomScrollView.contentInset)) contentSize=\(diagnosticSize(zoomScrollView.contentSize)) bounds=\(diagnosticSize(zoomScrollView.bounds.size)) zoomFrame=\(diagnosticRect(zoomContentView.frame)) zoomBounds=\(diagnosticRect(zoomContentView.bounds)) pageFrame=\(pageFrameInWebView.map(diagnosticRect) ?? "nil") webFrame=\(diagnosticRect(webView.frame)) innerScale=\(diagnosticNumber(scrollView.zoomScale)) innerOffset=\(diagnosticPoint(scrollView.contentOffset)) innerScrollEnabled=\(scrollView.isScrollEnabled) innerPinchEnabled=\(scrollView.pinchGestureRecognizer?.isEnabled ?? false) panState=\(diagnosticGestureState(recognizer.state)) translation=\(diagnosticPoint(recognizer.translation(in: zoomScrollView))) velocity=\(diagnosticPoint(recognizer.velocity(in: zoomScrollView))) scrollEnabled=\(zoomScrollView.isScrollEnabled) panEnabled=\(recognizer.isEnabled) pinchEnabled=\(zoomScrollView.pinchGestureRecognizer?.isEnabled ?? false) directionalLock=\(zoomScrollView.isDirectionalLockEnabled) tracking=\(zoomScrollView.isTracking) dragging=\(zoomScrollView.isDragging) decelerating=\(zoomScrollView.isDecelerating) suspended=\(isContentInteractionSuspended) overlay=\(overlayView != nil) revision=\(layoutRevision) pending=\(pendingLayoutRevision.map(String.init) ?? "none")"
    }

    /// Geometry from UIScrollView alone cannot reveal clipping performed by
    /// WebKit's out-of-process content layers. These diagnostics deliberately
    /// inspect presentation layers and recognizers without changing them.
    private func logDiagnosticRenderState(event: String, includeDOM: Bool) {
        let sequence = diagnosticZoomSequence
        let views = diagnosticRelevantViews()
        log(
            .info,
            "fixed-zoom render event=\(event) sequence=\(sequence) viewCount=\(views.count) \(diagnosticGeometry())"
        )
        for (index, item) in views.enumerated() {
            let view = item.view
            let layer = view.layer
            let presentation = layer.presentation()
            log(
                .info,
                "fixed-zoom renderView event=\(event) sequence=\(sequence) index=\(index) label=\(item.label) type=\(String(describing: type(of: view))) super=\(view.superview.map { String(describing: type(of: $0)) } ?? "nil") frame=\(diagnosticRect(view.frame)) bounds=\(diagnosticRect(view.bounds)) spreadRect=\(diagnosticRect(view.convert(view.bounds, to: self))) windowRect=\(diagnosticRect(view.convert(view.bounds, to: nil))) transform=\(diagnosticAffineTransform(view.transform)) clips=\(view.clipsToBounds) masks=\(layer.masksToBounds) hidden=\(view.isHidden) alpha=\(diagnosticNumber(view.alpha)) layerFrame=\(diagnosticRect(layer.frame)) presentationFrame=\(presentation.map { diagnosticRect($0.frame) } ?? "nil") layerTransform=\(diagnosticTransform3D(layer.transform)) presentationTransform=\(presentation.map { diagnosticTransform3D($0.transform) } ?? "nil")"
            )
        }
        logDiagnosticLayerTree(event: event, sequence: sequence)
        logDiagnosticRecognizers(event: event, sequence: sequence, views: views)
        if includeDOM {
            logDiagnosticDOMState(event: event, sequence: sequence)
        }
    }

    private func diagnosticRelevantViews() -> [(label: String, view: UIView)] {
        var result: [(String, UIView)] = []
        var seen = Set<ObjectIdentifier>()

        func append(_ label: String, _ view: UIView) {
            guard seen.insert(ObjectIdentifier(view)).inserted else { return }
            result.append((label, view))
        }

        append("spread", self)
        append("zoomScroll", zoomScrollView)
        append("zoomContent", zoomContentView)
        append("webView", webView)
        append("webScroll", scrollView)

        func visit(_ view: UIView, depth: Int) {
            guard depth <= 12 else { return }
            for (index, child) in view.subviews.enumerated() {
                let typeName = String(describing: type(of: child))
                if typeName.contains("WK")
                    || child.clipsToBounds
                    || child.layer.masksToBounds
                    || child.gestureRecognizers?.isEmpty == false
                {
                    append("webDescendant.\(depth).\(index)", child)
                }
                visit(child, depth: depth + 1)
            }
        }
        visit(webView, depth: 0)

        var ancestor = superview
        var ancestorIndex = 0
        while let view = ancestor, ancestorIndex < 12 {
            append("ancestor.\(ancestorIndex)", view)
            ancestor = view.superview
            ancestorIndex += 1
        }
        return result
    }

    private func logDiagnosticLayerTree(event: String, sequence: Int) {
        var index = 0
        func visit(_ layer: CALayer, depth: Int) {
            guard depth <= 14, index < 160 else { return }
            let typeName = String(describing: type(of: layer))
            if layer === webView.layer
                || layer.masksToBounds
                || typeName != "CALayer"
                || layer.name != nil
            {
                let presentation = layer.presentation()
                log(
                    .info,
                    "fixed-zoom renderLayer event=\(event) sequence=\(sequence) index=\(index) depth=\(depth) type=\(typeName) name=\(layer.name ?? "nil") super=\(layer.superlayer.map { String(describing: type(of: $0)) } ?? "nil") frame=\(diagnosticRect(layer.frame)) bounds=\(diagnosticRect(layer.bounds)) spreadRect=\(diagnosticRect(layer.convert(layer.bounds, to: self.layer))) position=\(diagnosticPoint(layer.position)) anchor=\(diagnosticPoint(layer.anchorPoint)) masks=\(layer.masksToBounds) hidden=\(layer.isHidden) opacity=\(diagnosticNumber(CGFloat(layer.opacity))) transform=\(diagnosticTransform3D(layer.transform)) presentationFrame=\(presentation.map { diagnosticRect($0.frame) } ?? "nil") presentationTransform=\(presentation.map { diagnosticTransform3D($0.transform) } ?? "nil")"
                )
                index += 1
            }
            for child in layer.sublayers ?? [] {
                visit(child, depth: depth + 1)
            }
        }
        visit(webView.layer, depth: 0)
    }

    private func logDiagnosticRecognizers(
        event: String,
        sequence: Int,
        views: [(label: String, view: UIView)]
    ) {
        var seen = Set<ObjectIdentifier>()
        var index = 0
        for item in views {
            for recognizer in item.view.gestureRecognizers ?? [] {
                guard seen.insert(ObjectIdentifier(recognizer)).inserted else { continue }
                var detail = ""
                if let pinch = recognizer as? UIPinchGestureRecognizer {
                    detail = " pinchScale=\(diagnosticNumber(pinch.scale)) pinchVelocity=\(diagnosticNumber(pinch.velocity))"
                } else if let pan = recognizer as? UIPanGestureRecognizer {
                    detail = " translation=\(diagnosticPoint(pan.translation(in: item.view))) velocity=\(diagnosticPoint(pan.velocity(in: item.view)))"
                }
                log(
                    .info,
                    "fixed-zoom renderRecognizer event=\(event) sequence=\(sequence) index=\(index) owner=\(item.label) type=\(String(describing: type(of: recognizer))) state=\(diagnosticGestureState(recognizer.state)) enabled=\(recognizer.isEnabled) touches=\(recognizer.numberOfTouches) cancels=\(recognizer.cancelsTouchesInView) delaysBegin=\(recognizer.delaysTouchesBegan) delaysEnd=\(recognizer.delaysTouchesEnded)\(detail)"
                )
                index += 1
            }
        }
    }

    private func logDiagnosticDOMState(event: String, sequence: Int) {
        webView.evaluateJavaScript("""
            (function() {
                function rect(node) {
                    if (!node) return null;
                    var r = node.getBoundingClientRect();
                    return [r.x, r.y, r.width, r.height].map(function(v) { return Math.round(v * 1000) / 1000; });
                }
                function style(node) {
                    if (!node) return null;
                    var s = getComputedStyle(node);
                    return {overflow: s.overflow, overflowX: s.overflowX, overflowY: s.overflowY, transform: s.transform, transformOrigin: s.transformOrigin, zoom: s.zoom};
                }
                var frame = Array.from(document.querySelectorAll('iframe')).find(function(node) {
                    var viewport = node.closest('.viewport');
                    return !viewport || getComputedStyle(viewport).display !== 'none';
                });
                var viewport = frame && frame.closest('.viewport');
                var visual = window.visualViewport;
                return JSON.stringify({
                    frameRect: rect(frame), frameStyle: style(frame),
                    viewportRect: rect(viewport), viewportStyle: style(viewport),
                    bodyRect: rect(document.body), bodyStyle: style(document.body),
                    htmlRect: rect(document.documentElement), htmlStyle: style(document.documentElement),
                    inner: [window.innerWidth, window.innerHeight],
                    visual: visual ? [visual.width, visual.height, visual.offsetLeft, visual.offsetTop, visual.scale] : null,
                    scroll: [window.scrollX, window.scrollY, document.documentElement.scrollWidth, document.documentElement.scrollHeight]
                });
            })();
        """) { [weak self] value, error in
            guard let self else { return }
            self.log(
                .info,
                "fixed-zoom renderDOM event=\(event) sequence=\(sequence) value=\(value as? String ?? "nil") jsError=\(error == nil ? "none" : "present")"
            )
        }
    }

    private func diagnosticNumber(_ value: CGFloat) -> String {
        String(format: "%.3f", value)
    }

    private func diagnosticPoint(_ point: CGPoint) -> String {
        "\(diagnosticNumber(point.x)),\(diagnosticNumber(point.y))"
    }

    private func diagnosticSize(_ size: CGSize) -> String {
        "\(diagnosticNumber(size.width))x\(diagnosticNumber(size.height))"
    }

    private func diagnosticRect(_ rect: CGRect) -> String {
        "\(diagnosticPoint(rect.origin)),\(diagnosticSize(rect.size))"
    }

    private func diagnosticInsets(_ insets: UIEdgeInsets) -> String {
        "\(diagnosticNumber(insets.top)),\(diagnosticNumber(insets.left)),\(diagnosticNumber(insets.bottom)),\(diagnosticNumber(insets.right))"
    }

    private func diagnosticAffineTransform(_ transform: CGAffineTransform) -> String {
        "\(diagnosticNumber(transform.a)),\(diagnosticNumber(transform.b)),\(diagnosticNumber(transform.c)),\(diagnosticNumber(transform.d)),\(diagnosticNumber(transform.tx)),\(diagnosticNumber(transform.ty))"
    }

    private func diagnosticTransform3D(_ transform: CATransform3D) -> String {
        "\(diagnosticNumber(transform.m11)),\(diagnosticNumber(transform.m12)),\(diagnosticNumber(transform.m21)),\(diagnosticNumber(transform.m22)),\(diagnosticNumber(transform.m34)),\(diagnosticNumber(transform.m41)),\(diagnosticNumber(transform.m42))"
    }

    private func diagnosticGestureState(_ state: UIGestureRecognizer.State) -> String {
        switch state {
        case .possible: "possible"
        case .began: "began"
        case .changed: "changed"
        case .ended: "ended"
        case .cancelled: "cancelled"
        case .failed: "failed"
        @unknown default: "unknown"
        }
    }

    private func diagnosticRectsApproximatelyEqual(_ lhs: CGRect?, _ rhs: CGRect?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil):
            return true
        case let (lhs?, rhs?):
            return abs(lhs.minX - rhs.minX) < 0.5
                && abs(lhs.minY - rhs.minY) < 0.5
                && abs(lhs.width - rhs.width) < 0.5
                && abs(lhs.height - rhs.height) < 0.5
        default:
            return false
        }
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

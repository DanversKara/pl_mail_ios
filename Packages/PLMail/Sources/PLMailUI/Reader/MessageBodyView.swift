#if os(iOS)

public import PLMailCore

import JMAPKit
import SafariServices
import SwiftUI
import WebKit

/// Renders one message's HTML.
///
/// The single most failure-prone view in the app, and every rule here is
/// load-bearing:
///
/// - **Dark mode is chosen per message, never applied blindly.** Mail is
///   authored for white, so one strategy cannot serve every message: a plain
///   reply is restyled outright, a designed newsletter is inverted with its
///   imagery inverted back so photos and logos stay right, and a message that
///   already ships dark styles is simply told the scheme and left alone.
///   Inverting everything is the one approach that reliably looks broken —
///   photos come out as negatives and adaptive mail double-inverts. See
///   ``PLMailCore/MessageRenderStyle``.
/// - **A way back to the original.** Inversion gets some messages wrong, and
///   when it does the reader needs to see what was actually sent.
/// - **Remote content blocked** until asked for. A remote image in mail is a
///   tracking pixel far more often than it is a picture.
/// - **`cid:` served from the local cache** through a scheme handler, so the
///   download URL is never handed to a web view. That matters because the
///   server ignores `accept`, always sets `nosniff`, and serves only
///   `image/*` inline.
/// - **No nested scrolling.** The web view reports its content height and
///   sizes to it, so the message scrolls with the thread around it.
struct MessageBodyView: View {
    let html: String
    let inlineParts: [AttachmentSnapshot]
    let accountKey: String
    let loadRemoteContent: Bool
    let renderStyle: MessageRenderStyle
    /// Supplies bytes for a `cid:` part. Without this the inline image handler
    /// has nothing to serve and every inline image renders broken.
    let inlineProvider: @Sendable (AttachmentSnapshot, String) async -> Data?
    let onRemoteContentBlocked: () -> Void

    @State private var height: CGFloat = 1

    var body: some View {
        WebBody(
            html: html,
            inlineParts: inlineParts,
            accountKey: accountKey,
            loadRemoteContent: loadRemoteContent,
            renderStyle: renderStyle,
            inlineProvider: inlineProvider,
            height: $height,
            onRemoteContentBlocked: onRemoteContentBlocked
        )
        .frame(height: height)
    }
}

private struct WebBody: UIViewRepresentable {
    let html: String
    let inlineParts: [AttachmentSnapshot]
    let accountKey: String
    let loadRemoteContent: Bool
    let renderStyle: MessageRenderStyle
    let inlineProvider: @Sendable (AttachmentSnapshot, String) async -> Data?
    @Binding var height: CGFloat
    let onRemoteContentBlocked: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(height: $height, onRemoteContentBlocked: onRemoteContentBlocked)
    }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.setURLSchemeHandler(
            context.coordinator.inlineHandler, forURLScheme: InlineImageHandler.scheme)

        let controller = WKUserContentController()
        controller.add(context.coordinator, name: Coordinator.heightMessage)
        controller.addUserScript(
            WKUserScript(
                source: Self.heightReportingScript,
                injectionTime: .atDocumentEnd,
                forMainFrameOnly: true
            )
        )
        configuration.userContentController = controller

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.scrollView.isScrollEnabled = false
        webView.scrollView.bounces = false
        webView.isOpaque = false

        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        let document = Self.document(html: html, inlineParts: inlineParts, style: renderStyle)

        // Set before the early return: the handler must be able to serve
        // inline images even when the document itself has not changed.
        context.coordinator.inlineHandler.parts = inlineParts
        context.coordinator.inlineHandler.accountKey = accountKey
        context.coordinator.inlineHandler.provider = inlineProvider
        context.coordinator.blocksRemoteContent = loadRemoteContent == false

        guard
            context.coordinator.renderedDocument != document
                || context.coordinator.renderedRemoteSetting != loadRemoteContent
        else { return }

        // The web view's own scheme has to match the strategy, or the gap
        // around a short message keeps the other appearance's colour.
        webView.overrideUserInterfaceStyle = renderStyle == .original ? .light : .dark
        webView.backgroundColor = UIColor(renderStyle.pageBackground)
        webView.scrollView.backgroundColor = webView.backgroundColor

        context.coordinator.renderedDocument = document
        context.coordinator.renderedRemoteSetting = loadRemoteContent

        // No base URL, so a relative reference in the message cannot
        // resolve to anything at all.
        webView.loadHTMLString(document, baseURL: nil)
    }

    // MARK: - Document

    /// Wraps the server's already-sanitised HTML.
    private static func document(
        html: String, inlineParts: [AttachmentSnapshot], style: MessageRenderStyle
    ) -> String {
        var body = html

        // Rewrite cid: references onto the custom scheme, so they are
        // served from the local cache rather than fetched.
        for part in inlineParts {
            guard let cid = part.cid else { continue }

            body = body.replacingOccurrences(
                of: "cid:\(cid)",
                with: "\(InlineImageHandler.scheme)://\(part.partID)"
            )
        }

        return """
            <!doctype html>
            <html>
            <head>
            <meta charset="utf-8">
            <meta name="viewport" content="width=device-width, initial-scale=1">
            <meta name="color-scheme" content="\(style.declaredScheme)">
            <style>
              :root { color-scheme: \(style.declaredScheme); }
              html, body {
                margin: 0; padding: 0;
                font: -apple-system-body;
                -webkit-text-size-adjust: 100%;
              }
              body { padding: 0 16px 8px; overflow-wrap: break-word; }
              img, video, table { max-width: 100% !important; height: auto; }
              /* Wide tables scroll themselves rather than widening the page. */
              table { display: block; overflow-x: auto; }
              pre { overflow-x: auto; }
              \(style.css)
            </style>
            </head>
            <body>\(body)</body>
            </html>
            """
    }

    /// Reports content height so SwiftUI can size the view.
    ///
    /// A `ResizeObserver` rather than a one-shot measurement: images and
    /// web fonts land after `DOMContentLoaded`, and a height taken before
    /// them clips the message.
    private static let heightReportingScript = """
        (function () {
          function report() {
            window.webkit.messageHandlers.\(Coordinator.heightMessage)
              .postMessage(document.documentElement.scrollHeight);
          }
          new ResizeObserver(report).observe(document.documentElement);
          window.addEventListener('load', report);
          report();
        })();
        """

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        static let heightMessage = "plmailHeight"

        let inlineHandler = InlineImageHandler()
        var renderedDocument: String?
        var renderedRemoteSetting: Bool?
        var blocksRemoteContent = true

        private let height: Binding<CGFloat>
        private let onRemoteContentBlocked: () -> Void

        init(height: Binding<CGFloat>, onRemoteContentBlocked: @escaping () -> Void) {
            self.height = height
            self.onRemoteContentBlocked = onRemoteContentBlocked
        }

        func userContentController(
            _ controller: WKUserContentController, didReceive message: WKScriptMessage
        ) {
            guard let value = message.body as? NSNumber else { return }

            let measured = CGFloat(value.doubleValue)

            // Only grow on a real change: ResizeObserver fires often, and
            // rewriting the binding every time makes SwiftUI churn.
            if abs(measured - height.wrappedValue) > 1 {
                height.wrappedValue = measured
            }
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor action: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            // The initial loadHTMLString and the local scheme are the only
            // things allowed to load.
            guard let url = action.request.url else {
                return decisionHandler(.allow)
            }

            if action.navigationType == .linkActivated {
                // Never navigate in place: the message would be replaced by
                // whatever the link points at, inside a view with no
                // address bar and no way back.
                Self.open(url)
                return decisionHandler(.cancel)
            }

            if url.scheme == InlineImageHandler.scheme || url.scheme == "about" {
                return decisionHandler(.allow)
            }

            if blocksRemoteContent, url.scheme == "http" || url.scheme == "https" {
                onRemoteContentBlocked()
                return decisionHandler(.cancel)
            }

            decisionHandler(.allow)
        }

        @MainActor
        private static func open(_ url: URL) {
            guard url.scheme == "http" || url.scheme == "https" else {
                UIApplication.shared.open(url)
                return
            }

            guard
                let scene = UIApplication.shared.connectedScenes
                    .first(where: { $0.activationState == .foregroundActive })
                    as? UIWindowScene,
                let presenter = scene.keyWindow?.rootViewController
            else { return }

            let safari = SFSafariViewController(url: url)
            presenter.topmost.present(safari, animated: true)
        }
    }
}

extension UIViewController {
    fileprivate var topmost: UIViewController {
        presentedViewController?.topmost ?? self
    }
}

#endif

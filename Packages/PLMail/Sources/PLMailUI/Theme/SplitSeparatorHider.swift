#if os(iOS)

import SwiftUI
import UIKit

/// Hides the hairline `NavigationSplitView` draws between its columns.
///
/// The panes are already separated by a gutter of window colour; the rule
/// drawn down the middle of that gutter is the thing the gap replaces, and it
/// is the detail people notice first about a three-pane layout that looks
/// stitched together rather than composed.
///
/// There is no API for it. `UISplitViewController` has never exposed its
/// separator, and painting over it does not work — SwiftUI clips a column's
/// background to the column, and the separator is drawn by the container above
/// both. So this reaches for the view itself.
///
/// The view in question is `_UISplitViewControllerAdaptiveColumnSeparatorView`
/// — half a point wide, the full height of the split view, filled with
/// `opaqueSeparatorColor`. It is matched on those properties rather than by
/// class name, so a rename does not silently turn this into a no-op while a
/// hardcoded string keeps compiling.
///
/// Written to fail harmlessly. It only ever sets `isHidden` on views that are
/// hairline-thin and column-tall, touches nothing else, and if a future
/// release stops producing such a view the loop simply matches nothing and the
/// rule comes back. Nothing about correctness depends on it.
struct SplitSeparatorHider: UIViewRepresentable {
    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.isUserInteractionEnabled = false
        view.isHidden = true

        return view
    }

    func updateUIView(_ view: UIView, context: Context) {
        // Next runloop: on the first pass this view is not in the hierarchy
        // yet, and the split view has not laid its columns out.
        DispatchQueue.main.async {
            guard let split = Self.splitViewController() else { return }

            // The separator sits exactly on the boundary between two columns,
            // so neither column's background covers the half point it occupied
            // — hiding it alone just swaps a grey line for a white one. The
            // container behind has to be the gutter colour too.
            split.view.backgroundColor = UIColor(PanelStyle.window)

            hideHairlines(in: split.view, containerHeight: split.view.bounds.height)
        }
    }

    /// A separator is thin, nearly as tall as the split view, and has a
    /// background colour. Anything failing one of those is left alone — that
    /// conjunction is narrow enough not to catch a divider inside a row, a
    /// scroll indicator, or a real content view.
    /// Found from the window's root rather than up the responder chain: this
    /// view lives in a column's background, and SwiftUI hosts that in a context
    /// whose responder chain does not reach the split view controller.
    static func splitViewController() -> UISplitViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let roots = scenes.flatMap(\.windows).compactMap(\.rootViewController)

        for root in roots {
            if let found = search(root) { return found }
        }

        return nil
    }

    private static func search(_ controller: UIViewController) -> UISplitViewController? {
        if let split = controller as? UISplitViewController { return split }

        for child in controller.children {
            if let found = search(child) { return found }
        }

        return search(controller.presentedViewController)
    }

    private static func search(_ controller: UIViewController?) -> UISplitViewController? {
        controller.flatMap(search)
    }

    private func hideHairlines(in view: UIView, containerHeight: CGFloat) {
        for subview in view.subviews {
            let size = subview.bounds.size
            let isHairline = size.width > 0 && size.width <= 2
            let spansColumn = size.height >= containerHeight * 0.8

            if isHairline, spansColumn, subview.backgroundColor != nil {
                subview.isHidden = true
            }

            hideHairlines(in: subview, containerHeight: containerHeight)
        }
    }
}

#endif

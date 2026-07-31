#if os(iOS)

import PLMailCore
import SwiftUI

extension MessageRenderStyle {
    /// What the document declares to CSS, so `prefers-color-scheme` inside
    /// the message resolves the way this strategy expects.
    var declaredScheme: String {
        self == .original ? "light" : "dark"
    }

    /// The colour behind the message, matched by the web view itself so a
    /// short message doesn't sit on a mismatched strip.
    var pageBackground: Color {
        self == .original ? Color.white : Color(red: 0.11, green: 0.11, blue: 0.12)
    }

    /// The strategy's stylesheet.
    var css: String {
        switch self {
        case .original: Self.originalCSS
        case .darkRestyled: Self.restyledCSS
        case .darkInverted: Self.invertedCSS
        case .darkNative: Self.nativeCSS
        }
    }

    /// The message as sent, on white — the truest rendering of anything
    /// designed, and what light appearance always gets.
    private static let originalCSS = """
        html, body { background: #ffffff; color: #1c1c1e; }
        a { color: #0b57d0; }
        blockquote {
          margin: 8px 0; padding-left: 12px;
          border-left: 2px solid #d1d1d6; color: #48484a;
        }
        """

    /// For messages that brought no colours of their own.
    ///
    /// Nothing is inverted, so nothing can come out looking like a
    /// negative — this is simply the message painted in the app's dark
    /// palette, and it is the best result available. It applies only where
    /// the analysis found no colours to fight with.
    ///
    /// The `!important` overrides catch the one thing that still bites: a
    /// stray `color: #000` on a signature line, which would otherwise be
    /// black on near-black.
    private static let restyledCSS = """
        html, body { background: #1c1c1e; color: #e5e5e7; }
        [style*="color"], font[color] { color: #e5e5e7 !important; }
        a, a[style*="color"] { color: #7aa7ff !important; }
        blockquote {
          margin: 8px 0; padding-left: 12px;
          border-left: 2px solid #48484a; color: #aeaeb2;
        }
        hr { border-color: #3a3a3c; }
        """

    /// For messages with a design of their own.
    ///
    /// Inverting lightness and rotating hue turns a light layout dark while
    /// keeping colour relationships roughly intact, which is the only thing
    /// that works on a message whose palette is load-bearing.
    ///
    /// The second rule is the part everyone forgets: **media is inverted
    /// back**, so photographs stay photographs and a logo keeps its brand
    /// colours. Without it every image in the message is a negative, which
    /// is exactly why blanket inversion has a bad reputation.
    ///
    /// `hue-rotate` accompanies `invert` because inverting alone also
    /// inverts hue — blues would come out orange.
    private static let invertedCSS = """
        html {
          filter: invert(1) hue-rotate(180deg);
          background: #ffffff;
        }
        img, picture, video, canvas, svg, iframe, embed, object,
        [style*="background-image"], [background] {
          filter: invert(1) hue-rotate(180deg);
        }
        """

    /// The message already has dark styles; declaring the scheme is all it
    /// needs. Touching anything else would undo work the sender did.
    private static let nativeCSS = """
        html, body { background: #1c1c1e; color: #e5e5e7; }
        """
}

#endif

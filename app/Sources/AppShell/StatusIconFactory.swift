import AppKit
import ReceiverKit

/// Status bar icon factory — **YC hand-drawn design** (2026-10-18 redesign).
///
/// icon-swap-e11ba2 replaces the previous YC drawing (screen + ripple
/// arcs + triangle, `app/Resources/StatusIcon/icon.svg`) with the
/// NEW source `app/Resources/StatusIcon/icon.svg` (= YC's
/// `~/Downloads/icon.svg`; md5 9dd970c8c5014ca9aa000faabdce1712;
/// 211×165 export frame): a black-stroked rounded screen with two solid
/// eye discs and a large play triangle whose apex tip pokes INTO the
/// screen while its body hangs below it.
///
/// Treatment (YC-ruled): every white fill (#FFFFFF ×2 — the screen's and
/// the triangle's) becomes TRANSPARENT; the black geometry (all strokes,
/// width 14.8958, plus the two #000000 eye fills) is the body, painted in
/// the state colour. This file remains the single replacement point: the
/// icon is drawn as vector code transcribed from the SVG's own geometry
/// — no asset is loaded at runtime, no image file, no emoji (the repo
/// copy under `app/Resources/StatusIcon/` is the tracked
/// source-of-truth for audit; the renderer does not read it).
///
/// YC ruling ③ is untouched: the SHAPE is fixed and the state is carried
/// BY COLOUR ONLY. The state→colour map and every trigger path are
/// unchanged from CP-2 ①:
///
///   idle / stopping → systemGray    (not started / not running)
///   waiting         → systemOrange  (in progress / waiting; a crash-recovery respawn maps to this state)
///   connected       → systemGreen   (running)
///
/// Geometry (source-canvas units, y-down — the SVG's own frame after its
/// `translate(-1938 -146)`, canvas 211×165):
///   • rounded rect 190×118 at (11.5, 8.5), corner radius 19.667
///     (circular — the export's cubics carry the standard 0.5523 κ);
///   • triangle (55.5,157.5) (106.5,68.5) (157.5,157.5) — apex up, base
///     below the screen; the apex tip reaches INTO the screen between
///     the eyes;
///   • two eye discs centred (54,54) and (159,54) — the SVG's r12.5
///     circles each carry its 14.8958 stroke, so each eye is ONE solid
///     disc of radius 12.5 + lineWidth/2 = 19.948;
///   • stroke width 14.8958 on every path (the SVG's own value).
///
/// Occlusion semantics (the key to white → transparent): in the SVG the triangle element
/// (white fill + black stroke) sits ON TOP of the screen's bottom edge
/// and interrupts it — on the page the bottom edge reads as two stubs,
/// each merging into one of the triangle's slanted sides. The menu bar
/// needs a TRANSPARENT background, so that interruption cannot come from
/// a white fill; it is reproduced the way the previous design's cut-out
/// triangles were (established technique, cp2-prefs-icon): the rect
/// stroke is CLIPPED against the triangle's path BEFORE the triangle's
/// outline is stroked — pixel-equivalent to the source's on-page
/// appearance, ink for ink (the triangle's stroke band re-covers
/// everything within ±lineWidth/2 of its edge, exactly as the SVG does).
///
/// Stroke weight: the SVG's own 14.8958 units render at 1.27 pt on the
/// 18-pt canvas (Retina ≈2.54 px)— at/above the macOS menu-bar
/// convention (~1 pt), so the N-8 raise (which existed to lift the old
/// design's 0.45-pt weight) does NOT trigger; the weight stays the
/// source's own value.
///
/// Canvas: 18 pt (YC ruling ① kept); the artwork scales by side/211 (design
/// frame width — the height fits, content 204.9×163.9 units ≈ 97%×99%
/// of the export frame) and is optically centred via the stroke-inclusive
/// content bounds — the same centring pipeline as the previous design.
enum StatusIconFactory {

    /// Menu-bar canvas size (pt). A3 §A/§G put the status icon at 16×16;
    /// 18 is chosen from the 16–18 band because the YC design's strokes
    /// are finer than the placeholder's fill. 16 is also rendered in the
    /// test sheet for a side-by-side clarity check — switching is a
    /// one-constant change (YC hands-on measurement).
    static let canvasSize: CGFloat = 18

    /// Draws the fixed-shape icon for the given receiver state.
    static func image(for state: ReceiverState) -> NSImage {
        image(for: state, canvasSize: canvasSize)
    }

    /// Draws the icon at an explicit canvas size — the geometry scales
    /// linearly (vector code; sharp at any size).
    static func image(for state: ReceiverState, canvasSize: CGFloat) -> NSImage {
        let side = canvasSize
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { _ in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }

            // The artwork is authored in a y-down 211×165 frame (the SVG
            // canvas). Build that frame: flip the canvas vertically, then
            // scale + centre the artwork's content box onto it.
            ctx.translateBy(x: 0, y: side)
            ctx.scaleBy(x: 1, y: -1)
            let scale = side / Design.canvasWidth
            ctx.translateBy(
                x: (side - Design.contentBounds.width * scale) / 2 - Design.contentBounds.minX * scale,
                y: (side - Design.contentBounds.height * scale) / 2 - Design.contentBounds.minY * scale
            )
            ctx.scaleBy(x: scale, y: scale)

            let colour = color(for: state)
            colour.setStroke()
            colour.setFill()

            // 1) Rect stroke, clipped clear of the triangle's interior —
            //    this reproduces the interruption the SVG's white
            //    triangle fill carves into the screen's bottom edge (see
            //    the occlusion note in the file header). The triangle's
            //    own stroke band re-covers the ±7.448-unit margin of
            //    that cut when it is stroked below.
            NSGraphicsContext.saveGraphicsState()
            let clip = NSBezierPath(
                rect: NSRect(x: 0, y: 0, width: Design.canvasWidth, height: Design.canvasHeight)
            )
            clip.append(triangle())
            clip.windingRule = .evenOdd
            clip.addClip()

            let rect = NSBezierPath(
                roundedRect: Design.rect,
                xRadius: Design.rectCornerRadius,
                yRadius: Design.rectCornerRadius
            )
            rect.lineWidth = Design.lineWidth
            rect.stroke()
            NSGraphicsContext.restoreGraphicsState()

            // 2) The triangle outline (unclipped — the clip above clears
            //    only its interior). Miter joins reproduce the SVG's
            //    sharp 60°-ish corners; butt caps match its linecap.
            let outline = triangle()
            outline.lineWidth = Design.lineWidth
            outline.lineJoinStyle = .miter
            outline.lineCapStyle = .butt
            outline.stroke()

            // 3) The two eyes, painted last (SVG paint order) as solid
            //    discs — each is the SVG's r12.5 circle merged with its
            //    14.8958 stroke, i.e. one filled circle of radius
            //    12.5 + lineWidth/2.
            for centre in Design.eyeCentres {
                let radius = Design.eyeOuterRadius
                NSBezierPath(
                    ovalIn: NSRect(
                        x: centre.x - radius,
                        y: centre.y - radius,
                        width: 2 * radius,
                        height: 2 * radius
                    )
                ).fill()
            }

            return true
        }
        // Colour carries the state (ruling ③) — deliberately NOT a template
        // image, which the system would re-tint to monochrome.
        image.isTemplate = false
        return image
    }

    /// State colour mapping (A3 §A three-state swatches) — unchanged from
    /// CP-2 ①: four receiver states, three colours.
    static func color(for state: ReceiverState) -> NSColor {
        switch state {
        case .idle, .stopping:
            return .systemGray
        case .waiting:
            return .systemOrange
        case .connected:
            return .systemGreen
        }
    }

    // MARK: - Geometry (source-canvas units — 1 unit = 1 SVG unit)

    private enum Design {
        /// Source canvas (the SVG export frame). The width drives the
        /// scale: side/211 keeps the full 204.9-unit content width at
        /// ~97% of any canvas side, matching the previous design's fill.
        static let canvasWidth: CGFloat = 211
        static let canvasHeight: CGFloat = 165

        /// Stroke width in canvas units — the SVG's own value on every
        /// path (rect, triangle, both eye circles). At the 18-pt canvas:
        /// 14.8958 × 18/211 = 1.27 pt (Retina ≈2.54 px): at/above the
        /// menu-bar convention, so no adjustment applies (the N-8 raise
        /// addressed only the old design's 0.45-pt weight).
        static let lineWidth: CGFloat = 14.8958

        /// The rounded “screen” — the SVG's 190×118 rect at (11.5, 8.5),
        /// circular corner radius 19.667.
        static let rect = NSRect(x: 11.5, y: 8.5, width: 190, height: 118)
        static let rectCornerRadius: CGFloat = 19.667

        /// The play triangle — the SVG's own three vertices, apex up
        /// (y-down frame). Transcribed verbatim (the trace is close to,
        /// but not exactly, equilateral — the authored vertices win).
        static let triangleVertices = [
            CGPoint(x: 106.5, y: 68.5),   // apex — inside the screen
            CGPoint(x: 55.5, y: 157.5),   // base, left
            CGPoint(x: 157.5, y: 157.5),  // base, right
        ]

        /// Eye centres — the SVG's r12.5 circles at (54,54) and (159,54).
        static let eyeCentres = [CGPoint(x: 54, y: 54), CGPoint(x: 159, y: 54)]
        /// Eye merge radius: r12.5 + the SVG's 14.8958 stroke (the disc
        /// the stroked-and-filled circle resolves to)= 19.9479.
        static let eyeOuterRadius: CGFloat = 12.5 + lineWidth / 2

        /// Bounding box of all inked content INCLUDING half the stroke —
        /// x: rect edges 11.5/201.5 ∓ lw/2; y: rect top 8.5 − lw/2 …
        /// triangle base outer edge 157.5 + lw/2 (the eye discs and the
        /// apex tip sit strictly inside these bounds)— used to optically
        /// centre the artwork on the menu-bar canvas at any size. Its
        /// CENTRE (106.5, 83.0) is the design's own symmetry centre, so
        /// the placement never shifts between sizes.
        static let contentBounds = NSRect(
            x: 11.5 - lineWidth / 2,
            y: 8.5 - lineWidth / 2,
            width: 190 + lineWidth,
            height: 149 + lineWidth
        )
    }

    /// The play-triangle path — the SVG's own vertex list, closed
    /// (y-down frame; used both as the drawn outline and as the clip
    /// footprint, exactly like the SVG's one triangle path).
    private static func triangle() -> NSBezierPath {
        let path = NSBezierPath()
        path.move(to: Design.triangleVertices[0])
        path.line(to: Design.triangleVertices[1])
        path.line(to: Design.triangleVertices[2])
        path.close()
        return path
    }
}

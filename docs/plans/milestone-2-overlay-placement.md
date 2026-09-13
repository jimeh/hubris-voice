# Milestone 2: overlay placement

Design brief for milestone 2 of [the daily driver plan](2026-09-13-daily-driver.md).
Builds on milestone 1. This document is the implementation contract.

## Outcome

- The overlay is positioned relative to the field being dictated into, using
  the best geometry the target app exposes, and never on the mouse's screen
  unless nothing better is known.
- Growth while the transcript streams keeps the edge nearest the field fixed.
- A placement preference lets the user force bottom or top of screen.

## Anchor resolution

At press time, immediately after `TextInsertionService.captureFocusedTarget()`,
the app resolves an `OverlayAnchor` from the same Accessibility handles.
Resolution order, first success wins:

1. **Caret.** `kAXBoundsForRangeParameterizedAttribute` on the focused
   element with its `kAXSelectedTextRangeAttribute` range. Accept a rect
   with `height > 0` and `width >= 0` whose center lies inside some
   `NSScreen.frame`. A zero-width rect is a valid caret.
2. **Element.** `kAXPositionAttribute` and `kAXSizeAttribute` of the focused
   element. Accept when both dimensions are `> 0` and the center is on a
   screen.
3. **Window.** `kAXFocusedWindowAttribute` of the application element, then
   its position and size. Same acceptance rule.
4. **None.** The app falls back to the screen under the mouse, as today.

Accessibility positions use a top-left origin measured from the primary
screen's top-left corner. Convert to AppKit's bottom-left origin before the
rect leaves the app layer:
`appKitY = primaryScreen.frame.height - (axY + height)`. The conversion is a
pure function in the core so it can be tested with stacked and mixed-scale
display layouts.

The screen used for clamping is the `NSScreen` whose frame contains the
anchor's center; for `.none` it is the mouse screen.

## Core types

`Sources/HubrisVoiceCore/OverlayPlacement.swift`:

```swift
public struct LayoutPoint: Equatable, Sendable { public var x, y: Double }
public struct LayoutSize: Equatable, Sendable { public var width, height: Double }
public struct LayoutRect: Equatable, Sendable {
  public var origin: LayoutPoint
  public var size: LayoutSize
  public var minX, midX, maxX, minY, midY, maxY: Double { get }
  public static func fromTopLeft(x: Double, y: Double, width: Double, height: Double,
                                 primaryScreenHeight: Double) -> LayoutRect
}

public struct OverlayAnchor: Equatable, Sendable {
  public enum Kind: Equatable, Sendable { case caret, element, window }
  public let kind: Kind
  public let rect: LayoutRect        // AppKit coordinates
}

public enum OverlayPlacementPreference: String, CaseIterable, Sendable {
  case automatic, bottomOfScreen, topOfScreen
}

public struct OverlayPlacement: Equatable, Sendable {
  public var gap: Double = 12          // between anchor and panel
  public var screenInset: Double = 44  // from top or bottom screen edge
  public var edgeMargin: Double = 8    // minimum distance from left/right/top/bottom of visibleFrame

  public func origin(
    anchor: OverlayAnchor?,
    preference: OverlayPlacementPreference,
    panelSize: LayoutSize,
    visibleFrame: LayoutRect
  ) -> LayoutPoint
}
```

Rules for `origin`:

- `bottomOfScreen`, or `preference == .automatic` with `anchor == nil`:
  horizontally centered in `visibleFrame`, `y = visibleFrame.minY + screenInset`.
- `topOfScreen`: horizontally centered, `y = visibleFrame.maxY - screenInset - panelSize.height`.
- `automatic` with a `caret` or `element` anchor: center the panel on
  `anchor.rect.midX`. Prefer above: `y = anchor.rect.maxY + gap`. If that
  would put `y + height` above `visibleFrame.maxY - edgeMargin`, place below:
  `y = anchor.rect.minY - gap - height`. If neither fits, use above and
  clamp.
- `automatic` with a `window` anchor: the field's location inside the window
  is unknown, and inputs are usually near the bottom, so place inside the
  window near its top: center on `window.midX`,
  `y = window.maxY - edgeMargin - height`.
- Always clamp the final origin so the panel stays inside `visibleFrame`
  inset by `edgeMargin` on every side. Clamping happens after the rules
  above, never instead of them.

## App changes

### `TextInsertionService.swift`

Add `func captureAnchor(for focus: CapturedFocus?) -> OverlayAnchor?`
implementing the resolution order above. Reuse the existing private AX
helpers; add a parameterized-attribute helper for the caret bounds and a
point/size helper for `AXValue` of type `.cgPoint` and `.cgSize`. Keep all
`NSScreen` use in this file or the overlay controller, never in the core.

### `Overlay.swift`

- `OverlayController.show(anchor: OverlayAnchor?, preference: OverlayPlacementPreference)`
  replaces the parameterless `show()`. It stores the anchor and preference,
  resolves the target screen, computes the origin with `OverlayPlacement`,
  sizes the panel, and orders it front. It remains idempotent: if the panel
  is already visible, only the anchor and preference are updated and the
  position is recomputed without ordering front again.
- `resizeForTranscript` recomputes the origin through the same placement
  call with the new size, so growth above an anchor extends upward and
  growth below extends downward. Replace the existing
  `positionOnActiveScreen` with the placement path; the mouse screen is only
  the fallback when `anchor == nil`.
- Keep the existing sizing options and hosting view behavior.

### `AppModel.swift`

- Read `OverlayPlacementPreference` from `UserDefaults` key
  `overlay.placement`, default `.automatic`. Expose it as `@Published var
  overlayPlacement` and persist on change.
- In `startCapture(generation:)`, capture the anchor right after the focus
  and store it as `currentAnchor`. Pass `currentAnchor` and the preference to
  `overlayController?.show(anchor:preference:)` from `publishSessionState`.
  Result and error presentations use the same anchor so the overlay does not
  jump when the state changes.
- Clear `currentAnchor` when the overlay hides.

### `SettingsView.swift`

Add an "Overlay placement" picker to the push-to-talk section with the three
preferences, labelled "Automatic", "Bottom of screen", "Top of screen".

## Tests

`Tests/HubrisVoiceCoreTests/OverlayPlacementTests.swift`:

1. Bottom-of-screen preference centers horizontally with the inset.
2. Top-of-screen preference sits below the top inset.
3. Automatic with no anchor equals bottom-of-screen.
4. Caret anchor with room above places the panel `gap` above the caret,
   centered on its midX.
5. Caret anchor near the top of the visible frame flips below.
6. Element anchor near the left edge clamps to `edgeMargin`.
7. Anchor with no room above or below uses above and clamps to the top
   margin.
8. Window anchor places inside the window near its top.
9. A zero-width, positive-height caret rect is used, not rejected. (Test the
   placement with such a rect; acceptance lives in the app layer.)
10. `fromTopLeft` converts a rect on the primary screen and on a screen
    stacked above the primary screen (negative AX y).
11. Growth: calling `origin` twice with a taller panel above an anchor keeps
    `minY` fixed; below an anchor keeps `maxY` fixed.

Update `OverlayControllerTests` for the new `show` signature; keep the
existing growth assertion.

## Checkpoints

1. Core types and the eleven placement tests green.
2. Anchor capture in `TextInsertionService`.
3. Overlay controller placement and resize, `AppModel` wiring, settings
   picker. `mise run check` green.
4. Self-review: no AppKit or CoreGraphics in the core; every rule in
   "Rules for `origin`" has a test; report anything unverifiable without a
   real macOS run.

## Manual verification (user present)

Native text field (TextEdit), a Slack or Discord composer at the bottom of
the window, a terminal prompt, a full-screen app, a second display placed
above the primary, and each preference.

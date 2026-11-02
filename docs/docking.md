# Companion docking and displays

Choose **Appearance → Companion display** and **Screen edge** to place Mochlet at the top, left or right of a connected display. The expanded side panel opens inward. **Center on selected edge** resets its position along that edge. Dragging the compact slime or expanded header offers the same placement path.

Automatic selection prefers a notched display, then the current main display, then an available display. An explicit choice uses the display UUID supplied by macOS where unique and available. Numeric display IDs from older preferences migrate when that display is found. If a saved display is disconnected, the app uses an available display and retains the preference so it can return when that identity reconnects. The picker labels the missing saved display; choosing Automatic explicitly replaces that preference.

Some virtual or identical displays may expose missing or duplicate UUIDs. Those choices use a session-specific ID, with a visible reminder to select again if the ID changes after restart. No claim is made that a hardware/adapter change always preserves display identity.

## Interrupted drags

Drag state now lives in a bounded transient state object. Escape, gesture cancellation, display reconfiguration, lock and sleep cancel placement changes and restore the saved placement. Late drag updates are suppressed until release/reset; duplicate release events cannot commit again. Local/global mouse-up handling complements SwiftUI gesture completion. Wake recomputes geometry. These operations do not modify tasks or cancel agent work.

## Evidence and limits

- Core fixture covers negative screen coordinates, anchor stability, cancellation, late updates, duplicate completion and invalid coordinates.
- Native-host fixtures cover explicit UUID selection, changed numeric IDs, disconnection/reconnection fallback, legacy IDs, no-notch/main selection and an empty display list.
- Native isolated QA selected the built-in display, quit/relaunched and verified restoration; right-edge expansion and Escape folding passed. [Settings screenshot](evidence/native-display-settings.jpg), [side panel](evidence/native-display-side-panel.jpg).
- Full check: 128 reported tests, three opt-in live skips, native build and orchestration fixtures pass. Read-only review found no Required/Critical findings.

Physical dragging and interrupted-drag event ordering, real display unplug/replug, full-screen/Space changes and sleep/lock still need interactive hardware validation. The native automation backend previously could not drag the borderless panel; this slice does not claim that gate passed. The global shortcut was not confirmed by synthetic input; the in-app shortcut and Escape were confirmed.

## Primary references

Apple documents that [gesture completion runs only on success](https://developer.apple.com/documentation/swiftui/gesture/onended(_:)) and [GestureState resets on cancellation](https://developer.apple.com/documentation/swiftui/gesturestate). Screen updates follow [display-configuration notifications](https://developer.apple.com/documentation/appkit/nsapplication/didchangescreenparametersnotification). Display identity uses [ColorSync UUID conversion](https://developer.apple.com/documentation/colorsync/cgdisplaycreateuuidfromdisplayid(_:)); [numeric display IDs](https://developer.apple.com/documentation/coregraphics/cgdirectdisplayid) can change on restart. Retrieved through Context7 and Apple documentation on 2026-11-02.

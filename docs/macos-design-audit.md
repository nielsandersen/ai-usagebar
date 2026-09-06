# macOS design review — 6 September 2026

Direction: preserve the custom compact readout, provider marks, rings, and native menu. Refine the surrounding controls to feel at home on macOS.

The existing design uses native menus, system fonts, and semantic text colors. It avoids decorative cards and artificial dashboard styling. Its main issues are discoverability and accessibility rather than its visual identity.

## Findings and implementation scope

- **High — Settings organization:** one long page mixes six groups and thirteen providers. Split General, Appearance, and Providers into native toolbar panes with independently scrollable content.
- **High — Accessible readout:** icon attachments have no explicit provider/value description. Give the status button a stable name and spoken values, and give truncated menu rows their full labels.
- **Medium — Provider setup:** disabled providers look like broken logins; first-render checks imply failure before finishing. Distinguish checking, login found, missing key, and not enabled. Put optional providers behind disclosure and refresh when returning from sign-in.
- **Medium — Resizing:** fixed-width SwiftUI content ignores the resizable window. Allow horizontal growth and preserve scrolling at short heights.
- **Medium — Menu grid:** connection notices incorrectly contribute to numeric label width. Measure only data rows.
- **Medium — Recovery discoverability:** Refresh is buried in More. Put Refresh Now in the main menu and use familiar Settings and Quit labels.
- **Low — Copy and hierarchy:** remove environment-variable names and TUI jargon from setup status; use consistent labels and standard control sizing.

Custom usage colors remain user-controlled. Color supplements numeric values; it is not the only source of information. This review does not claim full VoiceOver or contrast certification without manual assistive-technology testing.

## Sources

- Apple HIG: https://developer.apple.com/design/human-interface-guidelines/the-menu-bar
- Apple HIG: https://developer.apple.com/design/human-interface-guidelines/settings
- Apple HIG: https://developer.apple.com/design/human-interface-guidelines/accessibility

## Verification

Compile native application; run Swift regression tests; launch the actual settings views in a separate preview app using isolated preferences. Native UI selection timed out and offscreen image rendering did not produce usable screenshots, so visual light/dark, keyboard, and VoiceOver verification remain manual. Run the existing release checks before publishing the updated package.

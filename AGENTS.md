# ClipToMac Mac contributor rules

Before changing UI, read [`DESIGN_SYSTEM.md`](DESIGN_SYSTEM.md). Keep Android and Mac visually consistent while using native controls and conventions on each platform.

## Code structure

- Keep SwiftUI views focused on rendering and user interaction. Move business rules, protocol mapping, persistence, and transfer orchestration into focused types under `Sources/`.
- Keep `ContentView` as composition and presentation; keep `ClipStore` as library state/persistence coordination, not a catch-all network or UI implementation.
- Keep HTTP route handling thin: validate/authenticate input, dispatch to a feature/service, and encode a typed response. Put transfer and notification behavior in their own types.
- Use typed models and named constants for protocol contracts. Avoid duplicated JSON keys, magic limits, and stringly typed state transitions.
- Handle missing files, stale devices, permission denial, cancellation, and network failures explicitly. Surface actionable, user-readable errors without leaking secrets or notification contents into logs.
- Put user-facing copy in a localization catalog/resource as the project adopts one; until then centralize repeated copy rather than duplicating it across large views.

## UI implementation

- Reuse existing SwiftUI components, `GraphiteButtonStyle`, glass background, and system materials before adding custom drawing or new visual treatments.
- Preserve native macOS behavior: keyboard focus, Escape dismissal, VoiceOver labels, window sizing, scroll ownership, and light/dark appearance.
- Keep state ownership explicit and observable. Avoid doing file or network work synchronously on the main actor.
- Render loading, empty, error, disabled, and success states explicitly. Do not communicate state through color alone.

## Verification

- Add or update focused regression coverage for storage, protocol, security, and state changes using the existing `Tests/` harnesses.
- Run `./build.sh` and the relevant scripts in `Tests/` for Mac changes. Run all affected harnesses for protocol or persistence changes.
- Report commands and results. Do not claim UI/device behavior was verified by compiling alone.

# ClipToMac design system

This guide documents the existing ClipToMac visual language and the rules for extending it. Keep the phone and Mac apps recognizable as one product while respecting native platform behavior.

## Product feel

- Calm, precise, and utility-first. The interface should make connection, transfer progress, and the next action immediately clear.
- Use the dark graphite palette, restrained glass/translucent surfaces, thin subtle borders, and bundled Oxanium typography.
- Prefer clear hierarchy and generous spacing over decorative labels, excess gradients, or competing emphasis.

## Shared visual tokens

Match the semantic Android palette; use native SwiftUI/AppKit colors and materials where appropriate:

| Role | Shared intent | Use |
| --- | --- | --- |
| App background | Near-black graphite (`#0B0D10`) | Main app canvas |
| Surface | Deep charcoal (`#1E2126`) | Cards, sheets, grouped panels |
| Raised surface | Graphite (`#2B2F35`) | Selected rows, controls, secondary panels |
| Primary text | Soft white (`#F3F6FC`) | Titles and key values |
| Secondary text | Cool gray (`#AFB5BE`) | Supporting labels and descriptions |
| Subtle border | Slate gray (`#454B54`) | Card and input outlines |
| Neutral accent | Light silver (`#D5DAE0`) | Primary emphasis and selected controls |
| Destructive | Muted rose (`#E7AFB2`) | Destructive actions with confirmation |

Connection and transfer states may use semantic green, amber, and red indicators. Pair each indicator with readable text or an icon; color must not be the only status cue. Avoid introducing a second accent palette without updating both platforms and this guide.

## Type and layout

- Use bundled Oxanium for app text across Android and Mac. Native system surfaces use their platform typography. Keep heading, body, secondary, and metadata roles distinct.
- Use an 8-point spacing rhythm where practical: 8 for tight control gaps, 12 for related content, 16 for card/content padding, and 24 for section separation.
- Use modest continuous rounded corners consistent with current components (roughly 6–12 pt). Avoid pill shapes for large content cards.
- Keep interactive targets comfortable and keyboard/mouse accessible. Icon-only actions need accessibility labels and help text.

## Components and interaction

- Reuse `GraphiteButtonStyle`, existing glass backgrounds, native materials, and current card patterns before creating another component or style.
- Prefer grouped cards for related settings and transfer details; use one clear primary action per section and quieter secondary actions.
- Show transfer direction, file name, byte progress, rate/ETA when known, and a clear waiting/paused/cancelled/failed state. Never show stale values as current.
- Confirm destructive actions, explain what data is removed, and offer undo when the existing flow supports it.
- Use native macOS panels, menus, keyboard focus, and scroll behavior. Do not imitate Android controls where they conflict with Mac conventions.
- Respect light/dark appearance and reduced transparency. Design empty, loading, error, offline, permission-denied, and expired states alongside the happy path.

## Change rule

Before adding a color, font treatment, spacing, shadow, corner radius, or reusable component, check existing shared styles first. If a new token is necessary, define it centrally on Android, mirror its intent on Mac, and update both platform implementations and this guide in the same change.

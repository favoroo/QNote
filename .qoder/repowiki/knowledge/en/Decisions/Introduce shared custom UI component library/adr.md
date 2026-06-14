# Introduce shared custom UI component library

_Source: coding plans from commit period 2a749f1 → bbf9572 — records intent at planning time; the implementation may lag or differ._

**Status:** accepted

## Context
Redesigning every page individually with raw Material widgets would lead to code duplication and visual drift. A consistent set of reusable components was needed to enforce the new design language (subtle borders, no shadows, specific radii) across Diary, Notes, Todo, and other features.

## Decision drivers
- Development efficiency
- Visual consistency
- Maintainability of design tokens

## Considered options
- **Shared custom widgets (q_card, q_button, q_chip)** — pros: Encapsulates design rules (borders, colors, radii) in one place; ensures uniform appearance across all pages; simplifies future design tweaks.; cons: Initial upfront cost to create and test these wrappers; adds a layer of abstraction over Material widgets.
- **Inline styling on each page** _(rejected)_ — pros: No new files to create initially.; cons: High risk of inconsistency; difficult to update global design rules; verbose code on every page.

## Decision
Create a set of shared widgets in `lib/widgets/`: `q_card.dart` (dark surface, subtle border, no shadow), `q_button.dart` (primary/secondary/ghost variants with neon green), `q_chip.dart` (filled/outlined tags), and `q_section_header.dart`. These components replace direct usage of standard Material widgets in the redesigned pages.

## Consequences
Developers must use these shared components instead of standard Material widgets for core UI elements. This enforces the design system but requires discipline to avoid bypassing the components for quick fixes.
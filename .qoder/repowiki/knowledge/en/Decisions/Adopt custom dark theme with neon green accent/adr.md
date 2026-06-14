# Adopt custom dark theme with neon green accent

_Source: coding plans from commit period 2a749f1 → bbf9572 — records intent at planning time; the implementation may lag or differ._

**Status:** accepted

## Context
The application required a visual overhaul to match a specific design language (deep near-black backgrounds, neon green accents) that diverges significantly from standard Material Design defaults. The existing theme system needed restructuring to support this distinct aesthetic while maintaining consistency across all modules (Diary, Notes, Todo, AI, Settings).

## Decision drivers
- Visual identity alignment with reference design
- Consistency across all UI modules
- Readability and contrast in low-light environments

## Considered options
- **Custom dark theme with neon green accent (#00E676)** — pros: Matches the target design language exactly; provides high contrast for primary actions; distinct brand identity.; cons: Requires manual override of many Material component defaults; light mode remains unchanged for now, creating potential asymmetry.
- **Standard Material Dark Theme** _(rejected)_ — pros: Zero implementation cost; consistent with platform defaults.; cons: Fails to meet the specific 'deep near-black' and 'neon green' design requirements; lacks the desired visual distinctiveness.

## Decision
Implement a custom dark theme defined in `lib/core/theme/app_colors.dart` and `lib/core/theme/app_theme.dart`. The palette uses deep near-black backgrounds (#0D0F14 base, #141820 cards) and a neon green accent (#00E676). Light theme is preserved as-is for now. Component themes (AppBar, Card, Input, etc.) are explicitly overridden to remove heavy shadows and use subtle borders.

## Consequences
All UI modules must adopt the new color tokens (`bgBase`, `accent`, etc.). Standard Material widgets will require custom styling or replacement with shared components (e.g., `q_card.dart`, `q_button.dart`) to maintain visual consistency. Light mode functionality is preserved but not updated to match the new design language in this phase.
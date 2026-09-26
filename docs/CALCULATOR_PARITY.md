# Calculator parity record

Date: 2026-09-19

This is the Gate G1 comparison record. It distinguishes implemented behavior, automated evidence, and behavior that still requires observation on the owner's iPhone. It does not claim pixel parity with Apple Calculator.

## Implemented and automated

| Area | Current behavior | Evidence |
|---|---|---|
| Ordinary arithmetic | Decimal-backed addition, subtraction, multiplication, and division with explicit divide-by-zero errors | `ExpressionParserTests`, `CalculatorEngineTests` |
| Expression rules | Parentheses, deterministic precedence, right-associative powers, unary signs, malformed-input rejection, and source/exponent bounds | `ExpressionParserTests` |
| Key state | Leading-zero normalization, negative zero, decimal entry, delete, C/AC, operator replacement, continued calculation, repeated equals, and bounded input | `CalculatorEngineTests` |
| Percent | Add/subtract percentages use the current left side; multiply/divide use a fractional operand | `CalculatorEngineTests` |
| Scientific | Powers, roots, reciprocal, factorial, logarithms, exponentials, constants, degree/radian trigonometry, inverse trigonometry, memory, and typed domain errors | `CalculatorEngineTests` |
| History | In-memory newest-first inspection, result reuse, bounded retention, individual deletion, and clear-all | `CalculatorHistoryStoreTests`, `CalculatorViewModelTests` |
| Conversions | Offline length, mass, temperature, area, volume, time, and speed conversion; temperature uses affine formulas | `UnitConversionTests` |
| Boundaries | Calculator sources do not import authentication, vault, Keychain, Photos, or WebKit code | repository boundary scan |

## UI implementation

- Portrait mode provides the basic keypad plus a horizontally scrolling scientific strip.
- Landscape mode exposes the expanded scientific and memory pad beside the basic keypad.
- History and conversion tools are separate sheets. Phase 0 diagnostics, independent archive access, and social feasibility screens remain available under Prototype tools.
- Button geometry, colors, spacing, and display sizing are centralized in `CalculatorTheme`.
- Controls have accessibility labels, and the display exposes an accessibility value.

## Explicit parity gaps and provisional choices

- Owner-supplied Apple Calculator screenshots are now available for portrait and landscape reference on the target iPhone/iOS combination. They establish visible control presence and broad layout only; pixel-level color, typography, spacing, haptics, animation, and Dynamic Type parity remain **not verified**.
- Operator precedence is conventional mathematical precedence. Apple Calculator behavior for the owner's exact iOS version has not been recorded side by side.
- Percent behavior is implemented and tested as documented above, but has not been compared on the owner's iOS version.
- Repeated equals, operator replacement, scientific rounding, error wording, rotation layout, memory controls, and history interaction require physical comparison.
- The UI currently shows a period decimal key. Parser and formatter locale behavior is tested, but automatic locale selection in the UI is not implemented.
- Calculator history is intentionally in memory only for Gate G1. Persistence behavior has not been specified or claimed.
- Physical testing confirmed that history clears after the app process is closed. This matches the current in-memory implementation but remains a parity gap if the selected Apple Calculator reference persists history.

## Physical review checklist

Install the Gate G1 IPA on the existing iPhone without deleting the current app, then check:

1. Launch reaches the calculator and Prototype tools still opens the Phase 0 screens.
2. Basic portrait keys remain fully visible and usable at default and larger text sizes.
3. Rotate to landscape and exercise parentheses, power, roots, trigonometry, degree/radian mode, and memory.
4. Compare `5 + 2 = =`, `8 + × 3 =`, `200 + 10 % =`, `200 × 10 % =`, divide by zero, and a long result with Apple Calculator on the same iOS version.
5. Open History, reuse one result, delete one entry, and clear the remainder.
6. Open Convert and check at least one ordinary conversion plus `0 °C = 32 °F`.
7. Background and foreground once to ensure the Phase 0 privacy cover does not break calculator state.

Gate G1 passes with the documented limitations below. This is not a claim of full pixel or accessibility parity with Apple Calculator.

## Physical observations

### 2026-09-19 — installation, launch, and portrait layout

- PASS: the owner supplied a screenshot of the Phase 1 IPA running on the iPhone at the Calculator screen.
- PASS: the portrait display, complete five-row basic keypad, history control, conversion control, Prototype tools control, and horizontally scrolling scientific strip were visible.
- PASS: repeated equals — entering `5 + 2 = =` produced `9`; after the second equals, the expression display showed `7 + 2`.
- PASS (owner-observed): operator replacement — entering `8 + × 3 =` returned `24`, confirming that `×` replaced the pending `+`.
- PASS (owner-observed): additive percent — entering `200 + 10 % =` returned `220`.
- PASS (owner-observed): multiplicative percent — entering `200 × 10 % =` returned `20`.
- PASS (owner-observed): divide by zero — entering `1 ÷ 0 =` displayed `Cannot divide by zero` without terminating the app.
- PASS (owner-observed): history publication — successful calculations appeared after several calculations, while the `1 ÷ 0` error was omitted.
- PASS (owner-observed): history reuse — selecting a successful entry closed History and restored its result to the calculator display.
- PASS (owner-observed): history deletion — swiping and deleting one entry removed only that entry while preserving the others.
- PASS (owner-observed): history clear-all — Clear removed every remaining entry without changing the current calculator display.
- PASS (owner-observed): affine temperature conversion — `0 °C` converted to `32 °F`.
- PASS (owner-observed): multiplicative length conversion — `1 mile` converted to `1.609344 kilometers`.
- PASS (owner-observed): landscape layout — the expanded scientific keypad appeared fully usable without overlapping or clipped controls.
- PASS (owner-observed): square root — applying `√` to `9` displayed `3`.
- PASS (owner-observed): degree-mode trigonometry — with `Deg` selected, applying `sin` to `30` displayed `0.5`.
- PASS (owner-observed): radian-mode trigonometry — with `Rad` selected, `sin(π ÷ 2)` displayed `1`.
- PASS (owner-observed): scientific domain rejection — applying `√` to `-1` displayed `Domain error` without terminating the app.
- PASS (owner-observed): parentheses — entering `(2 + 3) × 4 =` returned `20`.
- PASS (owner-observed): power — entering `2 xʸ 3 =` returned `8`.
- PASS (owner-observed): factorial — applying `x!` to `5` returned `120`.
- PASS (owner-observed): memory add/recall — entering `4`, then `M+`, `AC`, and `MR` restored `4`.
- PASS (owner-observed): memory clear — after `MC`, `AC`, and `MR`, the display showed `0`.
- PASS (owner-observed): Phase 0 route preservation — Diagnostics, Independent local archive, and Social web profiles remained present under Prototype tools.
- PASS (owner-observed): foreground restoration — a displayed value of `42` remained after entering the app switcher and returning without terminating the app.
- OBSERVED LIMITATION: history cleared after closing and reopening the app, matching the documented in-memory store.
- NOT RUN: other key behavior, remaining scientific calculations, larger text, VoiceOver, and comparison with Apple Calculator.
- REFERENCE OBSERVATION: the owner supplied an Apple Calculator landscape screenshot showing the menu at top left and no top-right control. The standalone CalcVault `?` recovery button therefore failed visual parity and was removed. Recovery was initially assigned to a three-tap hotspot, then increased to fifteen taps at the owner's request. The blank top-right navigation area remains visually unchanged; the replacement passed fourteen-tap non-trigger and exact fifteen-tap trigger checks on the physical iPhone.

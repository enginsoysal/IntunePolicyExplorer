# 1.3.2 validation — 2026-11-06

Validation on Windows with synthetic Graph responses, followed by a real-tenant desktop test after the user signed in. Live requests were read-only; no tenant policies were changed. Tenant exports remain in a local Downloads QA folder, outside the repository.

## Correction after user tenant testing

The initial GUI fixtures all produced several settings rows and did not cover Administrative Templates or a single search match. The user's click on an Administrative Template with an empty `definitionValues` collection exposed an `ItemsSource` exception. The exact failure was reproduced before applying the fix. The previous passing totals did not establish correctness for that case.

The corrected detail and search bindings always capture arrays. `Test-Collections.ps1` executes the production detail-display statements (without the interactive error-message catch) against all ten policy types with zero, one and two configured settings. It also tests both production search binding paths with zero, one and two matches. GUI integration now exercises single-match and zero-match searches through the real button event as well. These tests run on both PowerShell versions in CI.

| Check | Result |
| --- | --- |
| Analysis regressions — Windows PowerShell 5.1 | 37 passed |
| Analysis regressions — PowerShell 7 | 37 passed |
| Collection cardinality, all ten policy types, search and JSON — PowerShell 5.1 | 70 passed |
| Collection cardinality, all ten policy types, search and JSON — PowerShell 7 | 70 passed |
| Production GUI events, bindings and exporters — PowerShell 5.1, 850×600 window | 32 passed |
| Production GUI events, bindings and exporters — PowerShell 7, 640×480 window | 32 passed |
| WPF layout, reachability and hit testing | 222 checks passed |
| Readable button labels, column minimum widths, summary/button overlap | Passed throughout layout matrix |
| Deterministic release build | Two builds using the same runtime produced identical per-file and ZIP SHA-256 checksums |
| Module metadata/import | Validated; import opens no window and exports only `Show-IntunePoliciesGUI` |

The layout matrix uses 1280×720, 1366×768 and 1920×1080 display areas, each at simulated 100%, 125%, 150% and 200% scale. The test subtracts taskbar space and converts to DIP viewports without changing Windows display settings. It visits all main and nested tabs, expands advanced options, supplies long tenant/analysis text and checks every named action and export selector. Controls may require page scrolling on a small screen. Their entire bounds must fit the scrolled viewport, their centers must hit the intended control, and button text must fit. The device-code helper is checked at 540×300 and 380×200 without requesting authentication.

The GUI integration harness executes the real production event handlers with offline Graph mocks. It covers disconnected/connected button states, loading, refresh, policy selection/details, filtering, analysis coverage, populated insight grids, setting search, all export formats and disconnect cleanup. JSON is parsed again and CSV settings are counted. The native folder picker is not opened by these tests.

Visual inspection of generated WPF renders found and corrected the advanced form overflow, a collapsed result viewport at 150% scale, summary text competing with the analysis button, and table columns shrinking below readable widths. The renders demonstrate both the advanced connection action and Export action after scrolling at 640×480. Current renders and the JSON reachability report are generated in ignored `tests/results/`.

## Real-tenant desktop test

The user's successful sign-in loaded 20 policies. A real connection-state bug was found: the normal successful sign-in path could show Connected while the internal flag stayed false, disabling Refresh and Load details. The fix centralizes state changes in `Set-ConnectedUI`. The offline sign-in mock no longer pre-sets that state, and regressions check that Refresh and Analyze remain enabled after completion. After the user signed into the corrected build, desktop mouse and keyboard testing confirmed:

- All ten type filters, by mouse and arrow keys. Four types contain data: Administrative Templates (1), Configuration Profiles (6), Settings Catalog (12), Windows Autopilot (1). The other six filters correctly return an empty grid and disable Load details.
- A representative detail view for each populated type: the previously failing ADMX policy (one fallback row), a Configuration Profile (9 rows), a Settings Catalog policy (one row), and Autopilot (15 rows). The actual Load details button was also used. Full analysis and exports retrieved details for all 20 policies; not every row was individually clicked.
- Refresh completes and stays enabled; name filtering works for zero and one result and restores the full list when cleared.
- Analyze completes with assignments 20/20, details 20/20 and zero collection errors. Recommendations, Policy health and Potential conflicts render; seven potential conflicts are displayed without claiming effective target overlap.
- Find setting handles empty input with the expected validation message, zero matches, exactly one match, and ten matches. Both Search and Enter work. The lazy index-building path was separately tested after Refresh, before Analyze, with one match and zero collection errors.
- Native folder picker: select/expand/scroll/confirm/cancel. JSON, CSV, HTML and HTML Audit Report were created using the actual Export button. No-selection validation, return from cancellation, and Open folder Yes/No were tested.
- Full JSON parses to 20 policies and 262 settings, with all Settings properties remaining arrays. CSV parses to 20 overview rows and 262 settings rows. HTML contains 20 policy sections, 20 tables and 262 settings rows. Audit HTML includes full coverage, inventory and potential-conflict labeling, without Passed/Failed compliance cards. Audit export also ran its required analysis automatically with no selected policies. A separate selected-policy JSON contains exactly one ADMX policy and one settings row.
- Advanced options expand, and page scrolling reaches Connect with app registration and Disconnect. Disconnect clears the tenant identity, policies, settings and analysis and disables connected actions. Empty advanced credentials show the expected client-ID validation error without making an authentication request.
- The actual window was reduced to approximately 640×480 using the Windows Size menu. Scrollbar dragging reveals the lower connection controls; the advanced connection button was clicked at that size. The Export button is also reachable by scrolling (correctly disabled after Disconnect). Maximize returns the window to a large usable layout.

The app was deliberately left disconnected on the Connection tab after testing Disconnect. The last connection-error status came from the expected empty-client-ID validation test.

## Limits and remaining release checks

Populated policies for Compliance, Endpoint Security, App Protection (iOS/Android/Windows) and Mobile App Configurations do not exist in this tenant. Their live empty-filter behavior and synthetic zero/one/multiple-row cases are tested; their populated live API behavior is not. Custom-app sign-in and device-code fallback have not been tested end to end. Actual Windows DPI settings were not changed; the 12-scale layout matrix remains simulated. Hosted GitHub Actions has not run yet. No Gallery publication or GitHub release was performed.

Commands and build/publication instructions are in [README.md](README.md).

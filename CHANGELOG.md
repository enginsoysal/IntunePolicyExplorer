# Changelog

## 1.3.2

- Synchronized internal connection/tenant state with the connected UI for every successful sign-in path. Refresh, Load details, Analyze and Search stay usable after completion.
- Fixed the WPF table exception when a policy produces one settings row, including Administrative Templates with an empty `definitionValues` collection. Zero/one/multiple search matches bind consistently, and JSON settings remain arrays for single-row policies.

- Failed assignment requests remain unknown, instead of reporting policies as unassigned.
- Inventory and settings failures are retained in analysis coverage, Policy health and HTML audit reports.
- Empty intermediate Graph pages still follow pagination; expanded settings collections are paged separately. Unexpected collection responses become errors.
- Recommendations describe inventory presence only. Missing evidence becomes unknown when collection is incomplete; keyword matches never certify enabled protection.
- Conflicts are labeled potential, grouped by policy type/platform/category/setting and require distinct policies. Assignment overlap is not evaluated.
- JSON comparison ignores object IDs and property order; actual setting value differences remain detectable.
- Connection and Export forms scroll; policy actions wrap; window dimensions fit the available work area. The device-code helper is resizable and scrollable.
- Source-controlled module metadata, deterministic ZIP/checksums, Windows regression tests and CI.

## 1.3.1 — 2026-06-22

- Increased JSON serialization depth for nested Settings Catalog policies.

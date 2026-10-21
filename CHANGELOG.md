# Changelog

## 0.1.0 — 2026-10-22

First public release.

- Opens JSON, NDJSON and JSON Lines files of any size with a lazy, one-level scanner
- 32-byte records per node instead of a document tree; arrays over 10,000 items are grouped into ranges
- Background full-text search with match highlighting and jump-to-match
- Light and dark themes, adjustable text size
- Copy value, key or JSONPath
- Tolerant of malformed input (single quotes, unquoted keys, trailing commas, truncated files)
- Universal binary for Apple silicon and Intel

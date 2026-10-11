# How are values with more than 100 items shown?

**Already built (PR #5):** lists, maps and non-record tuples with more than
100 children report DAP's `indexedVariables`. The `variables` request reads
`start`, `count` and `filter`:

- a client that pages (VS Code) asks for parts with `start`/`count` and
  draws its own `[0..99]` groups;
- a client that sends neither (LSP4IJ never does; checked in its source)
  gets groups named `[0..99]`, `[100..199]`, …, each one expandable. Groups
  hold a power of 100 items, so a million-item list shows 100 groups of
  10,000, each of which opens into 100 groups of 100;
- `filter: "named"` on a large value returns nothing, since all its
  children are indexed.

`value.paged_size` and `value.children_page` in `src/gleam_dap/value.gleam`,
`slice` and the `RangeRef` reference in `src/gleam_dap/inspect.gleam`.

## Where and when it came up

Closing the gaps with ElixirLS, which shows every child of a value (see
[17-value-rendering.md](17-value-rendering.md) for the 100-item limit this
replaces).

## Options

### A. DAP paging plus server-side groups (chosen)

- Every item is reachable in both editors, and nothing large is ever sent
  in one response.
- Two code paths (client paging and server groups), both tested in
  `large_values_are_paged_test`.

### B. DAP paging only

- Smaller. VS Code would be fine.
- LSP4IJ ignores `indexedVariables`; it would show everything at once or,
  with the cap kept, still only 100 items.

### C. No limit when expanding (what ElixirLS does)

- Simplest.
- Expanding a 100,000-item list freezes the editor, which is the ElixirLS
  weakness PLAN.md set out to avoid.

## Why

A is the only option that both reaches every item and stays responsive in
both editors.

## Details worth knowing

- Records aren't paged: their children are their labelled fields, and a
  record with more than 100 fields is not a realistic case.
- Lists are walked from the start for each page, so deep pages of very long
  lists cost time proportional to the offset. Fine for the sizes people
  inspect by hand.
- Map pages follow the map's iteration order, which is stable for a given
  map but not sorted.

## How to change it

The threshold is `value.Options.max_items`. To drop the server-side groups,
make `slice` return `children_page(term, options, start, count)` when no
`start`/`count` came.

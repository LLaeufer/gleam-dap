# Where do constructor and field names come from?

**Already built:** labels are read from the record headers Gleam writes to
`build/dev/erlang/<package>/include/<module>_<Constructor>.hrl`
(`gleam_dap_value_ffi:read_record_headers`, used by `project.build_index`).

## Where and when it came up

Step 3 of PLAN.md: "Learn custom types (constructor names, labels, field
order) from the record headers Gleam generates or from parsing each module's
source", and the architecture section mentions `glance` for this. It came up
when making `Person(name: "Ada", age: 36)` render instead of
`{person, <<"Ada">>, 2}`, and again for field access in the debug console
(`person.name`).

## What I chose

Parse the `-record(...)` headers. Each gives the tag, the constructor and
the field labels in order. A value is matched by tag and arity. Tuples whose
tag matches no header still render as constructors (`Circle(2.0)`), just
without labels. The constructor name is rebuilt from the tag (`circle` to
`Circle`) when there's no header.

## Options

### A. Record headers (chosen)

- Gleam writes them for every constructor with labelled fields, for every
  package, as part of the normal build. No parsing of Gleam needed.
- Exact: they come from the compiler.
- Headers exist only for constructors with labels. Unlabelled constructors
  fall back to positional rendering, which is what Gleam shows for them too.
- Two types in one module with constructors that share a tag and arity can't
  be told apart (rare, and their labels then come from whichever was read
  last).

### B. Parse the Gleam source with `glance`

- Knows every type, including unlabelled constructors, generics and which
  type a constructor belongs to; could show type names.
- A whole Gleam parser as a dependency, to keep in step with the compiler's
  syntax, and one more package to isolate from the program (see
  [09-packaging.md](09-packaging.md)).
- Slower start for big projects (parse every module).

### C. Read the `-type` attributes in the BEAM files

- Gleam 1.19's abstract code has a `-type` declaration per custom type,
  listing each constructor's tag and field types. That would give type names
  and every constructor, without parsing Gleam.
- No field labels, so it can't replace the headers, only add to them.

## Why

A gives the user-visible result (labels) with no dependency and no parser to
maintain. The cases it misses render acceptably.

## How to change it

Replace `read_record_headers` in `src/gleam_dap_value_ffi.erl` and the
`labels` field built in `project.build_index` with a source-based index. The
rest of the code only consumes `value.Labels`.

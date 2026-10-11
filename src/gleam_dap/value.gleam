//// Rendering BEAM terms the way Gleam prints values, and splitting them
//// into children for the variables view.

import gleam/bit_array
import gleam/dict.{type Dict}
import gleam/dynamic.{type Dynamic}
import gleam/int
import gleam/list
import gleam/string
import gleam_dap/names

/// A BEAM term, as classified by the FFI.
pub type Term {
  TInt(Int)
  TFloat(Float)
  TAtom(String)
  TBinary(BitArray)
  TBitstring(BitArray, Int)
  TList(List(Dynamic))
  TImproperList(List(Dynamic), Dynamic)
  TTuple(List(Dynamic))
  TMap(List(#(Dynamic, Dynamic)))
  TFunction(module: String, name: String, arity: Int, anonymous: Bool)
  TPid(String)
  TReference(String)
  TPort(String)
  TOther(String)
}

@external(erlang, "gleam_dap_ffi", "classify")
pub fn classify(term: Dynamic) -> Term

@external(erlang, "gleam_dap_ffi", "format_term")
pub fn erlang_format(term: Dynamic, depth: Int) -> String

/// Field labels of custom type constructors, keyed by constructor atom and
/// arity (not counting the tag). Learned from the record headers Gleam
/// generates.
pub type Labels =
  Dict(#(String, Int), Constructor)

pub type Constructor {
  Constructor(name: String, labels: List(String))
}

pub type Options {
  Options(labels: Labels, max_length: Int, max_items: Int)
}

pub fn default_options(labels: Labels) -> Options {
  Options(labels:, max_length: 1000, max_items: 100)
}

/// Gleam syntax for a term, like `string.inspect`, but with field labels
/// and limited in size.
pub fn render(term: Dynamic, options: Options) -> String {
  let text = render_term(term, options, 6)
  case string.length(text) > options.max_length {
    True -> string.slice(text, 0, options.max_length) <> "…"
    False -> text
  }
}

fn render_term(term: Dynamic, options: Options, depth: Int) -> String {
  case depth <= 0 {
    True -> "…"
    False ->
      case classify(term) {
        TBitstring(_, _) -> erlang_format(term, 10)
        classified -> render_classified(classified, options, depth)
      }
  }
}

fn render_classified(term: Term, options: Options, depth: Int) -> String {
  case term {
    TInt(i) -> int.to_string(i)
    TFloat(f) -> render_float(f)
    TAtom(atom) -> render_atom(atom)
    TBinary(bits) ->
      case bit_array.to_string(bits) {
        Ok(text) -> render_string(text)
        Error(Nil) -> render_bytes(bits, options)
      }
    TBitstring(_, size) -> "<<…:size(" <> int.to_string(size) <> ")>>"
    TList(items) -> "[" <> render_items(items, options, depth) <> "]"
    TImproperList(items, tail) ->
      "["
      <> render_items(items, options, depth)
      <> " | "
      <> render_term(tail, options, depth - 1)
      <> "]"
    TTuple([first, ..rest] as items) ->
      case classify(first) {
        TAtom(tag) -> render_record(tag, rest, options, depth)
        _ -> "#(" <> render_items(items, options, depth) <> ")"
      }
    TTuple([]) -> "#()"
    TMap(pairs) ->
      "dict.from_list(["
      <> pairs
      |> take_with_ellipsis(options.max_items, fn(pair) {
        "#("
        <> render_term(pair.0, options, depth - 1)
        <> ", "
        <> render_term(pair.1, options, depth - 1)
        <> ")"
      })
      |> string.join(", ")
      <> "])"
    TFunction(module:, name:, arity:, anonymous:) ->
      render_function(module, name, arity, anonymous)
    TPid(text) -> "//erl(" <> text <> ")"
    TReference(text) -> "//erl(" <> text <> ")"
    TPort(text) -> "//erl(" <> text <> ")"
    TOther(text) -> text
  }
}

fn render_items(items: List(Dynamic), options: Options, depth: Int) -> String {
  items
  |> take_with_ellipsis(options.max_items, render_term(_, options, depth - 1))
  |> string.join(", ")
}

fn take_with_ellipsis(
  items: List(a),
  max: Int,
  render: fn(a) -> String,
) -> List(String) {
  let shown = list.take(items, max) |> list.map(render)
  case list.length(items) > max {
    True -> list.append(shown, ["…"])
    False -> shown
  }
}

fn render_record(
  tag: String,
  fields: List(Dynamic),
  options: Options,
  depth: Int,
) -> String {
  let constructor = lookup_constructor(options.labels, tag, list.length(fields))
  case fields {
    [] -> constructor.name
    _ -> {
      let rendered = list.map(fields, render_term(_, options, depth - 1))
      let rendered = case
        list.length(constructor.labels) == list.length(fields)
      {
        True ->
          list.map2(constructor.labels, rendered, fn(label, value) {
            label <> ": " <> value
          })
        False -> rendered
      }
      constructor.name <> "(" <> string.join(rendered, ", ") <> ")"
    }
  }
}

pub fn lookup_constructor(
  labels: Labels,
  tag: String,
  arity: Int,
) -> Constructor {
  case dict.get(labels, #(tag, arity)) {
    Ok(constructor) -> constructor
    Error(Nil) -> Constructor(names.constructor_name(tag), [])
  }
}

fn render_atom(atom: String) -> String {
  case atom {
    "true" -> "True"
    "false" -> "False"
    "nil" -> "Nil"
    _ ->
      case is_gleam_atom(atom) {
        True -> names.constructor_name(atom)
        False -> "atom.create(" <> render_string(atom) <> ")"
      }
  }
}

/// Atoms Gleam can produce from constructor names: lowercase snake case.
fn is_gleam_atom(atom: String) -> Bool {
  case string.to_graphemes(atom) {
    [first, ..rest] ->
      is_lower(first)
      && list.all(rest, fn(c) { is_lower(c) || is_digit(c) || c == "_" })
    [] -> False
  }
}

fn is_lower(c: String) -> Bool {
  string.contains("abcdefghijklmnopqrstuvwxyz", c)
}

fn is_digit(c: String) -> Bool {
  string.contains("0123456789", c)
}

pub fn render_float(f: Float) -> String {
  float_to_string(f)
}

@external(erlang, "gleam_dap_value_ffi", "float_to_string")
fn float_to_string(f: Float) -> String

pub fn render_string(text: String) -> String {
  "\""
  <> text
  |> string.replace("\\", "\\\\")
  |> string.replace("\"", "\\\"")
  |> string.replace("\n", "\\n")
  |> string.replace("\r", "\\r")
  |> string.replace("\t", "\\t")
  <> "\""
}

fn render_bytes(bits: BitArray, options: Options) -> String {
  let bytes = bytes_of(bits)
  "<<"
  <> bytes
  |> take_with_ellipsis(options.max_items, int.to_string)
  |> string.join(", ")
  <> ">>"
}

fn bytes_of(bits: BitArray) -> List(Int) {
  case bits {
    <<byte, rest:bits>> -> [byte, ..bytes_of(rest)]
    _ -> []
  }
}

fn render_function(
  module: String,
  name: String,
  arity: Int,
  anonymous: Bool,
) -> String {
  let args = list.repeat("_", arity) |> string.join(", ")
  case anonymous {
    True ->
      case names.parse_function(name) {
        names.AnonymousFunction(parent, _) ->
          "//fn("
          <> args
          <> ") { … } in "
          <> names.module_to_gleam(module)
          <> "."
          <> parent
        names.NamedFunction(_) ->
          "//fn(" <> args <> ") { … } in " <> names.module_to_gleam(module)
      }
    False ->
      "//fn "
      <> names.module_to_gleam(module)
      <> "."
      <> name
      <> "/"
      <> int.to_string(arity)
  }
}

/// A child of a value in the variables view.
pub type Child {
  Child(name: String, value: Dynamic)
}

/// The children of a value, or an empty list for values that don't expand.
pub fn children(term: Dynamic, options: Options) -> List(Child) {
  case classify(term) {
    TList(items) -> indexed(items, options)
    TImproperList(items, tail) ->
      list.append(indexed(items, options), [Child("tail", tail)])
    TTuple([first, ..rest] as items) ->
      case classify(first) {
        TAtom(tag) -> {
          let constructor =
            lookup_constructor(options.labels, tag, list.length(rest))
          case list.length(constructor.labels) == list.length(rest) {
            True -> list.map2(constructor.labels, rest, Child)
            False -> indexed(rest, options)
          }
        }
        _ -> indexed(items, options)
      }
    TMap(pairs) ->
      pairs
      |> list.take(options.max_items)
      |> list.map(fn(pair) { Child(render(pair.0, options), pair.1) })
    _ -> []
  }
}

fn indexed(items: List(Dynamic), options: Options) -> List(Child) {
  items
  |> list.take(options.max_items)
  |> list.index_map(fn(item, i) { Child(int.to_string(i), item) })
}

/// How many children a list, map or tuple has when it is shown in pages
/// (DAP's indexed variables), or `Error(Nil)` for values that aren't paged.
/// Records aren't paged: their children are their fields.
pub fn paged_size(term: Dynamic) -> Result(Int, Nil) {
  case classify(term) {
    TList(items) -> Ok(list.length(items))
    TImproperList(items, _) -> Ok(list.length(items) + 1)
    TMap(pairs) -> Ok(list.length(pairs))
    TTuple([first, ..] as items) ->
      case classify(first) {
        TAtom(_) -> Error(Nil)
        _ -> Ok(list.length(items))
      }
    _ -> Error(Nil)
  }
}

/// The children of a paged value from `start`, at most `count` of them.
pub fn children_page(
  term: Dynamic,
  options: Options,
  start: Int,
  count: Int,
) -> List(Child) {
  let numbered = fn(items: List(Dynamic)) {
    items
    |> list.drop(start)
    |> list.take(count)
    |> list.index_map(fn(item, i) { Child(int.to_string(start + i), item) })
  }
  case classify(term) {
    TList(items) -> numbered(items)
    TTuple(items) -> numbered(items)
    TImproperList(items, tail) -> {
      let size = list.length(items)
      let shown = numbered(items)
      case start + count > size {
        True -> list.append(shown, [Child("tail", tail)])
        False -> shown
      }
    }
    TMap(pairs) ->
      pairs
      |> list.drop(start)
      |> list.take(count)
      |> list.map(fn(pair) { Child(render(pair.0, options), pair.1) })
    _ -> []
  }
}

/// Whether a value has children worth expanding.
pub fn is_expandable(term: Dynamic) -> Bool {
  case classify(term) {
    TList([]) -> False
    TList(_) | TImproperList(_, _) | TMap(_) -> True
    TTuple([]) -> False
    TTuple([first, ..rest]) ->
      case classify(first) {
        TAtom(_) -> rest != []
        _ -> True
      }
    _ -> False
  }
}

/// A short type name for the variables view.
pub fn type_name(term: Dynamic, options: Options) -> String {
  case classify(term) {
    TInt(_) -> "Int"
    TFloat(_) -> "Float"
    TAtom("true") | TAtom("false") -> "Bool"
    TAtom("nil") -> "Nil"
    TAtom(atom) -> names.constructor_name(atom)
    TBinary(bits) ->
      case bit_array.to_string(bits) {
        Ok(_) -> "String"
        Error(Nil) -> "BitArray"
      }
    TBitstring(_, _) -> "BitArray"
    TList(_) | TImproperList(_, _) -> "List"
    TTuple([first, ..rest]) ->
      case classify(first) {
        TAtom(tag) ->
          lookup_constructor(options.labels, tag, list.length(rest)).name
        _ -> "Tuple"
      }
    TTuple([]) -> "Tuple"
    TMap(_) -> "Dict"
    TFunction(..) -> "Function"
    TPid(_) -> "Pid"
    TReference(_) -> "Reference"
    TPort(_) -> "Port"
    TOther(_) -> "Term"
  }
}

/// Renders with labels given as a list, for the Erlang side (logpoints).
pub fn render_with_labels(
  term: Dynamic,
  labels: List(#(#(String, Int), #(String, List(String)))),
) -> String {
  let labels =
    labels
    |> list.map(fn(entry) {
      let #(key, #(name, fields)) = entry
      #(key, Constructor(name, fields))
    })
    |> dict.from_list
  render(term, default_options(labels))
}

/// The labels as a list, for `render_with_labels` and field access.
pub fn labels_to_list(
  labels: Labels,
) -> List(#(#(String, Int), #(String, List(String)))) {
  labels
  |> dict.to_list
  |> list.map(fn(entry) {
    let #(key, Constructor(name, fields)) = entry
    #(key, #(name, fields))
  })
}

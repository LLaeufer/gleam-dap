//// Translating between Gleam names and the names Gleam's code generator
//// uses on the BEAM.

import gleam/int
import gleam/list
import gleam/order
import gleam/result
import gleam/string

/// `app@user` → `app/user`.
pub fn module_to_gleam(module: String) -> String {
  string.replace(module, "@", "/")
}

/// `app/user` → `app@user`.
pub fn gleam_to_module(module: String) -> String {
  string.replace(module, "/", "@")
}

/// `src/app/user.gleam` → `app@user`. Also handles `test/` and `dev/`.
pub fn path_to_module(relative_path: String) -> Result(String, Nil) {
  let without_dir = case relative_path {
    "src/" <> rest | "test/" <> rest | "dev/" <> rest -> Ok(rest)
    _ -> Error(Nil)
  }
  use rest <- result.try(without_dir)
  case string.ends_with(rest, ".gleam") {
    True -> Ok(gleam_to_module(string.drop_end(rest, 6)))
    False ->
      case string.ends_with(rest, ".erl") {
        True -> Ok(string.drop_end(rest, 4) |> last_segment)
        False -> Error(Nil)
      }
  }
}

fn last_segment(path: String) -> String {
  path |> string.split("/") |> list.last |> result.unwrap(path)
}

/// What an Erlang variable name stands for in Gleam.
pub type Variable {
  /// A Gleam variable: `X@2` is `Variable("x", 2)`.
  GleamVariable(name: String, version: Int)
  /// Something the compiler introduced, such as `_pipe` or `_use0`.
  Temporary(name: String)
}

pub fn demangle_variable(erlang_name: String) -> Variable {
  case string.starts_with(erlang_name, "_") {
    True -> Temporary(erlang_name)
    False -> {
      let #(base, version) = case string.split_once(erlang_name, "@") {
        Ok(#(base, suffix)) ->
          case int.parse(suffix) {
            Ok(n) -> #(base, n)
            Error(Nil) -> #(erlang_name, 0)
          }
        Error(Nil) -> #(erlang_name, 0)
      }
      GleamVariable(lowercase_first(base), version)
    }
  }
}

fn lowercase_first(name: String) -> String {
  case string.pop_grapheme(name) {
    Ok(#(first, rest)) -> string.lowercase(first) <> rest
    Error(Nil) -> name
  }
}

/// Picks the latest version of every Gleam variable from a list of Erlang
/// bindings, dropping compiler temporaries. Sorted by name.
pub fn latest_bindings(bindings: List(#(String, a))) -> List(#(String, a)) {
  bindings
  |> list.filter_map(fn(binding) {
    case demangle_variable(binding.0) {
      GleamVariable(name, version) -> Ok(#(name, version, binding.1))
      Temporary(_) -> Error(Nil)
    }
  })
  |> list.sort(fn(a, b) {
    case string.compare(a.0, b.0) {
      order.Eq -> int.compare(b.1, a.1)
      other -> other
    }
  })
  |> dedupe_by_name([])
}

fn dedupe_by_name(
  sorted: List(#(String, Int, a)),
  acc: List(#(String, a)),
) -> List(#(String, a)) {
  case sorted, acc {
    [], _ -> list.reverse(acc)
    [#(name, _, _), ..rest], [#(previous, _), ..] if name == previous ->
      dedupe_by_name(rest, acc)
    [#(name, _, value), ..rest], _ ->
      dedupe_by_name(rest, [#(name, value), ..acc])
  }
}

/// Maps a Gleam variable name to the Erlang name of its latest version in
/// the given bindings.
pub fn erlang_name_for(
  gleam_name: String,
  bindings: List(#(String, a)),
) -> Result(String, Nil) {
  bindings
  |> list.filter_map(fn(binding) {
    case demangle_variable(binding.0) {
      GleamVariable(name, version) if name == gleam_name ->
        Ok(#(binding.0, version))
      _ -> Error(Nil)
    }
  })
  |> list.sort(fn(a, b) { int.compare(b.1, a.1) })
  |> list.first
  |> result.map(fn(found) { found.0 })
}

/// What a BEAM function name stands for.
pub type Function {
  NamedFunction(name: String)
  /// `-pipes/1-fun-0-` is an anonymous function inside `pipes/1`.
  AnonymousFunction(parent: String, parent_arity: Int)
}

pub fn parse_function(name: String) -> Function {
  case name {
    "-" <> rest ->
      case string.split_once(rest, "-fun-") {
        Ok(#(parent, _)) ->
          case string.split_once(parent, "/") {
            Ok(#(parent_name, arity)) ->
              case int.parse(arity) {
                Ok(arity) -> AnonymousFunction(parent_name, arity)
                Error(Nil) -> NamedFunction(name)
              }
            Error(Nil) -> NamedFunction(name)
          }
        Error(Nil) -> NamedFunction(name)
      }
    _ -> NamedFunction(name)
  }
}

/// The name of the top-level function a BEAM function belongs to.
pub fn base_function(name: String) -> String {
  case parse_function(name) {
    NamedFunction(name) -> name
    AnonymousFunction(parent, _) -> parent
  }
}

/// A stack frame's name: `app/user.greet`, or
/// `anonymous function in app/user.greet`.
pub fn frame_name(module: String, function: String) -> String {
  let module = module_to_gleam(module)
  case parse_function(function) {
    NamedFunction(name) -> module <> "." <> name
    AnonymousFunction(parent, _) ->
      "anonymous function in " <> module <> "." <> parent
  }
}

/// `person` → `Person`, `http_error` → `HttpError`: the Gleam name of a
/// constructor, from the atom Gleam generates for it.
pub fn constructor_name(atom: String) -> String {
  atom
  |> string.split("_")
  |> list.map(string.capitalise)
  |> string.concat
}

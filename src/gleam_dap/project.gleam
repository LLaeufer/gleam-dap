//// The Gleam project being debugged: its name, its compiled modules and
//// where their sources are.

import gleam/dict.{type Dict}
import gleam/int
import gleam/list
import gleam/result
import gleam/string
import gleam_dap/value

pub type FunctionInfo {
  FunctionInfo(
    name: String,
    arity: Int,
    start: Int,
    end: Int,
    /// First line of each clause's body.
    clause_lines: List(Int),
    /// Lines where `int` can stop.
    breakable: List(Int),
    /// Statement lines that define an anonymous function, such as the
    /// callback of a `use`.
    lines_with_fun: List(Int),
    /// Statement lines inside the body of an anonymous function, with how
    /// many anonymous functions they are nested in.
    fun_body_lines: List(#(Int, Int)),
  )
}

pub type ModuleInfo {
  ModuleInfo(
    module: String,
    package: String,
    /// Absolute path of the source file, or "" if unknown.
    source: String,
    beam: String,
    functions: List(FunctionInfo),
  )
}

pub fn is_gleam(module: ModuleInfo) -> Bool {
  string.ends_with(module.source, ".gleam")
}

pub type Index {
  Index(
    project_dir: String,
    name: String,
    modules: Dict(String, ModuleInfo),
    by_path: Dict(String, String),
    labels: value.Labels,
  )
}

@external(erlang, "gleam_dap_int_ffi", "analyse")
fn analyse(
  beam: String,
) -> Result(#(String, String, List(FunctionInfo)), String)

@external(erlang, "gleam_dap_ffi", "read_file")
fn read_file(path: String) -> Result(String, Nil)

@external(erlang, "gleam_dap_ffi", "wildcard")
pub fn wildcard(pattern: String) -> List(String)

@external(erlang, "gleam_dap_ffi", "absname")
pub fn absname(path: String) -> String

@external(erlang, "gleam_dap_value_ffi", "read_record_headers")
fn read_record_headers(dir: String) -> List(#(String, String, List(String)))

/// The project name from `gleam.toml`.
pub fn read_name(project_dir: String) -> Result(String, String) {
  use toml <- result.try(
    read_file(project_dir <> "/gleam.toml")
    |> result.replace_error("No gleam.toml in " <> project_dir),
  )
  toml
  |> string.split("\n")
  |> list.find_map(fn(line) {
    case string.split_once(line, "=") {
      Ok(#(key, value)) ->
        case string.trim(key) {
          "name" -> Ok(unquote(string.trim(value)))
          _ -> Error(Nil)
        }
      Error(Nil) -> Error(Nil)
    }
  })
  |> result.replace_error("No project name in gleam.toml")
}

fn unquote(text: String) -> String {
  text
  |> string.split("#")
  |> list.first
  |> result.unwrap(text)
  |> string.trim
  |> string.replace("\"", "")
}

/// Directories holding compiled modules, one per package.
pub fn ebin_dirs(project_dir: String) -> List(String) {
  wildcard(project_dir <> "/build/dev/erlang/*/ebin")
}

/// Builds the module ↔ file index from the compiled project.
pub fn build_index(project_dir: String, name: String) -> Index {
  let project_dir = absname(project_dir)
  let modules =
    ebin_dirs(project_dir)
    |> list.flat_map(fn(ebin) {
      let package = package_of(ebin)
      let root = case package == name {
        True -> project_dir
        False -> project_dir <> "/build/packages/" <> package
      }
      wildcard(ebin <> "/*.beam")
      |> list.filter_map(fn(beam) {
        use #(module, file, functions) <- result.try(
          analyse(beam) |> result.replace_error(Nil),
        )
        let source = case file {
          "" -> ""
          "/" <> _ -> file
          _ -> absname(root <> "/" <> file)
        }
        Ok(ModuleInfo(module:, package:, source:, beam:, functions:))
      })
    })
  let by_path =
    modules
    |> list.filter(fn(m) { m.source != "" })
    |> list.map(fn(m) { #(m.source, m.module) })
    |> dict.from_list
  let labels =
    wildcard(project_dir <> "/build/dev/erlang/*/include")
    |> list.flat_map(read_record_headers)
    |> list.map(fn(header) {
      let #(atom, constructor, fields) = header
      #(#(atom, list.length(fields)), value.Constructor(constructor, fields))
    })
    |> dict.from_list
  Index(
    project_dir:,
    name:,
    modules: modules |> list.map(fn(m) { #(m.module, m) }) |> dict.from_list,
    by_path:,
    labels:,
  )
}

fn package_of(ebin: String) -> String {
  ebin
  |> string.split("/")
  |> list.reverse
  |> list.drop(1)
  |> list.first
  |> result.unwrap("")
}

pub fn module_for_path(index: Index, path: String) -> Result(ModuleInfo, Nil) {
  use module <- result.try(dict.get(index.by_path, absname(path)))
  dict.get(index.modules, module)
}

pub fn get_module(index: Index, module: String) -> Result(ModuleInfo, Nil) {
  dict.get(index.modules, module)
}

/// Modules of the project itself (not dependencies) that have Gleam
/// sources.
pub fn project_modules(index: Index) -> List(ModuleInfo) {
  index.modules
  |> dict.values
  |> list.filter(fn(m) { m.package == index.name && is_gleam(m) })
  |> list.sort(fn(a, b) { string.compare(a.module, b.module) })
}

pub fn dependency_modules(index: Index) -> List(ModuleInfo) {
  index.modules
  |> dict.values
  |> list.filter(fn(m) { m.package != index.name && is_gleam(m) })
  |> list.sort(fn(a, b) { string.compare(a.module, b.module) })
}

// --- Lines ------------------------------------------------------------------

pub type Resolved {
  /// The breakpoint can stop, on this line (maybe moved from the
  /// requested one).
  Resolved(line: Int)
  Unresolved(reason: String)
}

/// Where a breakpoint on `line` will actually stop: the line itself if it
/// has code, else the next line with code in the same function.
pub fn resolve_line(module: ModuleInfo, line: Int) -> Resolved {
  case list.find(module.functions, fn(f) { f.start <= line && line <= f.end }) {
    Error(Nil) -> Unresolved("No code on this line")
    Ok(function) ->
      case
        function.breakable
        |> list.filter(fn(l) { l >= line })
        |> list.first
      {
        Ok(found) -> Resolved(found)
        Error(Nil) -> Unresolved("No code on this line")
      }
  }
}

/// Lines where breakpoints can be set between two lines (inclusive).
pub fn breakable_lines(module: ModuleInfo, from: Int, to: Int) -> List(Int) {
  module.functions
  |> list.flat_map(fn(f) { f.breakable })
  |> list.filter(fn(l) { l >= from && l <= to })
  |> list.unique
  |> list.sort(int.compare)
}

/// The function containing a line.
pub fn function_at(module: ModuleInfo, line: Int) -> Result(FunctionInfo, Nil) {
  list.find(module.functions, fn(f) { f.start <= line && line <= f.end })
}

pub fn find_function(
  module: ModuleInfo,
  name: String,
  arity: Int,
) -> Result(FunctionInfo, Nil) {
  list.find(module.functions, fn(f) { f.name == name && f.arity == arity })
}

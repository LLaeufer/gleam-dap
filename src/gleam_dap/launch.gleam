//// Launch and attach configurations, and preparing a project for
//// debugging: version checks, building, the module index and interpreting.

import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/int
import gleam/list
import gleam/result
import gleam/string
import gleam_dap/glob
import gleam_dap/log
import gleam_dap/names
import gleam_dap/project.{type Index, type ModuleInfo}

pub type Config {
  Config(
    project_dir: String,
    /// Gleam module name of the entry point, e.g. `app/cli`.
    module: String,
    function: String,
    /// Command-line arguments for the program.
    args: List(String),
    env: List(#(String, String)),
    target: Target,
    interpret_dependencies: Bool,
    interpret_modules: List(String),
    exclude_modules: List(String),
    stack_trace_mode: String,
    no_debug: Bool,
    gleam_path: String,
    build: Bool,
    stop_on_entry: Bool,
    /// For attach: the node to attach to and its cookie.
    node: String,
    cookie: String,
  )
}

pub type Target {
  Dev
  Test
}

pub fn decode_config(
  arguments: Dynamic,
  default_dir: String,
) -> Result(Config, String) {
  let decoder = {
    use project_dir <- decode.optional_field(
      "projectDir",
      default_dir,
      decode.string,
    )
    use module <- decode.optional_field("module", "", decode.string)
    use function <- decode.optional_field("function", "main", decode.string)
    use args <- decode.optional_field("args", [], decode.list(decode.string))
    use env <- decode.optional_field(
      "env",
      [],
      decode.dict(decode.string, decode.string)
        |> decode.map(fn(d) { dict_to_list(d) }),
    )
    use target <- decode.optional_field("target", "dev", decode.string)
    use interpret_dependencies <- decode.optional_field(
      "interpretDependencies",
      False,
      decode.bool,
    )
    use interpret_modules <- decode.optional_field(
      "interpretModules",
      [],
      decode.list(decode.string),
    )
    use exclude_modules <- decode.optional_field(
      "excludeModules",
      [],
      decode.list(decode.string),
    )
    use stack_trace_mode <- decode.optional_field(
      "stackTraceMode",
      "all",
      decode.one_of(decode.string, [
        decode.bool
        |> decode.map(fn(b) {
          case b {
            True -> "all"
            False -> "false"
          }
        }),
      ]),
    )
    use no_debug <- decode.optional_field("noDebug", False, decode.bool)
    use gleam_path <- decode.optional_field("gleamPath", "gleam", decode.string)
    use build <- decode.optional_field("build", True, decode.bool)
    use stop_on_entry <- decode.optional_field(
      "stopOnEntry",
      False,
      decode.bool,
    )
    use node <- decode.optional_field("node", "", decode.string)
    use cookie <- decode.optional_field("cookie", "", decode.string)
    decode.success(Config(
      project_dir:,
      module:,
      function:,
      args:,
      env:,
      target: case target {
        "test" -> Test
        _ -> Dev
      },
      interpret_dependencies:,
      interpret_modules:,
      exclude_modules:,
      stack_trace_mode:,
      no_debug:,
      gleam_path:,
      build:,
      stop_on_entry:,
      node:,
      cookie:,
    ))
  }
  decode.run(arguments, decoder)
  |> result.map_error(fn(errors) {
    "Invalid launch configuration: "
    <> errors
    |> list.map(fn(e) {
      string.join(e.path, ".") <> " should be " <> e.expected
    })
    |> string.join(", ")
  })
  |> result.try(fn(config) {
    case list.contains(["all", "no_tail", "false"], config.stack_trace_mode) {
      True -> Ok(config)
      False -> Error("stackTraceMode must be all, no_tail or false")
    }
  })
}

@external(erlang, "maps", "to_list")
fn dict_to_list(d: a) -> List(#(String, String))

// --- Versions ---------------------------------------------------------------

pub const minimum_gleam = #(1, 19)

pub const minimum_otp = 27

/// Parses `gleam 1.19.0` into `#(1, 19, 0)`.
pub fn parse_gleam_version(output: String) -> Result(#(Int, Int, Int), Nil) {
  let text = string.trim(output)
  let text = case text {
    "gleam " <> rest -> rest
    _ -> text
  }
  let version =
    text
    |> string.split("-")
    |> list.first
    |> result.unwrap(text)
  case string.split(version, ".") |> list.map(int.parse) {
    [Ok(major), Ok(minor), Ok(patch), ..] -> Ok(#(major, minor, patch))
    _ -> Error(Nil)
  }
}

pub fn gleam_version_ok(version: #(Int, Int, Int)) -> Bool {
  let #(major, minor, _) = version
  major > minimum_gleam.0
  || { major == minimum_gleam.0 && minor >= minimum_gleam.1 }
}

@external(erlang, "gleam_dap_ffi", "otp_release")
pub fn otp_release() -> Int

@external(erlang, "gleam_dap_ffi", "find_executable")
fn find_executable(name: String) -> Result(String, Nil)

@external(erlang, "gleam_dap_ffi", "run_command")
fn run_command(
  executable: String,
  args: List(String),
  cwd: String,
  env: List(#(String, String)),
) -> Result(#(Int, String), String)

fn gleam_executable(config: Config) -> Result(String, String) {
  case
    string.contains(config.gleam_path, "/")
    || string.contains(config.gleam_path, "\\")
  {
    True -> Ok(config.gleam_path)
    False ->
      find_executable(config.gleam_path)
      |> result.replace_error(
        "Could not find `"
        <> config.gleam_path
        <> "` on the PATH. Install Gleam 1.19 or newer, or set gleamPath in the launch configuration.",
      )
  }
}

pub fn check_versions(config: Config) -> Result(Nil, String) {
  use <- bool_guard(
    otp_release() < minimum_otp,
    Error(
      "gleam-dap needs Erlang/OTP "
      <> int.to_string(minimum_otp)
      <> " or newer, found OTP "
      <> int.to_string(otp_release())
      <> ".",
    ),
  )
  case config.build {
    False -> Ok(Nil)
    True -> {
      use gleam <- result.try(gleam_executable(config))
      use #(status, output) <- result.try(
        run_command(gleam, ["--version"], config.project_dir, []),
      )
      case status, parse_gleam_version(output) {
        0, Ok(version) ->
          case gleam_version_ok(version) {
            True -> Ok(Nil)
            False ->
              Error(
                "gleam-dap needs Gleam "
                <> int.to_string(minimum_gleam.0)
                <> "."
                <> int.to_string(minimum_gleam.1)
                <> " or newer, found "
                <> string.trim(output)
                <> ". Older versions don't record Gleam line numbers in compiled code.",
              )
          }
        _, _ -> Error("Could not read the Gleam version: " <> output)
      }
    }
  }
}

fn bool_guard(condition: Bool, error: a, next: fn() -> a) -> a {
  case condition {
    True -> error
    False -> next()
  }
}

/// Runs `gleam build`. Returns the compiler output either way.
pub fn build(config: Config) -> Result(String, String) {
  case config.build {
    False -> Ok("")
    True -> {
      use gleam <- result.try(gleam_executable(config))
      use #(status, output) <- result.try(
        run_command(
          gleam,
          ["build", "--target", "erlang"],
          config.project_dir,
          [],
        ),
      )
      case status {
        0 -> Ok(output)
        _ -> Error(output)
      }
    }
  }
}

// --- Interpreting -----------------------------------------------------------

@external(erlang, "code", "add_pathsz")
fn add_paths_charlists(paths: List(Charlist)) -> Dynamic

type Charlist

@external(erlang, "unicode", "characters_to_list")
fn to_charlist(text: String) -> Charlist

pub fn add_code_paths(project_dir: String) -> Nil {
  project.ebin_dirs(project_dir)
  |> list.map(to_charlist)
  |> add_paths_charlists
  Nil
}

@external(erlang, "gleam_dap_int_ffi", "interpret")
fn int_interpret(
  module: String,
  source: String,
  beam: String,
  distributed: Bool,
) -> Result(Nil, String)

@external(erlang, "gleam_dap_launch_ffi", "loaded_elsewhere")
fn loaded_elsewhere(module: String, project_dir: String) -> Bool

/// The modules to interpret, according to the configuration.
pub fn modules_to_interpret(index: Index, config: Config) -> List(ModuleInfo) {
  let selected = fn(module: ModuleInfo) {
    let name = names.module_to_gleam(module.module)
    let wanted =
      module.package == index.name
      || config.interpret_dependencies
      || list.any(config.interpret_modules, glob.matches(_, name))
    let excluded = list.any(config.exclude_modules, glob.matches(_, name))
    wanted && !excluded
  }
  list.append(project.project_modules(index), project.dependency_modules(index))
  |> list.filter(selected)
  // Never interpret code the adapter itself runs: a paused process would
  // deadlock the adapter as soon as it hits a breakpoint.
  |> list.filter(fn(module) {
    !loaded_elsewhere(module.module, index.project_dir)
  })
}

/// Whether a module that wasn't interpreted at launch may be when a
/// breakpoint is set in it.
pub fn can_interpret_later(
  index: Index,
  config: Config,
  module: ModuleInfo,
) -> Result(Nil, String) {
  let name = names.module_to_gleam(module.module)
  case
    config.no_debug,
    list.any(config.exclude_modules, glob.matches(_, name)),
    loaded_elsewhere(module.module, index.project_dir)
  {
    True, _, _ -> Error("The program runs without debugging")
    _, True, _ ->
      Error(
        name <> " is excluded by excludeModules in the launch configuration",
      )
    _, _, True ->
      Error(
        name
        <> " is used by the debugger itself, so it can't be interpreted. Its code runs, but breakpoints in it don't stop.",
      )
    False, False, False -> Ok(Nil)
  }
}

/// Interprets modules in parallel, on all connected nodes when
/// `distributed`. Returns the failures.
pub fn interpret(
  modules: List(ModuleInfo),
  distributed: Bool,
) -> List(#(String, String)) {
  modules
  |> parallel_map(fn(module) {
    case int_interpret(module.module, module.source, module.beam, distributed) {
      Ok(Nil) -> Ok(Nil)
      Error(reason) -> Error(#(names.module_to_gleam(module.module), reason))
    }
  })
  |> list.filter_map(fn(r) {
    case r {
      Ok(Nil) -> Error(Nil)
      Error(failure) -> Ok(failure)
    }
  })
  |> log_failures
}

fn log_failures(failures: List(#(String, String))) -> List(#(String, String)) {
  list.each(failures, fn(f) {
    log.info("Could not interpret " <> f.0 <> ": " <> f.1)
  })
  failures
}

@external(erlang, "gleam_dap_launch_ffi", "parallel_map")
fn parallel_map(items: List(a), f: fn(a) -> b) -> List(b)

pub fn entry_module(config: Config, index: Index) -> String {
  case config.module, config.target {
    "", Dev -> index.name
    "", Test -> index.name <> "_test"
    module, _ -> module
  }
}

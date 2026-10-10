//// The debug session: one process that handles DAP requests and `int`
//// events, and owns the session state.

import gleam/dict.{type Dict}
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/erlang/process.{type Pid, type Subject}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/set.{type Set}
import gleam/string
import gleam_dap/dap/protocol.{type Request}
import gleam_dap/inspect.{type Stopped, AtLine, Crashed}
import gleam_dap/json.{type Json, JArray, JBool, JInt, JObject, JString}
import gleam_dap/launch.{type Config}
import gleam_dap/log
import gleam_dap/names
import gleam_dap/project.{type Index, type ModuleInfo}
import gleam_dap/stepping
import gleam_dap/threads
import gleam_dap/value

pub type Message {
  Incoming(BitArray)
  InputClosed
  Int(IntEvent)
  ProgramDown(pid: Pid, reason: Dynamic)
  FinishProgram
  WorkerDone(request_seq: Int)
  Halt
}

/// Events from `gleam_dap_int_ffi:on_attach/2`.
pub type IntEvent {
  IntBreak(pid: Pid, module: String, line: Int)
  /// `attached` holds the meta process and the process holding the
  /// attachment, for processes that exited abnormally.
  IntExit(pid: Pid, reason: Dynamic, attached: Option(#(Pid, Pid)))
}

pub type Mode {
  Launch
  Attach
}

pub type ProgramState {
  NotStarted
  Running
  /// The entry process has ended; waiting to report it.
  Ended(exit_code: Int)
  Finished
}

/// How a stopped process is stopped.
pub type StopInfo {
  StoppedAt(module: String, line: Int)
  CrashStop(reason: Dynamic, meta: Pid, holder: Pid)
}

pub type Stepping {
  SimpleStep
  Over(stepping.StepOver)
}

pub type LineBreakpoint {
  LineBreakpoint(
    id: Int,
    requested: Int,
    resolved: project.Resolved,
    module: String,
    condition: Option(String),
    hit_condition: Option(String),
    log_message: Option(String),
  )
}

pub type FunctionBreakpoint {
  FunctionBreakpoint(
    id: Int,
    name: String,
    location: Result(#(ModuleInfo, List(Int)), String),
    condition: Option(String),
    hit_condition: Option(String),
  )
}

pub type State {
  State(
    subject: Subject(Message),
    initialized: Bool,
    mode: Mode,
    config: Option(Config),
    index: Option(Index),
    stdout: Option(Pid),
    line_breakpoints: Dict(String, List(LineBreakpoint)),
    function_breakpoints: List(FunctionBreakpoint),
    /// Breakpoints currently set in `int`.
    int_breaks: Set(#(String, Int)),
    /// Temporary breakpoint for `stopOnEntry`.
    entry_break: Option(#(String, Int)),
    next_breakpoint_id: Int,
    exception_filters: List(String),
    threads: threads.Registry,
    stopped: Dict(Pid, StopInfo),
    stepping: Dict(Pid, Stepping),
    pausing: Set(Pid),
    program: Option(Pid),
    program_state: ProgramState,
    workers: Dict(Int, Pid),
  )
}

// --- Starting ---------------------------------------------------------------

@external(erlang, "gleam_dap_ffi", "stdio_start")
fn stdio_start(on_message: fn(BitArray) -> Nil, on_eof: fn() -> Nil) -> Nil

@external(erlang, "gleam_dap_ffi", "refs_init")
fn refs_init() -> Nil

@external(erlang, "gleam_dap_ffi", "refs_clear_for")
fn refs_clear_for(pid: Pid) -> Nil

@external(erlang, "gleam_dap_ffi", "halt")
fn halt(code: Int) -> Nil

@external(erlang, "gleam_dap_ffi", "send_after")
fn send_after(ms: Int, f: fn() -> Nil) -> Nil

@external(erlang, "gleam_dap_ffi", "get_cwd")
fn get_cwd() -> String

/// Runs the adapter on stdio until the client disconnects.
pub fn run() -> Nil {
  refs_init()
  let subject = process.new_subject()
  stdio_start(fn(body) { process.send(subject, Incoming(body)) }, fn() {
    process.send(subject, InputClosed)
  })
  log.info("gleam-dap started")
  loop(new_state(subject))
}

pub fn new_state(subject: Subject(Message)) -> State {
  State(
    subject:,
    initialized: False,
    mode: Launch,
    config: None,
    index: None,
    stdout: None,
    line_breakpoints: dict.new(),
    function_breakpoints: [],
    int_breaks: set.new(),
    entry_break: None,
    next_breakpoint_id: 1,
    exception_filters: ["gleam"],
    threads: threads.new(),
    stopped: dict.new(),
    stepping: dict.new(),
    pausing: set.new(),
    program: None,
    program_state: NotStarted,
    workers: dict.new(),
  )
}

fn loop(state: State) -> Nil {
  let message = process.receive_forever(state.subject)
  case message {
    Halt -> {
      log.info("halting")
      halt(0)
    }
    _ -> loop(handle_message(state, message))
  }
}

pub fn handle_message(state: State, message: Message) -> State {
  case message {
    Incoming(body) ->
      case json.parse(body) |> result.try(protocol.decode_request) {
        Ok(request) -> {
          log.info("<- " <> request.command)
          handle_request(state, request)
        }
        Error(Nil) -> {
          log.info("ignoring message that is not a request")
          state
        }
      }
    InputClosed -> {
      log.info("client closed the input")
      halt(0)
      state
    }
    Int(event) -> handle_int_event(state, event)
    ProgramDown(pid, reason) -> program_down(state, pid, reason)
    FinishProgram -> finish_program(state)
    WorkerDone(seq) -> State(..state, workers: dict.delete(state.workers, seq))
    Halt -> state
  }
}

// --- Requests ---------------------------------------------------------------

fn handle_request(state: State, request: Request) -> State {
  case request.command, state.initialized {
    "initialize", _ -> initialize(state, request)
    _, False -> {
      respond_error(request, "The adapter is not initialized")
      state
    }
    "launch", True -> launch(state, request, Launch)
    "attach", True -> launch(state, request, Attach)
    "setBreakpoints", True -> set_breakpoints(state, request)
    "setFunctionBreakpoints", True -> set_function_breakpoints(state, request)
    "setExceptionBreakpoints", True -> set_exception_breakpoints(state, request)
    "breakpointLocations", True -> breakpoint_locations(state, request)
    "configurationDone", True -> configuration_done(state, request)
    "threads", True -> threads_request(state, request)
    "stackTrace", True -> stack_trace(state, request)
    "scopes", True -> scopes(state, request)
    "variables", True -> variables(state, request)
    "evaluate", True -> evaluate(state, request)
    "completions", True -> completions(state, request)
    "exceptionInfo", True -> exception_info(state, request)
    "continue", True -> continue_request(state, request)
    "next", True -> step_request(state, request, "next")
    "stepIn", True -> step_request(state, request, "stepIn")
    "stepOut", True -> step_request(state, request, "stepOut")
    "pause", True -> pause(state, request)
    "terminateThreads", True -> terminate_threads(state, request)
    "cancel", True -> cancel(state, request)
    "terminate", True -> terminate(state, request)
    "disconnect", True -> disconnect(state, request)
    command, True -> {
      respond_error(request, "Unsupported request: " <> command)
      state
    }
  }
}

fn respond(request: Request, body: Option(Json)) -> Nil {
  protocol.send(protocol.response(request, body))
}

fn respond_error(request: Request, message: String) -> Nil {
  log.info("error response to " <> request.command <> ": " <> message)
  protocol.send(protocol.error_response(request, message))
}

fn send_event(event: Json) -> Nil {
  protocol.send(event)
}

fn output(category: String, text: String) -> Nil {
  send_event(protocol.output_event(category, text))
}

fn decode_args(
  request: Request,
  decoder: decode.Decoder(a),
  next: fn(a) -> State,
  state: State,
) -> State {
  case decode.run(request.arguments, decoder) {
    Ok(args) -> next(args)
    Error(_) -> {
      respond_error(request, "Invalid arguments for " <> request.command)
      state
    }
  }
}

fn thread_id_decoder() -> decode.Decoder(Int) {
  use id <- decode.field("threadId", decode.int)
  decode.success(id)
}

// --- initialize ---------------------------------------------------------------

fn initialize(state: State, request: Request) -> State {
  let filters =
    JArray([
      JObject([
        #("filter", JString("gleam")),
        #("label", JString("Gleam errors")),
        #(
          "description",
          JString("Stop when a process crashes on panic, todo or let assert."),
        ),
        #("default", JBool(True)),
      ]),
      JObject([
        #("filter", JString("all")),
        #("label", JString("All crashes")),
        #("description", JString("Stop when any interpreted process crashes.")),
        #("default", JBool(False)),
      ]),
    ])
  let capabilities =
    JObject([
      #("supportsConfigurationDoneRequest", JBool(True)),
      #("supportsFunctionBreakpoints", JBool(True)),
      #("supportsConditionalBreakpoints", JBool(True)),
      #("supportsHitConditionalBreakpoints", JBool(True)),
      #("supportsLogPoints", JBool(True)),
      #("supportsEvaluateForHovers", JBool(True)),
      #("supportsBreakpointLocationsRequest", JBool(True)),
      #("supportsTerminateRequest", JBool(True)),
      #("supportTerminateDebuggee", JBool(True)),
      #("supportsExceptionInfoRequest", JBool(True)),
      #("supportsCompletionsRequest", JBool(True)),
      #("completionTriggerCharacters", JArray([JString(".")])),
      #("supportsTerminateThreadsRequest", JBool(True)),
      #("supportsCancelRequest", JBool(True)),
      #("supportsSingleThreadExecutionRequests", JBool(True)),
      #("exceptionBreakpointFilters", filters),
    ])
  respond(request, Some(capabilities))
  State(..state, initialized: True)
}

// --- launch and attach ---------------------------------------------------------

@external(erlang, "gleam_dap_int_ffi", "start")
fn int_start(stack_trace: String) -> Result(Nil, String)

@external(erlang, "gleam_dap_int_ffi", "auto_attach")
fn int_auto_attach(callback: fn(IntEvent) -> Nil) -> Nil

@external(erlang, "gleam_dap_ffi", "start_output")
fn start_output(category: String, on_output: fn(String, String) -> Nil) -> Pid

@external(erlang, "gleam_dap_ffi", "capture_stdio")
fn capture_stdio(stdout: Pid, stderr: Pid) -> Nil

@external(erlang, "gleam_dap_ffi", "set_cwd")
fn set_cwd(dir: String) -> Result(Nil, String)

@external(erlang, "gleam_dap_ffi", "put_env")
fn put_env(key: String, value: String) -> Nil

@external(erlang, "gleam_dap_eval_ffi", "set_labels")
fn set_labels(labels: List(#(#(String, Int), #(String, List(String))))) -> Nil

@external(erlang, "gleam_dap_launch_ffi", "connect_node")
fn connect_node(node: String, cookie: String) -> Result(Nil, String)

fn launch(state: State, request: Request, mode: Mode) -> State {
  case prepare(request, mode) {
    Ok(#(config, index)) -> {
      respond(request, None)
      send_event(protocol.event("initialized", None))
      State(..state, mode:, config: Some(config), index: Some(index))
      |> capture_output
    }
    Error(message) -> {
      respond_error(request, message)
      state
    }
  }
}

fn prepare(request: Request, mode: Mode) -> Result(#(Config, Index), String) {
  use config <- result.try(launch.decode_config(request.arguments, get_cwd()))
  let config =
    launch.Config(..config, project_dir: project.absname(config.project_dir))
  use name <- result.try(project.read_name(config.project_dir))
  use _ <- result.try(case mode {
    Attach ->
      case config.node {
        "" -> Error("Attach needs the `node` to attach to")
        node -> connect_node(node, config.cookie)
      }
    Launch -> Ok(Nil)
  })
  use _ <- result.try(launch.check_versions(config))
  use build_output <- result.try(
    launch.build(config)
    |> result.map_error(fn(output) { "gleam build failed:\n" <> output }),
  )
  case build_output {
    "" -> Nil
    _ -> output("console", build_output)
  }
  use _ <- result.try(set_cwd(config.project_dir))
  list.each(config.env, fn(pair) { put_env(pair.0, pair.1) })
  launch.add_code_paths(config.project_dir)
  let index = project.build_index(config.project_dir, name)
  set_labels(value.labels_to_list(index.labels))
  case config.no_debug {
    True -> Ok(#(config, index))
    False -> {
      use _ <- result.try(int_start(config.stack_trace_mode))
      let modules = launch.modules_to_interpret(index, config)
      let failures = launch.interpret(modules)
      list.each(failures, fn(f) {
        output("console", "Could not interpret " <> f.0 <> ": " <> f.1 <> "\n")
      })
      log.info(
        "interpreted "
        <> int.to_string(list.length(modules) - list.length(failures))
        <> " modules",
      )
      Ok(#(config, index))
    }
  }
}

fn capture_output(state: State) -> State {
  case state.mode {
    Attach -> state
    Launch -> {
      let on_output = fn(category, text) { output(category, text) }
      let stdout = start_output("stdout", on_output)
      let stderr = start_output("stderr", on_output)
      capture_stdio(stdout, stderr)
      State(..state, stdout: Some(stdout))
    }
  }
}

// --- configurationDone -----------------------------------------------------------

@external(erlang, "gleam_dap_ffi", "spawn_program")
fn spawn_program(
  module: String,
  function: String,
  args: List(Dynamic),
  group_leader: Pid,
) -> Pid

@external(erlang, "gleam_dap_ffi", "watch_process")
fn watch_process(pid: Pid, on_down: fn(Dynamic) -> Nil) -> Nil

@external(erlang, "gleam_dap_launch_ffi", "eunit_args")
fn eunit_args(modules: List(String)) -> List(Dynamic)

fn configuration_done(state: State, request: Request) -> State {
  let subject = state.subject
  case state.config, state.index {
    Some(config), Some(index) -> {
      case config.no_debug {
        True -> Nil
        False -> int_auto_attach(fn(event) { process.send(subject, Int(event)) })
      }
      respond(request, None)
      case state.mode {
        Attach -> state
        Launch -> start_program(state, config, index)
      }
    }
    _, _ -> {
      respond_error(request, "Launch the program first")
      state
    }
  }
}

fn start_program(state: State, config: Config, index: Index) -> State {
  let subject = state.subject
  let assert Some(stdout) = state.stdout
  let entry = names.gleam_to_module(launch.entry_module(config, index))
  let state = case config.stop_on_entry {
    True -> set_entry_break(state, index, entry, config.function)
    False -> state
  }
  let pid = case config.target, config.module {
    launch.Test, "" -> {
      let tests =
        project.project_modules(index)
        |> list.filter(fn(m) { string.ends_with(m.module, "_test") })
        |> list.map(fn(m) { m.module })
      spawn_program("eunit", "test", eunit_args(tests), stdout)
    }
    _, _ -> spawn_program(entry, config.function, [], stdout)
  }
  watch_process(pid, fn(reason) { process.send(subject, ProgramDown(pid, reason)) })
  let #(registry, id, _) = threads.id_for(state.threads, pid)
  log.info("started program, thread " <> int.to_string(id))
  State(..state, threads: registry, program: Some(pid), program_state: Running)
}

fn set_entry_break(
  state: State,
  index: Index,
  module: String,
  function: String,
) -> State {
  let location = {
    use info <- result.try(project.get_module(index, module))
    use f <- result.try(list.find(info.functions, fn(f) { f.name == function }))
    use line <- result.try(list.first(f.clause_lines))
    Ok(#(module, line))
  }
  case location {
    Ok(#(module, line)) -> {
      int_set_break(module, line)
      State(..state, entry_break: Some(#(module, line)))
    }
    Error(Nil) -> state
  }
}

// --- Breakpoints ---------------------------------------------------------------

@external(erlang, "gleam_dap_int_ffi", "set_break")
fn int_set_break(module: String, line: Int) -> Nil

@external(erlang, "gleam_dap_int_ffi", "delete_break")
fn int_delete_break(module: String, line: Int) -> Nil

@external(erlang, "gleam_dap_int_ffi", "set_condition")
fn int_set_condition(module: String, line: Int, check: #(String, String)) -> Nil

@external(erlang, "gleam_dap_eval_ffi", "set_conditions")
fn set_conditions(
  conditions: List(#(Int, Dynamic, Dynamic, Dynamic)),
  callbacks: #(fn(String) -> Nil, fn(String) -> Nil),
) -> Nil

type SourceBreakpoint {
  SourceBreakpoint(
    line: Int,
    condition: Option(String),
    hit_condition: Option(String),
    log_message: Option(String),
  )
}

fn non_empty(value: Option(String)) -> Option(String) {
  case value {
    Some("") -> None
    other -> other
  }
}

fn set_breakpoints(state: State, request: Request) -> State {
  let decoder = {
    use path <- decode.subfield(["source", "path"], decode.string)
    use breakpoints <- decode.optional_field(
      "breakpoints",
      [],
      decode.list({
        use line <- decode.field("line", decode.int)
        use condition <- decode.optional_field(
          "condition",
          None,
          decode.optional(decode.string),
        )
        use hit_condition <- decode.optional_field(
          "hitCondition",
          None,
          decode.optional(decode.string),
        )
        use log_message <- decode.optional_field(
          "logMessage",
          None,
          decode.optional(decode.string),
        )
        decode.success(SourceBreakpoint(
          line:,
          condition: non_empty(condition),
          hit_condition: non_empty(hit_condition),
          log_message: non_empty(log_message),
        ))
      }),
    )
    decode.success(#(path, breakpoints))
  }
  use #(path, requested) <- decode_args(request, decoder, _, state)
  let path = project.absname(path)
  let module = case state.index {
    Some(index) -> project.module_for_path(index, path)
    None -> Error(Nil)
  }
  let #(state, breakpoints) =
    list.map_fold(requested, state, fn(state, source) {
      let id = state.next_breakpoint_id
      let resolved = case module {
        Ok(module) -> project.resolve_line(module, source.line)
        Error(Nil) ->
          project.Unresolved("This file is not part of the debugged program")
      }
      let breakpoint =
        LineBreakpoint(
          id:,
          requested: source.line,
          resolved:,
          module: case module {
            Ok(m) -> m.module
            Error(Nil) -> ""
          },
          condition: source.condition,
          hit_condition: source.hit_condition,
          log_message: source.log_message,
        )
      #(State(..state, next_breakpoint_id: id + 1), breakpoint)
    })
  let state =
    State(
      ..state,
      line_breakpoints: dict.insert(state.line_breakpoints, path, breakpoints),
    )
    |> sync_breaks
  respond(
    request,
    Some(
      JObject([
        #(
          "breakpoints",
          JArray(list.map(breakpoints, line_breakpoint_json(_, path))),
        ),
      ]),
    ),
  )
  state
}

fn line_breakpoint_json(breakpoint: LineBreakpoint, path: String) -> Json {
  case breakpoint.resolved {
    project.Resolved(line) ->
      json.object([
        #("id", json.int(breakpoint.id)),
        #("verified", json.bool(True)),
        #("line", json.int(line)),
        #("source", Some(inspect.source_json(path))),
      ])
    project.Unresolved(reason) ->
      json.object([
        #("id", json.int(breakpoint.id)),
        #("verified", json.bool(False)),
        #("line", json.int(breakpoint.requested)),
        #("message", json.string(reason)),
        #("reason", json.string("failed")),
      ])
  }
}

fn set_function_breakpoints(state: State, request: Request) -> State {
  let decoder = {
    use breakpoints <- decode.field(
      "breakpoints",
      decode.list({
        use name <- decode.field("name", decode.string)
        use condition <- decode.optional_field(
          "condition",
          None,
          decode.optional(decode.string),
        )
        use hit_condition <- decode.optional_field(
          "hitCondition",
          None,
          decode.optional(decode.string),
        )
        decode.success(#(name, non_empty(condition), non_empty(hit_condition)))
      }),
    )
    decode.success(breakpoints)
  }
  use requested <- decode_args(request, decoder, _, state)
  let #(state, breakpoints) =
    list.map_fold(requested, state, fn(state, item) {
      let #(name, condition, hit_condition) = item
      let id = state.next_breakpoint_id
      let location = case state.index {
        Some(index) -> find_function_breakpoint(index, name)
        None -> Error("Launch the program first")
      }
      #(
        State(..state, next_breakpoint_id: id + 1),
        FunctionBreakpoint(id:, name:, location:, condition:, hit_condition:),
      )
    })
  let state = State(..state, function_breakpoints: breakpoints) |> sync_breaks
  respond(
    request,
    Some(
      JObject([
        #(
          "breakpoints",
          JArray(
            list.map(breakpoints, fn(b) {
              case b.location {
                Ok(#(module, [line, ..])) ->
                  json.object([
                    #("id", json.int(b.id)),
                    #("verified", json.bool(True)),
                    #("line", json.int(line)),
                    #("source", Some(inspect.source_json(module.source))),
                  ])
                Ok(#(_, [])) ->
                  json.object([
                    #("id", json.int(b.id)),
                    #("verified", json.bool(False)),
                    #("message", json.string("The function has no code")),
                  ])
                Error(message) ->
                  json.object([
                    #("id", json.int(b.id)),
                    #("verified", json.bool(False)),
                    #("message", json.string(message)),
                  ])
              }
            }),
          ),
        ),
      ]),
    ),
  )
  state
}

/// Finds `app/user.greet`, `app/user.greet/1` or just `greet` (searched in
/// the project's modules).
pub fn find_function_breakpoint(
  index: Index,
  name: String,
) -> Result(#(ModuleInfo, List(Int)), String) {
  let #(function_part, arity) = case string.split_once(name, "/") {
    _ ->
      case list.reverse(string.split(name, "/")) {
        [last, ..rest] ->
          case int.parse(last) {
            Ok(arity) -> #(string.join(list.reverse(rest), "/"), Some(arity))
            Error(Nil) -> #(name, None)
          }
        [] -> #(name, None)
      }
  }
  let #(module_name, function) = case
    string.split(function_part, ".") |> list.reverse
  {
    [function, module, ..rest] ->
      #(Some(string.join(list.reverse([module, ..rest]), ".")), function)
    _ -> #(None, function_part)
  }
  let candidates = case module_name {
    Some(module) ->
      project.get_module(index, names.gleam_to_module(module))
      |> result.map(fn(m) { [m] })
      |> result.unwrap([])
    None -> project.project_modules(index)
  }
  let found =
    list.flat_map(candidates, fn(module) {
      module.functions
      |> list.filter(fn(f) {
        f.name == function
        && case arity {
          Some(a) -> f.arity == a
          None -> True
        }
      })
      |> list.map(fn(f) { #(module, f.clause_lines) })
    })
  case found {
    [] -> Error("No function " <> name)
    [#(module, _), ..] ->
      Ok(#(
        module,
        found
          |> list.filter(fn(f) { { f.0 }.module == module.module })
          |> list.flat_map(fn(f) { f.1 })
          |> list.unique,
      ))
  }
}

type DesiredBreak {
  DesiredBreak(
    module: String,
    line: Int,
    condition: Option(String),
    hit_condition: Option(String),
    log_message: Option(String),
  )
}

/// Makes `int`'s breakpoints match the line and function breakpoints.
fn sync_breaks(state: State) -> State {
  let from_lines =
    state.line_breakpoints
    |> dict.values
    |> list.flatten
    |> list.filter_map(fn(b) {
      case b.resolved {
        project.Resolved(line) ->
          Ok(DesiredBreak(
            b.module,
            line,
            b.condition,
            b.hit_condition,
            b.log_message,
          ))
        project.Unresolved(_) -> Error(Nil)
      }
    })
  let from_functions =
    state.function_breakpoints
    |> list.flat_map(fn(b) {
      case b.location {
        Ok(#(module, lines)) ->
          list.map(lines, fn(line) {
            DesiredBreak(module.module, line, b.condition, b.hit_condition, None)
          })
        Error(_) -> []
      }
    })
  // One `int` breakpoint per line. An unconditional breakpoint wins over a
  // conditional one on the same line.
  let desired =
    list.append(from_lines, from_functions)
    |> list.fold(dict.new(), fn(acc, b: DesiredBreak) {
      let key = #(b.module, b.line)
      case dict.get(acc, key) {
        Ok(existing) ->
          case is_plain(existing) {
            True -> acc
            False -> dict.insert(acc, key, b)
          }
        Error(Nil) -> dict.insert(acc, key, b)
      }
    })
  set.each(state.int_breaks, fn(key) { int_delete_break(key.0, key.1) })
  let #(conditions, _) =
    desired
    |> dict.values
    |> list.map_fold(1, fn(slot, b) {
      int_set_break(b.module, b.line)
      case b.condition, b.hit_condition, b.log_message {
        None, None, None -> #(slot, None)
        _, _, _ -> {
          int_set_condition(b.module, b.line, #(
            "gleam_dap_conditions",
            "check_" <> int.to_string(slot),
          ))
          #(slot + 1, Some(#(slot, b)))
        }
      }
    })
    |> fn(pair) { #(option.values(pair.1), pair.0) }
  set_conditions(
    list.map(conditions, fn(c) {
      let #(slot, b) = c
      #(slot, or_none(b.condition), or_none(b.hit_condition), or_none(b.log_message))
    }),
    #(fn(text) { output("console", text <> "\n") }, fn(text) {
      output("stderr", text <> "\n")
    }),
  )
  // The stopOnEntry breakpoint survives until it is hit.
  case state.entry_break {
    Some(#(module, line)) -> int_set_break(module, line)
    None -> Nil
  }
  State(..state, int_breaks: desired |> dict.keys |> set.from_list)
}

fn is_plain(b: DesiredBreak) -> Bool {
  b.condition == None && b.hit_condition == None && b.log_message == None
}

@external(erlang, "gleam_dap_session_ffi", "or_none")
fn or_none(value: Option(String)) -> Dynamic

fn set_exception_breakpoints(state: State, request: Request) -> State {
  let decoder = {
    use filters <- decode.optional_field(
      "filters",
      [],
      decode.list(decode.string),
    )
    decode.success(filters)
  }
  use filters <- decode_args(request, decoder, _, state)
  respond(request, None)
  State(..state, exception_filters: filters)
}

fn breakpoint_locations(state: State, request: Request) -> State {
  let decoder = {
    use path <- decode.subfield(["source", "path"], decode.string)
    use line <- decode.field("line", decode.int)
    use end_line <- decode.optional_field("endLine", line, decode.int)
    decode.success(#(path, line, end_line))
  }
  use #(path, line, end_line) <- decode_args(request, decoder, _, state)
  let lines = case state.index {
    Some(index) ->
      case project.module_for_path(index, path) {
        Ok(module) -> project.breakable_lines(module, line, end_line)
        Error(Nil) -> []
      }
    None -> []
  }
  respond(
    request,
    Some(
      JObject([
        #(
          "breakpoints",
          JArray(list.map(lines, fn(l) { JObject([#("line", JInt(l))]) })),
        ),
      ]),
    ),
  )
  state
}

// --- Threads -------------------------------------------------------------------

@external(erlang, "gleam_dap_int_ffi", "snapshot")
fn int_snapshot() -> List(#(Pid, String, String, Int))

@external(erlang, "gleam_dap_ffi", "descendants")
fn descendants(root: Pid) -> List(Pid)

@external(erlang, "gleam_dap_ffi", "process_name")
fn process_name(pid: Pid) -> Result(String, Nil)

@external(erlang, "gleam_dap_ffi", "pid_to_string")
fn pid_to_string(pid: Pid) -> String

/// The processes shown as threads: interpreted processes, the program's
/// own processes and stopped processes (which may have crashed).
fn current_threads(state: State) -> List(Pid) {
  let interpreted = int_snapshot() |> list.map(fn(s) { s.0 })
  let program = case state.program, state.program_state {
    Some(pid), Running -> descendants(pid)
    _, _ -> []
  }
  list.flatten([program, interpreted, dict.keys(state.stopped)])
  |> list.unique
}

fn threads_request(state: State, request: Request) -> State {
  let pids = current_threads(state)
  let #(registry, entries) =
    list.map_fold(pids, state.threads, fn(registry, pid) {
      let #(registry, id, _) = threads.id_for(registry, pid)
      #(registry, #(id, pid))
    })
  let entries = list.sort(entries, fn(a, b) { int.compare(a.0, b.0) })
  respond(
    request,
    Some(
      JObject([
        #(
          "threads",
          JArray(
            list.map(entries, fn(entry) {
              JObject([
                #("id", JInt(entry.0)),
                #("name", JString(thread_name(state, entry.1))),
              ])
            }),
          ),
        ),
      ]),
    ),
  )
  State(..state, threads: registry)
}

fn thread_name(state: State, pid: Pid) -> String {
  let name = case state.program == Some(pid) {
    True -> "main"
    False -> process_name(pid) |> result.unwrap("process")
  }
  name <> " " <> pid_to_string(pid)
}

fn pid_for_thread(state: State, id: Int) -> Result(Pid, Nil) {
  threads.pid_for(state.threads, id)
}

// --- Reading stopped processes ------------------------------------------------

@external(erlang, "gleam_dap_session_ffi", "spawn_worker")
fn spawn_worker(f: fn() -> Nil) -> Pid

/// Runs a request in a worker process, which sends the response itself.
fn in_worker(
  state: State,
  request: Request,
  work: fn() -> Result(Json, String),
) -> State {
  let subject = state.subject
  let pid =
    spawn_worker(fn() {
      case work() {
        Ok(body) -> respond(request, Some(body))
        Error(message) -> respond_error(request, message)
      }
      process.send(subject, WorkerDone(request.seq))
    })
  State(..state, workers: dict.insert(state.workers, request.seq, pid))
}

fn context(state: State) -> Result(inspect.Context, String) {
  case state.index {
    Some(index) -> Ok(inspect.context(index))
    None -> Error("Launch the program first")
  }
}

fn to_inspect_stopped(info: StopInfo) -> Stopped {
  case info {
    StoppedAt(module, line) -> AtLine(module, line)
    CrashStop(reason, meta, _) -> Crashed(reason, meta)
  }
}

fn stack_trace(state: State, request: Request) -> State {
  let decoder = {
    use thread_id <- decode.field("threadId", decode.int)
    use start <- decode.optional_field("startFrame", 0, decode.int)
    use levels <- decode.optional_field("levels", 0, decode.int)
    decode.success(#(thread_id, start, levels))
  }
  use #(thread_id, start, levels) <- decode_args(request, decoder, _, state)
  let target = {
    use ctx <- result.try(context(state))
    use pid <- result.try(
      pid_for_thread(state, thread_id) |> result.replace_error("Unknown thread"),
    )
    use info <- result.try(
      dict.get(state.stopped, pid)
      |> result.replace_error("The thread is not stopped"),
    )
    Ok(#(ctx, pid, to_inspect_stopped(info)))
  }
  case target {
    Ok(#(ctx, pid, stopped)) ->
      in_worker(state, request, fn() {
        inspect.stack_trace_body(ctx, pid, stopped, start, levels)
      })
    Error(message) -> {
      respond_error(request, message)
      state
    }
  }
}

fn scopes(state: State, request: Request) -> State {
  let decoder = {
    use frame_id <- decode.field("frameId", decode.int)
    decode.success(frame_id)
  }
  use frame_id <- decode_args(request, decoder, _, state)
  in_worker(state, request, fn() { inspect.scopes_body(frame_id) })
}

fn variables(state: State, request: Request) -> State {
  let decoder = {
    use reference <- decode.field("variablesReference", decode.int)
    decode.success(reference)
  }
  use reference <- decode_args(request, decoder, _, state)
  case context(state) {
    Ok(ctx) ->
      in_worker(state, request, fn() { inspect.variables_body(ctx, reference) })
    Error(message) -> {
      respond_error(request, message)
      state
    }
  }
}

fn evaluate(state: State, request: Request) -> State {
  let decoder = {
    use expression <- decode.field("expression", decode.string)
    use frame_id <- decode.optional_field(
      "frameId",
      None,
      decode.optional(decode.int),
    )
    decode.success(#(expression, frame_id))
  }
  use #(expression, frame_id) <- decode_args(request, decoder, _, state)
  case context(state) {
    Ok(ctx) ->
      in_worker(state, request, fn() {
        inspect.evaluate_body(ctx, expression, frame_id)
      })
    Error(message) -> {
      respond_error(request, message)
      state
    }
  }
}

fn completions(state: State, request: Request) -> State {
  let decoder = {
    use text <- decode.field("text", decode.string)
    use column <- decode.field("column", decode.int)
    use frame_id <- decode.optional_field(
      "frameId",
      None,
      decode.optional(decode.int),
    )
    decode.success(#(text, column, frame_id))
  }
  use #(text, column, frame_id) <- decode_args(request, decoder, _, state)
  case context(state) {
    Ok(ctx) ->
      in_worker(state, request, fn() {
        inspect.completions_body(ctx, text, column, frame_id)
      })
    Error(message) -> {
      respond_error(request, message)
      state
    }
  }
}

fn exception_info(state: State, request: Request) -> State {
  use thread_id <- decode_args(request, thread_id_decoder(), _, state)
  let info = {
    use ctx <- result.try(context(state))
    use pid <- result.try(
      pid_for_thread(state, thread_id) |> result.replace_error("Unknown thread"),
    )
    case dict.get(state.stopped, pid) {
      Ok(CrashStop(reason, _, _)) -> Ok(inspect.exception_info_body(ctx, reason))
      _ -> Error("The thread is not stopped on an exception")
    }
  }
  case info {
    Ok(body) -> respond(request, Some(body))
    Error(message) -> respond_error(request, message)
  }
  state
}

// --- Execution control ---------------------------------------------------------

@external(erlang, "gleam_dap_int_ffi", "continue")
fn int_continue(pid: Pid) -> Nil

@external(erlang, "gleam_dap_int_ffi", "next")
fn int_next(pid: Pid) -> Nil

@external(erlang, "gleam_dap_int_ffi", "step")
fn int_step(pid: Pid) -> Nil

@external(erlang, "gleam_dap_int_ffi", "finish")
fn int_finish(pid: Pid) -> Nil

@external(erlang, "gleam_dap_int_ffi", "stop")
fn int_stop(pid: Pid) -> Result(Nil, Nil)

@external(erlang, "gleam_dap_int_ffi", "release")
fn int_release(holder: Pid) -> Nil

@external(erlang, "gleam_dap_int_ffi", "get_meta")
fn int_get_meta(pid: Pid) -> Result(Pid, Nil)

@external(erlang, "gleam_dap_int_ffi", "top_frame")
fn int_top_frame(meta: Pid) -> Result(#(Int, String, String, Int), String)

fn continue_request(state: State, request: Request) -> State {
  let decoder = {
    use thread_id <- decode.field("threadId", decode.int)
    use single <- decode.optional_field("singleThread", False, decode.bool)
    decode.success(#(thread_id, single))
  }
  use #(thread_id, single) <- decode_args(request, decoder, _, state)
  let pids = case single, pid_for_thread(state, thread_id) {
    True, Ok(pid) -> [pid]
    True, Error(Nil) -> []
    // Like ElixirLS, resuming one thread resumes all paused threads.
    False, _ -> dict.keys(state.stopped)
  }
  respond(
    request,
    Some(JObject([#("allThreadsContinued", JBool(!single))])),
  )
  list.fold(pids, state, resume)
}

/// Lets a stopped process run again.
fn resume(state: State, pid: Pid) -> State {
  refs_clear_for(pid)
  case dict.get(state.stopped, pid) {
    Ok(StoppedAt(_, _)) -> {
      int_continue(pid)
      State(..state, stopped: dict.delete(state.stopped, pid))
    }
    Ok(CrashStop(_, _, holder)) -> {
      int_release(holder)
      State(..state, stopped: dict.delete(state.stopped, pid))
      |> thread_exited(pid)
      |> maybe_finish
    }
    Error(Nil) -> state
  }
}

fn step_request(state: State, request: Request, kind: String) -> State {
  use thread_id <- decode_args(request, thread_id_decoder(), _, state)
  case pid_for_thread(state, thread_id) {
    Error(Nil) -> {
      respond_error(request, "Unknown thread")
      state
    }
    Ok(pid) ->
      case dict.get(state.stopped, pid) {
        Ok(StoppedAt(module, line)) -> {
          respond(request, None)
          refs_clear_for(pid)
          let state = State(..state, stopped: dict.delete(state.stopped, pid))
          case kind {
            "stepIn" -> {
              int_step(pid)
              State(..state, stepping: dict.insert(state.stepping, pid, SimpleStep))
            }
            "stepOut" -> {
              int_finish(pid)
              State(..state, stepping: dict.insert(state.stepping, pid, SimpleStep))
            }
            _ -> start_step_over(state, pid, module, line)
          }
        }
        Ok(CrashStop(..)) -> {
          // A crashed process can't step; stepping lets it go.
          respond(request, None)
          resume(state, pid)
        }
        Error(Nil) -> {
          respond_error(request, "The thread is not stopped")
          state
        }
      }
  }
}

fn current_frame(pid: Pid, module: String, line: Int) -> Result(stepping.Frame, Nil) {
  use meta <- result.try(int_get_meta(pid))
  use #(level, _module, function, arity) <- result.try(
    int_top_frame(meta) |> result.replace_error(Nil),
  )
  Ok(stepping.Frame(module:, function:, arity:, level:, line:))
}

fn start_step_over(state: State, pid: Pid, module: String, line: Int) -> State {
  case current_frame(pid, module, line) {
    Ok(frame) -> {
      let defines_fun = case state.index {
        Some(index) ->
          case project.get_module(index, module) {
            Ok(info) ->
              case project.function_at(info, line) {
                Ok(f) -> list.contains(f.lines_with_fun, line)
                Error(Nil) -> False
              }
            Error(Nil) -> False
          }
        None -> False
      }
      let #(command, step) = stepping.start(frame, defines_fun)
      run_command(pid, command)
      State(..state, stepping: dict.insert(state.stepping, pid, Over(step)))
    }
    Error(Nil) -> {
      int_next(pid)
      State(..state, stepping: dict.insert(state.stepping, pid, SimpleStep))
    }
  }
}

fn run_command(pid: Pid, command: stepping.Command) -> Nil {
  case command {
    stepping.Next -> int_next(pid)
    stepping.Step -> int_step(pid)
    stepping.Finish -> int_finish(pid)
  }
}

fn pause(state: State, request: Request) -> State {
  use thread_id <- decode_args(request, thread_id_decoder(), _, state)
  case pid_for_thread(state, thread_id) {
    Ok(pid) ->
      case dict.has_key(state.stopped, pid) {
        True -> {
          respond(request, None)
          state
        }
        False ->
          case int_stop(pid) {
            Ok(Nil) -> {
              respond(request, None)
              State(..state, pausing: set.insert(state.pausing, pid))
            }
            Error(Nil) -> {
              respond_error(
                request,
                "Only processes running interpreted code can be paused",
              )
              state
            }
          }
      }
    Error(Nil) -> {
      respond_error(request, "Unknown thread")
      state
    }
  }
}

@external(erlang, "gleam_dap_ffi", "kill")
fn kill(pid: Pid) -> Nil

fn terminate_threads(state: State, request: Request) -> State {
  let decoder = {
    use ids <- decode.optional_field("threadIds", [], decode.list(decode.int))
    decode.success(ids)
  }
  use ids <- decode_args(request, decoder, _, state)
  respond(request, None)
  list.fold(ids, state, fn(state, id) {
    case pid_for_thread(state, id) {
      Ok(pid) -> {
        let state = resume(state, pid)
        kill(pid)
        state
      }
      Error(Nil) -> state
    }
  })
}

fn cancel(state: State, request: Request) -> State {
  let decoder = {
    use id <- decode.optional_field("requestId", None, decode.optional(decode.int))
    decode.success(id)
  }
  use id <- decode_args(request, decoder, _, state)
  case id |> option.to_result(Nil) |> result.try(dict.get(state.workers, _)) {
    Ok(worker) -> {
      kill(worker)
      // The client expects the cancelled request to be answered.
      protocol.send(
        json.object([
          #("seq", Some(JInt(0))),
          #("type", json.string("response")),
          #("request_seq", json.int(option.unwrap(id, 0))),
          #("success", json.bool(False)),
          #("command", json.string("cancelled")),
          #("message", json.string("cancelled")),
        ]),
      )
    }
    Error(Nil) -> Nil
  }
  respond(request, None)
  State(..state, workers: case id {
    Some(id) -> dict.delete(state.workers, id)
    None -> state.workers
  })
}

fn terminate(state: State, request: Request) -> State {
  respond(request, None)
  stop_program(state)
}

fn stop_program(state: State) -> State {
  let state = dict.keys(state.stopped) |> list.fold(state, resume)
  case state.program {
    Some(pid) -> {
      list.each(descendants(pid), kill)
      kill(pid)
    }
    None -> Nil
  }
  case state.program_state {
    Finished -> state
    _ -> {
      send_event(protocol.terminated_event())
      State(..state, program_state: Finished)
    }
  }
}

@external(erlang, "gleam_dap_session_ffi", "detach_all")
fn detach_all() -> Nil

fn disconnect(state: State, request: Request) -> State {
  let decoder = {
    use terminate <- decode.optional_field(
      "terminateDebuggee",
      None,
      decode.optional(decode.bool),
    )
    decode.success(terminate)
  }
  use terminate_debuggee <- decode_args(request, decoder, _, state)
  let state = case state.mode, terminate_debuggee {
    Attach, Some(True) -> stop_program(state)
    Attach, _ -> {
      // Leave the node as we found it.
      let state = dict.keys(state.stopped) |> list.fold(state, resume)
      detach_all()
      state
    }
    Launch, _ -> stop_program(state)
  }
  respond(request, None)
  let subject = state.subject
  send_after(200, fn() { process.send(subject, Halt) })
  state
}

// --- int events --------------------------------------------------------------

fn handle_int_event(state: State, event: IntEvent) -> State {
  case event {
    IntBreak(pid, module, line) -> on_break(state, pid, module, line)
    IntExit(pid, reason, attached) -> on_exit(state, pid, reason, attached)
  }
}

fn register_thread(state: State, pid: Pid) -> #(State, Int) {
  let #(registry, id, new) = threads.id_for(state.threads, pid)
  case new {
    True -> send_event(protocol.thread_event("started", id))
    False -> Nil
  }
  #(State(..state, threads: registry), id)
}

fn thread_exited(state: State, pid: Pid) -> State {
  case threads.lookup(state.threads, pid) {
    Ok(id) -> {
      send_event(protocol.thread_event("exited", id))
      State(..state, threads: threads.remove(state.threads, pid))
    }
    Error(Nil) -> state
  }
}

fn on_break(state: State, pid: Pid, module: String, line: Int) -> State {
  let #(state, thread_id) = register_thread(state, pid)
  let at_breakpoint = set.contains(state.int_breaks, #(module, line))
  let at_entry = state.entry_break == Some(#(module, line))
  case dict.get(state.stepping, pid) {
    Ok(Over(step)) ->
      case current_frame(pid, module, line) {
        Ok(frame) ->
          case stepping.decide(step, frame, at_breakpoint) {
            stepping.Stop ->
              report_stop(
                State(..state, stepping: dict.delete(state.stepping, pid)),
                pid,
                thread_id,
                module,
                line,
                case at_breakpoint {
                  True -> "breakpoint"
                  False -> "step"
                },
              )
            stepping.Continue(command, step) -> {
              run_command(pid, command)
              State(
                ..state,
                stepping: dict.insert(state.stepping, pid, Over(step)),
              )
            }
          }
        Error(Nil) ->
          report_stop(
            State(..state, stepping: dict.delete(state.stepping, pid)),
            pid,
            thread_id,
            module,
            line,
            "step",
          )
      }
    Ok(SimpleStep) ->
      report_stop(
        State(..state, stepping: dict.delete(state.stepping, pid)),
        pid,
        thread_id,
        module,
        line,
        case at_breakpoint {
          True -> "breakpoint"
          False -> "step"
        },
      )
    Error(Nil) -> {
      let reason = case set.contains(state.pausing, pid), at_entry, at_breakpoint {
        True, _, _ -> "pause"
        _, True, False -> "entry"
        _, _, _ -> "breakpoint"
      }
      let state = case at_entry {
        True -> {
          let assert Some(#(m, l)) = state.entry_break
          case at_breakpoint {
            True -> Nil
            False -> int_delete_break(m, l)
          }
          State(..state, entry_break: None)
        }
        False -> state
      }
      report_stop(
        State(..state, pausing: set.delete(state.pausing, pid)),
        pid,
        thread_id,
        module,
        line,
        reason,
      )
    }
  }
}

fn report_stop(
  state: State,
  pid: Pid,
  thread_id: Int,
  module: String,
  line: Int,
  reason: String,
) -> State {
  let hit = case reason {
    "breakpoint" -> breakpoint_ids_at(state, module, line)
    _ -> []
  }
  log.info(
    "stopped ("
    <> reason
    <> ") at "
    <> module
    <> ":"
    <> int.to_string(line)
    <> " thread "
    <> int.to_string(thread_id),
  )
  send_event(protocol.stopped_event(reason, thread_id, None, None, hit))
  State(..state, stopped: dict.insert(state.stopped, pid, StoppedAt(module, line)))
}

fn breakpoint_ids_at(state: State, module: String, line: Int) -> List(Int) {
  let from_lines =
    state.line_breakpoints
    |> dict.values
    |> list.flatten
    |> list.filter(fn(b) {
      b.module == module && b.resolved == project.Resolved(line)
    })
    |> list.map(fn(b) { b.id })
  let from_functions =
    state.function_breakpoints
    |> list.filter(fn(b) {
      case b.location {
        Ok(#(m, lines)) -> m.module == module && list.contains(lines, line)
        Error(_) -> False
      }
    })
    |> list.map(fn(b) { b.id })
  list.append(from_lines, from_functions)
}

fn on_exit(
  state: State,
  pid: Pid,
  reason: Dynamic,
  attached: Option(#(Pid, Pid)),
) -> State {
  let state = State(..state, stepping: dict.delete(state.stepping, pid))
  case attached {
    None -> thread_exited(state, pid)
    Some(#(meta, holder)) ->
      case should_stop_on_crash(state, reason) {
        False -> {
          int_release(holder)
          thread_exited(state, pid)
        }
        True -> {
          let #(state, thread_id) = register_thread(state, pid)
          let description = case context(state) {
            Ok(ctx) -> inspect.describe_crash(ctx, reason)
            Error(_) -> "crashed"
          }
          log.info("stopped on crash: " <> description)
          send_event(protocol.stopped_event(
            "exception",
            thread_id,
            Some(description),
            Some(description),
            [],
          ))
          State(
            ..state,
            stopped: dict.insert(state.stopped, pid, CrashStop(reason, meta, holder)),
          )
        }
      }
  }
}

fn should_stop_on_crash(state: State, reason: Dynamic) -> Bool {
  let is_gleam_error = result.is_ok(inspect.gleam_error(reason))
  let ordinary_shutdown = is_shutdown(reason)
  case ordinary_shutdown {
    True -> False
    False ->
      list.contains(state.exception_filters, "all")
      || { is_gleam_error && list.contains(state.exception_filters, "gleam") }
  }
}

@external(erlang, "gleam_dap_session_ffi", "is_shutdown")
fn is_shutdown(reason: Dynamic) -> Bool

// --- Program end ---------------------------------------------------------------

@external(erlang, "gleam_dap_session_ffi", "is_normal")
fn is_normal(reason: Dynamic) -> Bool

fn program_down(state: State, pid: Pid, reason: Dynamic) -> State {
  case state.program == Some(pid) && state.program_state == Running {
    False -> state
    True -> {
      let code = case is_normal(reason) {
        True -> 0
        False -> 1
      }
      case code, context(state) {
        1, Ok(ctx) ->
          output(
            "stderr",
            "The program crashed: " <> inspect.describe_crash(ctx, reason) <> "\n",
          )
        _, _ -> Nil
      }
      log.info("program ended with exit code " <> int.to_string(code))
      let subject = state.subject
      // Give `int` a moment to report a crash, so we can stop on it first.
      send_after(300, fn() { process.send(subject, FinishProgram) })
      State(..state, program_state: Ended(code))
    }
  }
}

fn finish_program(state: State) -> State {
  maybe_finish(state)
}

/// Reports the end of the program once nothing is stopped on its crash.
fn maybe_finish(state: State) -> State {
  case state.program_state, state.program {
    Ended(code), Some(pid) ->
      case dict.has_key(state.stopped, pid) {
        True -> state
        False -> {
          let state = thread_exited(state, pid)
          send_event(protocol.exited_event(code))
          send_event(protocol.terminated_event())
          State(..state, program_state: Finished)
        }
      }
    _, _ -> state
  }
}

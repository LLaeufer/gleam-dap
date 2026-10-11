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
  /// A step over or step out running on temporary breakpoints.
  Targeted
  /// Running on from `debug.break()` to the caller's next line.
  DebugBreak
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
    /// Modules interpreted by `int`; breakpoints elsewhere never stop.
    interpreted: Set(String),
    stdout: Option(Pid),
    line_breakpoints: Dict(String, List(LineBreakpoint)),
    function_breakpoints: List(FunctionBreakpoint),
    /// Lines with a breakpoint of the user's.
    int_breaks: Set(#(String, Int)),
    /// Breakpoints currently set in `int`, with their condition slot if they
    /// have one. Includes the temporary breakpoints of steps in progress.
    installed: Dict(#(String, Int), Option(Int)),
    /// The condition slot of each line that ever needed one, kept stable so
    /// hit counts survive.
    slots: Dict(#(String, Int), Int),
    next_slot: Int,
    /// Temporary breakpoints of the steps in progress.
    step_targets: Dict(Pid, List(stepping.Target)),
    /// Temporary breakpoint for `stopOnEntry`.
    entry_break: Option(#(String, Int)),
    /// The breakpoint behind `debug.break()`, when the project uses it.
    debug_break: Option(#(String, Int)),
    next_breakpoint_id: Int,
    exception_filters: List(String),
    threads: threads.Registry,
    stopped: Dict(Pid, StopInfo),
    stepping: Dict(Pid, Stepping),
    pausing: Set(Pid),
    program: Option(Pid),
    program_state: ProgramState,
    workers: Dict(Int, Pid),
    /// The `initialize` request as it came, for a child adapter.
    initialize_body: Option(BitArray),
    /// When the program has arguments, the child adapter that runs it; this
    /// one only relays messages to it.
    relay: Option(Pid),
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

@external(erlang, "gleam_dap_session_ffi", "register")
fn register(pid: Pid, name: String) -> Bool

/// Runs the adapter on stdio until the client disconnects.
pub fn run() -> Nil {
  refs_init()
  // `debug.break()` checks for this name.
  let _ = register(process.self(), "gleam_dap_session")
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
    interpreted: set.new(),
    stdout: None,
    line_breakpoints: dict.new(),
    function_breakpoints: [],
    int_breaks: set.new(),
    installed: dict.new(),
    slots: dict.new(),
    next_slot: 1,
    step_targets: dict.new(),
    entry_break: None,
    debug_break: None,
    next_breakpoint_id: 1,
    exception_filters: ["gleam"],
    threads: threads.new(),
    stopped: dict.new(),
    stepping: dict.new(),
    pausing: set.new(),
    program: None,
    program_state: NotStarted,
    workers: dict.new(),
    initialize_body: None,
    relay: None,
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
    Incoming(body) if state.relay != None -> {
      let assert Some(relay) = state.relay
      relay_forward(relay, body)
      state
    }
    Incoming(body) ->
      case json.parse(body) |> result.try(protocol.decode_request) {
        Ok(request) -> {
          log.info("<- " <> request.command)
          case request.command, state.initialized {
            "initialize", _ ->
              handle_request(
                State(..state, initialize_body: Some(body)),
                request,
              )
            "launch", True ->
              case program_args(request) {
                [_, ..] as args -> start_relay(state, args, body)
                [] -> handle_request(state, request)
              }
            _, _ -> handle_request(state, request)
          }
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

// --- Program arguments ------------------------------------------------------

@external(erlang, "gleam_dap_relay_ffi", "is_child")
fn is_child() -> Bool

@external(erlang, "gleam_dap_relay_ffi", "start")
fn relay_start(
  args: List(String),
  initialize: BitArray,
  launch: BitArray,
  on_exit: fn(Int) -> Nil,
) -> Pid

@external(erlang, "gleam_dap_relay_ffi", "forward")
fn relay_forward(relay: Pid, body: BitArray) -> Nil

/// The program's arguments, when this adapter has to start a child adapter
/// for them: they can only be given to a VM when it starts (see
/// `gleam_dap_relay_ffi`).
fn program_args(request: Request) -> List(String) {
  case is_child(), launch.decode_config(request.arguments, "") {
    False, Ok(config) if config.node == "" -> config.args
    _, _ -> []
  }
}

fn start_relay(
  state: State,
  args: List(String),
  launch_body: BitArray,
) -> State {
  let subject = state.subject
  case state.initialize_body {
    Some(initialize) -> {
      log.info("starting a child adapter for the program's arguments")
      let relay =
        relay_start(args, initialize, launch_body, fn(status) {
          log.info("child adapter exited with " <> int.to_string(status))
          process.send(subject, Halt)
        })
      State(..state, relay: Some(relay))
    }
    None -> state
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
    Ok(#(config, index, interpreted, mode)) -> {
      respond(request, None)
      send_event(protocol.event("initialized", None))
      State(
        ..state,
        mode:,
        config: Some(config),
        index: Some(index),
        interpreted:,
        debug_break: setup_debug_break(index, config, mode),
      )
      |> capture_output
    }
    Error(message) -> {
      respond_error(request, message)
      state
    }
  }
}

fn prepare(
  request: Request,
  mode: Mode,
) -> Result(#(Config, Index, Set(String), Mode), String) {
  use config <- result.try(launch.decode_config(request.arguments, get_cwd()))
  // A `launch` that names a node attaches to it. LSP4IJ's own attach mode
  // expects a debug adapter listening on a socket, so IntelliJ users attach
  // through a launch configuration instead.
  let mode = case mode, config.node {
    Launch, "" -> Launch
    _, _ -> Attach
  }
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
  set_remote_conditions(mode == Attach)
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
    True -> Ok(#(config, index, set.new(), mode))
    False -> {
      use _ <- result.try(int_start(config.stack_trace_mode))
      let modules = launch.modules_to_interpret(index, config)
      let failures = launch.interpret(modules, mode == Attach)
      list.each(failures, fn(f) {
        output("console", "Could not interpret " <> f.0 <> ": " <> f.1 <> "\n")
      })
      log.info(
        "interpreted "
        <> int.to_string(list.length(modules) - list.length(failures))
        <> " modules",
      )
      let failed = list.map(failures, fn(f) { names.gleam_to_module(f.0) })
      let interpreted =
        modules
        |> list.map(fn(m) { m.module })
        |> list.filter(fn(m) { !list.contains(failed, m) })
        |> set.from_list
      Ok(#(config, index, interpreted, mode))
    }
  }
}

@external(erlang, "gleam_dap_int_ffi", "interpret")
fn int_interpret(
  module: String,
  source: String,
  beam: String,
  distributed: Bool,
) -> Result(Nil, String)

/// Interprets the `gleam_dap_debug` package's FFI module, if the project
/// uses it, and sets the breakpoint `debug.break()` relies on.
fn setup_debug_break(
  index: Index,
  config: Config,
  mode: Mode,
) -> Option(#(String, Int)) {
  let found = {
    use module <- result.try(project.get_module(index, debug_module))
    use f <- result.try(project.find_function(module, "stop_here", 0))
    use line <- result.try(list.first(f.clause_lines))
    use _ <- result.try(
      int_interpret(module.module, module.source, module.beam, mode == Attach)
      |> result.replace_error(Nil),
    )
    int_set_break(module.module, line)
    Ok(#(module.module, line))
  }
  case config.no_debug, found {
    False, Ok(location) -> Some(location)
    _, _ -> None
  }
}

const debug_module = "gleam_dap_debug_ffi"

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
        False ->
          int_auto_attach(fn(event) { process.send(subject, Int(event)) })
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
  watch_process(pid, fn(reason) {
    process.send(subject, ProgramDown(pid, reason))
  })
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

@external(erlang, "gleam_dap_eval_ffi", "set_remote")
fn set_remote_conditions(remote: Bool) -> Nil

@external(erlang, "gleam_dap_eval_ffi", "set_conditions")
fn set_conditions(
  slots: List(#(Int, String, Int, SlotUser)),
  callbacks: #(fn(String) -> Nil, fn(String) -> Nil),
) -> Nil

/// The user's breakpoint behind a condition slot.
type SlotUser {
  NoUser
  Plain
  Conditional(condition: Dynamic, hit: Dynamic, log: Dynamic)
}

@external(erlang, "gleam_dap_eval_ffi", "set_step_targets")
fn set_step_targets(targets: List(#(Pid, String, Int, Int, Bool))) -> Nil

@external(erlang, "gleam_dap_eval_ffi", "take_step_stop")
fn take_step_stop(pid: Pid) -> Bool

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
        Ok(module) ->
          case set.contains(state.interpreted, module.module) {
            True -> project.resolve_line(module, source.line)
            False -> not_interpreted(module)
          }
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

fn not_interpreted(module: ModuleInfo) -> project.Resolved {
  project.Unresolved(not_interpreted_message(module))
}

fn not_interpreted_message(module: ModuleInfo) -> String {
  names.module_to_gleam(module.module)
  <> " is not interpreted. Add it to interpretModules in the launch configuration to debug it."
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
        Some(index) ->
          find_function_breakpoint(index, name)
          |> result.try(fn(found) {
            case set.contains(state.interpreted, { found.0 }.module) {
              True -> Ok(found)
              False -> Error(not_interpreted_message(found.0))
            }
          })
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
  let #(function_part, arity) = case list.reverse(string.split(name, "/")) {
    [last, ..rest] ->
      case int.parse(last) {
        Ok(arity) -> #(string.join(list.reverse(rest), "/"), Some(arity))
        Error(Nil) -> #(name, None)
      }
    [] -> #(name, None)
  }
  let #(module_name, function) = case
    string.split(function_part, ".") |> list.reverse
  {
    [function, module, ..rest] -> #(
      Some(string.join(list.reverse([module, ..rest]), ".")),
      function,
    )
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
            DesiredBreak(
              module.module,
              line,
              b.condition,
              b.hit_condition,
              None,
            )
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
  let targets = state.step_targets |> dict.values |> list.flatten
  let target_keys =
    targets |> list.map(fn(t) { #(t.module, t.line) }) |> set.from_list
  let keys = set.union(set.from_list(dict.keys(desired)), target_keys)
  // Which lines need a condition slot, and for whom.
  let #(state, slotted) =
    keys
    |> set.to_list
    |> list.fold(#(state, []), fn(acc, key) {
      let #(state, slotted) = acc
      let user = case dict.get(desired, key) {
        Error(Nil) -> NoUser
        Ok(b) ->
          case is_plain(b) {
            True -> Plain
            False ->
              Conditional(
                or_none(b.condition),
                or_none(b.hit_condition),
                or_none(b.log_message),
              )
          }
      }
      case user, set.contains(target_keys, key) {
        Plain, False -> #(state, slotted)
        _, _ -> {
          let #(state, slot) = slot_for(state, key)
          #(state, [#(slot, key.0, key.1, user), ..slotted])
        }
      }
    })
  // Conditions first, so a new breakpoint never fires without its condition.
  set_step_targets(
    list.flat_map(dict.to_list(state.step_targets), fn(entry) {
      list.map(entry.1, fn(t: stepping.Target) {
        #(entry.0, t.module, t.line, t.max_level, t.any_level)
      })
    }),
  )
  set_conditions(
    slotted,
    #(fn(text) { output("console", text <> "\n") }, fn(text) {
      output("stderr", text <> "\n")
    }),
  )
  let wanted =
    keys
    |> set.to_list
    |> list.map(fn(key) {
      #(
        key,
        list.find(slotted, fn(s) { #(s.1, s.2) == key })
          |> result.map(fn(s) { s.0 })
          |> option.from_result,
      )
    })
    |> dict.from_list
  // Only touch what changed, so that breakpoints other processes are about
  // to hit stay in place.
  dict.each(state.installed, fn(key, _) {
    case dict.has_key(wanted, key) {
      True -> Nil
      False -> int_delete_break(key.0, key.1)
    }
  })
  dict.each(wanted, fn(key, slot) {
    case dict.get(state.installed, key), slot {
      Ok(None), None -> Nil
      Ok(Some(old)), Some(new) if old == new -> Nil
      Ok(Some(_)), None -> {
        // `int` can't drop a condition: replace the breakpoint.
        int_delete_break(key.0, key.1)
        int_set_break(key.0, key.1)
      }
      Ok(_), Some(slot) -> int_set_condition(key.0, key.1, check_for(slot))
      Error(Nil), None -> int_set_break(key.0, key.1)
      Error(Nil), Some(slot) -> {
        int_set_break(key.0, key.1)
        int_set_condition(key.0, key.1, check_for(slot))
      }
    }
  })
  // The stopOnEntry breakpoint survives until it is hit.
  case state.entry_break {
    Some(#(module, line)) -> int_set_break(module, line)
    None -> Nil
  }
  State(
    ..state,
    int_breaks: desired |> dict.keys |> set.from_list,
    installed: wanted,
  )
}

fn slot_for(state: State, key: #(String, Int)) -> #(State, Int) {
  case dict.get(state.slots, key) {
    Ok(slot) -> #(state, slot)
    Error(Nil) -> #(
      State(
        ..state,
        slots: dict.insert(state.slots, key, state.next_slot),
        next_slot: state.next_slot + 1,
      ),
      state.next_slot,
    )
  }
}

fn check_for(slot: Int) -> #(String, String) {
  #("gleam_dap_conditions", "check_" <> int.to_string(slot))
}

fn has_plain_breakpoint(state: State, module: String, line: Int) -> Bool {
  let lines =
    state.line_breakpoints
    |> dict.values
    |> list.flatten
    |> list.any(fn(b) {
      b.module == module
      && b.resolved == project.Resolved(line)
      && b.condition == None
      && b.hit_condition == None
      && b.log_message == None
    })
  let functions =
    list.any(state.function_breakpoints, fn(b) {
      b.condition == None
      && b.hit_condition == None
      && case b.location {
        Ok(#(m, lines)) -> m.module == module && list.contains(lines, line)
        Error(_) -> False
      }
    })
  lines || functions
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
    use start <- decode.optional_field(
      "start",
      None,
      decode.optional(decode.int),
    )
    use count <- decode.optional_field(
      "count",
      None,
      decode.optional(decode.int),
    )
    use filter <- decode.optional_field(
      "filter",
      None,
      decode.optional(decode.string),
    )
    decode.success(#(reference, inspect.Page(start:, count:, filter:)))
  }
  use #(reference, page) <- decode_args(request, decoder, _, state)
  case context(state) {
    Ok(ctx) ->
      in_worker(state, request, fn() {
        inspect.variables_body(ctx, reference, page)
      })
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
      Ok(CrashStop(reason, _, _)) ->
        Ok(inspect.exception_info_body(ctx, reason))
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
  respond(request, Some(JObject([#("allThreadsContinued", JBool(!single))])))
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
              State(
                ..state,
                stepping: dict.insert(state.stepping, pid, SimpleStep),
              )
            }
            "stepOut" -> start_step_out(state, pid, module, line)
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

fn current_frame(
  pid: Pid,
  module: String,
  line: Int,
) -> Result(stepping.Frame, Nil) {
  use meta <- result.try(int_get_meta(pid))
  use #(level, _module, function, arity) <- result.try(
    int_top_frame(meta) |> result.replace_error(Nil),
  )
  Ok(stepping.Frame(module:, function:, arity:, level:, line:))
}

fn start_step_over(state: State, pid: Pid, module: String, line: Int) -> State {
  case targeted_steps(state), step_frames(state, pid, module, line) {
    True, Ok(frames) ->
      case stepping.over_targets(frames, function_lookup(state)) {
        Ok(targets) -> start_targeted(state, pid, targets)
        Error(Nil) -> start_int_step_over(state, pid, module, line)
      }
    _, _ -> start_int_step_over(state, pid, module, line)
  }
}

fn start_step_out(state: State, pid: Pid, module: String, line: Int) -> State {
  case targeted_steps(state), step_frames(state, pid, module, line) {
    True, Ok(frames) ->
      start_targeted(
        state,
        pid,
        stepping.out_targets(frames, function_lookup(state)),
      )
    _, _ -> {
      int_finish(pid)
      State(..state, stepping: dict.insert(state.stepping, pid, SimpleStep))
    }
  }
}

/// Steps run on temporary breakpoints when the interpreter keeps a call
/// stack: their conditions need the call level.
fn targeted_steps(state: State) -> Bool {
  case state.config {
    Some(config) -> config.stack_trace_mode != "false"
    None -> False
  }
}

fn step_frames(
  state: State,
  pid: Pid,
  module: String,
  line: Int,
) -> Result(List(stepping.StackFrame), Nil) {
  use meta <- result.try(int_get_meta(pid))
  // Returning lands in the nearest callers first; deep recursion would make
  // reading the whole stack slow.
  use frames <- result.try(
    int_frames(meta, step_frame_limit) |> result.replace_error(Nil),
  )
  case frames {
    [] -> Error(Nil)
    [top, ..rest] -> {
      // The top frame's line is the one we stopped at; the others are
      // where each caller is waiting.
      let top = stepping.StackFrame(level: top.0, module:, line:)
      let rest =
        list.filter_map(rest, fn(f) {
          case set.contains(state.interpreted, f.1) && f.4 > 0 {
            True -> Ok(stepping.StackFrame(level: f.0, module: f.1, line: f.4))
            False -> Error(Nil)
          }
        })
      Ok([top, ..rest])
    }
  }
}

const step_frame_limit = 50

@external(erlang, "gleam_dap_int_ffi", "frames")
fn int_frames(
  meta: Pid,
  limit: Int,
) -> Result(List(#(Int, String, String, Int, Int)), String)

fn function_lookup(
  state: State,
) -> fn(String, Int) -> Result(project.FunctionInfo, Nil) {
  fn(module, line) {
    use index <- result.try(option.to_result(state.index, Nil))
    use info <- result.try(project.get_module(index, module))
    project.function_at(info, line)
  }
}

fn start_targeted(
  state: State,
  pid: Pid,
  targets: List(stepping.Target),
) -> State {
  let state =
    State(
      ..state,
      step_targets: dict.insert(state.step_targets, pid, targets),
      stepping: dict.insert(state.stepping, pid, Targeted),
    )
    |> sync_breaks
  int_continue(pid)
  state
}

/// Forgets a process's step, removing its temporary breakpoints.
fn end_stepping(state: State, pid: Pid) -> State {
  let state = State(..state, stepping: dict.delete(state.stepping, pid))
  case dict.has_key(state.step_targets, pid) {
    True ->
      State(..state, step_targets: dict.delete(state.step_targets, pid))
      |> sync_breaks
    False -> state
  }
}

/// Step over with `int`'s own commands, corrected for tail calls and `use`.
fn start_int_step_over(
  state: State,
  pid: Pid,
  module: String,
  line: Int,
) -> State {
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
    use id <- decode.optional_field(
      "requestId",
      None,
      decode.optional(decode.int),
    )
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
  case state.mode, state.config {
    Attach, Some(config) -> stop_node(config.node)
    _, _ -> Nil
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

@external(erlang, "gleam_dap_session_ffi", "stop_node")
fn stop_node(node: String) -> Nil

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
  let state = end_stepping(state, pid)
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
    _ if module == debug_module -> {
      // Stopped inside `debug.break()`: run on to the caller.
      let _ = take_step_stop(pid)
      let state = end_stepping(state, pid)
      int_finish(pid)
      State(..state, stepping: dict.insert(state.stepping, pid, DebugBreak))
    }
    Ok(Targeted) -> {
      let on_target = take_step_stop(pid)
      let paused = set.contains(state.pausing, pid)
      let reason = case paused, on_target, at_breakpoint {
        True, _, _ -> "pause"
        False, False, _ -> "breakpoint"
        // Both a step target and a breakpoint of the user's: a plain
        // breakpoint would have stopped anyway.
        False, True, True ->
          case has_plain_breakpoint(state, module, line) {
            True -> "breakpoint"
            False -> "step"
          }
        False, True, False -> "step"
      }
      report_stop(
        State(
          ..end_stepping(state, pid),
          pausing: set.delete(state.pausing, pid),
        ),
        pid,
        thread_id,
        module,
        line,
        reason,
      )
    }
    Ok(DebugBreak) ->
      report_stop(
        State(..state, stepping: dict.delete(state.stepping, pid)),
        pid,
        thread_id,
        module,
        line,
        "breakpoint",
      )
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
      let reason = case
        set.contains(state.pausing, pid),
        at_entry,
        at_breakpoint
      {
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
  State(
    ..state,
    stopped: dict.insert(state.stopped, pid, StoppedAt(module, line)),
  )
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
  let state = end_stepping(state, pid)
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
          send_event(
            protocol.stopped_event(
              "exception",
              thread_id,
              Some(description),
              Some(description),
              [],
            ),
          )
          State(
            ..state,
            stopped: dict.insert(
              state.stopped,
              pid,
              CrashStop(reason, meta, holder),
            ),
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
            "The program crashed: "
              <> inspect.describe_crash(ctx, reason)
              <> "\n",
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

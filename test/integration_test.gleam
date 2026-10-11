//// End-to-end tests: a real adapter debugging the fixture project.

import dap_client.{
  breakpoints, finish, get, launch, request, scope_variables, source, thread_arg,
  top, values, wait_event, wait_stop,
}
import gleam/dynamic
import gleam/dynamic/decode
import gleam/list
import gleam/string
import gleam_dap/json.{JArray, JBool, JInt, JObject, JString}

pub fn breakpoints_and_step_over_test() {
  let client = launch([])
  let response =
    request(client, "setBreakpoints", [
      #("source", source("sample.gleam")),
      #("breakpoints", breakpoints([9])),
    ])
  assert get(
      response,
      ["body", "breakpoints"],
      decode.list(decode.at(["verified"], decode.bool)),
    )
    == [True]
  let _ = request(client, "configurationDone", [])

  let #(thread, reason, frames) = wait_stop(client)
  assert reason == "breakpoint"
  assert top(frames) == #("sample.main", 9)
  let assert [frame, ..] = frames
  assert values(scope_variables(client, frame.id, "Locals")) == [#("x", "1")]

  let _ = request(client, "next", thread_arg(thread))
  let #(_, reason, frames) = wait_stop(client)
  assert reason == "step"
  assert top(frames) == #("sample.main", 10)
  let assert [frame, ..] = frames
  // Shadowed variables show their latest value; the raw scope has both.
  assert values(scope_variables(client, frame.id, "Locals")) == [#("x", "2")]
  assert values(scope_variables(client, frame.id, "Raw bindings"))
    == [#("X", "1"), #("X@1", "2")]

  let _ = request(client, "continue", thread_arg(thread))
  let _ = wait_event(client, "terminated")
  finish(client)
}

pub fn step_over_use_test() {
  let client = launch([])
  let _ =
    request(client, "setBreakpoints", [
      #("source", source("sample/flow.gleam")),
      #("breakpoints", breakpoints([24])),
    ])
  let _ = request(client, "configurationDone", [])
  let #(thread, _, frames) = wait_stop(client)
  assert top(frames) == #("sample/flow.with_use", 24)

  // Stepping over a `use` line goes into its callback, which is the rest of
  // the function, instead of skipping it.
  let lines =
    list.map([1, 2, 3], fn(_) {
      let _ = request(client, "next", thread_arg(thread))
      let #(_, _, frames) = wait_stop(client)
      top(frames)
    })
  assert lines
    == [
      #("anonymous function in sample/flow.with_use", 25),
      #("anonymous function in sample/flow.with_use", 26),
      #("sample.main", 18),
    ]
  finish(client)
}

pub fn step_over_use_without_tail_frames_test() {
  let client = launch([#("stackTraceMode", JString("no_tail"))])
  let _ =
    request(client, "setBreakpoints", [
      #("source", source("sample/flow.gleam")),
      #("breakpoints", breakpoints([24])),
    ])
  let _ = request(client, "configurationDone", [])
  let #(thread, _, _) = wait_stop(client)
  let lines =
    list.map([1, 2, 3], fn(_) {
      let _ = request(client, "next", thread_arg(thread))
      let #(_, _, frames) = wait_stop(client)
      top(frames).1
    })
  assert lines == [25, 26, 18]
  finish(client)
}

pub fn step_in_and_out_test() {
  let client = launch([])
  let _ =
    request(client, "setBreakpoints", [
      #("source", source("sample.gleam")),
      #("breakpoints", breakpoints([10])),
    ])
  let _ = request(client, "configurationDone", [])
  let #(thread, _, _) = wait_stop(client)
  let _ = request(client, "stepIn", thread_arg(thread))
  let #(_, _, frames) = wait_stop(client)
  assert top(frames) == #("sample.greet", 26)
  assert list.map(frames, fn(f) { #(f.name, f.line) })
    == [#("sample.greet", 26), #("sample.main", 10)]
  let _ = request(client, "stepOut", thread_arg(thread))
  let #(_, _, frames) = wait_stop(client)
  assert top(frames) == #("sample.main", 11)
  finish(client)
}

pub fn step_over_stops_at_breakpoints_inside_test() {
  step_over_stops_at_breakpoints_inside([])
}

pub fn step_over_stops_at_breakpoints_inside_without_tail_frames_test() {
  step_over_stops_at_breakpoints_inside([
    #("stackTraceMode", JString("no_tail")),
  ])
}

fn step_over_stops_at_breakpoints_inside(options) {
  let client = launch(options)
  let _ =
    request(client, "setBreakpoints", [
      #("source", source("sample.gleam")),
      #("breakpoints", breakpoints([10, 27])),
    ])
  let _ = request(client, "configurationDone", [])
  let #(thread, _, frames) = wait_stop(client)
  assert top(frames) == #("sample.main", 10)
  // Stepping over `greet("Ada")` stops at the breakpoint inside it.
  let _ = request(client, "next", thread_arg(thread))
  let #(_, reason, frames) = wait_stop(client)
  assert reason == "breakpoint"
  assert top(frames) == #("sample.greet", 27)
  // Stepping over the last line of `greet` returns to the caller.
  let _ = request(client, "next", thread_arg(thread))
  let #(_, reason, frames) = wait_stop(client)
  assert reason == "step"
  assert top(frames) == #("sample.main", 11)
  finish(client)
}

pub fn step_out_stops_at_breakpoints_on_the_way_test() {
  let client = launch([])
  let _ =
    request(client, "setBreakpoints", [
      #("source", source("sample/flow.gleam")),
      #("breakpoints", breakpoints([7, 11])),
    ])
  let _ = request(client, "configurationDone", [])
  let #(thread, _, frames) = wait_stop(client)
  assert top(frames) == #("sample/flow.pipes", 11)
  // The rest of `pipes` calls `double`, which has a breakpoint.
  let _ = request(client, "stepOut", thread_arg(thread))
  let #(_, reason, frames) = wait_stop(client)
  assert reason == "breakpoint"
  assert top(frames) == #("sample/flow.double", 7)
  // Without breakpoints in the way, step out returns to the caller.
  let _ =
    request(client, "setBreakpoints", [
      #("source", source("sample/flow.gleam")),
      #("breakpoints", breakpoints([])),
    ])
  let _ = request(client, "stepOut", thread_arg(thread))
  let #(_, reason, frames) = wait_stop(client)
  assert reason == "step"
  assert top(frames) == #("sample/flow.pipes", 13)
  finish(client)
}

pub fn breakpoint_validation_test() {
  let client = launch([])
  let response =
    request(client, "setBreakpoints", [
      #("source", source("sample.gleam")),
      #("breakpoints", breakpoints([1, 7, 25])),
    ])
  let results =
    get(
      response,
      ["body", "breakpoints"],
      decode.list({
        use verified <- decode.field("verified", decode.bool)
        use line <- decode.field("line", decode.int)
        decode.success(#(verified, line))
      }),
    )
  // An import has no code; a function head moves to its first line.
  assert results == [#(False, 1), #(True, 8), #(True, 26)]

  let response =
    request(client, "breakpointLocations", [
      #("source", source("sample.gleam")),
      #("line", JInt(24)),
      #("endLine", JInt(28)),
    ])
  assert get(
      response,
      ["body", "breakpoints"],
      decode.list(decode.at(["line"], decode.int)),
    )
    == [26, 27]
  finish(client)
}

pub fn values_look_like_gleam_test() {
  let client = launch([])
  let _ =
    request(client, "setBreakpoints", [
      #("source", source("sample.gleam")),
      #("breakpoints", breakpoints([16])),
    ])
  let _ = request(client, "configurationDone", [])
  let #(_, _, frames) = wait_stop(client)
  let assert [frame, ..] = frames
  let locals = scope_variables(client, frame.id, "Locals")
  assert values(locals)
    == [
      #("area", "15.0"),
      #("greeting", "\"Hello, Ada!\""),
      #("older", "Person(name: \"Ada\", age: 37)"),
      #("person", "Person(name: \"Ada\", age: 36)"),
      #("x", "2"),
    ]
  let assert Ok(person) = list.find(locals, fn(v) { v.name == "person" })
  assert values(dap_client.variables(client, person.reference))
    == [#("name", "\"Ada\""), #("age", "36")]

  let response =
    request(client, "evaluate", [
      #("expression", JString("person.age + x")),
      #("frameId", JInt(frame.id)),
    ])
  assert get(response, ["body", "result"], decode.string) == "38"
  finish(client)
}

pub fn large_values_are_paged_test() {
  let client = launch([#("function", JString("big_main"))])
  let _ =
    request(client, "setBreakpoints", [
      #("source", source("sample.gleam")),
      #("breakpoints", breakpoints([71])),
    ])
  let _ = request(client, "configurationDone", [])
  let #(_, _, frames) = wait_stop(client)
  let assert [frame, ..] = frames
  let response =
    request(client, "evaluate", [
      #("expression", JString("numbers")),
      #("frameId", JInt(frame.id)),
    ])
  assert get(response, ["body", "indexedVariables"], decode.int) == 250
  let reference = get(response, ["body", "variablesReference"], decode.int)

  // Clients that page (VS Code) ask for parts.
  assert dap_client.variables_with(client, reference, [
      #("filter", JString("indexed")),
      #("start", JInt(120)),
      #("count", JInt(3)),
    ])
    |> values
    == [#("120", "120"), #("121", "121"), #("122", "122")]
  assert dap_client.variables_with(client, reference, [
      #("filter", JString("named")),
    ])
    == []

  // Clients that don't (LSP4IJ) get groups to expand.
  let groups = dap_client.variables(client, reference)
  assert list.map(groups, fn(v) { v.name })
    == ["[0..99]", "[100..199]", "[200..249]"]
  let assert [_, _, last] = groups
  let items = dap_client.variables(client, last.reference)
  assert list.length(items) == 50
  assert list.first(values(items)) == Ok(#("200", "200"))
  assert list.last(values(items)) == Ok(#("249", "249"))
  // Paging inside a group counts from the group's start.
  assert dap_client.variables_with(client, last.reference, [
      #("start", JInt(10)),
      #("count", JInt(2)),
    ])
    |> values
    == [#("210", "210"), #("211", "211")]
  finish(client)
}

pub fn stop_on_gleam_error_test() {
  let client = launch([#("function", JString("crash_main"))])
  let _ =
    request(client, "setExceptionBreakpoints", [
      #("filters", JArray([JString("gleam")])),
    ])
  let _ = request(client, "configurationDone", [])
  let event = wait_event(client, "stopped")
  assert get(event, ["body", "reason"], decode.string) == "exception"
  let thread = get(event, ["body", "threadId"], decode.int)
  let description = get(event, ["body", "description"], decode.string)
  assert string.starts_with(description, "let assert:")

  let frames = dap_client.frames(client, thread)
  assert top(frames) == #("sample.crash_main", 33)
  let assert [frame, ..] = frames
  assert values(scope_variables(client, frame.id, "Locals"))
    == [#("value", "Error(\"negative\")")]

  let info = request(client, "exceptionInfo", thread_arg(thread))
  assert get(info, ["body", "exceptionId"], decode.string) == "let_assert"

  let _ = request(client, "continue", thread_arg(thread))
  let exited = wait_event(client, "exited")
  assert get(exited, ["body", "exitCode"], decode.int) == 1
  finish(client)
}

pub fn crash_without_stopping_test() {
  let client = launch([#("function", JString("panic_main"))])
  let _ = request(client, "setExceptionBreakpoints", [#("filters", JArray([]))])
  let _ = request(client, "configurationDone", [])
  let exited = wait_event(client, "exited")
  assert get(exited, ["body", "exitCode"], decode.int) == 1
  finish(client)
}

pub fn processes_are_threads_test() {
  let client = launch([])
  let _ =
    request(client, "setBreakpoints", [
      #("source", source("sample/flow.gleam")),
      #("breakpoints", breakpoints([70])),
    ])
  let _ = request(client, "configurationDone", [])
  let #(thread, _, frames) = wait_stop(client)
  assert top(frames) == #("sample/flow.worker", 70)
  let response = request(client, "threads", [])
  let ids =
    get(
      response,
      ["body", "threads"],
      decode.list(decode.at(["id"], decode.int)),
    )
  assert list.contains(ids, thread)
  finish(client)
}

pub fn conditions_and_logpoints_test() {
  let client = launch([])
  let _ =
    request(client, "setBreakpoints", [
      #("source", source("sample/flow.gleam")),
      #(
        "breakpoints",
        JArray([
          JObject([#("line", JInt(56)), #("condition", JString("first == 2"))]),
          JObject([
            #("line", JInt(43)),
            #("logMessage", JString("label={label} items={items}")),
          ]),
        ]),
      ),
    ])
  let _ = request(client, "configurationDone", [])
  let #(thread, _, frames) = wait_stop(client)
  assert top(frames) == #("sample/flow.map", 56)
  let assert [frame, ..] = frames
  let locals = values(scope_variables(client, frame.id, "Locals"))
  assert list.contains(locals, #("first", "2"))

  let _ = request(client, "continue", thread_arg(thread))
  let log = wait_until_output(client, "label=")
  assert log == "label=\"big\" items=[90, 180, 270]\n"
  let _ = wait_event(client, "terminated")
  finish(client)
}

fn wait_until_output(client, prefix: String) -> String {
  let event = wait_event(client, "output")
  let text = get(event, ["body", "output"], decode.string)
  case string.starts_with(text, prefix) {
    True -> text
    False -> wait_until_output(client, prefix)
  }
}

pub fn function_breakpoints_test() {
  let client = launch([])
  let response =
    request(client, "setFunctionBreakpoints", [
      #(
        "breakpoints",
        JArray([
          JObject([#("name", JString("sample/shapes.describe"))]),
          JObject([#("name", JString("sample/nothing.here"))]),
        ]),
      ),
    ])
  assert get(
      response,
      ["body", "breakpoints"],
      decode.list(decode.at(["verified"], decode.bool)),
    )
    == [True, False]
  let _ = request(client, "configurationDone", [])
  let #(_, _, frames) = wait_stop(client)
  assert top(frames) == #("sample/shapes.describe", 28)
  finish(client)
}

pub fn pause_and_terminate_test() {
  let client =
    launch([#("function", JString("loop_main")), #("stopOnEntry", JBool(True))])
  let _ = request(client, "configurationDone", [])
  let #(thread, reason, frames) = wait_stop(client)
  assert reason == "entry"
  assert top(frames) == #("sample.loop_main", 43)
  let _ = request(client, "continue", thread_arg(thread))
  let response = request(client, "pause", thread_arg(thread))
  assert dap_client.success(response)
  let #(_, reason, frames) = wait_stop(client)
  assert reason == "pause"
  assert { top(frames) }.0 == "sample.count_down"
  let _ = request(client, "terminate", [])
  let _ = wait_event(client, "terminated")
  finish(client)
}

pub fn evaluate_errors_test() {
  let client = launch([])
  let _ =
    request(client, "setBreakpoints", [
      #("source", source("sample.gleam")),
      #("breakpoints", breakpoints([9])),
    ])
  let _ = request(client, "configurationDone", [])
  let #(_, _, frames) = wait_stop(client)
  let assert [frame, ..] = frames
  let response =
    request(client, "evaluate", [
      #("expression", JString("nope + 1")),
      #("frameId", JInt(frame.id)),
    ])
  assert !dap_client.success(response)
  assert get(response, ["message"], decode.string) == "Unknown variable nope"

  let response =
    request(client, "completions", [
      #("text", JString("sample/flow.cl")),
      #("column", JInt(15)),
      #("frameId", JInt(frame.id)),
    ])
  assert get(
      response,
      ["body", "targets"],
      decode.list(decode.at(["label"], decode.string)),
    )
    == ["classify"]
  finish(client)
}

@external(erlang, "test_ffi", "get_env")
fn get_env(name: String) -> Result(String, Nil)

pub fn program_with_dependencies_test() {
  let client =
    dap_client.launch_project(
      dap_client.project_root() <> "/fixtures/with_deps",
      [#("interpretModules", JArray([JString("gleam/list")]))],
    )
  let _ =
    request(client, "setBreakpoints", [
      #(
        "source",
        JObject([
          #(
            "path",
            JString(
              dap_client.project_root()
              <> "/fixtures/with_deps/src/with_deps.gleam",
            ),
          ),
        ]),
      ),
      #("breakpoints", breakpoints([12])),
    ])
  let response =
    request(client, "setFunctionBreakpoints", [
      #(
        "breakpoints",
        JArray([JObject([#("name", JString("gleam/list.map"))])]),
      ),
    ])
  let verified =
    get(
      response,
      ["body", "breakpoints"],
      decode.list(decode.at(["verified"], decode.bool)),
    )
  // The packaged adapter renames its own gleam_stdlib, so the program's copy
  // can be interpreted. Run from the source tree the adapter shares it, and
  // it must refuse rather than deadlock.
  let packaged = get_env("GLEAM_DAP_COMMAND") |> result_is_ok
  assert verified == [packaged]
  let _ = request(client, "configurationDone", [])

  let thread = case packaged {
    True -> {
      let #(thread, _, frames) = wait_stop(client)
      assert top(frames) == #("gleam/list.map", 352)
      let _ = request(client, "continue", thread_arg(thread))
      thread
    }
    False -> 0
  }
  let #(stopped_thread, _, frames) = wait_stop(client)
  let _ = thread
  assert top(frames) == #("with_deps.main", 12)
  let assert [frame, ..] = frames
  assert values(scope_variables(client, frame.id, "Locals"))
    == [
      #("counts", "dict.from_list([#(\"a\", 1), #(\"b\", 2)])"),
      #("doubled", "[2, 4, 6]"),
      #("maybe", "Some(3)"),
      #("numbers", "[1, 2, 3]"),
    ]
  let _ = request(client, "continue", thread_arg(stopped_thread))
  let _ = wait_event(client, "terminated")
  finish(client)
}

fn result_is_ok(r: Result(a, b)) -> Bool {
  case r {
    Ok(_) -> True
    Error(_) -> False
  }
}

pub fn debug_break_test() {
  let client = launch([#("module", JString("sample/debugging"))])
  let _ = request(client, "configurationDone", [])
  let #(thread, reason, frames) = wait_stop(client)
  assert reason == "breakpoint"
  // The stop is reported on the line after the call, in the caller.
  assert top(frames) == #("sample/debugging.main", 9)
  let _ = request(client, "continue", thread_arg(thread))
  let _ = wait_event(client, "terminated")
  finish(client)
}

@external(erlang, "test_ffi", "start_target")
fn start_target(cookie: String) -> String

@external(erlang, "test_ffi", "stop_target")
fn stop_target(node: String, cookie: String) -> dynamic.Dynamic

@external(erlang, "test_ffi", "target_down")
fn target_down(node: String, cookie: String) -> Bool

pub fn attach_test() {
  attach_with("attach")
}

/// IntelliJ attaches through a `launch` that names the node.
pub fn attach_through_launch_test() {
  attach_with("launch")
}

fn attach_with(command: String) {
  let cookie = "gleam_dap_test"
  let node = start_target(cookie)
  let client = dap_client.start_and_initialize()
  let response =
    request(client, command, [
      #("projectDir", JString(dap_client.fixture())),
      #("node", JString(node)),
      #("cookie", JString(cookie)),
    ])
  assert dap_client.success(response)
  let _ = wait_event(client, "initialized")
  let _ =
    request(client, "setBreakpoints", [
      #("source", source("sample/flow.gleam")),
      #("breakpoints", breakpoints([7])),
    ])
  let _ = request(client, "configurationDone", [])
  let #(_, reason, frames) = wait_stop(client)
  assert reason == "breakpoint"
  assert top(frames) == #("sample/flow.double", 7)
  let _ = request(client, "disconnect", [#("terminateDebuggee", JBool(False))])
  dap_client.stop(client)
  // Detaching leaves nothing interpreted on the node.
  assert stop_target(node, cookie) == dynamic.list([])
}

@external(erlang, "test_ffi", "run_on_target")
fn run_on_target(node: String, cookie: String) -> Nil

/// Conditions, logpoints and stepping over calls with breakpoints inside
/// work on an attached node too.
pub fn attach_conditions_and_stepping_test() {
  let cookie = "gleam_dap_test"
  let node = start_target(cookie)
  let client = dap_client.start_and_initialize()
  let response =
    request(client, "attach", [
      #("projectDir", JString(dap_client.fixture())),
      #("node", JString(node)),
      #("cookie", JString(cookie)),
    ])
  assert dap_client.success(response)
  let _ = wait_event(client, "initialized")
  let _ =
    request(client, "setBreakpoints", [
      #("source", source("sample.gleam")),
      #(
        "breakpoints",
        JArray([
          JObject([#("line", JInt(10))]),
          JObject([
            #("line", JInt(26)),
            #("logMessage", JString("greeting {name}")),
          ]),
          JObject([
            #("line", JInt(27)),
            #("condition", JString("name == \"Ada\"")),
          ]),
        ]),
      ),
    ])
  let _ = request(client, "configurationDone", [])
  run_on_target(node, cookie)
  let #(thread, _, frames) = wait_stop(client)
  assert top(frames) == #("sample.main", 10)
  let _ = request(client, "next", thread_arg(thread))
  // The logpoint on the way logs before the step stops.
  assert wait_until_output(client, "greeting") == "greeting \"Ada\"\n"
  let #(_, reason, frames) = wait_stop(client)
  assert reason == "breakpoint"
  assert top(frames) == #("sample.greet", 27)
  let _ = request(client, "next", thread_arg(thread))
  let #(_, reason, frames) = wait_stop(client)
  assert reason == "step"
  assert top(frames) == #("sample.main", 11)
  let _ = request(client, "disconnect", [#("terminateDebuggee", JBool(False))])
  dap_client.stop(client)
  assert stop_target(node, cookie) == dynamic.list([])
}

pub fn terminate_attached_node_test() {
  let cookie = "gleam_dap_test"
  let node = start_target(cookie)
  let client = dap_client.start_and_initialize()
  let response =
    request(client, "attach", [
      #("projectDir", JString(dap_client.fixture())),
      #("node", JString(node)),
      #("cookie", JString(cookie)),
    ])
  assert dap_client.success(response)
  let _ = wait_event(client, "initialized")
  let _ = request(client, "configurationDone", [])
  let _ = request(client, "terminate", [])
  let _ = wait_event(client, "terminated")
  let _ = request(client, "disconnect", [])
  dap_client.stop(client)
  assert target_down(node, cookie)
}

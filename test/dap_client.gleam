//// Helpers for the integration tests: a DAP client talking to a real
//// adapter process, and decoders for the parts of responses we check.

import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/list
import gleam/string
import gleam_dap/json.{type Json, JObject, JString}

pub type Client

@external(erlang, "dap_client_ffi", "start")
fn start_client() -> Client

@external(erlang, "dap_client_ffi", "request")
fn raw_request(
  client: Client,
  command: String,
  args: String,
) -> Result(Dynamic, String)

@external(erlang, "dap_client_ffi", "wait_event")
fn raw_wait_event(
  client: Client,
  name: String,
  timeout: Int,
) -> Result(Dynamic, String)

@external(erlang, "dap_client_ffi", "stop")
pub fn stop(client: Client) -> Nil

@external(erlang, "dap_client_ffi", "project_root")
pub fn project_root() -> String

pub fn fixture() -> String {
  project_root() <> "/fixtures/sample"
}

pub fn source(file: String) -> Json {
  JObject([#("path", JString(fixture() <> "/src/" <> file))])
}

/// Starts an adapter, initializes it and launches the fixture with the
/// given extra launch options.
pub fn launch(options: List(#(String, Json))) -> Client {
  let client = start_client()
  let _ = request(client, "initialize", [#("adapterID", JString("gleam"))])
  let response =
    request(client, "launch", [#("projectDir", JString(fixture())), ..options])
  let assert True = success(response)
  let _ = wait_event(client, "initialized")
  client
}

pub fn request(
  client: Client,
  command: String,
  args: List(#(String, Json)),
) -> Dynamic {
  let assert Ok(response) =
    raw_request(client, command, json.to_string(JObject(args)))
  response
}

pub fn wait_event(client: Client, name: String) -> Dynamic {
  let assert Ok(event) = raw_wait_event(client, name, 30_000)
  event
}

pub fn success(response: Dynamic) -> Bool {
  let assert Ok(ok) = decode.run(response, decode.at(["success"], decode.bool))
  ok
}

pub fn get(value: Dynamic, path: List(String), decoder: decode.Decoder(a)) -> a {
  case decode.run(value, decode.at(path, decoder)) {
    Ok(result) -> result
    Error(errors) ->
      panic as {
        "could not decode "
        <> string.join(path, ".")
        <> ": "
        <> string.inspect(errors)
        <> " in "
        <> string.inspect(value)
      }
  }
}

pub type Frame {
  Frame(id: Int, name: String, line: Int)
}

/// Waits for a stop and returns its thread id, reason and stack frames.
pub fn wait_stop(client: Client) -> #(Int, String, List(Frame)) {
  let event = wait_event(client, "stopped")
  let thread = get(event, ["body", "threadId"], decode.int)
  let reason = get(event, ["body", "reason"], decode.string)
  #(thread, reason, frames(client, thread))
}

pub fn frames(client: Client, thread: Int) -> List(Frame) {
  let response =
    request(client, "stackTrace", [#("threadId", json.JInt(thread))])
  get(
    response,
    ["body", "stackFrames"],
    decode.list({
      use id <- decode.field("id", decode.int)
      use name <- decode.field("name", decode.string)
      use line <- decode.field("line", decode.int)
      decode.success(Frame(id:, name:, line:))
    }),
  )
}

pub fn top(frames: List(Frame)) -> #(String, Int) {
  let assert [first, ..] = frames
  #(first.name, first.line)
}

pub type Variable {
  Variable(name: String, value: String, reference: Int)
}

/// The variables of a scope ("Locals" or "Raw bindings") of a frame.
pub fn scope_variables(
  client: Client,
  frame: Int,
  scope: String,
) -> List(Variable) {
  let response = request(client, "scopes", [#("frameId", json.JInt(frame))])
  let scopes =
    get(
      response,
      ["body", "scopes"],
      decode.list({
        use name <- decode.field("name", decode.string)
        use reference <- decode.field("variablesReference", decode.int)
        decode.success(#(name, reference))
      }),
    )
  let assert Ok(#(_, reference)) = list.find(scopes, fn(s) { s.0 == scope })
  variables(client, reference)
}

pub fn variables(client: Client, reference: Int) -> List(Variable) {
  let response =
    request(client, "variables", [#("variablesReference", json.JInt(reference))])
  get(
    response,
    ["body", "variables"],
    decode.list({
      use name <- decode.field("name", decode.string)
      use value <- decode.field("value", decode.string)
      use reference <- decode.field("variablesReference", decode.int)
      decode.success(Variable(name:, value:, reference:))
    }),
  )
}

pub fn values(variables: List(Variable)) -> List(#(String, String)) {
  list.map(variables, fn(v) { #(v.name, v.value) })
}

pub fn thread_arg(thread: Int) -> List(#(String, Json)) {
  [#("threadId", json.JInt(thread))]
}

pub fn breakpoints(lines: List(Int)) -> Json {
  json.JArray(
    list.map(lines, fn(line) { JObject([#("line", json.JInt(line))]) }),
  )
}

/// Ends the session the way an editor does.
pub fn finish(client: Client) -> Nil {
  let _ = request(client, "disconnect", [])
  stop(client)
}

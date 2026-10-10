//// Requests, responses and events of the Debug Adapter Protocol, as far as
//// gleam-dap uses them.

import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam_dap/dap/framing
import gleam_dap/json.{type Json, JBool, JInt, JNull, JObject, JString}

pub type Request {
  Request(seq: Int, command: String, arguments: Dynamic)
}

pub fn decode_request(message: Dynamic) -> Result(Request, Nil) {
  let decoder = {
    use seq <- decode.field("seq", decode.int)
    use kind <- decode.field("type", decode.string)
    use command <- decode.optional_field("command", "", decode.string)
    use arguments <- decode.optional_field(
      "arguments",
      empty_object(),
      decode.dynamic,
    )
    case kind {
      "request" -> decode.success(Request(seq:, command:, arguments:))
      _ -> decode.failure(Request(seq:, command:, arguments:), "request")
    }
  }
  decode.run(message, decoder)
  |> option.from_result
  |> option.to_result(Nil)
}

@external(erlang, "maps", "new")
fn empty_object() -> Dynamic

/// The JSON for a successful response.
pub fn response(request: Request, body: Option(Json)) -> Json {
  json.object([
    #("seq", Some(JInt(0))),
    #("type", json.string("response")),
    #("request_seq", json.int(request.seq)),
    #("success", json.bool(True)),
    #("command", json.string(request.command)),
    #("body", body),
  ])
}

/// The JSON for a failed response. `message` is shown to the user.
pub fn error_response(request: Request, message: String) -> Json {
  json.object([
    #("seq", Some(JInt(0))),
    #("type", json.string("response")),
    #("request_seq", json.int(request.seq)),
    #("success", json.bool(False)),
    #("command", json.string(request.command)),
    #("message", json.string(message)),
    #(
      "body",
      Some(
        JObject([
          #(
            "error",
            JObject([
              #("id", JInt(1)),
              #("format", JString(message)),
              #("showUser", JBool(True)),
            ]),
          ),
        ]),
      ),
    ),
  ])
}

pub fn event(name: String, body: Option(Json)) -> Json {
  json.object([
    #("seq", Some(JInt(0))),
    #("type", json.string("event")),
    #("event", json.string(name)),
    #("body", body),
  ])
}

/// Replaces the placeholder `seq` with the next sequence number and sends
/// the message. Safe to call from any process.
pub fn send(message: Json) -> Nil {
  let message = case message {
    JObject(fields) ->
      JObject([
        #("seq", JInt(next_seq())),
        ..remove_field(fields, "seq")
      ])
    other -> other
  }
  write(framing.encode(json.to_string(message)))
}

fn remove_field(
  fields: List(#(String, Json)),
  name: String,
) -> List(#(String, Json)) {
  case fields {
    [] -> []
    [#(key, _), ..rest] if key == name -> rest
    [field, ..rest] -> [field, ..remove_field(rest, name)]
  }
}

@external(erlang, "gleam_dap_ffi", "next_seq")
fn next_seq() -> Int

@external(erlang, "gleam_dap_ffi", "write")
fn write(bytes: BitArray) -> Nil

// --- Events -----------------------------------------------------------------

pub fn output_event(category: String, text: String) -> Json {
  event(
    "output",
    Some(
      JObject([#("category", JString(category)), #("output", JString(text))]),
    ),
  )
}

pub fn stopped_event(
  reason: String,
  thread_id: Int,
  description: Option(String),
  text: Option(String),
  hit_breakpoints: List(Int),
) -> Json {
  event(
    "stopped",
    Some(
      json.object([
        #("reason", json.string(reason)),
        #("threadId", json.int(thread_id)),
        #("description", json.optional_string(description)),
        #("text", json.optional_string(text)),
        #("allThreadsStopped", json.bool(False)),
        #("preserveFocusHint", json.bool(False)),
        #("hitBreakpointIds", case hit_breakpoints {
          [] -> None
          ids -> json.array(list.map(ids, JInt))
        }),
      ]),
    ),
  )
}

pub fn continued_event(thread_id: Int, all: Bool) -> Json {
  event(
    "continued",
    Some(
      JObject([
        #("threadId", JInt(thread_id)),
        #("allThreadsContinued", JBool(all)),
      ]),
    ),
  )
}

pub fn thread_event(reason: String, thread_id: Int) -> Json {
  event(
    "thread",
    Some(JObject([#("reason", JString(reason)), #("threadId", JInt(thread_id))])),
  )
}

pub fn exited_event(code: Int) -> Json {
  event("exited", Some(JObject([#("exitCode", JInt(code))])))
}

pub fn terminated_event() -> Json {
  event("terminated", None)
}

pub fn null() -> Json {
  JNull
}

//// Answers to the requests that read a stopped process: stack traces,
//// scopes, variables, evaluate and completions. These run in worker
//// processes, outside the session, because reading from `int` can block.

import gleam/dict
import gleam/dynamic.{type Dynamic}
import gleam/erlang/process.{type Pid}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import gleam_dap/json.{type Json, JArray, JInt, JObject, JString}
import gleam_dap/names
import gleam_dap/project.{type Index}
import gleam_dap/value

/// Why a process is stopped, as far as reading it is concerned.
pub type Stopped {
  AtLine(module: String, line: Int)
  Crashed(reason: Dynamic, meta: Pid)
}

pub type FrameData {
  FrameData(
    meta: Option(Pid),
    /// `int` stack level, or 0 for the innermost frame.
    level: Int,
    module: String,
    function: String,
    line: Int,
  )
}

pub type ScopeKind {
  Locals
  Raw
}

/// What a DAP frame id or variables reference points at. Element 2 of
/// every variant is the process, so entries can be dropped when it resumes.
pub type Ref {
  FrameRef(pid: Pid, frame: FrameData)
  ScopeRef(pid: Pid, frame: FrameData, kind: ScopeKind)
  ValueRef(pid: Pid, value: Dynamic)
}

@external(erlang, "gleam_dap_ffi", "refs_put")
fn refs_put(ref: Ref) -> Int

@external(erlang, "gleam_dap_ffi", "refs_get")
pub fn refs_get(id: Int) -> Result(Ref, Nil)

@external(erlang, "gleam_dap_int_ffi", "get_meta")
fn get_meta(pid: Pid) -> Result(Pid, Nil)

@external(erlang, "gleam_dap_int_ffi", "frames")
fn int_frames(
  meta: Pid,
  limit: Int,
) -> Result(List(#(Int, String, String, Int, Int)), String)

@external(erlang, "gleam_dap_int_ffi", "bindings")
fn int_bindings(
  meta: Pid,
  level: Int,
) -> Result(List(#(String, Dynamic)), String)

pub type GleamError {
  GleamError(
    kind: String,
    message: String,
    module: String,
    function: String,
    line: Int,
    file: String,
    /// The value that didn't match, for `let assert`.
    value: Option(Dynamic),
  )
}

/// `let_assert` → `let assert`.
pub fn error_kind_label(kind: String) -> String {
  string.replace(kind, "_", " ")
}

@external(erlang, "gleam_dap_value_ffi", "gleam_error")
pub fn gleam_error(reason: Dynamic) -> Result(GleamError, Nil)

@external(erlang, "gleam_dap_value_ffi", "crash_stacktrace")
fn crash_stacktrace(reason: Dynamic) -> List(#(String, String, Int, Int))

@external(erlang, "gleam_dap_value_ffi", "crash_reason")
pub fn crash_reason(reason: Dynamic) -> Dynamic

pub type Context {
  Context(index: Index, options: value.Options)
}

pub fn context(index: Index) -> Context {
  Context(index:, options: value.default_options(index.labels))
}

// --- Stack trace ------------------------------------------------------------

/// The frames of a stopped process, at most `limit` (0 for all).
pub fn frames(
  pid: Pid,
  stopped: Stopped,
  limit: Int,
) -> Result(List(FrameData), String) {
  case stopped {
    AtLine(module, line) -> {
      use meta <- result.try(
        get_meta(pid) |> result.replace_error("The process is not interpreted"),
      )
      use raw <- result.try(int_frames(meta, limit))
      Ok(
        list.index_map(raw, fn(frame, i) {
          let #(level, frame_module, function, _arity, frame_line) = frame
          case i {
            0 -> FrameData(Some(meta), 0, module, function, line)
            _ ->
              FrameData(Some(meta), level, frame_module, function, frame_line)
          }
        }),
      )
    }
    Crashed(reason, meta) ->
      case gleam_error(reason) {
        // The backtrace is gone after a crash, but the bindings of the
        // failing function are still there. The error says where it was.
        Ok(error) ->
          Ok([
            FrameData(
              Some(meta),
              0,
              names.gleam_to_module(error.module),
              error.function,
              error.line,
            ),
          ])
        Error(Nil) ->
          case crash_stacktrace(reason) {
            [] -> Ok([FrameData(Some(meta), 0, "", "crash", 0)])
            [top, ..rest] ->
              Ok([
                FrameData(Some(meta), 0, top.0, top.1, top.3),
                ..list.map(rest, fn(f) { FrameData(None, -1, f.0, f.1, f.3) })
              ])
          }
      }
  }
}

pub fn stack_trace_body(
  ctx: Context,
  pid: Pid,
  stopped: Stopped,
  start: Int,
  levels: Int,
) -> Result(Json, String) {
  // Tail-recursive loops can build up very deep stacks in `int`, so only
  // read as many frames as the client asks for, plus one to know whether
  // there are more.
  let limit = case levels {
    0 -> 0
    _ -> start + levels + 1
  }
  use all <- result.try(frames(pid, stopped, limit))
  let total = list.length(all)
  let shown = case levels {
    0 -> list.drop(all, start)
    _ -> all |> list.drop(start) |> list.take(levels)
  }
  let frames_json =
    list.map(shown, fn(frame) {
      let id = refs_put(FrameRef(pid, frame))
      frame_json(ctx, id, frame)
    })
  Ok(
    JObject([
      #("stackFrames", JArray(frames_json)),
      #("totalFrames", JInt(total)),
    ]),
  )
}

fn frame_json(ctx: Context, id: Int, frame: FrameData) -> Json {
  let source = case project.get_module(ctx.index, frame.module) {
    Ok(module) if module.source != "" -> Some(source_json(module.source))
    _ -> None
  }
  json.object([
    #("id", json.int(id)),
    #("name", json.string(names.frame_name(frame.module, frame.function))),
    #("line", json.int(int.max(frame.line, 0))),
    #("column", json.int(1)),
    #("source", source),
    #("presentationHint", case source {
      Some(_) -> None
      None -> json.string("subtle")
    }),
  ])
}

pub fn source_json(path: String) -> Json {
  JObject([
    #(
      "name",
      JString(path |> string.split("/") |> list.last |> result.unwrap(path)),
    ),
    #("path", JString(path)),
  ])
}

// --- Scopes and variables ---------------------------------------------------

pub fn scopes_body(frame_id: Int) -> Result(Json, String) {
  case refs_get(frame_id) {
    Ok(FrameRef(pid, frame)) -> {
      let scopes = case frame.meta {
        Some(_) -> [
          scope_json("Locals", refs_put(ScopeRef(pid, frame, Locals)), False),
          scope_json("Raw bindings", refs_put(ScopeRef(pid, frame, Raw)), True),
        ]
        None -> []
      }
      Ok(JObject([#("scopes", JArray(scopes))]))
    }
    _ -> Error("Unknown frame")
  }
}

fn scope_json(name: String, reference: Int, expensive: Bool) -> Json {
  JObject([
    #("name", JString(name)),
    #("variablesReference", JInt(reference)),
    #("expensive", json.JBool(expensive)),
    #("presentationHint", JString("locals")),
  ])
}

pub fn frame_bindings(
  frame: FrameData,
) -> Result(List(#(String, Dynamic)), String) {
  case frame.meta {
    Some(meta) -> int_bindings(meta, frame.level)
    None -> Ok([])
  }
}

pub fn variables_body(ctx: Context, reference: Int) -> Result(Json, String) {
  case refs_get(reference) {
    Ok(ScopeRef(pid, frame, kind)) -> {
      use bindings <- result.try(frame_bindings(frame))
      let shown = case kind {
        Locals -> names.latest_bindings(bindings)
        Raw ->
          list.sort(bindings, fn(a, b) { string.compare(a.0, b.0) })
          |> list.filter(fn(b) { b.0 != "_" })
      }
      Ok(
        variables_json(
          list.map(shown, fn(b) { variable_json(ctx, pid, b.0, b.1, Some(b.0)) }),
        ),
      )
    }
    Ok(ValueRef(pid, term)) ->
      Ok(variables_json(
        value.children(term, ctx.options)
        |> list.map(fn(child) {
          variable_json(ctx, pid, child.name, child.value, None)
        }),
      ))
    _ -> Error("Unknown variables reference")
  }
}

fn variables_json(variables: List(Json)) -> Json {
  JObject([#("variables", JArray(variables))])
}

pub fn variable_json(
  ctx: Context,
  pid: Pid,
  name: String,
  term: Dynamic,
  evaluate_name: Option(String),
) -> Json {
  json.object([
    #("name", json.string(name)),
    #("value", json.string(value.render(term, ctx.options))),
    #("type", json.string(value.type_name(term, ctx.options))),
    #("variablesReference", json.int(child_reference(pid, term))),
    #("evaluateName", json.optional_string(evaluate_name)),
  ])
}

pub fn child_reference(pid: Pid, term: Dynamic) -> Int {
  case value.is_expandable(term) {
    True -> refs_put(ValueRef(pid, term))
    False -> 0
  }
}

// --- Evaluate ---------------------------------------------------------------

@external(erlang, "gleam_dap_eval_ffi", "eval")
fn eval(
  source: String,
  bindings: List(#(String, Dynamic)),
) -> Result(Dynamic, String)

/// Evaluates an expression in a frame (or with no bindings if there is no
/// frame).
pub fn evaluate_body(
  ctx: Context,
  expression: String,
  frame_id: Option(Int),
) -> Result(Json, String) {
  let frame = case frame_id {
    Some(id) ->
      case refs_get(id) {
        Ok(FrameRef(pid, frame)) -> Ok(Some(#(pid, frame)))
        _ -> Error("Unknown frame")
      }
    None -> Ok(None)
  }
  use frame <- result.try(frame)
  use bindings <- result.try(case frame {
    Some(#(_, frame)) -> frame_bindings(frame)
    None -> Ok([])
  })
  use term <- result.try(eval(expression, bindings))
  let pid = case frame {
    Some(#(pid, _)) -> pid
    None -> process.self()
  }
  Ok(
    JObject([
      #("result", JString(value.render(term, ctx.options))),
      #("type", JString(value.type_name(term, ctx.options))),
      #("variablesReference", JInt(child_reference(pid, term))),
    ]),
  )
}

// --- Completions ------------------------------------------------------------

@external(erlang, "gleam_dap_launch_ffi", "module_exports")
fn module_exports(module: String) -> List(#(String, Int))

/// Completions for the debug console: variables in scope, module names and
/// a module's public functions after `module.`.
pub fn completions_body(
  ctx: Context,
  text: String,
  column: Int,
  frame_id: Option(Int),
) -> Result(Json, String) {
  let before = string.slice(text, 0, column - 1)
  let word = last_word(before)
  let items = case string.split_once(word, ".") {
    Ok(#(module_name, prefix)) -> {
      let module = resolve_module(ctx, module_name)
      module_exports(module)
      |> list.filter(fn(f) { string.starts_with(f.0, prefix) })
      |> list.map(fn(f) { completion(f.0, "function", string.length(prefix)) })
    }
    Error(Nil) -> {
      let variables = case frame_id {
        Some(id) ->
          case refs_get(id) {
            Ok(FrameRef(_, frame)) ->
              frame_bindings(frame)
              |> result.unwrap([])
              |> names.latest_bindings
              |> list.map(fn(b) { b.0 })
            _ -> []
          }
        None -> []
      }
      let modules =
        ctx.index.modules
        |> dict.keys
        |> list.map(names.module_to_gleam)
      list.append(
        list.map(variables, completion(_, "variable", string.length(word))),
        list.map(modules, completion(_, "module", string.length(word))),
      )
      |> list.filter(fn(item) { string.starts_with(item.0, word) })
    }
  }
  Ok(
    JObject([
      #(
        "targets",
        JArray(
          list.map(items, fn(item) {
            JObject([
              #("label", JString(item.0)),
              #("type", JString(item.1)),
              #("length", JInt(item.2)),
            ])
          }),
        ),
      ),
    ]),
  )
}

fn completion(
  label: String,
  kind: String,
  length: Int,
) -> #(String, String, Int) {
  #(label, kind, length)
}

fn last_word(text: String) -> String {
  text
  |> string.to_graphemes
  |> list.reverse
  |> list.take_while(fn(c) {
    c == "." || c == "_" || c == "/" || is_alphanumeric(c)
  })
  |> list.reverse
  |> string.concat
}

fn is_alphanumeric(c: String) -> Bool {
  string.contains(
    "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789",
    c,
  )
}

fn resolve_module(ctx: Context, name: String) -> String {
  let module = names.gleam_to_module(name)
  case dict.has_key(ctx.index.modules, module) {
    True -> module
    False ->
      ctx.index.modules
      |> dict.keys
      |> list.find(fn(m) { string.ends_with(m, "@" <> module) })
      |> result.unwrap(
        case dict.has_key(ctx.index.modules, "gleam@" <> module) {
          True -> "gleam@" <> module
          False -> module
        },
      )
  }
}

// --- Exception info ---------------------------------------------------------

pub fn exception_info_body(ctx: Context, reason: Dynamic) -> Json {
  case gleam_error(reason) {
    Ok(error) ->
      json.object([
        #("exceptionId", json.string(error.kind)),
        #("description", json.string(describe_crash(ctx, reason))),
        #("breakMode", json.string("unhandled")),
        #(
          "details",
          Some(
            json.object([
              #("message", json.string(error.message)),
              #("typeName", json.string(error_kind_label(error.kind))),
              #(
                "stackTrace",
                json.string(
                  error.file
                  <> ":"
                  <> int.to_string(error.line)
                  <> " in "
                  <> error.module
                  <> "."
                  <> error.function,
                ),
              ),
            ]),
          ),
        ),
      ])
    Error(Nil) -> {
      let text = value.render(crash_reason(reason), ctx.options)
      json.object([
        #("exceptionId", json.string("crash")),
        #("description", json.string(text)),
        #("breakMode", json.string("unhandled")),
      ])
    }
  }
}

/// A one-line description of a crash, for the stopped event and output.
pub fn describe_crash(ctx: Context, reason: Dynamic) -> String {
  case gleam_error(reason) {
    Ok(error) -> {
      let base = error_kind_label(error.kind) <> ": " <> error.message
      case error.value {
        Some(v) -> base <> " Value: " <> value.render(v, ctx.options)
        None -> base
      }
    }
    Error(Nil) -> value.render(crash_reason(reason), ctx.options)
  }
}

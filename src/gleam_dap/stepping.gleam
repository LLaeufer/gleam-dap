//// "Step over" and "step out" on top of `int`.
////
//// Normally these run on temporary breakpoints (see `over_targets` below),
//// so that breakpoints inside the calls being stepped over still stop. When
//// that isn't possible (attaching to a node, or no call stack), step over
//// falls back to `int`'s own commands, corrected as follows.
////
//// `int`'s `next` stops at the next expression on the same call level or
//// lower. Two things make that feel wrong in Gleam:
////
//// - The callback of a `use` (and any anonymous function defined in the
////   current function) runs on a deeper level, so `next` would skip the
////   rest of the function after a `use` line.
//// - With the `no_tail` stack trace mode, a call in tail position doesn't add
////   a level, so `next` stops inside the called function.
////
//// So when the current line defines an anonymous function we single-step
//// until we are back in the starting function, in an anonymous function
//// defined inside it, or in a caller. When `next` lands in another function
//// on the same level, that function was tail-called and we finish it.

import gleam/dict
import gleam/int
import gleam/list
import gleam/order
import gleam/result
import gleam/string
import gleam_dap/names
import gleam_dap/project.{type FunctionInfo}

pub type Frame {
  Frame(module: String, function: String, arity: Int, level: Int, line: Int)
}

pub type Command {
  Next
  Step
  Finish
}

pub type StepOver {
  StepOver(
    module: String,
    base_function: String,
    base_arity: Int,
    level: Int,
    line: Int,
    steps: Int,
    /// Single-stepping because the starting line defines an anonymous
    /// function.
    single_step: Bool,
  )
}

pub type Decision {
  Stop
  Continue(Command, StepOver)
}

/// Single steps allowed before giving up and stopping wherever we are.
pub const step_limit = 2000

/// Starts a step over from a frame. `defines_fun` says whether the current
/// line defines an anonymous function.
pub fn start(frame: Frame, defines_fun: Bool) -> #(Command, StepOver) {
  let #(base, arity) = base_of(frame)
  let state =
    StepOver(
      module: frame.module,
      base_function: base,
      base_arity: arity,
      level: frame.level,
      line: frame.line,
      steps: 0,
      single_step: defines_fun,
    )
  case defines_fun {
    True -> #(Step, state)
    False -> #(Next, state)
  }
}

fn base_of(frame: Frame) -> #(String, Int) {
  case names.parse_function(frame.function) {
    names.NamedFunction(name) -> #(name, frame.arity)
    names.AnonymousFunction(parent, arity) -> #(parent, arity)
  }
}

/// Decides what to do when the process stopped again during a step over.
pub fn decide(state: StepOver, frame: Frame, at_breakpoint: Bool) -> Decision {
  let state = StepOver(..state, steps: state.steps + 1)
  let #(base, arity) = base_of(frame)
  let same_function =
    frame.module == state.module
    && base == state.base_function
    && arity == state.base_arity
  let anonymous = case names.parse_function(frame.function) {
    names.AnonymousFunction(..) -> True
    names.NamedFunction(_) -> False
  }
  case at_breakpoint, state.steps > step_limit {
    True, _ -> Stop
    _, True -> Stop
    False, False ->
      case frame.level < state.level, same_function, anonymous {
        // Returned to a caller.
        True, _, _ -> Stop
        // Back in the starting function, or a tail-recursive call of it.
        False, True, False if frame.level == state.level -> Stop
        // Deeper recursion of the starting function: keep going.
        False, True, False -> Continue(Step, state)
        // An anonymous function defined in the starting function, like a
        // `use` callback. Lambdas on the starting line (`list.map(xs, fn(x)
        // { .. })`) are run through, not stopped in.
        False, True, True if frame.line == state.line -> Continue(Step, state)
        False, True, True -> Stop
        // Some other function. On the starting level it was tail-called,
        // so finish it, unless an anonymous function of ours may still run
        // inside it; deeper, keep single-stepping.
        False, False, _ if frame.level == state.level && !state.single_step ->
          Continue(Finish, state)
        False, False, _ -> Continue(Step, state)
      }
  }
}

// --- Steps through temporary breakpoints -------------------------------------
//
// `int`'s `next` and `finish` run calls without checking breakpoints in
// them, so a breakpoint in a function being stepped over never stopped.
// Instead of them, the session lets the process continue with temporary
// breakpoints on every line where the step may end. Each one only fires in
// the stepping process at a call level no deeper than `max_level`, or at any
// level for the bodies of anonymous functions defined in the code being
// stepped (the callback of a `use`). The process runs at full speed and
// stops at the user's breakpoints on the way.

/// A frame of the stopped process, from the top of the stack down.
pub type StackFrame {
  StackFrame(level: Int, module: String, line: Int)
}

pub type Target {
  Target(module: String, line: Int, max_level: Int, any_level: Bool)
}

/// Where a step over from the top frame may end: the rest of the current
/// function, anonymous functions nested in it, and the callers.
pub fn over_targets(
  frames: List(StackFrame),
  lookup: fn(String, Int) -> Result(FunctionInfo, Nil),
) -> Result(List(Target), Nil) {
  case frames {
    [] -> Error(Nil)
    [top, ..callers] -> {
      use function <- result.try(lookup(top.module, top.line))
      let depth = fun_depth(function, top.line)
      let own =
        list.map(function.breakable, fn(line) {
          let any_level = line != top.line && fun_depth(function, line) > depth
          Target(top.module, line, top.level, any_level)
        })
      Ok(merge(list.append(own, caller_targets(callers, lookup))))
    }
  }
}

/// Where a step out from the top frame may end: the callers.
pub fn out_targets(
  frames: List(StackFrame),
  lookup: fn(String, Int) -> Result(FunctionInfo, Nil),
) -> List(Target) {
  case frames {
    [] -> []
    [_, ..callers] -> merge(caller_targets(callers, lookup))
  }
}

fn caller_targets(
  callers: List(StackFrame),
  lookup: fn(String, Int) -> Result(FunctionInfo, Nil),
) -> List(Target) {
  list.flat_map(callers, fn(frame) {
    case lookup(frame.module, frame.line) {
      Ok(function) ->
        list.map(function.breakable, fn(line) {
          Target(frame.module, line, frame.level, False)
        })
      Error(Nil) -> []
    }
  })
}

/// How many anonymous functions a line is nested in.
fn fun_depth(function: FunctionInfo, line: Int) -> Int {
  case list.key_find(function.fun_body_lines, line) {
    Ok(depth) -> depth
    Error(Nil) -> 0
  }
}

/// One target per line: the most permissive one.
fn merge(targets: List(Target)) -> List(Target) {
  targets
  |> list.fold(dict.new(), fn(acc, target) {
    let key = #(target.module, target.line)
    case dict.get(acc, key) {
      Ok(existing) ->
        dict.insert(
          acc,
          key,
          Target(
            ..existing,
            max_level: int.max(existing.max_level, target.max_level),
            any_level: existing.any_level || target.any_level,
          ),
        )
      Error(Nil) -> dict.insert(acc, key, target)
    }
  })
  |> dict.values
  |> list.sort(fn(a, b) {
    case string.compare(a.module, b.module) {
      order.Eq -> int.compare(a.line, b.line)
      other -> other
    }
  })
}

//// "Step over" on top of `int`.
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

import gleam_dap/names

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

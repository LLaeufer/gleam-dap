import gleam_dap/project.{FunctionInfo}
import gleam_dap/stepping.{
  Continue, Finish, Frame, Next, StackFrame, Step, Stop, Target,
}

fn frame(function: String, level: Int, line: Int) -> stepping.Frame {
  Frame(module: "app", function:, arity: 1, level:, line:)
}

pub fn plain_line_uses_next_test() {
  let #(command, _) = stepping.start(frame("main", 2, 10), False)
  assert command == Next
}

pub fn line_with_fun_single_steps_test() {
  let #(command, _) = stepping.start(frame("main", 2, 10), True)
  assert command == Step
}

pub fn stops_on_next_line_test() {
  let #(_, state) = stepping.start(frame("main", 2, 10), False)
  assert stepping.decide(state, frame("main", 2, 11), False) == Stop
}

pub fn stops_after_return_test() {
  let #(_, state) = stepping.start(frame("main", 2, 10), False)
  assert stepping.decide(state, frame("caller", 1, 5), False) == Stop
}

pub fn finishes_tail_called_function_test() {
  let #(_, state) = stepping.start(frame("main", 2, 10), False)
  let assert Continue(Finish, _) =
    stepping.decide(state, frame("other", 2, 3), False)
}

pub fn stops_in_use_callback_test() {
  let #(_, state) = stepping.start(frame("main", 2, 10), True)
  let assert Continue(Step, state) =
    stepping.decide(state, frame("check", 3, 30), False)
  let assert Continue(Step, state) =
    stepping.decide(state, frame("try", 3, 18), False)
  assert stepping.decide(state, frame("-main/1-fun-0-", 4, 11), False) == Stop
}

pub fn runs_through_lambda_on_same_line_test() {
  let #(_, state) = stepping.start(frame("main", 2, 10), True)
  let assert Continue(Step, _) =
    stepping.decide(state, frame("-main/1-fun-0-", 4, 10), False)
}

pub fn single_step_keeps_stepping_in_tail_call_test() {
  let #(_, state) = stepping.start(frame("main", 2, 10), True)
  let assert Continue(Step, _) =
    stepping.decide(state, frame("other", 2, 3), False)
}

pub fn breakpoint_always_stops_test() {
  let #(_, state) = stepping.start(frame("main", 2, 10), True)
  assert stepping.decide(state, frame("other", 5, 3), True) == Stop
}

pub fn recursion_keeps_going_test() {
  let #(_, state) = stepping.start(frame("main", 2, 10), True)
  let assert Continue(Step, _) =
    stepping.decide(state, frame("main", 3, 10), False)
}

// --- Temporary breakpoint targets ----------------------------------------------

/// `with_use` spans lines 10-13: line 11 is `use y <- try(x)`, lines 12-13
/// are its callback. `caller` spans lines 20-22.
fn lookup(module: String, line: Int) -> Result(project.FunctionInfo, Nil) {
  case module, line {
    "app", l if l >= 10 && l <= 13 ->
      Ok(
        FunctionInfo(
          name: "with_use",
          arity: 1,
          start: 10,
          end: 13,
          clause_lines: [10],
          breakable: [10, 11, 12, 13],
          lines_with_fun: [11],
          fun_body_lines: [#(12, 1), #(13, 1)],
        ),
      )
    "app", l if l >= 20 && l <= 22 ->
      Ok(
        FunctionInfo(
          name: "caller",
          arity: 0,
          start: 20,
          end: 22,
          clause_lines: [20],
          breakable: [20, 21, 22],
          lines_with_fun: [],
          fun_body_lines: [],
        ),
      )
    _, _ -> Error(Nil)
  }
}

pub fn step_over_targets_test() {
  let frames = [StackFrame(5, "app", 11), StackFrame(4, "app", 21)]
  assert stepping.over_targets(frames, lookup)
    == Ok([
      // The rest of the function, on the same level or higher.
      Target("app", 10, 5, False),
      Target("app", 11, 5, False),
      // The `use` callback runs deeper, so it stops at any level.
      Target("app", 12, 5, True),
      Target("app", 13, 5, True),
      // The caller, once the function has returned.
      Target("app", 20, 4, False),
      Target("app", 21, 4, False),
      Target("app", 22, 4, False),
    ])
}

pub fn step_over_inside_callback_test() {
  // Already in the callback: its own lines run on this level.
  let frames = [StackFrame(6, "app", 12)]
  let assert Ok(targets) = stepping.over_targets(frames, lookup)
  assert targets
    == [
      Target("app", 10, 6, False),
      Target("app", 11, 6, False),
      Target("app", 12, 6, False),
      Target("app", 13, 6, False),
    ]
}

pub fn step_over_unknown_function_test() {
  assert stepping.over_targets([StackFrame(2, "other", 1)], lookup)
    == Error(Nil)
}

pub fn step_out_targets_test() {
  let frames = [StackFrame(5, "app", 11), StackFrame(4, "app", 21)]
  assert stepping.out_targets(frames, lookup)
    == [
      Target("app", 20, 4, False),
      Target("app", 21, 4, False),
      Target("app", 22, 4, False),
    ]
}

pub fn recursive_targets_merge_test() {
  // The same function as caller and callee: one target per line, at the
  // deepest level either allows.
  let frames = [StackFrame(5, "app", 21), StackFrame(4, "app", 20)]
  let assert Ok(targets) = stepping.over_targets(frames, lookup)
  assert targets
    == [
      Target("app", 20, 5, False),
      Target("app", 21, 5, False),
      Target("app", 22, 5, False),
    ]
}

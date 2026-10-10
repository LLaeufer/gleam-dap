import gleam_dap/stepping.{Continue, Finish, Frame, Next, Step, Stop}

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

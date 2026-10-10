import gleam/dict
import gleam/dynamic.{type Dynamic}
import gleam_dap/launch

@external(erlang, "test_ffi", "to_dynamic")
fn d(x: a) -> Dynamic

pub fn parse_gleam_version_test() {
  assert launch.parse_gleam_version("gleam 1.19.0\n") == Ok(#(1, 19, 0))
  assert launch.parse_gleam_version("gleam 1.20.0-rc1") == Ok(#(1, 20, 0))
  assert launch.parse_gleam_version("nonsense") == Error(Nil)
}

pub fn gleam_version_ok_test() {
  assert launch.gleam_version_ok(#(1, 19, 0))
  assert launch.gleam_version_ok(#(2, 0, 0))
  assert !launch.gleam_version_ok(#(1, 18, 5))
}

pub fn decode_defaults_test() {
  let assert Ok(config) = launch.decode_config(d(dict.new()), "/work")
  assert config.project_dir == "/work"
  assert config.function == "main"
  assert config.stack_trace_mode == "all"
  assert config.target == launch.Dev
  assert config.build
}

pub fn decode_options_test() {
  let args =
    dict.from_list([
      #("projectDir", d("/p")),
      #("module", d("app/cli")),
      #("target", d("test")),
      #("stackTraceMode", d(False)),
      #("interpretModules", d(["gleam/list"])),
      #("env", d(dict.from_list([#("A", "1")]))),
    ])
  let assert Ok(config) = launch.decode_config(d(args), "/work")
  assert config.module == "app/cli"
  assert config.target == launch.Test
  assert config.stack_trace_mode == "false"
  assert config.interpret_modules == ["gleam/list"]
  assert config.env == [#("A", "1")]
}

pub fn decode_rejects_bad_mode_test() {
  let args = dict.from_list([#("stackTraceMode", d("sometimes"))])
  let assert Error(_) = launch.decode_config(d(args), "/work")
}

import gleam_dap/names

pub fn module_names_test() {
  assert names.module_to_gleam("app@user@admin") == "app/user/admin"
  assert names.gleam_to_module("app/user") == "app@user"
}

pub fn path_to_module_test() {
  assert names.path_to_module("src/app/user.gleam") == Ok("app@user")
  assert names.path_to_module("test/app_test.gleam") == Ok("app_test")
  assert names.path_to_module("src/app_ffi.erl") == Ok("app_ffi")
  assert names.path_to_module("README.md") == Error(Nil)
}

pub fn demangle_test() {
  assert names.demangle_variable("X") == names.GleamVariable("x", 0)
  assert names.demangle_variable("X@2") == names.GleamVariable("x", 2)
  assert names.demangle_variable("My_var") == names.GleamVariable("my_var", 0)
  assert names.demangle_variable("_pipe") == names.Temporary("_pipe")
  assert names.demangle_variable("_use0") == names.Temporary("_use0")
}

pub fn latest_bindings_test() {
  let bindings = [#("X", 1), #("X@1", 2), #("_pipe", 3), #("Name", 4), #("X@10", 5)]
  assert names.latest_bindings(bindings) == [#("name", 4), #("x", 5)]
}

pub fn erlang_name_for_test() {
  assert names.erlang_name_for("x", [#("X", 1), #("X@1", 2)]) == Ok("X@1")
  assert names.erlang_name_for("y", [#("X", 1)]) == Error(Nil)
}

pub fn parse_function_test() {
  assert names.parse_function("greet") == names.NamedFunction("greet")
  assert names.parse_function("-with_use/1-fun-0-")
    == names.AnonymousFunction("with_use", 1)
  assert names.base_function("-pipes/2-fun-3-") == "pipes"
}

pub fn frame_name_test() {
  assert names.frame_name("app@user", "greet") == "app/user.greet"
  assert names.frame_name("app@user", "-greet/1-fun-0-")
    == "anonymous function in app/user.greet"
}

pub fn constructor_name_test() {
  assert names.constructor_name("person") == "Person"
  assert names.constructor_name("http_error") == "HttpError"
}

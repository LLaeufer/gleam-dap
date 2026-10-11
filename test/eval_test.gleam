import gleam/dynamic.{type Dynamic}
import gleam/option.{Some}

@external(erlang, "test_ffi", "to_dynamic")
fn d(x: a) -> Dynamic

@external(erlang, "gleam_dap_eval_ffi", "eval")
fn eval(
  source: String,
  bindings: List(#(String, Dynamic)),
) -> Result(Dynamic, String)

@external(erlang, "gleam_dap_eval_ffi", "set_labels")
fn set_labels(labels: List(#(#(String, Int), #(String, List(String))))) -> Nil

@external(erlang, "gleam_dap_eval_ffi", "interpolate")
fn interpolate(message: String, bindings: List(#(String, Dynamic))) -> String

type Person {
  Person(name: String, age: Int)
}

pub fn gleam_variable_names_test() {
  let bindings = [#("X", d(1)), #("X@1", d(5))]
  assert eval("x * 2", bindings) == Ok(d(10))
}

pub fn gleam_literals_test() {
  assert eval("True", []) == Ok(d(True))
  assert eval("Nil", []) == Ok(d(Nil))
  assert eval("\"hi\"", []) == Ok(d("hi"))
}

pub fn gleam_operators_test() {
  let bindings = [#("N", d(3))]
  assert eval("n != 4 && n > 2", bindings) == Ok(d(True))
  assert eval("n == 4 || False", bindings) == Ok(d(False))
}

pub fn string_comparison_test() {
  assert eval("name == \"Ada\"", [#("Name", d("Ada"))]) == Ok(d(True))
}

pub fn string_concat_test() {
  let bindings = [#("Name", d("Ada"))]
  assert eval("\"Hello, \" <> name <> \"!\"", bindings) == Ok(d("Hello, Ada!"))
  assert eval("[1] <> [2]", []) == Ok(d([1, 2]))
  assert eval("<<>> == \"\"", []) == Ok(d(True))
}

pub fn field_access_test() {
  set_labels([#(#("person", 2), #("Person", ["name", "age"]))])
  let bindings = [#("P", d(Person("Ada", 36))), #("Pair", d(#(1, Some(2))))]
  assert eval("p.age + 1", bindings) == Ok(d(37))
  assert eval("pair.1", bindings) == Ok(d(Some(2)))
}

pub fn module_calls_test() {
  assert eval("erlang.length(xs)", [#("Xs", d([1, 2, 3]))]) == Ok(d(3))
}

pub fn unknown_variable_test() {
  assert eval("nope", []) == Error("Unknown variable nope")
}

pub fn syntax_error_test() {
  let assert Error(_) = eval("1 +", [])
}

pub fn interpolate_test() {
  assert interpolate("x is {x}, {y}!", [#("X", d([1])), #("Y", d("a"))])
    == "x is [1], \"a\"!"
}

// --- Gleam expressions ------------------------------------------------------

type Shape {
  Circle(radius: Float)
  Square(Float)
}

fn labels() {
  set_labels([
    #(#("person", 2), #("Person", ["name", "age"])),
    #(#("circle", 1), #("Circle", ["radius"])),
  ])
}

pub fn gleam_numbers_test() {
  assert eval("1_000 + 0xff + 0b10 + 0o10", []) == Ok(d(1265))
  assert eval("1.5e3 +. 0.5", []) == Ok(d(1500.5))
  // Gleam's division: integer, and zero for division by zero.
  assert eval("7 / 2", []) == Ok(d(3))
  assert eval("7 / 0", []) == Ok(d(0))
  assert eval("7 % 0", []) == Ok(d(0))
  assert eval("1.0 /. 0.0", []) == Ok(d(0.0))
  assert eval("-3 * 2", []) == Ok(d(-6))
}

pub fn gleam_precedence_test() {
  assert eval("1 + 2 * 3 == 7 && !False", []) == Ok(d(True))
  assert eval("2.0 <. 3.0 || 1 > 2", []) == Ok(d(True))
}

pub fn gleam_strings_test() {
  assert eval("\"a\\tb\\u{1F600}\"", []) == Ok(d("a\tb😀"))
  assert eval("\"é\" <> \"!\"", []) == Ok(d("é!"))
}

pub fn gleam_collections_test() {
  let bindings = [#("Xs", d([2, 3]))]
  assert eval("[1, ..xs]", bindings) == Ok(d([1, 2, 3]))
  assert eval("#(1, \"a\").1", []) == Ok(d("a"))
  assert eval("<<1, 2:size(16)>>", []) == Ok(d(<<1, 0, 2>>))
  assert eval("<<\"hi\":utf8>>", []) == Ok(d(<<"hi":utf8>>))
}

pub fn gleam_constructors_test() {
  labels()
  assert eval("Person(age: 36, name: \"Ada\")", []) == Ok(d(Person("Ada", 36)))
  assert eval("Person(\"Ada\", age: 36)", []) == Ok(d(Person("Ada", 36)))
  assert eval("option.Some(1)", []) == Ok(d(Some(1)))
  assert eval("Ok(Nil)", []) == Ok(d(Ok(Nil)))
  assert eval("Square(1.0)", []) == Ok(d(Square(1.0)))
  let bindings = [#("P", d(Person("Ada", 36)))]
  assert eval("Person(..p, age: p.age + 1)", bindings)
    == Ok(d(Person("Ada", 37)))
}

pub fn gleam_pipes_and_functions_test() {
  let bindings = [#("Xs", d([1, 2, 3]))]
  assert eval("xs |> erlang.length", bindings) == Ok(d(3))
  assert eval("xs |> lists.map(fn(x) { x * 10 }, _)", bindings)
    == Ok(d([10, 20, 30]))
  assert eval("5 |> Some", []) == Ok(d(Some(5)))
  assert eval("{ let double = fn(n: Int) -> Int { n * 2 } double(4) }", [])
    == Ok(d(8))
  assert eval("let y = 2\ny * 21", []) == Ok(d(42))
}

pub fn gleam_case_test() {
  labels()
  let bindings = [#("P", d(Person("Ada", 36))), #("S", d(Circle(2.0)))]
  assert eval("case p { Person(name: \"Ada\", ..) -> 1 _ -> 2 }", bindings)
    == Ok(d(1))
  assert eval("case p.age { n if n > 30 -> \"old\" _ -> \"young\" }", bindings)
    == Ok(d("old"))
  assert eval("case s { Circle(r) | Square(r) -> r }", bindings) == Ok(d(2.0))
  assert eval("case \"hello\" { \"he\" <> rest -> rest _ -> \"\" }", [])
    == Ok(d("llo"))
  assert eval("case [1, 2] { [first, ..] as all -> #(first, all) }", [])
    == Ok(d(#(1, [1, 2])))
  // A guard that needs more than an Erlang guard can do.
  assert eval(
      "case p { x if x.age > 40 -> 1 x if x.age > 30 -> 2 _ -> 3 }",
      bindings,
    )
    == Ok(d(2))
}

pub fn gleam_errors_test() {
  assert eval("let assert Ok(x) = Error(1)\nx", [])
    == Error("Pattern match failed, no pattern matched the value: Error(1)")
  let assert Error(message) = eval("list.map(over: [1], with: fn(x) { x })", [])
  assert message
    == "Labelled arguments (`over:`) can't be checked against the function here; pass the arguments in order without labels"
}

pub fn erlang_fallback_test() {
  // Not Gleam, but still works.
  assert eval("erlang:length([1, 2])", []) == Ok(d(2))
  assert eval("X@1 + 1", [#("X@1", d(1))]) == Ok(d(2))
}

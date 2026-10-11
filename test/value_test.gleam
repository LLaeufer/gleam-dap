import gleam/dict
import gleam/dynamic.{type Dynamic}
import gleam/list
import gleam/option.{None, Some}
import gleam_dap/value

@external(erlang, "test_ffi", "to_dynamic")
fn d(x: a) -> Dynamic

@external(erlang, "test_ffi", "make_pid")
fn make_pid() -> Dynamic

@external(erlang, "test_ffi", "make_fun")
fn make_fun() -> Dynamic

@external(erlang, "test_ffi", "bits")
fn bits() -> Dynamic

@external(erlang, "test_ffi", "improper")
fn improper() -> Dynamic

type Person {
  Person(name: String, age: Int)
}

type Shape {
  Rectangle(Float, Float)
  Empty
}

fn options() {
  value.default_options(
    dict.from_list([
      #(#("person", 2), value.Constructor("Person", ["name", "age"])),
    ]),
  )
}

fn render(x: a) -> String {
  value.render(d(x), options())
}

pub fn scalars_test() {
  assert render(42) == "42"
  assert render(1.5) == "1.5"
  assert render(2.0) == "2.0"
  assert render(True) == "True"
  assert render(Nil) == "Nil"
  assert render("hi \"there\"\n") == "\"hi \\\"there\\\"\\n\""
}

pub fn collections_test() {
  assert render([1, 2, 3]) == "[1, 2, 3]"
  assert render(#(1, "a")) == "#(1, \"a\")"
  assert render([]) == "[]"
  assert render(dict.from_list([#("a", 1)])) == "dict.from_list([#(\"a\", 1)])"
}

pub fn custom_types_test() {
  assert render(Person("Ada", 36)) == "Person(name: \"Ada\", age: 36)"
  assert render(Rectangle(1.0, 2.0)) == "Rectangle(1.0, 2.0)"
  assert render(Empty) == "Empty"
  assert render(Some(Ok(1))) == "Some(Ok(1))"
  assert render(None) == "None"
  assert render(Error(Nil)) == "Error(Nil)"
}

pub fn bit_arrays_test() {
  assert render(<<255, 0>>) == "<<255, 0>>"
  assert value.render(bits(), options()) == "<<1:3>>"
}

pub fn other_terms_test() {
  assert value.render(make_pid(), options()) == "//erl(<0.42.0>)"
  assert value.render(make_fun(), options()) == "//fn lists.map/2"
  assert value.render(improper(), options()) == "[1 | 2]"
}

pub fn limits_test() {
  let options = value.Options(..options(), max_items: 2)
  assert value.render(d([1, 2, 3]), options) == "[1, 2, …]"
  let options = value.Options(..options, max_length: 5)
  assert value.render(d("abcdefgh"), options) == "\"abcd…"
}

pub fn children_test() {
  let children = value.children(d(Person("Ada", 36)), options())
  assert children == [value.Child("name", d("Ada")), value.Child("age", d(36))]
  assert value.children(d([10, 20]), options())
    == [value.Child("0", d(10)), value.Child("1", d(20))]
  assert value.children(d(Rectangle(1.0, 2.0)), options())
    == [value.Child("0", d(1.0)), value.Child("1", d(2.0))]
  assert value.children(d(1), options()) == []
}

pub fn paging_test() {
  assert value.paged_size(d([1, 2, 3])) == Ok(3)
  assert value.paged_size(improper()) == Ok(2)
  assert value.paged_size(d(#(1, 2))) == Ok(2)
  assert value.paged_size(d(Person("Ada", 36))) == Error(Nil)
  assert value.paged_size(d(1)) == Error(Nil)
  assert value.children_page(d([10, 20, 30, 40]), options(), 1, 2)
    == [value.Child("1", d(20)), value.Child("2", d(30))]
  assert value.children_page(improper(), options(), 1, 1)
    == [value.Child("tail", d(2))]
  let map = dict.from_list([#(1, "a"), #(2, "b"), #(3, "c")])
  assert value.paged_size(d(map)) == Ok(3)
  assert list.length(value.children_page(d(map), options(), 2, 5)) == 1
}

pub fn expandable_test() {
  assert value.is_expandable(d([1]))
  assert !value.is_expandable(d([]))
  assert !value.is_expandable(d(Empty))
  assert value.is_expandable(d(Some(1)))
  assert !value.is_expandable(d("text"))
}

pub fn type_name_test() {
  assert value.type_name(d(Person("Ada", 1)), options()) == "Person"
  assert value.type_name(d("x"), options()) == "String"
  assert value.type_name(d([1]), options()) == "List"
  assert value.type_name(d(True), options()) == "Bool"
}

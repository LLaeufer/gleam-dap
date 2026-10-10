import gleam/dict
import gleam/int
import gleam/io
import gleam/list
import gleam/option.{Some}

pub fn main() -> Nil {
  let numbers = [1, 2, 3]
  let doubled = list.map(numbers, fn(n) { n * 2 })
  let counts = dict.from_list([#("a", 1), #("b", 2)])
  let maybe = Some(list.length(doubled))
  io.println(int.to_string(list.fold(doubled, 0, int.add)))
  let _ = #(counts, maybe)
  Nil
}

import gleam/dynamic/decode
import gleam/option.{None, Some}
import gleam_dap/json.{JArray, JBool, JFloat, JInt, JNull, JObject, JString}

pub fn encode_scalars_test() {
  assert json.to_string(JNull) == "null"
  assert json.to_string(JBool(True)) == "true"
  assert json.to_string(JInt(42)) == "42"
  assert json.to_string(JString("a\"b")) == "\"a\\\"b\""
}

pub fn round_trip_test() {
  let value =
    JObject([
      #("list", JArray([JInt(1), JFloat(1.5), JNull])),
      #("text", JString("héllo")),
    ])
  let assert Ok(parsed) = json.parse(<<json.to_string(value):utf8>>)
  let decoder = {
    use text <- decode.field("text", decode.string)
    use first <- decode.subfield(["list"], decode.list(decode.dynamic))
    decode.success(#(text, first))
  }
  let assert Ok(#(text, items)) = decode.run(parsed, decoder)
  assert text == "héllo"
  assert decode.run(items |> list_first, decode.int) == Ok(1)
}

fn list_first(items) {
  let assert [first, ..] = items
  first
}

pub fn object_leaves_out_none_test() {
  assert json.to_string(json.object([#("a", Some(JInt(1))), #("b", None)]))
    == "{\"a\":1}"
}

pub fn parse_invalid_test() {
  assert json.parse(<<"{nope":utf8>>) == Error(Nil)
}

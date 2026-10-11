//// A small JSON value type, encoded with OTP 27's `json` module.

import gleam/dynamic.{type Dynamic}
import gleam/list
import gleam/option.{type Option, None, Some}

pub type Json {
  JNull
  JBool(Bool)
  JInt(Int)
  JFloat(Float)
  JString(String)
  JArray(List(Json))
  JObject(List(#(String, Json)))
}

@external(erlang, "gleam_dap_ffi", "json_encode")
pub fn to_string(json: Json) -> String

@external(erlang, "gleam_dap_ffi", "json_decode")
pub fn parse(text: BitArray) -> Result(Dynamic, Nil)

/// Builds an object, leaving out fields whose value is `None`.
pub fn object(fields: List(#(String, Option(Json)))) -> Json {
  fields
  |> list.filter_map(fn(field) {
    case field.1 {
      Some(value) -> Ok(#(field.0, value))
      None -> Error(Nil)
    }
  })
  |> JObject
}

pub fn string(value: String) -> Option(Json) {
  Some(JString(value))
}

pub fn int(value: Int) -> Option(Json) {
  Some(JInt(value))
}

pub fn bool(value: Bool) -> Option(Json) {
  Some(JBool(value))
}

pub fn array(values: List(Json)) -> Option(Json) {
  Some(JArray(values))
}

pub fn optional_string(value: Option(String)) -> Option(Json) {
  option.map(value, JString)
}

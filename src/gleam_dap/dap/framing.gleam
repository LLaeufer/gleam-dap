//// DAP messages on stdio are framed like LSP: a `Content-Length` header,
//// a blank line, then that many bytes of JSON.

import gleam/bit_array
import gleam/int
import gleam/list
import gleam/result
import gleam/string

/// Splits complete messages off the front of a buffer. Returns the message
/// bodies and whatever is left over (an incomplete message).
pub fn parse(buffer: BitArray) -> #(List(BitArray), BitArray) {
  parse_loop(buffer, [])
}

fn parse_loop(
  buffer: BitArray,
  acc: List(BitArray),
) -> #(List(BitArray), BitArray) {
  case split_header(buffer, 0) {
    Error(Nil) -> #(list.reverse(acc), buffer)
    Ok(#(header, body_start)) -> {
      case content_length(header) {
        // A header without a length can't be recovered from; drop it.
        Error(Nil) -> {
          let rest_size = bit_array.byte_size(buffer) - body_start
          let assert Ok(rest) = bit_array.slice(buffer, body_start, rest_size)
          parse_loop(rest, acc)
        }
        Ok(length) -> {
          let available = bit_array.byte_size(buffer) - body_start
          case available >= length {
            False -> #(list.reverse(acc), buffer)
            True -> {
              let assert Ok(body) = bit_array.slice(buffer, body_start, length)
              let assert Ok(rest) =
                bit_array.slice(
                  buffer,
                  body_start + length,
                  available - length,
                )
              parse_loop(rest, [body, ..acc])
            }
          }
        }
      }
    }
  }
}

/// Finds the end of the header block (`\r\n\r\n`). Returns the header text
/// and the offset where the body starts.
fn split_header(buffer: BitArray, offset: Int) -> Result(#(String, Int), Nil) {
  case bit_array.slice(buffer, offset, 4) {
    Error(Nil) -> Error(Nil)
    Ok(<<"\r\n\r\n":utf8>>) -> {
      use header_bytes <- result.try(bit_array.slice(buffer, 0, offset))
      use header <- result.try(bit_array.to_string(header_bytes))
      Ok(#(header, offset + 4))
    }
    Ok(_) -> split_header(buffer, offset + 1)
  }
}

fn content_length(header: String) -> Result(Int, Nil) {
  header
  |> string.split("\r\n")
  |> list.find_map(fn(line) {
    case string.split_once(line, ":") {
      Ok(#(name, value)) ->
        case string.lowercase(string.trim(name)) {
          "content-length" -> int.parse(string.trim(value))
          _ -> Error(Nil)
        }
      Error(Nil) -> Error(Nil)
    }
  })
}

/// Frames a message body for sending.
pub fn encode(body: String) -> BitArray {
  let bytes = bit_array.from_string(body)
  let length = int.to_string(bit_array.byte_size(bytes))
  bit_array.concat([
    bit_array.from_string("Content-Length: " <> length <> "\r\n\r\n"),
    bytes,
  ])
}

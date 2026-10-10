import gleam/bit_array
import gleam_dap/dap/framing

fn frame(body: String) -> BitArray {
  framing.encode(body)
}

pub fn encode_test() {
  assert framing.encode("{}") == <<"Content-Length: 2\r\n\r\n{}":utf8>>
}

pub fn encode_counts_bytes_test() {
  assert framing.encode("\"é\"") == <<"Content-Length: 4\r\n\r\n\"é\"":utf8>>
}

pub fn parse_one_test() {
  assert framing.parse(frame("{\"a\":1}")) == #([<<"{\"a\":1}":utf8>>], <<>>)
}

pub fn parse_several_test() {
  let buffer = bit_array.concat([frame("1"), frame("22"), frame("333")])
  assert framing.parse(buffer) == #([<<"1">>, <<"22">>, <<"333">>], <<>>)
}

pub fn parse_partial_body_test() {
  let assert <<partial:bytes-size(25), _:bits>> = frame("{\"command\":\"x\"}")
  assert framing.parse(partial) == #([], partial)
}

pub fn parse_partial_header_test() {
  assert framing.parse(<<"Content-Len":utf8>>) == #([], <<"Content-Len":utf8>>)
}

pub fn parse_complete_then_partial_test() {
  let buffer = bit_array.concat([frame("1"), <<"Content-Length: 5\r\n\r\nab":utf8>>])
  assert framing.parse(buffer)
    == #([<<"1">>], <<"Content-Length: 5\r\n\r\nab":utf8>>)
}

pub fn parse_header_case_and_extra_headers_test() {
  let buffer =
    <<"content-length: 2\r\nContent-Type: application/json\r\n\r\n{}":utf8>>
  assert framing.parse(buffer) == #([<<"{}">>], <<>>)
}

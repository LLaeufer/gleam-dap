//// Anchored globs over Gleam module names: `*` matches within one path
//// segment, `**` matches across segments. `app/*` matches `app/user` but
//// not `app/user/admin`; `app/**` matches both.

import gleam/string

pub fn matches(pattern: String, name: String) -> Bool {
  do_match(string.to_graphemes(pattern), string.to_graphemes(name))
}

fn do_match(pattern: List(String), name: List(String)) -> Bool {
  case pattern, name {
    [], [] -> True
    ["*", "*", ..rest], _ -> match_any(rest, name, True)
    ["*", ..rest], _ -> match_any(rest, name, False)
    [p, ..prest], [n, ..nrest] if p == n -> do_match(prest, nrest)
    _, _ -> False
  }
}

fn match_any(rest: List(String), name: List(String), cross: Bool) -> Bool {
  case do_match(rest, name) {
    True -> True
    False ->
      case name {
        [] -> False
        ["/", ..] if !cross -> False
        [_, ..more] -> match_any(rest, more, cross)
      }
  }
}

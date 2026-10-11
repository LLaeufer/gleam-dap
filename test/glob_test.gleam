import gleam_dap/glob

pub fn literal_test() {
  assert glob.matches("app/user", "app/user")
  assert !glob.matches("app/user", "app/users")
  assert !glob.matches("app", "app/user")
}

pub fn star_test() {
  assert glob.matches("app/*", "app/user")
  assert !glob.matches("app/*", "app/user/admin")
  assert glob.matches("gleam/*", "gleam/list")
  assert glob.matches("*_test", "app_test")
}

pub fn double_star_test() {
  assert glob.matches("app/**", "app/user/admin")
  assert glob.matches("**", "anything/at/all")
}

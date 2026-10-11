//// DAP thread ids for BEAM processes. Ids are never reused.

import gleam/dict.{type Dict}
import gleam/erlang/process.{type Pid}

pub type Registry {
  Registry(next_id: Int, by_pid: Dict(Pid, Int), by_id: Dict(Int, Pid))
}

pub fn new() -> Registry {
  Registry(next_id: 1, by_pid: dict.new(), by_id: dict.new())
}

/// The id for a process, registering it if needed. The `Bool` is `True`
/// for a newly registered process.
pub fn id_for(registry: Registry, pid: Pid) -> #(Registry, Int, Bool) {
  case dict.get(registry.by_pid, pid) {
    Ok(id) -> #(registry, id, False)
    Error(Nil) -> {
      let id = registry.next_id
      let registry =
        Registry(
          next_id: id + 1,
          by_pid: dict.insert(registry.by_pid, pid, id),
          by_id: dict.insert(registry.by_id, id, pid),
        )
      #(registry, id, True)
    }
  }
}

pub fn pid_for(registry: Registry, id: Int) -> Result(Pid, Nil) {
  dict.get(registry.by_id, id)
}

pub fn lookup(registry: Registry, pid: Pid) -> Result(Int, Nil) {
  dict.get(registry.by_pid, pid)
}

pub fn remove(registry: Registry, pid: Pid) -> Registry {
  case dict.get(registry.by_pid, pid) {
    Ok(id) ->
      Registry(
        ..registry,
        by_pid: dict.delete(registry.by_pid, pid),
        by_id: dict.delete(registry.by_id, id),
      )
    Error(Nil) -> registry
  }
}

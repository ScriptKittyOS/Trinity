<!-- SPDX-FileCopyrightText: Sudo Apt Holdings LLC -->
<!-- SPDX-License-Identifier: Apache-2.0 -->
# The sandbox

Skills that can execute need a real programming surface. Trinity gives the agent one without giving
it the machine: `luerl` interprets Lua 5.3 inside this node, so a script has no operating system
process, no filesystem handle and no network socket. Anything it wants *done* it asks for through
the host API, which is decided by the same permission gate as any other tool call.

## What it protects against, and what it does not

**It protects against** a script that loops for ever, allocates without bound, tries to read a file,
run a command, open a socket, load more code, or reach the module path. Each is refused by a limit
the virtual machine enforces or by a global that is not there.

**It does not protect against** anything a *tool* can do. A script that calls
`trinity.tool("fs_write", …)` and is allowed writes a file, because the owner allowed it. The
sandbox constrains the script; the permission gate constrains the effect. Reading the first as a
guarantee about the second is the mistake this page exists to prevent.

**It is not a defence against a hostile native dependency**, a compromised BEAM, or anything running
outside the interpreter. It is an in-VM sandbox and the boundary is the interpreter.

## The limits, and which ones actually bind

| Limit | Enforced by | Binds? |
|---|---|---|
| Wall clock | a monitor and a timeout in `Trinity.Sandbox.Runner` | **Yes.** The runner is killed. |
| Heap | `max_heap_size` with `kill: true`, set by the runner on itself | **Yes.** The VM kills it at the boundary, without this code being involved. |
| Concurrency | `max_children` on the runners' supervisor | **Yes.** An over-limit run is refused by name rather than queued. |
| Reductions | reported as a statistic | **No.** See below. |

**Reductions are a statistic here, not a limit, and the reason is measured.** `luerl_sandbox` offers
a `max_reductions` control, and it is implemented as a poll with a 100 ms sleep between checks, so
the first observation of a tight loop already sees tens of millions. Measured on this project:

```
cap=1000     -> reductions=21721012 in 101ms
cap=10000    -> reductions=26449116 in 101ms
cap=100000   -> reductions=34313448 in 101ms
cap=1000000  -> reductions=34373451 in 101ms
```

A cap of one thousand and a cap of one million behave identically, because neither is ever the
binding constraint. Trinity therefore runs the interpreter under its own process with a heap limit
and a timeout, and reports the reductions a run used as information rather than pretending they were
bounded.

## What a script can reach

`luerl_sandbox.init/0` removes `io` and `file` wholesale; `package`, `require`, `dofile`, `load`,
`loadfile` and `loadstring`; and from `os`, the members `execute`, `exit`, `getenv`, `remove`,
`rename` and `tmpname`.

**`os` itself survives.** `os.time`, `os.date` and `os.clock` remain callable. None of them reaches a
resource, and none is a hole. They are named here because all three are **non-deterministic**, which
matters when a script's output can end up in a receipt: two runs of one script can differ without
anything having changed.

The host surface Trinity adds:

| Call | What it does |
|---|---|
| `trinity.tool(name, args)` | A tool call, through the same executor a model's own call uses. |
| `trinity.log(text)` | A line in the run's log, returned with the result. |
| `trinity.result(table)` | Declares the run's structured answer, replacing its return value. |
| `json.encode(v)` / `json.decode(s)` | JSON, with Lua's own array-versus-object rule. |

## A script cannot wait for a person

A sandboxed run is bounded in wall clock, typically a second. A permission decision of "ask" raises
an approval that a person answers in their own time. Those cannot both be true, so a tool call that
needs approval returns an error value to Lua **immediately** rather than blocking until the run's
clock kills it.

This is a real limit and it is the honest one. Letting a script block would turn every approval into
a timeout and teach the owner that sandbox runs fail at random.

Errors are values, not exceptions: a failing host call returns `nil, message`, which is Lua's own
idiom and which leaves the script running so it can decide what to do.

## Skill scripts

A skill may declare `trinity.lua_entry` in its front matter, naming a file under its own `scripts/`
directory. `Trinity.Sandbox.Skill.run/4` reads it and runs it with `args` bound as a Lua table.

**The path is resolved, not trusted.** `lua_entry` comes from front matter and a skill can be
proposed by the agent, so the resolved path is checked to be inside the skill's own directory before
anything is opened. `Path.expand/2` resolves `..` first, so a traversal is caught by where it lands
rather than by what it looks like: a pattern match on `..` is defeated by symlinks and by encoding,
and a resolved path is not. An absolute entry is neutralised rather than honoured, because
`Path.join/2` drops the leading slash.

Slice 041 controls *what gets installed*; this controls what an installed skill can reach. They are
different questions.

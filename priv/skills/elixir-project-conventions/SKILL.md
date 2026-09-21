---
name: elixir-project-conventions
description: How to read, change and test an Elixir or Phoenix project without breaking its conventions. Use when editing .ex or .exs files, adding a module, a test, a migration or a dependency, or when mix, ExUnit, Ecto or LiveView come up.
license: Apache-2.0
metadata:
  author: trinity
  version: "1.0"
  category: development
trinity:
  requires_toolsets: [fs]
  risk: write
---

# Elixir project conventions

## Before changing anything

- Read `mix.exs` for the app name, the Elixir version and the aliases; read `.formatter.exs`.
- Find the module you are changing with `fs_grep` for `defmodule`, and read the whole file
  before editing part of it.
- If the project has `CLAUDE.md`, `AGENTS.md` or `CONTRIBUTING.md`, they win over this skill.

## Changing code

- One module per file, the file path mirroring the module name (`lib/app/thing.ex` for
  `App.Thing`).
- Public functions carry `@doc` and `@spec`; a module carries `@moduledoc`. Private helpers go
  below the public ones.
- Pattern match in function heads before reaching for `case`; keep functions short; no
  `Code.eval_string` on anything that came from outside.
- Run `mix format` on what you touched and `mix compile --warnings-as-errors` before you say it
  compiles. Warnings are failures in most gated projects.

## Tests

- A test lives beside its module's path under `test/` and ends in `_test.exs`.
- Tests that touch a database use the project's DataCase; tests that reach the network are
  tagged and excluded by default. Do not add a network call to a test.
- Run the test file you changed, then the whole suite; report the numbers, not "tests pass".

## Migrations and dependencies

- A schema change is a migration (`mix ecto.gen.migration`), never an edit to an old one.
- A new dependency goes through `mix.exs` with a version requirement, and `mix deps.get`;
  say why it is needed. `references/mix-commands.md` lists the commands.

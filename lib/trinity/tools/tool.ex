# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Tools.Tool do
  @moduledoc """
  What a tool is. Slice 020, Trinity's own behaviour (ADR-0009: no Jido).

  A tool is a stateless module: a name, a description for the model, a JSON Schema for its
  arguments (validated with `jsv` before `execute/2`, never repaired), a risk tier the
  permission gate reads from the name alone, an effect class the membrane reads, and
  `execute/2`. Stateful runtimes (a shell, a browser) live under `Trinity.Tools.Supervisor`
  and are looked up by the tool; the tool module itself holds nothing.

  `effect/0` is part of the behaviour (docs/07): `:none` is a read, `:artifact` a local
  write, `:catalog` an external effect. A `:catalog` tool exists only in
  `Trinity.Effects.Catalog`'s module attribute; a runtime registration claiming it is refused.
  """

  alias Trinity.Tools.{Context, Result}

  @type risk :: :read | :write | :exec | :network | :destructive
  @type effect :: :none | :artifact | :catalog
  @type args :: map()

  @doc "The tool's name: the model calls it by this, and the permission tier is a function of it."
  @callback name() :: String.t()

  @doc "One paragraph for the model."
  @callback description() :: String.t()

  @doc "A JSON Schema (2020-12) map for the arguments, string keys."
  @callback schema() :: map()

  @doc "The risk tier the gate reads for a core tool of this name."
  @callback risk() :: risk()

  @doc "The effect class the membrane reads."
  @callback effect() :: effect()

  @doc "Runs the tool with validated arguments."
  @callback execute(args(), Context.t()) :: {:ok, Result.t()} | {:error, term()}

  @doc "Milliseconds before the runner gives up on a call. Default: the configured default."
  @callback timeout() :: pos_integer()

  @doc "The text the model reads for a result. Default: the content as text."
  @callback format_result(Result.t()) :: String.t()

  @optional_callbacks timeout: 0, format_result: 1

  @doc "True when `module` implements this behaviour."
  @spec implemented_by?(module()) :: boolean()
  def implemented_by?(module) when is_atom(module) do
    Code.ensure_loaded?(module) and
      __MODULE__ in List.flatten(Keyword.get_values(module.module_info(:attributes), :behaviour))
  end
end

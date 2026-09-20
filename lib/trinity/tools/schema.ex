# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Tools.Schema do
  @moduledoc """
  Argument validation against a tool's JSON Schema, with `jsv`. Slice 020. `cast: false`: a
  malformed call is refused with reasons the model can read, and nothing is coerced or filled
  in (docs/07: malformed arguments are denied, never repaired).
  """

  @doc "The arguments as given when they satisfy the schema; otherwise the reasons."
  @spec validate(map(), map()) :: {:ok, map()} | {:error, [String.t()]}
  def validate(schema, args) when is_map(schema) and is_map(args) do
    with {:ok, root} <- build(schema),
         {:ok, _} <- JSV.validate(args, root, cast: false) do
      {:ok, args}
    else
      {:error, %JSV.ValidationError{} = error} -> {:error, reasons(error)}
      {:error, other} -> {:error, [inspect(other)]}
    end
  end

  def validate(_schema, args), do: {:error, ["arguments must be an object, got #{inspect(args)}"]}

  @doc "True when the schema itself builds: what the registry asks before admitting a tool."
  @spec valid_schema?(map()) :: boolean()
  def valid_schema?(schema) when is_map(schema), do: match?({:ok, _}, build(schema))
  def valid_schema?(_), do: false

  defp build(schema), do: JSV.build(schema)

  defp reasons(error) do
    error
    |> JSV.normalize_error()
    |> Map.get(:details, [])
    |> Enum.flat_map(fn detail ->
      path = Map.get(detail, :instanceLocation, "")

      detail
      |> Map.get(:errors, [])
      |> Enum.map(fn e -> "#{path}: #{Map.get(e, :message)}" end)
    end)
    |> case do
      [] -> [Exception.message(error)]
      list -> list
    end
  end
end

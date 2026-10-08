# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Mix.Tasks.Trinity.Space.Retier do
  @shortdoc "Re-embeds the store into an embedder's space and moves the active pointer"

  @moduledoc """
  Slice 133, the operator's re-tier. Builds the target embedder's space beside the active one
  (every semantic memory embedded into it, in batches), then moves the active pointer to it in
  one transaction. The old space's vectors stay until `mix trinity.space.drop <id> --confirm`.

      mix trinity.space.retier [static|local|hosted|ollama|fake]

  Without a name, the first embedder `config :trinity, :memory, embedder:` names. For a store
  to keep answering while it builds, configure the target ahead of the current embedder
  (`embedder: [:static, :local]`): the store is served by whichever configured embedder writes
  the active space, so it answers from the old space until the pointer moves and from the new
  one after.
  """
  use Boundary, classify_to: Trinity
  use Mix.Task

  alias Trinity.Memory.{Embedder, Space, Spaces}

  @impl Mix.Task
  def run(argv) do
    Mix.Task.run("app.start")

    module =
      case argv do
        [] ->
          Embedder.impl()

        [name] ->
          case Embedder.from_name(name) do
            {:ok, m} ->
              m

            {:error, reason} ->
              Mix.raise("#{inspect(reason)}; one of #{Enum.join(Embedder.names(), ", ")}")
          end
      end

    progress = fn n -> if rem(n, 1000) < 64, do: Mix.shell().info("  #{n} embedded") end

    case Spaces.retier(module, on_batch: progress) do
      {:ok, %{space: id, previous: prev, embedded: n}} ->
        Mix.shell().info(
          "space #{Space.short(id)} is active (#{n} embedded); " <>
            if(prev,
              do:
                "the previous space #{Space.short(prev)} is kept until `mix trinity.space.drop #{Space.short(prev)} --confirm`",
              else: "there was no previous space"
            )
        )

      {:error, reason} ->
        Mix.raise("re-tier refused: #{inspect(reason)}")
    end
  end
end

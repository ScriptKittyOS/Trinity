# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Gateways.Mattermost.TestHelpers do
  @moduledoc """
  Starting the Mattermost adapter against `FakeServer` in a test (slice 072), and waiting on what
  the server is shown. The token is a fresh random value in a variable of its own per test, so a
  test asserting it never reaches a log line is looking for a value nothing else in the run holds.
  """
  import ExUnit.Assertions

  alias Trinity.Gateways.Mattermost
  alias Trinity.Gateways.Mattermost.{FakeServer, State}

  @doc "The recorded tester's user id, the person writing in every recorded frame."
  def tester_id, do: "yuadbo77878m8myazrtkfyi5pw"

  @doc """
  A token shaped like a Mattermost one (26 lower-case letters and digits), in an environment
  variable of its own. Answers `{env_var, token}`.
  """
  def token! do
    env = "MATTERMOST_TEST_TOKEN_#{System.unique_integer([:positive])}"
    token = FakeServer.random_id()
    System.put_env(env, token)
    ExUnit.Callbacks.on_exit(fn -> System.delete_env(env) end)
    {env, token}
  end

  @doc """
  A fake server and the adapter connected to it. Options go to the adapter (`callback_url:`) or
  the server (`max_post_size:`). Waits until the adapter has learned the server and its socket
  is connected.
  """
  def start_adapter!(opts \\ []) do
    {env, token} = token!()
    server = FakeServer.start!(token, Keyword.take(opts, [:max_post_size]))

    adapter_opts =
      [url: server.url, token_env: env, backoff_ms: 20, max_backoff_ms: 100]
      |> Keyword.merge(Keyword.drop(opts, [:max_post_size]))

    ExUnit.Callbacks.start_supervised!({Mattermost, adapter_opts})
    await(fn -> State.facts() != nil and FakeServer.sockets(server) != [] end)
    Map.merge(server, %{token: token, token_env: env})
  end

  @doc "Pairs the recorded tester with the adapter, as the desktop would."
  def pair_tester! do
    {:ok, identity, :pending} = Trinity.Gateways.Identities.admit("mattermost", tester_id())
    {:ok, _} = Trinity.Gateways.Identities.pair("mattermost", tester_id(), identity.code)
    :ok
  end

  @doc "Waits until `fun` is truthy, flunking with `what` after `timeout`."
  def await(fun, what \\ "the condition", timeout \\ 5_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_await(fun, what, deadline)
  end

  defp do_await(fun, what, deadline) do
    case fun.() do
      falsy when falsy in [nil, false] ->
        if System.monotonic_time(:millisecond) > deadline do
          flunk("waited for #{what} and it never held")
        else
          Process.sleep(20)
          do_await(fun, what, deadline)
        end

      value ->
        value
    end
  end

  @doc "Every message the server holds now, joined, for a wait on what a person would see."
  def shown(server), do: server |> FakeServer.posts() |> Map.values() |> Enum.join("\n")

  @doc "Waits until a post the server holds contains `fragment`."
  def await_shown(server, fragment),
    do: await(fn -> shown(server) =~ fragment end, "a post containing #{inspect(fragment)}")
end

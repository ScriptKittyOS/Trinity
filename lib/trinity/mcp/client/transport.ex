# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.MCP.Client.Transport do
  @moduledoc """
  What carries a request to a server and its answer back (slice 060). Two implementations:
  `Trinity.MCP.Client.Transport.Stdio` (a child process on a Port, newline-delimited, the
  answers correlated by id) and `Trinity.MCP.Client.Transport.HTTP` (one POST per request,
  the answer in the response). `connect/2` is called by the client process, which owns the
  handle; `request/3` may be called from any process (a tool call runs in its own task), so a
  transport holding a connection is a process of its own and a transport without one is a
  struct. A transport that loses its server tells the owner with
  `{:mcp_transport_down, handle, reason}`; a notification the server sends on its own is
  `{:mcp_notification, handle, method, params}`.
  """

  alias Trinity.MCP.ServerConfig

  @type handle :: term()

  @doc "Opens the transport for a configured server; `owner` receives the down and notification messages."
  @callback connect(ServerConfig.t(), owner :: pid(), opts :: keyword()) ::
              {:ok, handle()} | {:error, term()}

  @doc "Sends a request and waits for the answer with that id; `opts` carry `schemas:` (for the HTTP headers) and `timeout:`."
  @callback request(handle(), map(), keyword()) :: {:ok, map()} | {:error, term()}

  @doc "Sends a notification (no id, no answer)."
  @callback notify(handle(), map(), keyword()) :: :ok | {:error, term()}

  @doc "Closes the transport."
  @callback close(handle()) :: :ok
end

# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule TrinityWeb.Auth do
  @moduledoc """
  Who is asking, on every web request and every LiveView step (slice 136).

  Three checks, each where the request is:

    * `TrinityWeb.Auth.Gate`, in the endpoint ahead of the router: no principal, no route. A `GET`
      for a page is sent to `/auth/login`; anything else is `401`. This is what makes a `POST` to
      a path that has only a `GET` route a `401` rather than a `404` that says the path exists.
    * `TrinityWeb.Auth.RequireRole`, in the router's pipelines: the role a route needs, and a
      receipt for every privileged route used or refused.
    * `on_mount/4`, on every `live_session`: "Performing authorization on mount is important
      because navigates do not go through the plug pipeline" (the LiveView docs). It checks the
      session on mount, again on every `handle_params` (a revoked session is halted on its next
      patch, AC3) and on every `handle_event`, where the event's role comes from
      `TrinityWeb.Auth.Policy`.

  In `:none` (a loopback node) every check passes with `TrinityWeb.Auth.Principal.owner/0`; the
  Host allow-list and the origin list are what stand in for identity there.
  """
  import Plug.Conn

  require Logger

  alias Phoenix.LiveView
  alias TrinityWeb.Auth.{Policy, Principal, Sessions}

  @session_key "web_sid"

  @doc """
  The processes the web login needs, started by the application ahead of the endpoint: the
  session store always, the issuer's configuration worker under `:oidc`.
  """
  @spec children() :: [Supervisor.child_spec() | module()]
  def children, do: [Sessions | TrinityWeb.Auth.OIDC.children()]

  @doc "The session key holding the web session id."
  @spec session_key() :: String.t()
  def session_key, do: @session_key

  @doc """
  The principal of a session map (a `Plug.Conn` session, or the session a LiveView receives).
  `:none` answers the owner without looking.
  """
  @spec principal(map()) :: {:ok, Principal.t()} | {:error, atom()}
  def principal(session) when is_map(session) do
    case Trinity.WebAuth.mode() do
      :none -> {:ok, Principal.owner()}
      _mode -> Sessions.fetch(session[@session_key])
    end
  end

  @doc """
  Logs a principal in: a new server-side session, the cookie renewed (a fixed session id from
  before the login is not carried across it), and the LiveView socket id set so `log_out/1` and
  `Sessions.revoke/1` reach every open page.
  """
  @spec log_in(Plug.Conn.t(), Principal.t()) :: Plug.Conn.t()
  def log_in(conn, %Principal{} = principal) do
    sid = Sessions.create(principal)

    conn
    |> configure_session(renew: true)
    |> clear_session()
    |> put_session(@session_key, sid)
    |> put_session(:live_socket_id, Sessions.socket_id(sid))
  end

  @doc "Ends the request's session on the server and in the cookie."
  @spec log_out(Plug.Conn.t()) :: Plug.Conn.t()
  def log_out(conn) do
    case get_session(conn, @session_key) do
      sid when is_binary(sid) -> Sessions.revoke(sid)
      _ -> :ok
    end

    conn |> configure_session(drop: true)
  end

  ## LiveView

  @doc """
  The `on_mount` guard: `{TrinityWeb.Auth, role}` on a `live_session` requires `role` to mount.

  Attaches two hooks. `handle_params` re-checks the session, so a revoked or expired one is
  redirected to the login on its next patch. `handle_event` re-checks it and asks
  `TrinityWeb.Auth.Policy` which role the event needs; an event the principal may not send is
  halted with a flash and, when the role is not `view`, a receipt.
  """
  @spec on_mount(Principal.role(), map(), map(), LiveView.Socket.t()) ::
          {:cont, LiveView.Socket.t()} | {:halt, LiveView.Socket.t()}
  def on_mount(role, _params, session, socket) when role in [:view, :approve, :administer] do
    with {:ok, principal} <- principal(session),
         true <- Principal.has_role?(principal, role) do
      socket =
        socket
        |> Phoenix.Component.assign(:web_principal, principal)
        |> Phoenix.Component.assign(:web_auth_mode, Trinity.WebAuth.mode())
        |> LiveView.attach_hook(:web_auth_params, :handle_params, &recheck_params(&1, &2, &3))
        |> LiveView.attach_hook(:web_auth_events, :handle_event, &check_event(&1, &2, &3))

      {:cont, socket}
    else
      false -> {:halt, LiveView.redirect(socket, to: "/auth/forbidden")}
      {:error, _reason} -> {:halt, LiveView.redirect(socket, to: "/auth/login")}
    end
  end

  defp recheck_params(_params, _uri, socket) do
    case recheck(socket) do
      {:ok, _principal} -> {:cont, socket}
      {:error, _} -> {:halt, LiveView.redirect(socket, to: "/auth/login")}
    end
  end

  defp check_event(event, _params, socket) do
    role = Policy.event_role(socket.view, event)

    case recheck(socket) do
      {:ok, principal} ->
        decide_event(socket, principal, role, Principal.has_role?(principal, role), event)

      {:error, _} ->
        {:halt, LiveView.redirect(socket, to: "/auth/login")}
    end
  end

  defp decide_event(socket, _principal, :view, true, _event), do: {:cont, socket}

  defp decide_event(socket, principal, role, true, event) do
    case privileged_receipt(principal, role, "allow", event_detail(socket, event)) do
      :ok ->
        {:cont, socket}

      {:error, _} ->
        {:halt, LiveView.put_flash(socket, :error, "Not done: it could not be receipted.")}
    end
  end

  defp decide_event(socket, principal, role, false, event) do
    _ = privileged_receipt(principal, role, "deny", event_detail(socket, event))
    {:halt, LiveView.put_flash(socket, :error, "Not permitted: this needs the #{role} role.")}
  end

  defp event_detail(socket, event), do: %{"view" => inspect(socket.view), "event" => event}

  # The session as it stands now, not as it stood at mount.
  defp recheck(socket) do
    case socket.assigns[:web_principal] do
      %Principal{mode: :none} = p ->
        if Trinity.WebAuth.mode() == :none, do: {:ok, p}, else: {:error, :mode_changed}

      %Principal{sid: sid} when is_binary(sid) ->
        Sessions.fetch(sid)

      _ ->
        {:error, :unknown}
    end
  end

  @doc """
  What an approval decided from a page carries to `Trinity.Permissions.decide_request/3`: the
  decider's name for the row (`by:`) and the principal's receipt form for the approval receipt
  (`principal:`, with the role `approve`). Every approval then says who gave it.
  """
  @spec decider_opts(LiveView.Socket.t()) :: keyword()
  def decider_opts(socket) do
    case socket.assigns[:web_principal] do
      %Principal{} = p -> [by: Principal.label(p), principal: Principal.receipt(p, :approve)]
      _ -> []
    end
  end

  ## Receipts

  @doc """
  Appends a receipt of a privileged act (an approval decided, a privileged route or event used or
  refused) to the access chain, carrying the principal's `sub` and `iss` and the role the act
  needed (AC9).

  When the receipt cannot be written the act is refused, except on a loopback node with no login,
  where the desktop must stay usable with its signer down (slice 100: the keychain helper may be
  absent); there the failure is logged.
  """
  @spec privileged_receipt(Principal.t(), Principal.role(), String.t(), map()) ::
          :ok | {:error, term()}
  def privileged_receipt(%Principal{} = principal, role, outcome, detail) do
    subject =
      detail
      |> Map.put("phase", Map.get(detail, "phase", "privileged"))
      |> Map.put("principal", Principal.receipt(principal, role))

    attrs = %{
      kind: "decision",
      subject: subject,
      decision: %{"outcome" => outcome, "basis" => "web_auth", "role" => Atom.to_string(role)},
      subject_ref: "access:" <> principal.sub
    }

    case Trinity.Receipts.append(Trinity.Receipts.access_scope(), attrs) do
      {:ok, _} ->
        :ok

      {:error, reason} = error ->
        Logger.error("web auth: privileged act not receipted: #{inspect(reason)}")
        if principal.mode == :none, do: :ok, else: error
    end
  end
end

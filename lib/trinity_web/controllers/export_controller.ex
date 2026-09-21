# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule TrinityWeb.ExportController do
  @moduledoc """
  `GET /settings/export.tar.gz[?keys=1]` (slice 034): the running Trinity's archive as a
  download, made the same way the mix task makes it. Private keys only with `keys=1`.
  """
  use TrinityWeb, :controller

  def download(conn, params) do
    keys? = params["keys"] in ["1", "true"]
    stamp = DateTime.utc_now() |> DateTime.to_iso8601(:basic) |> String.slice(0, 15)
    name = "trinity-#{stamp}#{if keys?, do: "-with-keys", else: ""}.tar.gz"

    out =
      Path.join(
        System.tmp_dir!(),
        "trinity-download-#{System.unique_integer([:positive])}.tar.gz"
      )

    case Trinity.Archive.export(Trinity.Archive.Layout.current(), out, keys: keys?) do
      {:ok, _} ->
        conn = send_download(conn, {:file, out}, filename: name, content_type: "application/gzip")
        File.rm(out)
        conn

      {:error, reason} ->
        conn |> put_status(500) |> text("export failed: #{inspect(reason)}")
    end
  end
end

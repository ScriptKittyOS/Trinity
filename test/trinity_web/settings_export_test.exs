# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule TrinityWeb.SettingsExportTest do
  @moduledoc "Slice 034: the settings page links to the export; the download is a tarball whose manifest parses and names the keys choice."
  use TrinityWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Trinity.Archive.Manifest

  # No sandbox mode change: the export opens the database files itself (VACUUM INTO through
  # exqlite), beside whatever the pool holds.

  test "the page shows the data directory and links to both exports and the boot receipt", %{
    conn: conn
  } do
    {:ok, view, html} = live(conn, ~p"/settings")
    assert has_element?(view, "#export[href='/settings/export.tar.gz']")
    assert has_element?(view, "#export-with-keys[href='/settings/export.tar.gz?keys=1']")
    assert html =~ "docs/backup.md"
    assert html =~ Trinity.Paths.data_dir()
    {:ok, index, _} = live(conn, ~p"/")
    assert has_element?(index, "#settings-link")
  end

  test "the download is a gzip tarball with a manifest; keys only on request", %{conn: conn} do
    conn = get(conn, ~p"/settings/export.tar.gz")
    assert conn.status == 200
    assert get_resp_header(conn, "content-type") |> hd() =~ "application/gzip"

    assert get_resp_header(conn, "content-disposition") |> hd() =~
             ~r/attachment; filename="trinity-\d{8}T\d{6}\.tar\.gz"/

    {:ok, entries} = :erl_tar.extract({:binary, conn.resp_body}, [:compressed, :memory])
    entries = Map.new(entries, fn {n, b} -> {List.to_string(n), b} end)

    assert {:ok, %Manifest{keys_included: false, files: files}} =
             Manifest.decode(entries["manifest.json"])

    assert Enum.map(files, & &1["path"]) |> Enum.sort() == [
             "keys/registry.json",
             "receipts.db",
             "trinity.db"
           ]

    assert :ok = Manifest.verify(elem(Manifest.decode(entries["manifest.json"]), 1), entries)

    conn = get(build_conn(), ~p"/settings/export.tar.gz?keys=1")
    {:ok, entries} = :erl_tar.extract({:binary, conn.resp_body}, [:compressed, :memory])
    entries = Map.new(entries, fn {n, b} -> {List.to_string(n), b} end)
    assert {:ok, %Manifest{keys_included: true}} = Manifest.decode(entries["manifest.json"])
    assert Enum.any?(Map.keys(entries), &String.match?(&1, ~r/^keys\/receipts-.*\.key$/))
    assert get_resp_header(conn, "content-disposition") |> hd() =~ "-with-keys.tar.gz"
  end
end

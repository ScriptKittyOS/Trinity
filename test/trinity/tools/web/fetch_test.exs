# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Tools.Web.FetchTest do
  @moduledoc "Slice 022 AC5: web_fetch against a local Plug (no socket), and the search fake (AC6's fake half)."
  use ExUnit.Case, async: false

  alias Trinity.Tools.Context
  alias Trinity.Tools.Web.{Fetch, Search}

  setup do
    previous = Application.get_env(:trinity, :web, [])

    Application.put_env(
      :trinity,
      :web,
      Keyword.put(previous, :req_options, plug: Trinity.FakeWeb)
    )

    on_exit(fn -> Application.put_env(:trinity, :web, previous) end)
    {:ok, ctx: %Context{}}
  end

  test "extracts the main text without chrome, keeps the title, and answers an untrusted part", %{
    ctx: ctx
  } do
    assert {:ok, r} = Fetch.execute(%{"url" => "http://example.test/page"}, ctx)
    assert r.content =~ "Main heading" and r.content =~ "First paragraph"

    refute r.content =~ "Sidebar" or r.content =~ "Footer noise" or r.content =~ "alert(1)" or
             r.content =~ "Home About"

    assert r.meta["title"] == "The Page Title"

    assert [
             %{
               taint: :untrusted,
               origin: "tool:web_fetch",
               source_ref: "http://example.test/page",
               digest: d
             }
           ] = r.parts

    assert String.length(d) == 64

    assert r.content =~ Trinity.FakeWeb.injected(),
           "the instruction is data in the part, not dropped"
  end

  test "caps the body at 1 MB and says so; plain text comes raw; a redirect is followed", %{
    ctx: ctx
  } do
    assert {:ok, big} = Fetch.execute(%{"url" => "http://example.test/big"}, ctx)
    assert byte_size(big.content) == 1_048_576
    assert big.meta["capped_at_bytes"] == 1_048_576 and big.meta["bytes"] == 2 * 1_048_576
    assert {:ok, text} = Fetch.execute(%{"url" => "http://example.test/text"}, ctx)
    assert text.content == "plain text body"
    assert {:ok, redirected} = Fetch.execute(%{"url" => "http://example.test/redirect"}, ctx)
    assert redirected.meta["title"] == "The Page Title"
  end

  test "a binary content type and an HTTP error are descriptive errors; a bad URL is refused", %{
    ctx: ctx
  } do
    assert {:error, {:content_type, msg}} =
             Fetch.execute(%{"url" => "http://example.test/bin"}, ctx)

    assert msg =~ "image/png"
    assert {:error, {:http, msg}} = Fetch.execute(%{"url" => "http://example.test/500"}, ctx)
    assert msg =~ "500"
    assert {:error, {:url, _}} = Fetch.execute(%{"url" => "ftp://example.test/x"}, ctx)
  end

  test "a non-public host escalates to :ask; a public one does not", %{ctx: ctx} do
    for url <- [
          "http://localhost/x",
          "http://127.0.0.1/x",
          "http://10.0.0.5/",
          "http://169.254.169.254/latest",
          "http://[::1]/",
          "http://box.local/"
        ] do
      assert Fetch.escalate(%{"url" => url}, ctx) == :ask, url
    end

    assert Fetch.escalate(%{"url" => "https://example.com/"}, ctx) == nil
    assert Fetch.escalate(%{"url" => "http://93.184.216.34/"}, ctx) == nil
    assert Fetch.escalate(%{"url" => "not a url"}, ctx) == :ask
  end

  test "AC6 (fake): web_search returns structured results as one untrusted part", %{ctx: ctx} do
    assert {:ok, r} = Search.execute(%{"query" => "elixir otp", "count" => 2}, ctx)
    assert r.meta["results"] == 2 and r.meta["provider"] =~ "Fake"
    assert r.content =~ "1. Result 1 for elixir otp" and r.content =~ "https://example.com/"
    refute r.content =~ "3. Result 3"
    assert [%{taint: :untrusted, source_ref: "search:elixir otp"}] = r.parts
  end
end

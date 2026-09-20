# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Evals.Compaction.FactsEvalTest do
  @moduledoc """
  The compaction eval harness (slice 023, risk R7), the first suite of the harness later
  slices extend (tool selection, injection resistance, memory recall).

  Three scripted long conversations, each seeded with named facts. Each is compacted by the
  model in force, the compaction row's text is searched for every fact, and a table (facts
  tracked, survived, ratio, plus the token estimate against the provider's own count) is
  written to `slices/023-context-compaction/proof/eval-<date>.md`. AC4's threshold: at least
  90 % of the tracked facts survive across the three.

  Opt in: `TRINITY_LIVE=1 mix test --only eval test/evals/compaction` with the provider's key
  in the environment (`TRINITY_EVAL_MODEL` picks a registry id other than the default) (the fake answers "fake" for every field, and then the ratio is 0: the
  fake run proves the plumbing and writes the table with the fake's name in it).
  """
  use Trinity.DataCase, async: false
  @moduletag :eval
  @moduletag timeout: 1_800_000
  @moduletag ownership_timeout: 1_800_000

  alias Trinity.Factory
  alias Trinity.LLM.Request
  alias Trinity.Memory.{Compactor, Tokens}
  alias Trinity.Sessions

  @proof_dir "slices/023-context-compaction/proof"

  # The registry id under test: TRINITY_EVAL_MODEL, or the registry's default.
  defp model, do: System.get_env("TRINITY_EVAL_MODEL")

  # With TRINITY_LIVE=1 the registry is the dev/prod one (config/llm.exs), as the 011 live
  # suite does; the fake stays otherwise.
  setup_all do
    if System.get_env("TRINITY_LIVE") == "1" do
      original = Application.get_env(:trinity, :llm)
      Application.put_env(:trinity, :llm, Config.Reader.read!("config/llm.exs")[:trinity][:llm])
      on_exit(fn -> Application.put_env(:trinity, :llm, original) end)
    end

    :ok
  end

  # Each conversation: a list of {user, assistant} turns; the facts are what a later turn would need.
  @conversations [
    %{
      name: "trip planning",
      facts: [
        "Lisbon",
        "14 March",
        "Hotel Avenida",
        "vegetarian",
        "budget of 1200 euros",
        "TAP flight 1044"
      ],
      turns: [
        {"I want to plan a trip to Lisbon.",
         "Lisbon is a fine choice. When are you thinking of going?"},
        {"Arriving 14 March, five nights.",
         "Five nights from 14 March. Where would you like to stay?"},
        {"Book the Hotel Avenida if it has rooms.", "Noted: Hotel Avenida for the five nights."},
        {"I am vegetarian, keep that in mind for restaurants.",
         "Understood, vegetarian restaurants only."},
        {"My budget of 1200 euros covers everything except the flight.",
         "A budget of 1200 euros for lodging and meals."},
        {"The flight is TAP flight 1044, already booked.",
         "TAP flight 1044 it is; I will not touch the flight."},
        {"What should I see on the first day?",
         "The Alfama district and the tram 28 route make a good first day."},
        {"And the second?", "Belém: the tower and the monastery, with pastéis de nata."},
        {"Is the weather usually good in March?",
         "Mild, around 17 degrees, with some rain; a light jacket helps."},
        {"Remind me of the whole plan later.",
         "I will keep every detail: dates, hotel, diet, budget and flight."}
      ]
    },
    %{
      name: "code review",
      facts: [
        "lib/billing/invoice.ex",
        "round_half_even",
        "issue 4821",
        "Priya",
        "release 2.9",
        "PostgreSQL 16"
      ],
      turns: [
        {"We have a rounding bug in lib/billing/invoice.ex.",
         "In lib/billing/invoice.ex, which function?"},
        {"The totals use round_half_even but the tests expect half-up.",
         "So round_half_even versus half-up in the totals."},
        {"It is tracked as issue 4821.", "Issue 4821, noted."},
        {"Priya owns the billing module, loop her in.",
         "I will keep Priya in the loop as the owner."},
        {"It has to ship in release 2.9.", "Release 2.9 is the target."},
        {"We run PostgreSQL 16 in production, if that matters.",
         "PostgreSQL 16; the numeric type behaves the same."},
        {"What is the safest fix?",
         "Keep round_half_even and fix the tests, or switch to half-up everywhere; the first is smaller."},
        {"Draft the commit message.",
         "fix(billing): totals round half-even consistently; closes issue 4821."},
        {"Who reviews?", "Priya, as the module owner."},
        {"Summarise for the standup.",
         "Rounding bug in invoice.ex, issue 4821, fix in 2.9, Priya reviews."}
      ]
    },
    %{
      name: "home network",
      facts: ["192.168.4.1", "Unifi", "Mira", "port 51820", "WireGuard", "every Sunday at 03:00"],
      turns: [
        {"My router is at 192.168.4.1.", "The router at 192.168.4.1; what brand?"},
        {"It is a Unifi gateway.", "A Unifi gateway, so the controller manages it."},
        {"The NAS is called Mira.", "Mira, the NAS; noted."},
        {"I opened port 51820 for WireGuard.", "Port 51820 for WireGuard, the VPN."},
        {"Backups run every Sunday at 03:00.", "Every Sunday at 03:00, the backup job."},
        {"Should I change the DNS?",
         "Point the clients at the gateway and let it forward; nothing else needed."},
        {"Is the VPN port safe to leave open?",
         "WireGuard on 51820 is fine to expose; it does not answer unauthenticated packets."},
        {"How do I check Mira's disks?",
         "The NAS dashboard shows SMART data; look for reallocated sectors."},
        {"Remind me what is open on the firewall.", "Only 51820 for WireGuard."},
        {"Recap the whole setup.",
         "Gateway 192.168.4.1 (Unifi), NAS Mira, WireGuard on 51820, backups Sunday 03:00."}
      ]
    }
  ]

  test "at least 90 % of the tracked facts survive compaction across the three conversations" do
    rows =
      for conv <- @conversations do
        session = Factory.session!()

        for {u, a} <- conv.turns do
          Factory.message!(session.id, %{role: "user", content: u})
          Factory.message!(session.id, %{role: "assistant", content: a})
        end

        history = Sessions.history(session.id)
        # Keep only the last two rows verbatim so the facts must come through the summary.
        {:ok, attrs} = Compactor.compact(session.id, history, keep: 2, model: model())
        text = attrs.content

        survived =
          Enum.filter(conv.facts, &String.contains?(String.downcase(text), String.downcase(&1)))

        estimate =
          Tokens.estimate(
            Request.new!(%{
              system: "",
              messages: Enum.map(history, &%{role: &1.role, content: &1.content}),
              tools: [],
              model: nil,
              params: %{}
            })
          )

        %{
          name: conv.name,
          tracked: length(conv.facts),
          survived: length(survived),
          missing: conv.facts -- survived,
          estimate: estimate,
          summary_bytes: byte_size(text)
        }
      end

    tracked = Enum.sum(Enum.map(rows, & &1.tracked))
    survived = Enum.sum(Enum.map(rows, & &1.survived))
    ratio = survived / tracked
    provider = Trinity.LLM.Registry.lookup(model()) |> elem(1) |> Map.get(:id)
    usage = last_usage()

    table =
      [
        "# Compaction eval, #{Date.utc_today()}",
        "",
        "Model: `#{provider}`. Keep: 2 rows verbatim; everything earlier summarised. Fact survival is a case-insensitive substring search of the compaction text.",
        "",
        "| conversation | facts tracked | survived | ratio | missing | estimate (tokens) | summary bytes |",
        "|---|---|---|---|---|---|---|"
      ] ++
        Enum.map(rows, fn r ->
          "| #{r.name} | #{r.tracked} | #{r.survived} | #{Float.round(r.survived / r.tracked, 2)} | #{Enum.join(r.missing, ", ")} | #{r.estimate} | #{r.summary_bytes} |"
        end) ++
        [
          "| **all** | #{tracked} | #{survived} | **#{Float.round(ratio, 3)}** | | | |",
          "",
          usage_line(usage, rows)
        ]

    File.mkdir_p!(@proof_dir)
    path = Path.join(@proof_dir, "eval-#{Date.utc_today()}.md")
    File.write!(path, Enum.join(table, "\n") <> "\n")
    IO.puts("\n" <> Enum.join(table, "\n") <> "\nwritten to #{path}")

    if System.get_env("TRINITY_LIVE") == "1" do
      assert ratio >= 0.9, "#{survived} of #{tracked} facts survived (#{Float.round(ratio, 3)})"
    else
      assert ratio == 0.0,
             "the fake answers \"fake\": a survival above zero means the harness read something else"
    end
  end

  # The provider's own input count for the last object call, from the usage_events row.
  defp last_usage do
    import Ecto.Query
    Trinity.Repo.one(from u in Trinity.LLM.Usage, order_by: [desc: u.inserted_at], limit: 1)
  rescue
    _ -> nil
  end

  defp usage_line(nil, _rows), do: "Token calibration: no usage row (the provider reported none)."

  defp usage_line(usage, rows) do
    input = usage.input_tokens || 0
    last = List.last(rows)

    "Token calibration on the last compaction call: the provider counted #{input} input tokens for a transcript this harness estimated at #{last.estimate} (the estimate excludes the compaction instructions, so the provider's count is expected to be higher by roughly 120 tokens)."
  end
end

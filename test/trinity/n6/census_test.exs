# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.N6.CensusTest do
  @moduledoc """
  Slice 138, AC9: every place in `lib/` that hashes or signs, classified.

  The rule `Trinity.N6` serves has two halves: what this tree constructs and signs is N6, and bytes
  someone else produced are hashed exactly as received. This census holds every call site that
  could break either half, so a new one cannot arrive unread. The population is derived from the
  tree: every `.ex` file under `lib/`, scanned for the calls in `@calls`. A file whose count differs
  from its row, or a file with no row, fails here by name.

  Classes:

    * `:n6` - this boundary;
    * `:exact_bytes` - bytes hashed exactly as read or received;
    * `:identifier` - a local identifier, key derivation or comparison, not a statement and not a
      reference to someone else's bytes;
    * `:protocol` - a format an external protocol fixes (PKCE S256, an OAuth access token's JWS);
    * `:local_artifact` - a digest of this tree's own build output;
    * `:in_memory` - within one run, never written or signed;
    * `:test_double` - a fake used by the suite;
    * `:legacy_signed` - receipts and checkpoints as they are signed today (DSSE's
      pre-authentication encoding over RFC 8785 JSON, SHA-256 chains), which move to N6 with the
      receipts slice and the per-box log;
    * `:reserialized` - foreign data re-encoded before it is hashed, which the rule forbids. Each
      is declared here with what it would take to hash the exact bytes instead; none changes in
      this slice.
  """

  use ExUnit.Case, async: true

  @calls ~r/:crypto\.(hash|hash_init|sign|verify|mac|mac_init)\(|Jcs\.encode\(|JOSE\.JWS\.sign\(|Envelope\.pae\(/

  # path => {calls in that file, class, why}
  @census %{
    "lib/trinity/n6/cose.ex" => {3, :n6, "thumbprint, ML-DSA-87 sign and verify"},
    "lib/trinity/n6/digest.ex" => {1, :n6, "SHA-384 over foreign bytes exactly as given"},
    "lib/trinity/archive.ex" => {1, :exact_bytes, "the archive file's bytes"},
    "lib/mix/tasks/trinity.image.inspect.ex" => {2, :exact_bytes, "image layer and file bytes"},
    "lib/trinity/skills/parser.ex" => {1, :exact_bytes, "a skill file's bytes"},
    "lib/trinity/skills/staging.ex" => {1, :exact_bytes, "staged skill files' bytes"},
    "lib/trinity_web/controllers/auth_controller.ex" =>
      {2, :identifier, "constant-time comparison of a token's digest"},
    "lib/trinity/keys/local.ex" => {2, :identifier, "a key id and HKDF expansion"},
    "lib/mix/tasks/trinity.names.ex" =>
      {1, :identifier, "salted digests of names the check refuses"},
    "lib/trinity/content/part.ex" => {1, :identifier, "a message part's identity"},
    "lib/trinity/mcp/auth/client/store.ex" => {1, :identifier, "a storage key"},
    "lib/trinity/memory/observer.ex" => {1, :identifier, "a memory entry's key suffix"},
    "lib/trinity/tools/fs.ex" => {1, :identifier, "a path's identity"},
    "lib/trinity/mcp/auth/embedded.ex" =>
      {2, :protocol, "PKCE S256 (RFC 7636) and the access token's JWS"},
    "lib/trinity/mcp/auth/client.ex" => {1, :protocol, "PKCE S256 (RFC 7636)"},
    "lib/trinity/core_policy.ex" => {1, :local_artifact, "the policy modules' stripped beams"},
    "lib/mix/tasks/trinity.effects.catalog.ex" => {1, :local_artifact, "the generated catalogue"},
    "lib/trinity/tools/registry.ex" => {1, :in_memory, "term_to_binary digest within one run"},
    "lib/trinity/memory/embedders/fake.ex" => {1, :test_double, "the fake embedder's vectors"},
    "lib/trinity/receipts/envelope.ex" =>
      {2, :legacy_signed, "RFC 8785 body and SHA-256 chain hash"},
    "lib/trinity/receipts/chain_writer.ex" =>
      {6, :legacy_signed, "DSSE PAE for receipts and checkpoints"},
    "lib/trinity/receipts/verifier.ex" => {2, :legacy_signed, "DSSE PAE, verified"},
    "lib/trinity/receipts/merkle.ex" => {3, :legacy_signed, "the checkpoint tree, SHA-256"},
    "lib/trinity/receipts/signer.ex" => {1, :legacy_signed, "RFC 7638 key id"},
    "lib/trinity/receipts/key_custody.ex" =>
      {5, :legacy_signed, "receipt key ids and fingerprints"},
    "lib/trinity/receipts/signer/ed25519.ex" => {2, :legacy_signed, "Ed25519 sign and verify"},
    "lib/trinity/receipts/signer/p384.ex" => {2, :legacy_signed, "ECDSA P-384 sign and verify"},
    "lib/trinity/receipts/signer/mldsa87.ex" => {2, :legacy_signed, "ML-DSA-87 sign and verify"},
    "lib/trinity/tools/definition_digest.ex" =>
      {2, :reserialized,
       "a server's tool listing, rebuilt as RFC 8785 JSON; the exact bytes are the listing response, which the MCP client layer does not expose"},
    "lib/trinity/permissions/fingerprint.ex" =>
      {2, :reserialized,
       "the model's call arguments as RFC 8785 JSON; they can hold floats, so the exact bytes of the call are the candidate"},
    "lib/trinity/mcp/server/envelope.ex" =>
      {1, :reserialized,
       "a client's call arguments re-encoded with sorted keys; the exact request bytes are the candidate"},
    "lib/trinity/effects.ex" =>
      {1, :reserialized,
       "tool output: exact for a binary, `inspect/1` otherwise, which is not stable across Elixir versions"}
  }

  @classes ~w(n6 exact_bytes identifier protocol local_artifact in_memory test_double legacy_signed reserialized)a

  test "every hashing and signing call in lib/ is in the census, with its count and a class" do
    found =
      for path <- Path.wildcard("lib/**/*.ex"),
          count = length(Regex.scan(@calls, File.read!(path))),
          count > 0,
          into: %{},
          do: {path, count}

    expected = Map.new(@census, fn {path, {count, _class, _why}} -> {path, count} end)

    unclassified =
      for {path, n} <- found, Map.get(expected, path) != n, do: "#{path}: #{n} call(s)"

    gone =
      for {path, n} <- expected,
          not is_map_key(found, path),
          do: "#{path}: row for #{n}, none found"

    assert unclassified == [],
           "calls the census does not hold:\n" <> Enum.join(unclassified, "\n")

    assert gone == [], "rows with no calls left:\n" <> Enum.join(gone, "\n")
  end

  test "every row names a known class and says why" do
    for {path, {_count, class, why}} <- @census do
      assert class in @classes, "#{path}: unknown class #{inspect(class)}"
      assert is_binary(why) and why != "", "#{path}: no reason given"
    end
  end
end

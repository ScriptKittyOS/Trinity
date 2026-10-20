# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.N6.EC2 do
  @moduledoc """
  ESP384 (-51) keys and signatures under N6 (slice 140): ECDSA on P-384 with SHA-384, RFC 9864's
  fully specified identifier, admitted on the `commercial` profile for FIPS-mode nodes (the
  publisher's Decision of 2026-10-20, point 1).

  ## The key

  A public key is the uncompressed point `0x04 || x || y`, 97 bytes, as `:crypto` returns it. A
  compressed point, another curve, or a point not on P-384 is refused (`key_invalid`, this tree's
  code: the Decision says the verifier checks the key type, the curve and the point, and names no
  code for it).

  The `kid` is SHA-384 of the RFC 9679 thumbprint input over the EC2 required members
  `{1: 2, -1: 2, -2: x, -3: y}` (EC2 and P-384 are 2 and 2 in RFC 9053 section 7.1), encoded under
  RFC 8949 section 4.2.1 directly, so exactly the 107 bytes
  `a4 01 02 20 02 21 58 30 || x || 22 58 30 || y`. `x` and `y` are always 48 bytes, left-padded
  with zeros: a coordinate with a leading zero byte keeps it, or about one key in 128 would get
  another `kid`.

  ## The signature

  The 96-byte `r || s` of RFC 9053 section 2.1, each half 48 bytes. `:crypto` signs and verifies
  DER (`ECDSA-Sig-Value`, RFC 3279), so `from_der/1` and `to_der/1` convert. A signature that is not
  exactly 96 bytes is `signature_encoding`; no DER is ever parsed from a statement. Both `s` and
  `n - s` verify, as OpenSSL accepts both: a verifier that enforced low-s would split verdicts with
  every other.
  """

  @p 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEFFFFFFFF0000000000000000FFFFFFFF
  @b 0xB3312FA7E23EE7E4988E056BE3F82D19181D9C6EFE8141120314088F5013875AC656398D8A2ED19D2A85C8EDD3EC2AEF

  @doc "The P-384 group order `n`."
  @spec order() :: pos_integer()
  def order,
    do:
      0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFC7634D81F4372DDF581A0DB248B0A77AECEC196ACCC52973

  @doc "Whether bytes are an uncompressed P-384 point on the curve."
  @spec valid_key?(binary()) :: boolean()
  def valid_key?(<<4, x::unsigned-size(384), y::unsigned-size(384)>>) when x < @p and y < @p,
    do: rem(y * y - (x * x * x - 3 * x + @b), @p) == 0

  def valid_key?(_other), do: false

  @doc "The RFC 9679 SHA-384 thumbprint of a P-384 public key: its `kid`."
  @spec thumbprint(binary()) :: binary()
  def thumbprint(<<4, x::binary-size(48), y::binary-size(48)>>),
    do: :crypto.hash(:sha384, thumbprint_input(x, y))

  @doc "The 107 bytes the thumbprint hashes."
  @spec thumbprint_input(binary(), binary()) :: binary()
  def thumbprint_input(x, y) when byte_size(x) == 48 and byte_size(y) == 48,
    do: <<0xA4, 0x01, 0x02, 0x20, 0x02, 0x21, 0x58, 0x30>> <> x <> <<0x22, 0x58, 0x30>> <> y

  @doc "The 96-byte `r || s` of a DER `ECDSA-Sig-Value`."
  @spec from_der(binary()) :: {:ok, binary()} | :error
  def from_der(<<0x30, len, rest::binary>>) when byte_size(rest) == len do
    with {:ok, r, rest} <- der_integer(rest),
         {:ok, s, ""} <- der_integer(rest),
         true <- r < 2 ** 384 and s < 2 ** 384 do
      {:ok, <<r::unsigned-size(384), s::unsigned-size(384)>>}
    else
      _ -> :error
    end
  end

  def from_der(_other), do: :error

  @doc "The DER `ECDSA-Sig-Value` for a 96-byte `r || s`."
  @spec to_der(binary()) :: binary()
  def to_der(<<r::unsigned-size(384), s::unsigned-size(384)>>) do
    body = der_integer_bytes(r) <> der_integer_bytes(s)
    <<0x30, byte_size(body)>> <> body
  end

  # Short-form lengths only: two P-384 integers are at most 49 bytes each, so the sequence is at most
  # 102 bytes and every length is below 128.
  defp der_integer(<<0x02, len, bytes::binary-size(len), rest::binary>>) when len in 1..49,
    do: {:ok, :binary.decode_unsigned(bytes), rest}

  defp der_integer(_other), do: :error

  defp der_integer_bytes(n) do
    bytes = :binary.encode_unsigned(n)
    bytes = if :binary.first(bytes) >= 0x80, do: <<0>> <> bytes, else: bytes
    <<0x02, byte_size(bytes)>> <> bytes
  end

  @doc "`r || s` with `s` replaced by `n - s`: the other signature that verifies the same bytes."
  @spec negate_s(binary()) :: binary()
  def negate_s(<<r::binary-size(48), s::unsigned-size(384)>>),
    do: r <> <<order() - s::unsigned-size(384)>>
end

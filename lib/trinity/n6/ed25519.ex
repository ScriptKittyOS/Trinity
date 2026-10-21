# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.N6.Ed25519 do
  @moduledoc """
  Ed25519 points as the N6 profile reads them: the strict decoding of RFC 8032 section 5.1.3
  (draft v0.1-r7 section 5.2, K2; slice 142), and the publisher's verification rule (r7 section 5.3,
  decided 2026-10-21; slice 144), which `:crypto` does not apply. Measured on OpenSSL 3.0.13 and
  3.5.9: the identity key with R the identity and S = 0 verifies for every message; a key whose y
  is not below p is accepted; R the identity, made by the key's holder, verifies.

    * A key is valid when it decodes strictly, is not the identity, and [L]A is the identity: full
      public key validation (NIST SP 800-186 D.1.3.2). It refuses every small-order and mixed-order
      point and never a key RFC 8032 key generation made.
    * A signature's R must decode strictly and not be of small order ([8]R not the identity), and
      its S must be below L. The equation itself, cofactorless, stays `:crypto`'s.

  A 32-byte string decodes when y, its low 255 bits, is below p; x, recovered from y, exists; and x
  is not 0 with the sign bit set. Only public values pass through here, so the arithmetic needs no
  care for timing. Signing never uses this module.
  """

  import Bitwise

  @p (1 <<< 255) - 19
  # d = -121665 / 121666 mod p (RFC 8032 section 5.1).
  @d 37_095_705_934_669_439_343_138_083_508_754_565_189_542_113_879_843_219_016_388_785_533_085_940_283_555
  # sqrt(-1) mod p, 2^((p - 1) / 4).
  @sqrt_m1 19_681_161_376_707_505_956_807_079_304_988_542_015_446_066_515_923_890_162_744_021_073_123_829_784_752

  # L, the order of the base point (RFC 8032 section 5.1).
  @l (1 <<< 252) + 27_742_317_777_372_353_535_851_937_790_883_648_493

  @typedoc "A point in affine coordinates."
  @type point :: {non_neg_integer(), non_neg_integer()}

  @doc """
  Whether 32 bytes are a public key the profile accepts (r7 section 5.3, the key rule). The [L]A
  check costs about half a millisecond, and a receipt chain verifies every row under one key, so
  a key found valid is remembered in the calling process; one found invalid is checked again.
  """
  @spec valid_key?(binary()) :: boolean()
  def valid_key?(bytes) when is_binary(bytes) do
    memo = {__MODULE__, :valid_key, bytes}

    if Process.get(memo) do
      true
    else
      valid = validate_key(bytes)
      if valid, do: Process.put(memo, true)
      valid
    end
  end

  defp validate_key(bytes) do
    case decode(bytes) do
      {:ok, a} -> not identity?(extended(a)) and identity?(multiply(@l, extended(a)))
      :error -> false
    end
  end

  @doc """
  Whether a 64-byte signature's R and S pass the profile's checks before the equation: R decodes
  strictly and is not of small order, and S is below L.
  """
  @spec valid_r_and_s?(binary()) :: boolean()
  def valid_r_and_s?(<<r::binary-32, s::little-256>>) when s < @l do
    case decode(r) do
      {:ok, point} -> not identity?(multiply(8, extended(point)))
      :error -> false
    end
  end

  def valid_r_and_s?(_signature), do: false

  @doc "Strictly decodes a 32-byte encoding of a point (RFC 8032 section 5.1.3)."
  @spec decode(binary()) :: {:ok, point()} | :error
  def decode(<<_::binary-32>> = bytes) do
    <<n::little-256>> = bytes
    sign = n >>> 255
    y = n &&& (1 <<< 255) - 1
    if y >= @p, do: :error, else: recover_x(y, sign)
  end

  def decode(_bytes), do: :error

  defp recover_x(y, sign) do
    u = mod(y * y - 1)
    v = mod(@d * y * y + 1)
    x = mod(u * pow(v, 3) * pow(mod(u * pow(v, 7)), div(@p - 5, 8)))
    vx2 = mod(v * x * x)

    x =
      cond do
        vx2 == u -> x
        vx2 == mod(-u) -> mod(x * @sqrt_m1)
        true -> nil
      end

    cond do
      x == nil -> :error
      x == 0 and sign == 1 -> :error
      (x &&& 1) != sign -> {:ok, {@p - x, y}}
      true -> {:ok, {x, y}}
    end
  end

  # Extended coordinates (X, Y, Z, T), x = X/Z, y = Y/Z, xy = T/Z; the addition of RFC 8032
  # section 5.1.4, which also doubles.
  defp extended({x, y}), do: {x, y, 1, mod(x * y)}

  defp add({x1, y1, z1, t1}, {x2, y2, z2, t2}) do
    a = mod((y1 - x1) * (y2 - x2))
    b = mod((y1 + x1) * (y2 + x2))
    c = mod(2 * @d * t1 * t2)
    d = mod(2 * z1 * z2)
    {e, f, g, h} = {b - a, d - c, d + c, b + a}
    {mod(e * f), mod(g * h), mod(f * g), mod(e * h)}
  end

  defp multiply(k, point), do: multiply(k, point, {0, 1, 1, 0})
  defp multiply(0, _point, acc), do: acc

  defp multiply(k, point, acc) do
    acc = if (k &&& 1) == 1, do: add(acc, point), else: acc
    multiply(k >>> 1, add(point, point), acc)
  end

  defp identity?({x, y, z, _t}), do: mod(x) == 0 and mod(y - z) == 0

  defp mod(n), do: Integer.mod(n, @p)
  defp pow(b, e), do: :crypto.mod_pow(b, e, @p) |> :binary.decode_unsigned()
end

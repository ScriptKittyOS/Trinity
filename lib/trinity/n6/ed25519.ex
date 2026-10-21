# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.N6.Ed25519 do
  @moduledoc """
  Ed25519 points as the N6 profile reads them (draft v0.1-r7 section 5.2, K2; slice 142): the
  strict decoding of RFC 8032 section 5.1.3, which `:crypto` does not apply (measured on OpenSSL
  3.0.13 and 3.5.9: a key whose y is not below p is accepted).

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

  @typedoc "A point in affine coordinates."
  @type point :: {non_neg_integer(), non_neg_integer()}

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

  defp mod(n), do: Integer.mod(n, @p)
  defp pow(b, e), do: :crypto.mod_pow(b, e, @p) |> :binary.decode_unsigned()
end

# SPDX-FileCopyrightText: Sudo Apt Holdings LLC
# SPDX-License-Identifier: Apache-2.0
defmodule Trinity.Gateways.Telegram.Media do
  @moduledoc """
  Images that arrive in a Telegram message (slice 071): a photo, or a file sent as a document whose
  type is an image.

  `attachments/1` reads nothing from Telegram. It answers what the message carries as attachments
  the router can fetch, each with a `fetch` function, and the router calls it only after the sender
  has been admitted and is inside the rate limit (`Trinity.Gateways.Router`). So a stranger's photo
  is never downloaded: docs/07 says nothing of an unknown sender's message is read but the code it
  might be, and a file on disk is a lot more than a code.

  A fetched image is stored at `<state dir>/media/<sha256>.<ext>`, named by its digest so the same
  image sent twice is one file. It is refused when Telegram says it is larger than the limit
  (`config :trinity, :telegram, max_image_bytes:`, 10 MB by default), when more bytes than that
  arrive, and when its first bytes are not the image format it claims to be: the bytes are handed
  to a model as an image, so they have to be one.
  """

  alias Trinity.Gateways.Telegram
  alias Trinity.Gateways.Telegram.Client

  # Sobelow reads `@sobelow_skip` from the source; the compiler would call it unused otherwise.
  Module.register_attribute(__MODULE__, :sobelow_skip, persist: true)

  @image_types %{
    "image/jpeg" => "jpg",
    "image/png" => "png",
    "image/webp" => "webp",
    "image/gif" => "gif"
  }

  @typedoc "An attachment as the router receives it."
  @type attachment :: %{
          kind: :image,
          media_type: String.t(),
          fetch: (-> {:ok, map()} | {:error, term()})
        }

  @doc "The images a message carries, as attachments to fetch later. Nothing is downloaded here."
  @spec attachments(map()) :: [attachment()]
  def attachments(%{"photo" => [_ | _] = sizes}) do
    max = Telegram.max_image_bytes()

    # Telegram lists a photo's sizes smallest first; the largest that fits is the one worth
    # reading. A size with no reported file_size is taken on trust and checked on arrival.
    size =
      sizes
      |> Enum.filter(&(Map.get(&1, "file_size", 0) <= max))
      |> List.last()

    case size do
      %{"file_id" => file_id} -> [attachment(file_id, "image/jpeg")]
      _ -> [too_large(List.last(sizes))]
    end
  end

  def attachments(%{"document" => %{"file_id" => file_id, "mime_type" => type} = doc})
      when is_map_key(@image_types, type) do
    if Map.get(doc, "file_size", 0) <= Telegram.max_image_bytes(),
      do: [attachment(file_id, type)],
      else: [too_large(doc)]
  end

  def attachments(_message), do: []

  defp attachment(file_id, media_type),
    do: %{kind: :image, media_type: media_type, fetch: fn -> fetch(file_id, media_type) end}

  defp too_large(size) do
    bytes = Map.get(size || %{}, "file_size", 0)
    %{kind: :image, media_type: "image/jpeg", fetch: fn -> {:error, {:too_large, bytes}} end}
  end

  @doc """
  Downloads an image Telegram holds, checks it, and stores it. Answers the image part a session
  row carries: its path, media type, digest, size and origin.
  """
  @spec fetch(String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def fetch(file_id, media_type) do
    max = Telegram.max_image_bytes()

    with {:ok, %{"file_path" => file_path} = file} <-
           Client.call("getFile", %{file_id: file_id}),
         :ok <- within(Map.get(file, "file_size", 0), max),
         {:ok, bytes} <- Client.download(file_path, max),
         :ok <- sniff(bytes, media_type) do
      store(bytes, media_type)
    else
      {:ok, _no_path} -> {:error, :no_file_path}
      {:error, _} = error -> error
    end
  end

  defp within(size, max) when is_integer(size) and size > max, do: {:error, {:too_large, size}}
  defp within(_size, _max), do: :ok

  # The first bytes of each format this accepts. A file whose bytes are not the format it claims
  # is not handed to a model as an image.
  defp sniff(<<0xFF, 0xD8, 0xFF, _::binary>>, "image/jpeg"), do: :ok
  defp sniff(<<0x89, "PNG", 0x0D, 0x0A, 0x1A, 0x0A, _::binary>>, "image/png"), do: :ok
  defp sniff(<<"RIFF", _size::binary-size(4), "WEBP", _::binary>>, "image/webp"), do: :ok
  defp sniff(<<"GIF8", _::binary>>, "image/gif"), do: :ok
  defp sniff(_bytes, media_type), do: {:error, {:not_an_image, media_type}}

  # sobelow_skip reason: Traversal.FileModule: the directory is `Telegram.state_dir/0` plus a
  # constant, and the file name is the SHA-256 of the bytes in hex and an extension from a fixed
  # map; nothing the sender chose (a file name, a caption, Telegram's `file_path`) is in the path.
  @sobelow_skip ["Traversal.FileModule"]
  defp store(bytes, media_type) do
    hex = :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
    dir = Path.join(Telegram.state_dir(), "media")
    path = Path.join(dir, hex <> "." <> Map.fetch!(@image_types, media_type))
    File.mkdir_p!(dir)
    unless File.exists?(path), do: File.write!(path, bytes)

    {:ok,
     %{
       "path" => path,
       "media_type" => media_type,
       "digest" => "sha256:" <> hex,
       "bytes" => byte_size(bytes),
       "origin" => "gateway:telegram"
     }}
  end
end

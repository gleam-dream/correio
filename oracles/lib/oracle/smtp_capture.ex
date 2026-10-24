defmodule Oracle.SmtpCapture do
  @moduledoc "Loopback-only SMTP peer observing the real Swoosh adapter envelope and MIME."

  def deliver(email) do
    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, active: false, packet: :line, ip: {127, 0, 0, 1}])

    {:ok, {_, port}} = :inet.sockname(listener)

    task =
      Task.async(fn ->
        {:ok, socket} = :gen_tcp.accept(listener, 5_000)
        :gen_tcp.close(listener)

        try do
          :ok = :gen_tcp.send(socket, "220 oracle.local ESMTP\r\n")
          commands(socket, nil, [], nil)
        after
          :gen_tcp.close(socket)
        end
      end)

    {:ok, _receipt} =
      Swoosh.Adapters.SMTP.deliver(email,
        relay: "127.0.0.1",
        port: port,
        tls: :never,
        auth: :never,
        no_mx_lookups: true,
        retries: 0,
        timeout: 5_000
      )

    Task.await(task, 5_000)
  end

  defp commands(socket, sender, recipients, raw) do
    case :gen_tcp.recv(socket, 0, 5_000) do
      {:ok, "EHLO " <> _} ->
        :ok = :gen_tcp.send(socket, "250 oracle.local\r\n")
        commands(socket, sender, recipients, raw)

      {:ok, "MAIL FROM:" <> value} ->
        :ok = :gen_tcp.send(socket, "250 accepted\r\n")
        commands(socket, mailbox(value), recipients, raw)

      {:ok, "RCPT TO:" <> value} ->
        :ok = :gen_tcp.send(socket, "250 accepted\r\n")
        commands(socket, sender, [mailbox(value) | recipients], raw)

      {:ok, "DATA\r\n"} ->
        :ok = :gen_tcp.send(socket, "354 send body\r\n")
        raw = body(socket, [])
        :ok = :gen_tcp.send(socket, "250 local-receipt\r\n")
        commands(socket, sender, recipients, raw)

      {:ok, "QUIT\r\n"} ->
        observation(sender, recipients, raw)

      {:error, :closed} when is_binary(raw) ->
        observation(sender, recipients, raw)

      other ->
        raise "unexpected SMTP oracle exchange: #{inspect(other)}"
    end
  end

  defp body(socket, lines) do
    case :gen_tcp.recv(socket, 0, 5_000) do
      {:ok, ".\r\n"} ->
        # Pinned gen_smtp appends CRLF before its dot terminator regardless of
        # the MIME body's ending. Remove that one framing CRLF, not authored
        # whitespace, to compare the renderer's bytes with Correio's renderer.
        framed = lines |> Enum.reverse() |> IO.iodata_to_binary()
        content_size = byte_size(framed) - 2
        <<content::binary-size(content_size), "\r\n">> = framed
        content

      {:ok, ".." <> rest} ->
        body(socket, ["." <> rest | lines])

      {:ok, line} ->
        body(socket, [line | lines])

      other ->
        raise "incomplete SMTP oracle DATA: #{inspect(other)}"
    end
  end

  defp mailbox(value),
    do: value |> String.trim() |> String.trim_leading("<") |> String.trim_trailing(">")

  defp observation(sender, recipients, raw) do
    %{
      raw_base64: Base.encode64(raw),
      envelope: %{sender: sender, recipients: Enum.reverse(recipients)}
    }
  end
end

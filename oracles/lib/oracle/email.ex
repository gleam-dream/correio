defmodule Oracle.Email do
  @moduledoc "Swoosh message construction and its real SMTP MIME renderer."

  def run(fixtures) do
    Map.new(fixtures, fn fixture ->
      {fixture["id"], fixture |> build() |> Oracle.SmtpCapture.deliver()}
    end)
  end

  defp build(fixture) do
    email =
      Swoosh.Email.new()
      |> Swoosh.Email.from(address(fixture["from"]))
      |> Swoosh.Email.to(Enum.map(fixture["to"], &address/1))
      |> Swoosh.Email.cc(Enum.map(Map.get(fixture, "cc", []), &address/1))
      |> Swoosh.Email.bcc(Enum.map(Map.get(fixture, "bcc", []), &address/1))
      |> Swoosh.Email.subject(fixture["subject"])
      |> Swoosh.Email.text_body(fixture["text"])
      |> Swoosh.Email.html_body(fixture["html"])

    email =
      case fixture["reply_to"] do
        nil -> email
        value -> Swoosh.Email.reply_to(email, address(value))
      end

    email =
      Enum.reduce(Map.get(fixture, "headers", %{}), email, fn {key, value}, email ->
        Swoosh.Email.header(email, key, value)
      end)

    Enum.reduce(Map.get(fixture, "attachments", []), email, fn item, email ->
      attachment = %Swoosh.Attachment{
        filename: item["filename"],
        content_type: item["content_type"],
        data: Base.decode64!(item["body_base64"]),
        type: if(item["disposition"] == "inline", do: :inline, else: :attachment),
        cid: item["cid"],
        headers: []
      }

      Swoosh.Email.attachment(email, attachment)
    end)
  end

  defp address(value), do: {Map.get(value, "name", ""), value["address"]}
end

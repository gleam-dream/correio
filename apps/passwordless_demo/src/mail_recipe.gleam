import correio/address
import correio/capture
import correio/delivery
import correio/message
import correio/smtp
import gleam/result

type Customer {
  Customer(id: Int, address: address.Address)
}

fn greeting(
  customer: Customer,
  sender: address.Address,
) -> Result(message.Message, message.MessageError) {
  message.new(
    sender,
    customer.address,
    "Your order",
    message.Alternative(
      "Your order is ready.",
      "<p>Your order is ready.</p><img src=\"cid:logo\">",
    ),
  )
}

pub fn exercise() -> Nil {
  let assert Ok(from) =
    address.parse("hello@example.com")
    |> result.try(address.named(_, "Correio Store"))
  let assert Ok(to) = address.parse("customer@example.com")
  let customer = Customer(42, to)
  let assert Ok(mail) = greeting(customer, from)
  let assert Ok(bounce) = address.parse("bounces@example.com")
  let assert Ok(logo) =
    message.attachment(
      "logo.png",
      "image/png",
      <<0, 1, 2, 255>>,
      message.Inline("logo"),
    )
  let mail = mail |> message.set_envelope_sender(bounce) |> message.attach(logo)
  let assert Ok(box) = capture.start(1)
  let sender: delivery.Sender = capture.sender(box)
  let assert delivery.Accepted(_) = sender(mail)
  let assert delivery.NotSent(delivery.CapacityReached) = sender(mail)
  let assert Ok(Nil) = capture.clear(box)
  let assert delivery.Accepted(_) = sender(mail)
  let assert Ok(Nil) = capture.stop(box)
  let assert Ok(config) =
    smtp.starttls("smtp.example.com", 587) |> result.try(smtp.deadline(_, 5000))
  let _sender: delivery.Sender = smtp.sender(config)
  Nil
}

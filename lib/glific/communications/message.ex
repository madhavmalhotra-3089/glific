defmodule Glific.Communications.Message do
  alias Glific.Messages
  alias Glific.Messages.Message
  alias Glific.Contacts

  defmacro __using__(_opts \\ []) do
    quote do
    end
  end

  def send_message(%Message{type: :text} = message) do
    message
    |> send_text()
  end

  def send_message(message) do
    message
    |> send_media()
  end

  defp send_text(message) do
    provider_module()
    |> apply(:send_text, [message])
  end

  defp send_media(message) do
    case message.type do
      :image ->
        provider_module()
        |> apply(:send_image, [message])

      :audio ->
        provider_module()
        |> apply(:send_audio, [message])

      :video ->
        provider_module()
        |> apply(:send_video, [message])

      :document ->
        provider_module()
        |> apply(:send_document, [message])
    end
  end

  def receive_text(message_params) do
    contact = Contacts.upsert(message_params.sender)

    message_params
    |> Map.merge(%{
      type: :text,
      sender_id: contact.id,
      recipient_id: get_recipient_id_for_inbound()
    })
    |> Messages.create_message()
    |> publish_message()
  end

  def receive_media(message_params) do
    contact = Contacts.upsert(message_params.sender)
    {:ok, message_media} = Messages.create_message_media(message_params)

    message_params
    |> Map.merge(%{
      sender_id: contact.id,
      media_id: message_media.id,
      recipient_id: get_recipient_id_for_inbound()
    })
    |> Messages.create_message()
    |> publish_message()
  end

  defp publish_message({:ok, message}) do
    Absinthe.Subscription.publish(
      GlificWeb.Endpoint,
      message,
      received_message: "*")
    {:ok, message}
  end
  defp publish_message(err), do: err

  def provider_module() do
    provider = Glific.Communications.effective_provider()
    String.to_existing_atom(to_string(provider) <> ".Message")
  end

  def organisation_contact() do
    Glific.Communications.organisation_contact()
  end

  def get_recipient_id_for_inbound() do
    # TODO: Make this dynamic
    1
  end
end

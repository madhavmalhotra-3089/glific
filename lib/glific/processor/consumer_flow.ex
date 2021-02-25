defmodule Glific.Processor.ConsumerFlow do
  @moduledoc """
  Given a message, run it thru the flow engine. This is an auxilary module to help
  consumer_worker which is the main workhorse
  """

  import Ecto.Query, warn: false

  alias Glific.{
    Flows,
    Flows.FlowContext,
    Flows.Periodic,
    Messages,
    Messages.Message
  }

  @doc """
  Load the relevant state into the gen_server state object that we need
  to process messages
  """
  @spec load_state(non_neg_integer) :: map()
  def load_state(organization_id), do: %{flow_keywords: Flows.flow_keywords_map(organization_id)}

  @doc false
  @spec process_message({Message.t(), map()}, String.t()) :: {Message.t(), map()}
  def process_message({message, state}, body) do
    if should_skip_message?(message, state),
      do: {message, state},
      else: do_process_message({message, state}, body)
  end

  # Setting this to 0 since we are pushing out our own optin flow
  @delay_time 0

  @spec do_process_message({Message.t(), map()}, String.t()) :: {Message.t(), map()}
  defp do_process_message({message, state}, body) do
    # check if draft keyword, if so bypass ignore keywords
    # and start draft flow, issue #621
    is_beta = is_beta_keyword?(state, body)

    if is_beta,
      do: FlowContext.mark_flows_complete(message.contact_id)

    context = FlowContext.active_context(message.contact_id)

    # if contact is not optout if we are in a flow and the flow is set to ignore keywords
    # then send control to the flow directly
    # context is not nil
    if should_start_optin_flow?(message.contact, context, body) do
        start_optin_flow(message, state)

    else
        with false <- is_nil(context),
             {:ok, flow} <-
               Flows.get_cached_flow(
                 message.organization_id,
                 {:flow_uuid, context.flow_uuid, context.status}
               ),
             true <- flow.ignore_keywords do
          check_contexts(context, message, body, state)
        else
          _ ->
            cond do
              Map.get(state, :newcontact, false) &&
                  Map.has_key?(state.flow_keywords["published"], "newcontact") ->
                # delay new contact flows by 2 minutes to allow user to deal with signon link
                check_flows(message, "newcontact", state, is_beta: false, delay: @delay_time)

              Map.has_key?(state.flow_keywords["published"], body) ->
                check_flows(message, body, state, is_beta: false)

              is_beta ->
                check_flows(message, message.body, state, is_beta: true)

              true ->
                check_contexts(context, message, body, state)
            end
        end
    end
  end

  @beta_phrase "draft"
  @final_phrase "published"

  @spec is_beta_keyword?(map(), String.t()) :: boolean()
  defp is_beta_keyword?(_state, nil), do: false

  defp is_beta_keyword?(state, body) do
    if String.starts_with?(body, @beta_phrase) and
         Map.has_key?(
           state.flow_keywords["draft"],
           String.replace_leading(body, @beta_phrase, "")
         ),
       do: true,
       else: false
  end

  @doc """
  Start a flow or reactivate a flow if needed. This will be linked to the entire
  trigger mechanism once we have that under control.
  """
  @spec check_flows(atom() | Message.t(), String.t(), map(), Keyword.t()) :: {Message.t(), map()}
  def check_flows(message, body, state, opts \\ []) do
    is_beta = Keyword.get(opts, :is_beta, false)

    {status, body} =
      if is_beta do
        # lets complete all existing flows for this contact
        {@beta_phrase, String.replace_leading(body, @beta_phrase <> ":", "")}
      else
        {@final_phrase, body}
      end

    Flows.get_cached_flow(
      message.organization_id,
      {:flow_keyword, body, status}
    )
    |> case do
      {:ok, flow} ->
        FlowContext.init_context(flow, message.contact, status, opts)

      {:error, _} ->
        nil
    end

    {message, state}
  end

  @doc false
  @spec check_contexts(FlowContext.t() | nil, atom() | Message.t(), String.t(), map()) ::
          {Message.t(), map()}
  def check_contexts(nil = _context, message, _body, state) do
    # lets do the periodic flow routine and send those out
    # in a priority order
    state = Periodic.run_flows(state, message)
    {message, state}
  end

  def check_contexts(context, message, _body, state) do
    {:ok, flow} =
      Flows.get_cached_flow(
        message.organization_id,
        {:flow_uuid, context.flow_uuid, context.status}
      )

    {:ok, message} =
      message
      |> Messages.update_message(%{flow_id: context.flow_id})

    context
    |> Map.merge(%{last_message: message})
    |> FlowContext.load_context(flow)
    # we are using message.body here since we want to use the original message
    # not the stripped version
    # I'm not sure why we are creating a message here instead of reusing the existing
    # message. We'll switch this to using message in the next release (1.0.1)
    |> FlowContext.step_forward(
      Messages.create_temp_message(
        message.organization_id,
        message.body,
        type: message.type,
        id: message.id,
        media: message.media,
        media_id: message.media_id,
        location: message.location
      )
    )

    {message, state}
  end

  # if this is a new contact then we will allow to
  # process the message other wise system will check if
  # they opted in again and skip the flow
  @spec should_skip_message?(Message.t(), map()) :: boolean()
  defp should_skip_message?(message, state) do
    if Map.get(state, :newcontact, false) || is_nil(message.body),
      do: false,
      else: String.contains?(message.body, "Hi, I would like to receive notifications.")
  end

  @optin_flow_keyword "optin"
  ## check if contact is not in the optin flow and has optout time
  defp should_start_optin_flow?(contact, active_context, _body) do
    is_optin_flow =
      active_context.flow.keywords
      |> Enum.member?(@optin_flow_keyword)

    if is_optin_flow,
      do: false,
      else: !is_nil(contact.optout_time)
  end

  defp should_start_optin_flow?(contact, nil, _body) do
    if is_nil(contact.optout_time), do: true, else: false
  end

  defp start_optin_flow(message, state) do
    FlowContext.mark_flows_complete(message.contact_id)

    Flows.get_cached_flow(
      message.organization_id,
      {:flow_keyword, @optin_flow_keyword, @final_phrase}
    )
    |> case do
      {:ok, flow} ->
        FlowContext.init_context(flow, message.contact, @final_phrase, is_beta: false)

      {:error, _} ->
        nil
    end

    {message, state}
  end
end

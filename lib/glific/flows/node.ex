defmodule Glific.Flows.Node do
  @moduledoc """
  The Node object which encapsulates one node in a given flow
  """
  alias __MODULE__

  use Ecto.Schema

  alias Glific.{
    Flows,
    Messages.Message
  }

  alias Glific.Flows.{
    Action,
    Exit,
    Flow,
    FlowContext,
    FlowCount,
    Router
  }

  @required_fields [:uuid, :actions, :exits]

  @type t() :: %__MODULE__{
          uuid: Ecto.UUID.t() | nil,
          flow_uuid: Ecto.UUID.t() | nil,
          flow_id: Ecto.UUID.t() | nil,
          flow: Flow.t() | nil,
          actions: [Action.t()] | [],
          exits: [Exit.t()] | [],
          router: Router.t() | nil
        }

  embedded_schema do
    field :uuid, Ecto.UUID
    field :flow_id, Ecto.UUID
    field :flow_uuid, Ecto.UUID
    embeds_one :flow, Flow

    embeds_many :actions, Action
    embeds_many :exits, Exit
    embeds_one :router, Router
  end

  @doc """
  Process a json structure from floweditor to the Glific data types
  """
  @spec process(map(), map(), Flow.t()) :: {Node.t(), map()}
  def process(json, uuid_map, flow) do
    Flows.check_required_fields(json, @required_fields)

    node = %Node{
      uuid: json["uuid"],
      flow_uuid: flow.uuid,
      flow_id: flow.id
    }

    {actions, uuid_map} =
      Flows.build_flow_objects(
        json["actions"],
        uuid_map,
        &Action.process/3,
        node
      )

    node = Map.put(node, :actions, actions)

    {exits, uuid_map} =
      Flows.build_flow_objects(
        json["exits"],
        uuid_map,
        &Exit.process/3,
        node
      )

    node = Map.put(node, :exits, exits)

    {node, uuid_map} =
      if Map.has_key?(json, "router") do
        {router, uuid_map} = Router.process(json["router"], uuid_map, node)
        {Map.put(node, :router, router), uuid_map}
      else
        {node, uuid_map}
      end

    uuid_map = Map.put(uuid_map, node.uuid, {:node, node})
    {node, uuid_map}
  end

  @doc """
  Validate a node and all its children
  """
  @spec validate(Node.t(), Keyword.t(), map()) :: Keyword.t()
  def validate(node, errors, flow) do
    errors =
      node.actions
      |> Enum.reduce(
        errors,
        &Action.validate(&1, &2, flow)
      )

    errors =
      node.exits
      |> Enum.reduce(
        errors,
        &Exit.validate(&1, &2, flow)
      )

    if node.router,
      do: Router.validate(node.router, errors, flow),
      else: errors
  end

  @doc """
  Execute a node, given a message stream.
  Consume the message stream as processing occurs
  """
  @spec execute(Node.t(), FlowContext.t(), [Message.t()]) ::
          {:ok | :wait, FlowContext.t(), [Message.t()]} | {:error, String.t()}
  def execute(node, context, messages) do
    # update the flow count

    FlowCount.upsert_flow_count(%{
      uuid: node.uuid,
      flow_id: node.flow_id,
      flow_uuid: node.flow_uuid,
      organization_id: context.organization_id,
      type: "node"
    })

    # if node has an action, execute the first action
    cond do
      # if both are non-empty, it means that we have either a
      #    * sub-flow option
      #    * calling a web hook
      !Enum.empty?(node.actions) && !is_nil(node.router) ->
        execute_node_router(node, context, messages)

      !Enum.empty?(node.actions) ->
        execute_node_actions(node, context, messages)

      !is_nil(node.router) ->
        Router.execute(node.router, context, messages)

      true ->
        {:error, "Unsupported node type"}
    end
  end

  @spec execute_node_router(Node.t(), FlowContext.t(), [Message.t()]) ::
          {:ok | :wait, FlowContext.t(), [Message.t()]} | {:error, String.t()}
  defp execute_node_router(node, context, messages) do
    # need a better way to figure out if we should handle router or action
    # this is a hack for now
    if messages != [] and
         hd(messages).clean_body in ["completed", "expired", "success", "failure"],
       do: Router.execute(node.router, context, messages),
       else: Action.execute(hd(node.actions), context, messages)
  end

  @spec execute_node_actions(Node.t(), FlowContext.t(), [Message.t()]) ::
          {:ok | :wait, FlowContext.t(), [Message.t()]} | {:error, String.t()}
  defp execute_node_actions(node, context, messages) do
    # we need to execute all the actions (nodes can have multiple actions)
    {status, context, messages} =
      Enum.reduce(
        node.actions,
        {:ok, context, messages},
        fn action, acc ->
          {:ok, context, messages} = acc
          Action.execute(action, context, messages)
        end
      )

    case status do
      :ok -> Exit.execute(hd(node.exits), context, messages)
      :wait -> {:ok, context, messages}
    end
  end
end

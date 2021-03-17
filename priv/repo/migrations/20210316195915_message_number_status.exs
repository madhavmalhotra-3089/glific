defmodule Glific.Repo.Migrations.MessageNumberStatus do
  use Ecto.Migration

  def change do
    drop_if_exists table(:search_messages)

    alter table(:contacts) do
      add :org_read_messages?, :boolean,
        default: false,
        comment: "Has a staff read the messages sent by this contact"

      add :org_replied_messages?, :boolean,
        default: false,
        comment: "Has a staff or flow replied to the messages sent by this contact"

      add :contact_replied_messages?, :boolean,
        default: false,
        comment: "Has the contact replied to the messages sent by the system"

      add :last_message_number, :integer,
        default: 0,
        comment: "The max message number recd or sent by this contact"
    end

    alter table(:messages) do
      remove_if_exists(:is_read, :boolean)
      remove_if_exists(:is_replied, :boolean)
    end

    alter table(:groups) do
      add :last_message_number, :integer,
        default: 0,
        comment: "The max message number sent via this group"
    end
  end
end

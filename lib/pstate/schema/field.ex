defmodule PState.Schema.Field do
  @moduledoc """
  Represents a field definition in an entity schema.

  A field specifies the name, type, and optional migration function for a field
  in an entity. Migration functions are stored but not executed during schema
  definition (execution happens in RMX003).

  ## Field Types

  - `:string` - String values
  - `:integer` - Integer values
  - `:map` - Map values
  - `:list` - List values
  - `:ref` - Single reference to another entity
  - `:collection` - Collection of references (map of id -> ref)

  ## Examples

      %PState.Schema.Field{
        name: :front,
        type: :string,
        migrate_fn: nil,
        opts: []
      }

      %PState.Schema.Field{
        name: :deck,
        type: :ref,
        ref_type: :base_deck,
        migrate_fn: nil,
        opts: [ref: :base_deck]
      }

      %PState.Schema.Field{
        name: :metadata,
        type: :map,
        migrate_fn: fn
          str when is_binary(str) -> %{notes: str}
          map when is_map(map) -> map
        end,
        opts: []
      }
  """

  @enforce_keys [:name, :type]
  defstruct [
    :name,
    :type,
    :ref_type,
    :migrate_fn,
    :migrate_fn_ref,
    :validate_fn,
    opts: []
  ]

  @type t :: %__MODULE__{
          name: atom(),
          type: atom(),
          ref_type: atom() | nil,
          migrate_fn: (term() -> term()) | nil,
          migrate_fn_ref: {module(), atom()} | nil,
          validate_fn: (term() -> boolean()) | nil,
          opts: keyword()
        }
end

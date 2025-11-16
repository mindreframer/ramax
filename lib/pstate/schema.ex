defmodule PState.Schema do
  @moduledoc """
  DSL for defining entity schemas with typed fields.

  This module provides macros for defining entity structures, fields, and
  relationships. Migration functions can be attached to fields but are NOT
  executed during schema definition (execution happens in RMX003).

  ## Usage

      defmodule MyApp.ContentSchema do
        use PState.Schema

        entity :base_card do
          field :id, :string
          field :front, :string
          field :back, :string
          field :created_at, :integer

          belongs_to :deck, ref: :base_deck

          field :metadata, :map do
            migrate fn
              str when is_binary(str) -> %{notes: str}
              map when is_map(map) -> map
              nil -> %{}
            end
          end
        end

        entity :host_card do
          field :id, :string
          field :country, :string

          belongs_to :base_card, ref: :base_card

          has_many :translations, ref: :translation do
            migrate fn
              ids when is_list(ids) ->
                Map.new(ids, &{&1, PState.Ref.new(:translation, &1)})
              refs when is_map(refs) -> refs
              nil -> %{}
            end
          end
        end
      end

  ## Introspection

  After compilation, the schema module provides introspection functions:

      MyApp.ContentSchema.__schema__(:entities)
      # => %{base_card: [...fields...], host_card: [...fields...]}

      MyApp.ContentSchema.__schema__(:entity, :base_card)
      # => [...field structs...]

      MyApp.ContentSchema.__schema__(:fields, :base_card)
      # => [...field structs...]

  ## Available Macros

  - `entity/2` - Define an entity
  - `field/2-3` - Define a field (with optional migration)
  - `belongs_to/2-3` - Define a reference field (with optional migration)
  - `has_many/2-3` - Define a collection field (with optional migration)
  - `migrate/1` - Wrap migration function (passthrough)
  """

  alias PState.Schema.Field

  @doc false
  defmacro __using__(_opts) do
    quote do
      import PState.Schema
      Module.register_attribute(__MODULE__, :entities, accumulate: true)
      Module.register_attribute(__MODULE__, :current_entity, [])
      @before_compile PState.Schema
    end
  end

  @doc """
  Define an entity with the given name and fields.

  Sets the current entity context for field definitions within the do-block.

  ## Examples

      entity :base_card do
        field :id, :string
        field :front, :string
      end
  """
  defmacro entity(name, do: block) do
    quote do
      @current_entity unquote(name)
      unquote(block)
    end
  end

  @doc """
  Define a simple field without migration.

  When called with a do-block, stores a migration function.

  ## Examples

      # Simple field
      field :front, :string
      field :created_at, :integer
      field :metadata, :map, default: %{}

      # Field with migration
      field :metadata, :map do
        migrate fn
          str when is_binary(str) -> %{notes: str}
          map when is_map(map) -> map
        end
      end
  """
  defmacro field(name, type, opts \\ [])

  defmacro field(name, type, opts) when is_list(opts) do
    quote do
      field_spec = %Field{
        name: unquote(name),
        type: unquote(type),
        migrate_fn: nil,
        opts: unquote(opts)
      }

      PState.Schema.__register_field__(__MODULE__, @current_entity, field_spec)
    end
  end

  defmacro field(name, type, do: block) do
    # TODO RMX002_4A: Properly implement migration function storage
    # For now, we evaluate the block to get the function
    quote do
      migrate_fn = unquote(block)

      field_spec = %Field{
        name: unquote(name),
        type: unquote(type),
        migrate_fn: migrate_fn,
        opts: []
      }

      PState.Schema.__register_field__(__MODULE__, @current_entity, field_spec)
    end
  end

  @doc """
  Define a reference field (belongs_to relationship).

  ## Examples

      belongs_to :deck, ref: :base_deck

      belongs_to :base_card, ref: :base_card do
        migrate fn
          id when is_binary(id) -> PState.Ref.new(:base_card, id)
          %PState.Ref{} = ref -> ref
        end
      end
  """
  defmacro belongs_to(name, opts) when is_list(opts) do
    quote do
      ref_type = Keyword.fetch!(unquote(opts), :ref)

      field_spec = %Field{
        name: unquote(name),
        type: :ref,
        ref_type: ref_type,
        migrate_fn: nil,
        opts: unquote(opts)
      }

      PState.Schema.__register_field__(__MODULE__, @current_entity, field_spec)
    end
  end

  defmacro belongs_to(name, opts, do: block) do
    # TODO RMX002_4A: Properly implement migration function storage
    quote do
      ref_type = Keyword.fetch!(unquote(opts), :ref)
      migrate_fn = unquote(block)

      field_spec = %Field{
        name: unquote(name),
        type: :ref,
        ref_type: ref_type,
        migrate_fn: migrate_fn,
        opts: unquote(opts)
      }

      PState.Schema.__register_field__(__MODULE__, @current_entity, field_spec)
    end
  end

  @doc """
  Define a collection reference field (has_many relationship).

  ## Examples

      has_many :cards, ref: :base_card

      has_many :translations, ref: :translation do
        migrate fn
          ids when is_list(ids) ->
            Map.new(ids, &{&1, PState.Ref.new(:translation, &1)})
          refs when is_map(refs) -> refs
        end
      end
  """
  defmacro has_many(name, opts) when is_list(opts) do
    quote do
      ref_type = Keyword.fetch!(unquote(opts), :ref)

      field_spec = %Field{
        name: unquote(name),
        type: :collection,
        ref_type: ref_type,
        migrate_fn: nil,
        opts: unquote(opts)
      }

      PState.Schema.__register_field__(__MODULE__, @current_entity, field_spec)
    end
  end

  defmacro has_many(name, opts, do: block) do
    # TODO RMX002_4A: Properly implement migration function storage
    quote do
      ref_type = Keyword.fetch!(unquote(opts), :ref)
      migrate_fn = unquote(block)

      field_spec = %Field{
        name: unquote(name),
        type: :collection,
        ref_type: ref_type,
        migrate_fn: migrate_fn,
        opts: unquote(opts)
      }

      PState.Schema.__register_field__(__MODULE__, @current_entity, field_spec)
    end
  end

  @doc """
  Passthrough macro for migration function blocks.

  This macro extracts the function from a `migrate fn...end` expression.

  ## Examples

      migrate fn
        str when is_binary(str) -> %{notes: str}
        map when is_map(map) -> map
      end
  """
  defmacro migrate(fn_expr) do
    fn_expr
  end

  @doc false
  def __register_field__(module, entity_name, field_spec) do
    entities = Module.get_attribute(module, :entities) || []

    # Find or create entity entry
    case List.keyfind(entities, entity_name, 0) do
      {^entity_name, fields} ->
        # Entity exists, add field to it
        updated = {entity_name, [field_spec | fields]}
        new_entities = List.keyreplace(entities, entity_name, 0, updated)
        Module.delete_attribute(module, :entities)

        for entity <- new_entities do
          Module.put_attribute(module, :entities, entity)
        end

      nil ->
        # Entity doesn't exist, create it
        Module.put_attribute(module, :entities, {entity_name, [field_spec]})
    end
  end

  @doc false
  defmacro __before_compile__(_env) do
    # TODO RMX002_4A: This implementation doesn't properly handle migration functions
    # Migration functions cannot be escaped into module attributes
    # This will be fixed when implementing RMX002_4A
    quote do
      @doc """
      Get schema introspection information.

      ## Examples

          __schema__(:entities)
          # => %{entity_name: [%Field{}, ...], ...}

          __schema__(:entity, :base_card)
          # => [%Field{}, ...]

          __schema__(:fields, :base_card)
          # => [%Field{}, ...]
      """
      def __schema__(:entities) do
        @entities
        |> Enum.map(fn {name, fields} ->
          {name, Enum.reverse(fields)}
        end)
        |> Map.new()
      end

      def __schema__(:entity, name) do
        __schema__(:entities)[name]
      end

      def __schema__(:fields, entity_name) do
        case __schema__(:entity, entity_name) do
          nil -> []
          fields -> fields
        end
      end
    end
  end
end

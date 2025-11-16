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
      # Store field as plain data
      field_data = {
        :field_spec,
        unquote(name),
        unquote(type),
        nil,
        # ref_type
        nil,
        # migrate_fn_ref
        unquote(opts)
        # opts
      }

      PState.Schema.__register_field__(__MODULE__, @current_entity, field_data)
    end
  end

  defmacro field(name, type, do: block) do
    # Generate a unique migration function name at macro expansion time
    migration_fn_name = :"__migration_field_#{name}_#{:erlang.unique_integer([:positive])}__"

    # Extract the function AST from the migrate macro
    # The block should be wrapped with `migrate fn ... end`
    fn_ast =
      case block do
        {{:., _, [{:__aliases__, _, [:PState, :Schema]}, :migrate]}, _, [fn_expr]} ->
          fn_expr

        {:migrate, _, [fn_expr]} ->
          fn_expr

        # If no migrate wrapper, assume block is the function itself
        _ ->
          block
      end

    # Extract clauses from the function
    # The fn_ast should be {:fn, meta, clauses}
    clauses =
      case fn_ast do
        {:fn, _, fn_clauses} ->
          # Convert fn clauses to def clauses
          Enum.map(fn_clauses, fn {:->, clause_meta, [args, body]} ->
            {:->, clause_meta, [args, body]}
          end)

        _ ->
          # Single expression, treat as identity
          [{:->, [], [[{:value, [], nil}], fn_ast]}]
      end

    quote do
      # Define the named migration function with the extracted clauses
      def unquote(migration_fn_name)(value) do
        case value do
          unquote(clauses)
        end
      end

      # Store field spec as plain data (no structs, no functions)
      field_data = {
        :field_spec,
        unquote(name),
        unquote(type),
        nil,
        # ref_type
        {__MODULE__, unquote(migration_fn_name)},
        # migrate_fn_ref
        []
        # opts
      }

      PState.Schema.__register_field__(__MODULE__, @current_entity, field_data)
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

      field_data = {
        :field_spec,
        unquote(name),
        :ref,
        ref_type,
        nil,
        # migrate_fn_ref
        unquote(opts)
        # opts
      }

      PState.Schema.__register_field__(__MODULE__, @current_entity, field_data)
    end
  end

  defmacro belongs_to(name, opts, do: block) do
    # Generate a unique migration function name at macro expansion time
    migration_fn_name = :"__migration_belongs_to_#{name}_#{:erlang.unique_integer([:positive])}__"

    # Extract the function AST from the migrate macro
    fn_ast =
      case block do
        {{:., _, [{:__aliases__, _, [:PState, :Schema]}, :migrate]}, _, [fn_expr]} ->
          fn_expr

        {:migrate, _, [fn_expr]} ->
          fn_expr

        _ ->
          block
      end

    # Extract clauses from the function
    clauses =
      case fn_ast do
        {:fn, _, fn_clauses} ->
          Enum.map(fn_clauses, fn {:->, clause_meta, [args, body]} ->
            {:->, clause_meta, [args, body]}
          end)

        _ ->
          [{:->, [], [[{:value, [], nil}], fn_ast]}]
      end

    quote do
      ref_type = Keyword.fetch!(unquote(opts), :ref)

      # Define the named migration function with the extracted clauses
      def unquote(migration_fn_name)(value) do
        case value do
          unquote(clauses)
        end
      end

      # Store field as plain data
      field_data = {
        :field_spec,
        unquote(name),
        :ref,
        ref_type,
        {__MODULE__, unquote(migration_fn_name)},
        # migrate_fn_ref
        unquote(opts)
        # opts
      }

      PState.Schema.__register_field__(__MODULE__, @current_entity, field_data)
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

      field_data = {
        :field_spec,
        unquote(name),
        :collection,
        ref_type,
        nil,
        # migrate_fn_ref
        unquote(opts)
        # opts
      }

      PState.Schema.__register_field__(__MODULE__, @current_entity, field_data)
    end
  end

  defmacro has_many(name, opts, do: block) do
    # Generate a unique migration function name at macro expansion time
    migration_fn_name = :"__migration_has_many_#{name}_#{:erlang.unique_integer([:positive])}__"

    # Extract the function AST from the migrate macro
    fn_ast =
      case block do
        {{:., _, [{:__aliases__, _, [:PState, :Schema]}, :migrate]}, _, [fn_expr]} ->
          fn_expr

        {:migrate, _, [fn_expr]} ->
          fn_expr

        _ ->
          block
      end

    # Extract clauses from the function
    clauses =
      case fn_ast do
        {:fn, _, fn_clauses} ->
          Enum.map(fn_clauses, fn {:->, clause_meta, [args, body]} ->
            {:->, clause_meta, [args, body]}
          end)

        _ ->
          [{:->, [], [[{:value, [], nil}], fn_ast]}]
      end

    quote do
      ref_type = Keyword.fetch!(unquote(opts), :ref)

      # Define the named migration function with the extracted clauses
      def unquote(migration_fn_name)(value) do
        case value do
          unquote(clauses)
        end
      end

      # Store field as plain data
      field_data = {
        :field_spec,
        unquote(name),
        :collection,
        ref_type,
        {__MODULE__, unquote(migration_fn_name)},
        # migrate_fn_ref
        unquote(opts)
        # opts
      }

      PState.Schema.__register_field__(__MODULE__, @current_entity, field_data)
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
  def __register_field__(module, entity_name, field_data) do
    entities = Module.get_attribute(module, :entities) || []

    # Find or create entity entry
    case List.keyfind(entities, entity_name, 0) do
      {^entity_name, fields} ->
        # Entity exists, add field to it
        updated = {entity_name, [field_data | fields]}
        new_entities = List.keyreplace(entities, entity_name, 0, updated)
        Module.delete_attribute(module, :entities)

        for entity <- new_entities do
          Module.put_attribute(module, :entities, entity)
        end

      nil ->
        # Entity doesn't exist, create it
        Module.put_attribute(module, :entities, {entity_name, [field_data]})
    end
  end

  @doc false
  defmacro __before_compile__(_env) do
    quote do
      # Generate entities map as a runtime computation
      defp __entities_raw__ do
        @entities
        |> Enum.map(fn {name, fields} ->
          {name, Enum.reverse(fields)}
        end)
        |> Map.new()
      end

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
        # Convert migrate_fn_ref to actual functions at runtime
        __entities_raw__()
        |> Enum.map(fn {name, fields} ->
          fields_with_fns =
            Enum.map(fields, fn field ->
              PState.Schema.__hydrate_field__(field)
            end)

          {name, fields_with_fns}
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

  @doc false
  def __hydrate_field__({:field_spec, name, type, ref_type, migrate_fn_ref, opts}) do
    %Field{
      name: name,
      type: type,
      ref_type: ref_type,
      migrate_fn:
        case migrate_fn_ref do
          {mod, fn_name} -> fn value -> apply(mod, fn_name, [value]) end
          nil -> nil
        end,
      migrate_fn_ref: migrate_fn_ref,
      opts: opts
    }
  end
end

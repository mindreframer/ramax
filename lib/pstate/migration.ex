defmodule PState.Migration do
  @moduledoc """
  Type checking and migration detection for PState entities.

  This module provides functions to check if values match expected types
  and determine if field values need migration.

  ## Examples

      iex> PState.Migration.type_matches?("hello", :string)
      true

      iex> PState.Migration.type_matches?(42, :string)
      false

      iex> field = %PState.Schema.Field{name: :metadata, type: :map, migrate_fn: fn _ -> %{} end}
      iex> PState.Migration.needs_migration?("old_string", field)
      true
  """

  alias PState.Schema.Field

  @doc """
  Check if value matches expected type.

  Returns true if the value matches the expected type, false otherwise.
  Nil values are considered to match any type.

  ## Examples

      iex> PState.Migration.type_matches?(nil, :string)
      true

      iex> PState.Migration.type_matches?("hello", :string)
      true

      iex> PState.Migration.type_matches?(42, :integer)
      true

      iex> PState.Migration.type_matches?(%{a: 1}, :map)
      true

      iex> PState.Migration.type_matches?([1, 2], :list)
      true

      iex> PState.Migration.type_matches?(%PState.Ref{key: "card:1"}, :ref)
      true

      iex> PState.Migration.type_matches?("anything", :collection)
      true

      iex> PState.Migration.type_matches?(42, :string)
      false
  """
  @spec type_matches?(term(), atom()) :: boolean()
  def type_matches?(nil, _type), do: true
  def type_matches?(v, :string) when is_binary(v), do: true
  def type_matches?(v, :integer) when is_integer(v), do: true
  def type_matches?(v, :map) when is_map(v) and not is_struct(v), do: true
  def type_matches?(v, :list) when is_list(v), do: true
  def type_matches?(%PState.Ref{}, :ref), do: true
  def type_matches?(_, :collection), do: true
  def type_matches?(_, _), do: false

  @doc """
  Check if field needs migration.

  Returns true if:
  1. The field has a migration function defined, AND
  2. Either:
     a. The value does not match the expected type, OR
     b. The field has a validate_fn and the value fails validation

  ## Examples

      iex> field = %PState.Schema.Field{name: :metadata, type: :map, migrate_fn: fn str -> %{notes: str} end}
      iex> PState.Migration.needs_migration?("old_string", field)
      true

      iex> field = %PState.Schema.Field{name: :metadata, type: :map, migrate_fn: fn str -> %{notes: str} end}
      iex> PState.Migration.needs_migration?(%{notes: "new"}, field)
      false

      iex> field = %PState.Schema.Field{name: :front, type: :string, migrate_fn: nil}
      iex> PState.Migration.needs_migration?("old_string", field)
      false
  """
  @spec needs_migration?(term(), Field.t()) :: boolean()
  def needs_migration?(value, field_spec) do
    has_migration_fn? = field_spec.migrate_fn != nil

    cond do
      not has_migration_fn? ->
        false

      # If field has validate_fn, use it to check if value is valid
      field_spec.validate_fn != nil ->
        not field_spec.validate_fn.(value)

      # Otherwise use type matching
      true ->
        not type_matches?(value, field_spec.type)
    end
  end
end

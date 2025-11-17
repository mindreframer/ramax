defmodule PState.Ref do
  @moduledoc """
  First-class reference type (like GunDB's {'#': 'key'}).
  References are auto-resolved transparently on access.

  ## Examples

      iex> PState.Ref.new("base_card:550e8400-e29b-41d4-a716-446655440000")
      %PState.Ref{key: "base_card:550e8400-e29b-41d4-a716-446655440000"}

      iex> PState.Ref.new(:base_card, "550e8400-e29b-41d4-a716-446655440000")
      %PState.Ref{key: "base_card:550e8400-e29b-41d4-a716-446655440000"}
  """

  @enforce_keys [:key]
  @derive {Jason.Encoder, only: [:key]}
  defstruct [:key]

  @type t :: %__MODULE__{
          key: String.t()
        }

  @doc """
  Create a new reference with a full key string.

  ## Examples

      iex> PState.Ref.new("base_card:uuid")
      %PState.Ref{key: "base_card:uuid"}
  """
  @spec new(String.t()) :: t()
  def new(key) when is_binary(key), do: %__MODULE__{key: key}

  @doc """
  Create a new reference from entity type and ID.

  ## Examples

      iex> PState.Ref.new(:base_card, "uuid")
      %PState.Ref{key: "base_card:uuid"}
  """
  @spec new(atom(), String.t()) :: t()
  def new(entity_type, id) when is_atom(entity_type) and is_binary(id) do
    %__MODULE__{key: "#{entity_type}:#{id}"}
  end
end

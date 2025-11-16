defmodule PState.Error do
  @moduledoc """
  Exception module for PState errors.

  Provides structured error handling for various PState operations.
  """

  defexception [:message, :reason]

  @type t :: %__MODULE__{
          message: String.t(),
          reason: atom() | term()
        }

  @doc """
  Create an exception from a reason tuple.

  ## Examples

      iex> raise PState.Error, {:adapter_error, :connection_failed}
      ** (PState.Error) Adapter operation failed: :connection_failed

      iex> raise PState.Error, {:circular_ref, ["a:1", "b:2", "a:1"]}
      ** (PState.Error) Circular reference detected: ["a:1", "b:2", "a:1"]

  """
  def exception({:adapter_error, reason}) do
    %__MODULE__{
      message: "Adapter operation failed: #{inspect(reason)}",
      reason: reason
    }
  end

  def exception({:invalid_ref, key}) do
    %__MODULE__{
      message: "Invalid reference: #{key}",
      reason: :invalid_ref
    }
  end

  def exception({:circular_ref, keys}) do
    %__MODULE__{
      message: "Circular reference detected: #{inspect(keys)}",
      reason: :circular_ref
    }
  end

  def exception({:missing_field, field}) do
    %__MODULE__{
      message: "Required field missing: #{field}",
      reason: :missing_field
    }
  end

  def exception(message) when is_binary(message) do
    %__MODULE__{
      message: message,
      reason: :unknown
    }
  end
end

defmodule EventStore.Error do
  @moduledoc """
  Error types for EventStore operations.

  This module defines structured errors that can occur during
  event store operations.
  """

  defexception [:message, :reason]

  @type t :: %__MODULE__{
          message: String.t(),
          reason: term()
        }

  @doc """
  Error when adapter initialization fails.
  """
  def adapter_init_failed(reason) do
    %__MODULE__{
      message: "Adapter initialization failed",
      reason: reason
    }
  end

  @doc """
  Error when an event cannot be found by its ID.
  """
  def event_not_found(event_id) do
    %__MODULE__{
      message: "Event not found",
      reason: event_id
    }
  end

  @doc """
  Error when a storage operation fails.
  """
  def storage_error(reason) do
    %__MODULE__{
      message: "Storage error",
      reason: reason
    }
  end
end

defmodule PState.MigrationWriter do
  @moduledoc """
  Background writer for migrated data.

  Queues writes and flushes in batches for performance.
  Enables eventual consistency for migrated entities.

  ## Architecture

  - Queues migration writes asynchronously
  - Auto-flushes when batch_size reached (default 100)
  - Timer-based flushing (default 5000ms)
  - Uses multi_put for batch writes

  ## Examples

      # Start the writer
      {:ok, pid} = PState.MigrationWriter.start_link(
        pstate: pstate,
        batch_size: 100,
        flush_interval: 5000
      )

      # Queue a migration write
      PState.MigrationWriter.queue_write("base_card:uuid", %{front: "Hello"})

      # Manually flush
      :ok = PState.MigrationWriter.flush()
  """

  use GenServer

  require Logger

  @type t :: %__MODULE__{
          pstate: PState.t(),
          queue: [{String.t(), term()}],
          batch_size: pos_integer(),
          flush_interval: pos_integer()
        }

  defstruct [
    :pstate,
    queue: [],
    batch_size: 100,
    flush_interval: 5000
  ]

  # Client API

  @doc """
  Start the migration writer GenServer.

  ## Options

  - `:pstate` - PState instance (required)
  - `:batch_size` - Max batch size before auto-flush (default: 100)
  - `:flush_interval` - Flush interval in milliseconds (default: 5000)

  ## Examples

      {:ok, pid} = PState.MigrationWriter.start_link(pstate: pstate)
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Queue a migration write (async).

  The write will be batched and flushed later.

  ## Examples

      PState.MigrationWriter.queue_write("base_card:uuid", %{front: "Hello"})
  """
  @spec queue_write(String.t(), term()) :: :ok
  def queue_write(key, value) do
    GenServer.cast(__MODULE__, {:queue, key, value})
  end

  @doc """
  Flush queue immediately (sync).

  Returns `:ok` when flush completes.

  ## Examples

      :ok = PState.MigrationWriter.flush()
  """
  @spec flush() :: :ok
  def flush do
    GenServer.call(__MODULE__, :flush)
  end

  # GenServer Callbacks

  @impl true
  def init(opts) do
    pstate = Keyword.fetch!(opts, :pstate)
    batch_size = Keyword.get(opts, :batch_size, 100)
    flush_interval = Keyword.get(opts, :flush_interval, 5000)

    # Schedule first flush
    schedule_flush(flush_interval)

    {:ok,
     %__MODULE__{
       pstate: pstate,
       batch_size: batch_size,
       flush_interval: flush_interval
     }}
  end

  @impl true
  def handle_cast({:queue, key, value}, state) do
    new_queue = [{key, value} | state.queue]

    # Emit queue telemetry
    :telemetry.execute(
      [:pstate, :migration_writer, :queue],
      %{queue_size: length(new_queue)},
      %{key: key}
    )

    # Auto-flush if batch size reached
    if length(new_queue) >= state.batch_size do
      do_flush(state.pstate, new_queue, :batch_size)
      {:noreply, %{state | queue: []}}
    else
      {:noreply, %{state | queue: new_queue}}
    end
  end

  @impl true
  def handle_call(:flush, _from, state) do
    do_flush(state.pstate, state.queue, :manual)
    {:reply, :ok, %{state | queue: []}}
  end

  @impl true
  def handle_info(:flush_timer, state) do
    do_flush(state.pstate, state.queue, :timer)
    schedule_flush(state.flush_interval)
    {:noreply, %{state | queue: []}}
  end

  # Private Helpers

  defp do_flush(_pstate, [], _trigger), do: :ok

  defp do_flush(pstate, queue, trigger) do
    start_time = System.monotonic_time(:microsecond)

    # Reverse queue to maintain insertion order
    entries = Enum.reverse(queue)

    # Use multi_put for batch write
    PState.Internal.multi_put(pstate, entries)

    duration = System.monotonic_time(:microsecond) - start_time

    # Emit flush telemetry
    :telemetry.execute(
      [:pstate, :migration_writer, :flush],
      %{duration: duration, count: length(entries)},
      %{trigger: trigger}
    )
  end

  defp schedule_flush(interval) do
    Process.send_after(self(), :flush_timer, interval)
  end
end

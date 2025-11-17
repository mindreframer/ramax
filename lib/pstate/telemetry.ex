defmodule PState.Telemetry do
  @moduledoc """
  Example telemetry handler for PState observability.

  This module demonstrates how to attach telemetry handlers to PState events
  for monitoring, logging, and metrics collection.

  ## Telemetry Events

  ### [:pstate, :fetch]
  Emitted when an entity is fetched from PState.

  - Measurements: `%{duration: microseconds}`
  - Metadata: `%{key: string, migrated?: boolean, from_cache?: boolean}`

  ### [:pstate, :put]
  Emitted when an entity is written to PState.

  - Measurements: `%{duration: microseconds}`
  - Metadata: `%{key: string}`

  ### [:pstate, :migration]
  Emitted when a migration occurs during fetch.

  - Measurements: `%{duration: microseconds}`
  - Metadata: `%{key: string, entity_type: atom, fields_migrated: integer}`

  ### [:pstate, :migration_writer, :queue]
  Emitted when a migration write is queued.

  - Measurements: `%{queue_size: integer}`
  - Metadata: `%{key: string}`

  ### [:pstate, :migration_writer, :flush]
  Emitted when the migration writer flushes its queue.

  - Measurements: `%{duration: microseconds, count: integer}`
  - Metadata: `%{trigger: :batch_size | :timer | :manual}`

  ### [:pstate, :cache]
  Emitted on cache hit/miss.

  - Measurements: `%{hit?: 0 | 1}`
  - Metadata: `%{key: string}`

  ## Examples

      # Attach handlers during application startup
      defmodule MyApp.Application do
        def start(_type, _args) do
          PState.Telemetry.setup()
          # ... rest of application startup
        end
      end

      # Custom handler
      defmodule MyApp.CustomTelemetry do
        def setup do
          :telemetry.attach_many(
            "my-app-pstate-metrics",
            [
              [:pstate, :fetch],
              [:pstate, :migration]
            ],
            &__MODULE__.handle_event/4,
            nil
          )
        end

        def handle_event([:pstate, :fetch], measurements, metadata, _config) do
          # Send to your metrics system
          MyApp.Metrics.histogram("pstate.fetch.duration", measurements.duration,
            tags: [migrated: metadata.migrated?, cached: metadata.from_cache?]
          )
        end

        def handle_event([:pstate, :migration], measurements, metadata, _config) do
          MyApp.Metrics.counter("pstate.migrations", 1,
            tags: [entity_type: metadata.entity_type]
          )
        end
      end
  """

  require Logger

  @doc """
  Setup default telemetry handlers.

  Attaches handlers that log important PState events.
  This is useful for development and debugging.

  ## Examples

      iex> PState.Telemetry.setup()
      :ok
  """
  @spec setup() :: :ok
  def setup do
    events = [
      [:pstate, :fetch],
      [:pstate, :put],
      [:pstate, :migration],
      [:pstate, :migration_writer, :flush]
    ]

    :telemetry.attach_many("pstate-default-handlers", events, &__MODULE__.handle_event/4, nil)
  end

  @doc """
  Default event handler that logs telemetry events.

  This is automatically attached when calling `setup/0`.
  """
  def handle_event([:pstate, :fetch], measurements, metadata, _config) do
    migrated = if metadata.migrated?, do: "migrated", else: "direct"
    cached = if metadata.from_cache?, do: "cached", else: "uncached"

    Logger.debug(
      "PState fetch #{metadata.key}: #{migrated}, #{cached} in #{measurements.duration}μs"
    )
  end

  def handle_event([:pstate, :put], measurements, metadata, _config) do
    Logger.debug("PState put #{metadata.key} in #{measurements.duration}μs")
  end

  def handle_event([:pstate, :migration], measurements, metadata, _config) do
    Logger.info(
      "PState migration #{metadata.key} (#{metadata.entity_type}): " <>
        "#{metadata.fields_migrated} fields in #{measurements.duration}μs"
    )
  end

  def handle_event([:pstate, :migration_writer, :flush], measurements, metadata, _config) do
    Logger.info(
      "PState flushed #{measurements.count} entries in #{measurements.duration}μs " <>
        "(trigger: #{metadata.trigger})"
    )
  end
end

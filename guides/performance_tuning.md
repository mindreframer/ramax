# Performance Tuning Guide

This guide covers performance optimization strategies for PState in production.

## Performance Targets

| Operation | Target | Notes |
|-----------|--------|-------|
| Background queue write | <0.1ms | Async cast |
| Batch flush (100 entries) | <50ms | SQLite transaction |
| multi_get (100 keys) | <20ms | Single query |
| multi_put (100 entries) | <50ms | Single transaction |
| Preload (100 refs) | <20ms | Batch fetch |
| First read (with migration) | <2ms | Sync migration |
| Second read (migrated) | <0.5ms | No migration needed |

## 1. Batch Operations

### Problem: N+1 Queries

```elixir
# ❌ Bad: Individual fetches (N+1 problem)
deck = pstate["base_deck:uuid"]

cards = Enum.map(deck.cards, fn {_id, ref} ->
  pstate[ref.key]  # N individual fetches
end)
```

### Solution: Use Preloading

```elixir
# ✅ Good: Single batch fetch
pstate = PState.preload(pstate, "base_deck:uuid", [:cards])

deck = pstate["base_deck:uuid"]
# All cards now in cache, no additional fetches needed
cards = Enum.map(deck.cards, fn {_id, ref} ->
  pstate[ref.key]  # Cache hit
end)
```

### Advanced: Nested Preloading

```elixir
# Preload deck → cards → translations in one operation
pstate = PState.preload(pstate, "base_deck:uuid", [
  cards: [:translations]
])

# All data loaded, no N+1
deck = pstate["base_deck:uuid"]
cards = Enum.map(deck.cards, fn {_id, ref} ->
  card = pstate[ref.key]
  translations = Enum.map(card.translations, fn {_, t_ref} ->
    pstate[t_ref.key]  # All in cache
  end)
  %{card | translations: translations}
end)
```

## 2. Migration Writer Configuration

### Default Configuration

```elixir
{:ok, _pid} = PState.MigrationWriter.start_link(
  pstate: pstate,
  batch_size: 100,        # Auto-flush after 100 writes
  flush_interval: 5000    # Flush every 5 seconds
)
```

### Tuning for Different Workloads

#### High-Throughput Workload (Many Migrations)

```elixir
# Larger batches, more frequent flushes
PState.MigrationWriter.start_link(
  pstate: pstate,
  batch_size: 500,        # Larger batch for efficiency
  flush_interval: 2000    # Flush more frequently (2s)
)
```

**Trade-offs:**
- ✅ Fewer transactions (better throughput)
- ✅ More efficient SQLite writes
- ❌ Longer eventual consistency window
- ❌ More memory usage in queue

#### Low-Latency Workload (Quick Consistency)

```elixir
# Smaller batches, frequent flushes
PState.MigrationWriter.start_link(
  pstate: pstate,
  batch_size: 50,         # Smaller batch
  flush_interval: 1000    # Flush every second
)
```

**Trade-offs:**
- ✅ Faster eventual consistency
- ✅ Lower memory usage
- ❌ More transactions (overhead)
- ❌ Lower throughput

#### Memory-Constrained Environment

```elixir
# Small batches, aggressive flushing
PState.MigrationWriter.start_link(
  pstate: pstate,
  batch_size: 25,
  flush_interval: 500
)
```

## 3. SQLite Optimization

### WAL Mode (Already Enabled)

PState automatically enables WAL (Write-Ahead Logging) mode:

```elixir
# Automatically done in SQLite adapter
PRAGMA journal_mode=WAL
```

**Benefits:**
- ✅ Concurrent reads during writes
- ✅ Better performance
- ✅ Crash safety

### Custom SQLite Configuration

```elixir
defmodule MyApp.CustomSQLiteAdapter do
  use PState.Adapters.SQLite

  def init(opts) do
    {:ok, state} = super(opts)

    # Custom PRAGMA settings
    conn = state.conn

    # Increase cache size (default: 2MB)
    :ok = Exqlite.Sqlite3.execute(conn, "PRAGMA cache_size = -10000")  # 10MB

    # Synchronous mode (adjust based on durability needs)
    :ok = Exqlite.Sqlite3.execute(conn, "PRAGMA synchronous = NORMAL")

    # Memory-mapped I/O (faster reads)
    :ok = Exqlite.Sqlite3.execute(conn, "PRAGMA mmap_size = 268435456")  # 256MB

    {:ok, state}
  end
end
```

### WAL Checkpoint Strategy

```elixir
defmodule MyApp.WALCheckpoint do
  use GenServer

  def start_link(pstate) do
    GenServer.start_link(__MODULE__, pstate, name: __MODULE__)
  end

  def init(pstate) do
    # Checkpoint every 5 minutes
    schedule_checkpoint()
    {:ok, pstate}
  end

  def handle_info(:checkpoint, pstate) do
    # Checkpoint WAL file
    conn = pstate.adapter_state.conn
    :ok = Exqlite.Sqlite3.execute(conn, "PRAGMA wal_checkpoint(TRUNCATE)")

    schedule_checkpoint()
    {:noreply, pstate}
  end

  defp schedule_checkpoint do
    Process.send_after(self(), :checkpoint, :timer.minutes(5))
  end
end
```

## 4. Cache Management

### Cache Warming on Startup

```elixir
defmodule MyApp.CacheWarmer do
  @doc "Preload frequently accessed data on startup"
  def warm_cache(pstate, track_id) do
    # Load track and all decks
    pstate = PState.preload(pstate, "track:#{track_id}", [:decks])

    track = pstate["track:#{track_id}"]

    # Load all cards for all decks
    Enum.reduce(track.decks, pstate, fn {_id, deck_ref}, acc_pstate ->
      PState.preload(acc_pstate, deck_ref.key, [:cards])
    end)
  end
end
```

### Selective Cache Invalidation

```elixir
# Instead of clearing entire cache on write
# Only invalidate affected keys (future enhancement)

defmodule PState.Internal do
  defp invalidate_ref_cache_selective(pstate, key) do
    # Track reverse dependencies
    # Only invalidate keys that reference this key
    reverse_deps = get_reverse_deps(pstate, key)

    Enum.reduce(reverse_deps, pstate, fn dep_key, acc ->
      update_in(acc.ref_cache, &Map.delete(&1, dep_key))
    end)
  end
end
```

## 5. Monitoring & Telemetry

### Setup Telemetry Handlers

```elixir
defmodule MyApp.PStateMetrics do
  def setup do
    events = [
      [:pstate, :fetch],
      [:pstate, :put],
      [:pstate, :migration],
      [:pstate, :migration_writer, :flush],
      [:pstate, :cache]
    ]

    :telemetry.attach_many("pstate-metrics", events, &handle_event/4, nil)
  end

  def handle_event([:pstate, :fetch], %{duration: duration}, metadata, _) do
    # Send to metrics system (Prometheus, StatsD, etc.)
    :telemetry_metrics_prometheus_core.execute(
      [:pstate, :fetch, :duration],
      duration,
      %{
        migrated: metadata.migrated?,
        cached: metadata.from_cache?
      }
    )
  end

  def handle_event([:pstate, :cache], %{hit?: hit?}, metadata, _) do
    # Track cache hit rate
    :telemetry_metrics_prometheus_core.execute(
      [:pstate, :cache, :hit_rate],
      hit?,
      %{key_prefix: extract_prefix(metadata.key)}
    )
  end

  # ... other handlers

  defp extract_prefix(key) do
    key |> String.split(":") |> hd()
  end
end
```

### Key Metrics to Monitor

1. **Cache Hit Rate**
   ```elixir
   # Target: >80% for warm cache
   cache_hit_rate = cache_hits / (cache_hits + cache_misses)
   ```

2. **Migration Rate**
   ```elixir
   # Should decrease over time as data migrates
   migrations_per_second = count([:pstate, :migration]) / time_window
   ```

3. **Background Queue Size**
   ```elixir
   # Alert if queue grows too large
   if queue_size > 1000 do
     Logger.warn("Migration queue backing up: #{queue_size} entries")
   end
   ```

4. **Flush Duration**
   ```elixir
   # Target: <50ms for 100 entries
   # Alert if consistently slow
   if flush_duration > 100_000 do  # 100ms
     Logger.warn("Slow flush: #{flush_duration}μs for #{count} entries")
   end
   ```

## 6. Benchmarking

### Using Benchee

```elixir
# benchmark/pstate_benchmark.exs
Mix.install([
  {:benchee, "~> 1.0"},
  {:ramax, path: "."}
])

# Setup
pstate = PState.new("track:uuid",
  adapter: PState.Adapters.SQLite,
  adapter_opts: [path: "/tmp/bench.db"]
)

# Seed data
keys = for i <- 1..1000, do: "base_card:#{i}"
Enum.each(keys, fn key ->
  put_in(pstate[key], %{id: key, front: "Hello", back: "Hola"})
end)

# Run benchmarks
Benchee.run(%{
  "fetch (cold, no cache)" => fn ->
    # Clear cache
    pstate = %{pstate | cache: %{}}
    pstate["base_card:500"]
  end,

  "fetch (warm, cached)" => fn ->
    pstate["base_card:500"]
  end,

  "multi_get (10 keys)" => fn ->
    pstate.adapter.multi_get(pstate.adapter_state, Enum.take(keys, 10))
  end,

  "multi_get (100 keys)" => fn ->
    pstate.adapter.multi_get(pstate.adapter_state, Enum.take(keys, 100))
  end,

  "preload (100 refs)" => fn ->
    PState.preload(pstate, "base_deck:uuid", [:cards])
  end
})
```

### Expected Results

```
Name                              ips        average  deviation         median         99th %
fetch (warm, cached)          2.00 M        0.50 μs   ±100.00%        0.45 μs        1.20 μs
fetch (cold, no cache)      500.00 K        2.00 μs    ±50.00%        1.80 μs        4.50 μs
multi_get (10 keys)          10.00 K      100.00 μs    ±20.00%       95.00 μs      150.00 μs
multi_get (100 keys)          1.00 K     1000.00 μs    ±15.00%      950.00 μs     1500.00 μs
preload (100 refs)            1.00 K     1000.00 μs    ±15.00%      950.00 μs     1500.00 μs
```

## 7. Production Checklist

### Configuration

- [ ] Set appropriate `batch_size` for workload
- [ ] Configure `flush_interval` based on consistency needs
- [ ] Enable WAL mode (automatic in SQLite adapter)
- [ ] Set SQLite cache size for available memory
- [ ] Configure WAL checkpoint interval

### Monitoring

- [ ] Setup telemetry handlers
- [ ] Monitor cache hit rate (target >80%)
- [ ] Monitor migration rate (should decrease over time)
- [ ] Monitor queue size (alert if >1000)
- [ ] Monitor flush duration (alert if >100ms)
- [ ] Track slow queries (>10ms)

### Data Management

- [ ] Plan migration rollout strategy
- [ ] Setup backup/restore procedures
- [ ] Document SQLite file location
- [ ] Plan for database growth (380k cards ≈ 100MB)
- [ ] Setup WAL checkpoint automation

### Testing

- [ ] Load test with production data volume
- [ ] Test graceful shutdown (flush on terminate)
- [ ] Test recovery from crashes
- [ ] Verify migration correctness
- [ ] Benchmark against performance targets

## 8. Troubleshooting

### Slow Fetches

**Symptom**: Fetch operations taking >5ms

**Possible Causes:**
1. Cache not warmed up
2. Too many migrations happening
3. SQLite disk I/O slow

**Solutions:**
```elixir
# 1. Warm cache on startup
MyApp.CacheWarmer.warm_cache(pstate, track_id)

# 2. Check migration rate
:telemetry.attach("debug", [:pstate, :migration], fn _, _, meta, _ ->
  IO.inspect(meta, label: "Migration")
end, nil)

# 3. Check SQLite performance
:ok = Exqlite.Sqlite3.execute(conn, "PRAGMA optimize")
```

### Growing Queue

**Symptom**: Migration queue keeps growing

**Possible Causes:**
1. `batch_size` too large
2. Flush too slow (SQLite bottleneck)
3. Too many migrations happening

**Solutions:**
```elixir
# 1. Reduce batch size
batch_size: 50  # Instead of 100

# 2. Increase flush frequency
flush_interval: 1000  # 1s instead of 5s

# 3. Manual flush if needed
PState.MigrationWriter.flush()
```

### High Memory Usage

**Symptom**: Process memory growing

**Possible Causes:**
1. Large cache
2. Large migration queue
3. Many large entities in memory

**Solutions:**
```elixir
# 1. Limit cache size (future enhancement)
# 2. Reduce batch size
batch_size: 25

# 3. Process.send_after for cleanup
defp schedule_cache_cleanup do
  Process.send_after(self(), :cleanup_cache, :timer.minutes(10))
end
```

## 9. Advanced: Custom Adapters

For specialized storage needs, implement custom adapter:

```elixir
defmodule MyApp.RedisAdapter do
  @behaviour PState.Adapter

  @impl true
  def init(opts) do
    {:ok, conn} = Redix.start_link(opts)
    {:ok, %{conn: conn}}
  end

  @impl true
  def get(%{conn: conn}, key) do
    case Redix.command(conn, ["GET", key]) do
      {:ok, nil} -> {:ok, nil}
      {:ok, value} -> {:ok, Jason.decode!(value)}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def multi_get(%{conn: conn}, keys) do
    case Redix.command(conn, ["MGET" | keys]) do
      {:ok, values} ->
        results = keys
        |> Enum.zip(values)
        |> Enum.reject(fn {_, v} -> is_nil(v) end)
        |> Map.new(fn {k, v} -> {k, Jason.decode!(v)} end)

        {:ok, results}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # ... implement other callbacks
end
```

## Summary

1. **Use Preloading** for batch operations
2. **Tune MigrationWriter** for your workload
3. **Monitor Telemetry** events
4. **Optimize SQLite** settings
5. **Benchmark** against targets
6. **Setup Alerts** for queue size and slow operations

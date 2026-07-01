defmodule LeythersCom.Intelligence.LLMGuard do
  @moduledoc """
  Lightweight OTP circuit breaker for LLM calls.

  It protects the pipeline from repeatedly hammering an unhealthy provider by
  temporarily opening the circuit after consecutive transient failures.
  """

  use GenServer

  @default_failure_threshold 4
  @default_open_cooldown_ms 30_000
  @default_open_cooldown_min_ms 2_000
  @default_open_cooldown_step_ms 2_000
  @default_open_cooldown_max_ms 30_000

  @type state :: %{
          consecutive_failures: non_neg_integer(),
          open_until_ms: integer() | nil
        }

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def allow? do
    GenServer.call(__MODULE__, :allow?)
  catch
    :exit, _ -> true
  end

  def report_success do
    GenServer.cast(__MODULE__, :success)
  end

  def report_failure do
    GenServer.cast(__MODULE__, :failure)
  end

  @impl true
  def init(_opts) do
    {:ok, %{consecutive_failures: 0, open_until_ms: nil}}
  end

  @impl true
  def handle_call(:allow?, _from, state) do
    now_ms = now_ms()

    allow? =
      case state.open_until_ms do
        nil -> true
        open_until_ms -> now_ms >= open_until_ms
      end

    next_state =
      if allow? and state.open_until_ms do
        %{state | open_until_ms: nil, consecutive_failures: 0}
      else
        state
      end

    {:reply, allow?, next_state}
  end

  @impl true
  def handle_cast(:success, state) do
    {:noreply, %{state | consecutive_failures: 0, open_until_ms: nil}}
  end

  @impl true
  def handle_cast(:failure, state) do
    threshold = config(:failure_threshold, @default_failure_threshold)
    failures = state.consecutive_failures + 1

    next_state =
      if failures >= threshold do
        cooldown_ms = cooldown_ms(failures, threshold)
        %{consecutive_failures: failures, open_until_ms: now_ms() + cooldown_ms}
      else
        %{state | consecutive_failures: failures}
      end

    {:noreply, next_state}
  end

  defp config(key, default) do
    :leythers_com
    |> Application.get_env(:llm_guard, [])
    |> Keyword.get(key, default)
  end

  defp cooldown_ms(failures, threshold) do
    # Keep backwards compatibility when fixed cooldown is explicitly configured.
    guard_config = Application.get_env(:leythers_com, :llm_guard, [])

    cond do
      progressive_backoff_configured?(guard_config) ->
        progressive_cooldown_ms(guard_config, failures, threshold)

      true ->
        Keyword.get(guard_config, :open_cooldown_ms, @default_open_cooldown_ms)
    end
  end

  defp progressive_backoff_configured?(guard_config) do
    Keyword.has_key?(guard_config, :open_cooldown_min_ms) or
      Keyword.has_key?(guard_config, :open_cooldown_step_ms) or
      Keyword.has_key?(guard_config, :open_cooldown_max_ms)
  end

  defp progressive_cooldown_ms(guard_config, failures, threshold) do
    min_ms = Keyword.get(guard_config, :open_cooldown_min_ms, @default_open_cooldown_min_ms)
    step_ms = Keyword.get(guard_config, :open_cooldown_step_ms, @default_open_cooldown_step_ms)
    max_ms = Keyword.get(guard_config, :open_cooldown_max_ms, @default_open_cooldown_max_ms)

    overflow_failures = max(failures - threshold, 0)
    min(min_ms + overflow_failures * step_ms, max_ms)
  end

  defp now_ms, do: System.monotonic_time(:millisecond)
end

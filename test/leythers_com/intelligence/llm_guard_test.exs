defmodule LeythersCom.Intelligence.LLMGuardTest do
  use ExUnit.Case, async: false

  alias LeythersCom.Intelligence.LLMGuard

  setup do
    original = Application.get_env(:leythers_com, :llm_guard)

    on_exit(fn ->
      if original do
        Application.put_env(:leythers_com, :llm_guard, original)
      else
        Application.delete_env(:leythers_com, :llm_guard)
      end

      LLMGuard.report_success()
      _ = :sys.get_state(LLMGuard)
    end)

    LLMGuard.report_success()
    _ = :sys.get_state(LLMGuard)

    :ok
  end

  test "uses progressive cooldown when min/step/max config is present" do
    Application.put_env(:leythers_com, :llm_guard,
      failure_threshold: 2,
      open_cooldown_min_ms: 100,
      open_cooldown_step_ms: 50,
      open_cooldown_max_ms: 200
    )

    LLMGuard.report_failure()
    state_after_first_failure = :sys.get_state(LLMGuard)
    assert state_after_first_failure.consecutive_failures == 1
    assert state_after_first_failure.open_until_ms == nil

    LLMGuard.report_failure()
    state_after_threshold_failure = :sys.get_state(LLMGuard)

    first_cooldown_ms =
      state_after_threshold_failure.open_until_ms - System.monotonic_time(:millisecond)

    assert first_cooldown_ms <= 100
    assert first_cooldown_ms > 0

    :sys.replace_state(LLMGuard, fn _state ->
      %{consecutive_failures: 2, open_until_ms: nil}
    end)

    LLMGuard.report_failure()
    state_after_next_failure = :sys.get_state(LLMGuard)

    next_cooldown_ms = state_after_next_failure.open_until_ms - System.monotonic_time(:millisecond)

    assert next_cooldown_ms <= 150
    assert next_cooldown_ms > first_cooldown_ms
  end

  test "uses fixed cooldown when open_cooldown_ms is configured" do
    Application.put_env(:leythers_com, :llm_guard,
      failure_threshold: 2,
      open_cooldown_ms: 250
    )

    LLMGuard.report_failure()
    LLMGuard.report_failure()

    state = :sys.get_state(LLMGuard)
    cooldown_ms = state.open_until_ms - System.monotonic_time(:millisecond)

    assert cooldown_ms <= 250
    assert cooldown_ms > 0
  end
end

defmodule LeythersCom.Ingestion.RawSourceStatusMachine do
  @moduledoc """
  State machine for raw source lifecycle transitions.

  The machine keeps raw-source status changes explicit so regeneration and
  editorial completion use the same allowed transitions.
  """

  alias LeythersCom.Ingestion.RawSource
  alias LeythersCom.Repo

  @states ~w[pending processed ignored]
  @transitions %{
    "pending" => ~w[processed ignored],
    "processed" => ~w[pending],
    "ignored" => ~w[pending]
  }

  def reset_to_pending(%RawSource{} = raw_source), do: transition_to(raw_source, "pending")

  def mark_processed(%RawSource{} = raw_source), do: transition_to(raw_source, "processed")

  def mark_ignored(%RawSource{} = raw_source), do: transition_to(raw_source, "ignored")

  def transition_to(%RawSource{} = raw_source, next_state) when is_binary(next_state) do
    with :ok <- validate_state(next_state),
         :ok <- validate_transition(raw_source.status, next_state) do
      persist(raw_source, next_state)
    end
  end

  def persist(%RawSource{} = raw_source, next_state) do
    case raw_source
         |> RawSource.changeset(%{status: next_state})
         |> Repo.update() do
      {:ok, updated_source} -> {:ok, updated_source}
      {:error, changeset} -> {:error, changeset}
    end
  end

  defp validate_state(next_state) when next_state in @states, do: :ok
  defp validate_state(_next_state), do: {:error, :invalid_state}

  defp validate_transition(current_state, next_state) do
    allowed = Map.get(@transitions, current_state, [])

    if Enum.member?(allowed, next_state) do
      :ok
    else
      {:error, {:invalid_transition, current_state, next_state}}
    end
  end
end

defmodule LeythersCom.Intelligence.LLMClientTest do
  use ExUnit.Case, async: true

  alias LeythersCom.Intelligence.LLMClient

  defmodule FakeAdapter do
    @behaviour LeythersCom.Intelligence.LLMClient

    @impl true
    def generate(prompt, opts) do
      {:ok, %{text: "echo: " <> prompt, model: opts[:model] || "fake"}}
    end
  end

  test "uses configured adapter and merges config with opts" do
    original = Application.get_env(:leythers_com, :llm)

    on_exit(fn ->
      if original do
        Application.put_env(:leythers_com, :llm, original)
      else
        Application.delete_env(:leythers_com, :llm)
      end
    end)

    Application.put_env(:leythers_com, :llm,
      adapter: FakeAdapter,
      model: "config-model"
    )

    assert {:ok, %{text: "echo: test prompt", model: "override-model"}} =
             LLMClient.generate("test prompt", model: "override-model")
  end
end

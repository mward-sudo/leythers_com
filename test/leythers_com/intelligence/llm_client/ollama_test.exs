defmodule LeythersCom.Intelligence.LLMClient.OllamaTest do
  use ExUnit.Case, async: true

  alias LeythersCom.Intelligence.LLMClient.Ollama

  defmodule FakeHTTPClient do
    def post(_url, _opts) do
      {:ok,
       %{
         status: 200,
         body: %{
           "response" => "Generated output",
           "model" => "llama3.1:8b"
         }
       }}
    end
  end

  defmodule FakeErrorHTTPClient do
    def post(_url, _opts), do: {:error, :econnrefused}
  end

  test "returns generated text on success" do
    assert {:ok, %{text: "Generated output", model: "llama3.1:8b"}} =
             Ollama.generate(
               "prompt",
               [endpoint: "http://127.0.0.1:11434", model: "llama3.1:8b"],
               FakeHTTPClient
             )
  end

  test "returns transport error when request fails" do
    assert {:error, :econnrefused} =
             Ollama.generate(
               "prompt",
               [endpoint: "http://127.0.0.1:11434", model: "llama3.1:8b"],
               FakeErrorHTTPClient
             )
  end

  test "normalizes endpoint with trailing slash" do
    assert {:ok, %{text: "Generated output", model: "llama3.1:8b"}} =
             Ollama.generate(
               "prompt",
               [endpoint: "http://127.0.0.1:11434/", model: "llama3.1:8b"],
               FakeHTTPClient
             )
  end
end

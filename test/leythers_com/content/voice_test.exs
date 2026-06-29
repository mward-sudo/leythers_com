defmodule LeythersCom.Content.VoiceTest do
  use ExUnit.Case, async: true

  alias LeythersCom.Content.Voice

  describe "apply/2" do
    test "adds rumour labeling and fan signoff" do
      styled =
        Voice.apply(
          %{
            title: "Leigh linked with late-window move",
            body: "Initial source summary"
          },
          rumour: true
        )

      assert styled.title == "Rumour: Leigh linked with late-window move"
      assert styled.body =~ "Rumour mill warning"
      assert styled.body =~ "Terrace verdict"
    end

    test "avoids duplicating existing rumour label" do
      styled =
        Voice.apply(
          %{
            title: "Rumour: Leigh linked with late-window move",
            body: "Rumour mill warning: treat this as chatter until confirmed."
          },
          rumour: true
        )

      assert styled.title == "Rumour: Leigh linked with late-window move"
      assert String.split(styled.body, "Rumour mill warning") |> length() == 2
    end
  end
end

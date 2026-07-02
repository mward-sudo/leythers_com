defmodule LeythersCom.Content.VoiceTest do
  use ExUnit.Case, async: true

  alias LeythersCom.Content.Voice

  describe "apply/2" do
    test "adds rumour labeling without appending a repeated signoff" do
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
      refute styled.body =~ "Terrace verdict"
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

    test "uses an override profile when provided" do
      styled =
        Voice.apply(
          %{
            title: "Leigh linked with late-window move",
            body: "Initial source summary"
          },
          rumour: true,
          profile: [
            rumour_title_prefix: "Speculation:",
            rumour_notice: "Speculation only until official confirmation.",
            fan_signoff: "Fan verdict: write it in marker, not pen."
          ]
        )

      assert styled.title == "Speculation: Leigh linked with late-window move"
      assert styled.body =~ "Speculation only until official confirmation."
      refute styled.body =~ "Fan verdict: write it in marker, not pen."
    end
  end
end

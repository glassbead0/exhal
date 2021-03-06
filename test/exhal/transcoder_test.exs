defmodule ExHal.TranscoderTest do
  use ExUnit.Case

  setup do
    hal = """
    {
      "thing" : 1,
      "TheOtherThing": 2,
      "yer_mom": true,
      "_links": {
        "up": { "href": "http://example.com/1" },
        "none": [],
        "nolink": { "href": null},
        "tag": [
          {"href": "foo:1"},
          {"href": "http://2"},
          {"href": "urn:1"}
        ],
        "nested": { "href": "http://example.com/2" },
        "fillin": { "href": "http://example.com/3{?data}", "templated": true}
      }
    }
    """

    {:ok, doc: ExHal.Document.parse!(ExHal.client, hal)}
  end

  test "can we make the most simple transcoder", %{doc: doc} do
    defmodule MyTranscoder do
      use ExHal.Transcoder
    end

    assert MyTranscoder.decode!(doc) == %{}
    assert %ExHal.Document{} = MyTranscoder.encode!(%{})
  end

  test "transcode properties", %{doc: doc} do
    defmodule NegationConverter do
      @behaviour ExHal.Transcoder.ValueConverter
      def to_hal(val), do: val * -1
      def from_hal(val), do: val * -1
    end
    defmodule MyOverreachingTranscoder do
      use ExHal.Transcoder

      defproperty "thing"
      defproperty "TheOtherThing", param: :thing2, value_converter: NegationConverter
      defproperty "missingThing",  param: :thing3
      defproperty "yer_mom", param: [:yer, :mom]
    end

    assert %{thing: 1, thing2: -2, yer: %{mom: true}} == MyOverreachingTranscoder.decode!(doc)

    encoded = MyOverreachingTranscoder.encode!(%{thing: 1, thing2: 2, yer: %{mom: true}})
    assert 1 == ExHal.get_lazy(encoded, "thing", fn -> :missing end)
    assert -2 == ExHal.get_lazy(encoded, "TheOtherThing", fn -> :missing end)
    assert true == ExHal.get_lazy(encoded, "yer_mom", fn -> :missing end)
    assert :missing == ExHal.get_lazy(encoded, "missingThing", fn -> :missing end)
  end

  test "re-using transcode params" do
    defmodule MySimpleTranscoder do
      use ExHal.Transcoder

      defproperty "firstUse",  param: :thing
      defproperty "secondUse", param: :thing
    end

    encoded = MySimpleTranscoder.encode!(%{thing: "thing_value"})

    assert "thing_value" == ExHal.get_lazy(encoded, "firstUse",  fn -> :missing end)
    assert "thing_value" == ExHal.get_lazy(encoded, "secondUse", fn -> :missing end)
  end

  test "transcoding with dynamic value converters" do
    defmodule DynamicConverter do
      @behaviour ExHal.Transcoder.ValueConverterWithOptions

      def to_hal(val, factor: multiplier), do: val * multiplier
      def from_hal(val, factor: divisor), do: val / divisor
    end

    defmodule DynamicTranscoder do
      use ExHal.Transcoder

      defproperty "thing", value_converter: DynamicConverter
    end

    encoded = DynamicTranscoder.encode!(%{thing: 2}, factor: 2)
    assert 4 == ExHal.get_lazy(encoded, "thing", fn -> :missing end)
    decoded = DynamicTranscoder.decode!(encoded, factor: 2)
    assert 2 == decoded[:thing]
  end

  test "extract links", %{doc: doc} do
    defmodule MyLinkTranscoder do
      use ExHal.Transcoder

      deflink "up", param: :mylink
      deflink "none", param: :none
      deflink "nolink", param: :nolink
      deflink "nested", param: [:nested, :url]
      deflink "fillin", param: :fillin, templated: true
    end

    assert MyLinkTranscoder.decode!(doc) == %{mylink: "http://example.com/1",
                                              nested: %{url: "http://example.com/2"},
                                              fillin: "http://example.com/3{?data}"
                                             }

    encoded = MyLinkTranscoder.encode!(%{mylink: "http://example.com/1",
                                         nested: %{url: "http://example.com/2"},
                                         fillin: "http://example.com/3{?data}"})

    assert {:ok, "http://example.com/1"} == ExHal.link_target(encoded, "up")
    assert {:ok, "http://example.com/2"} == ExHal.link_target(encoded, "nested")
    assert {:ok, "http://example.com/3?data=INFO"} == ExHal.link_target(encoded, "fillin", tmpl_vars: [data: "INFO"])
  end

  test "don't try to extract links from document that has no links" do
    defmodule MyTinyTranscoder do
      use ExHal.Transcoder

      deflink "up", param: :mylink
    end

    hal = """
    {
      "_links": {}
    }
    """

    doc = ExHal.Document.parse!(ExHal.client, hal)
    assert MyTinyTranscoder.decode!(doc) == %{}
  end

  test "trying to extract multiple links", %{doc: doc} do
    defmodule MyOtherMultiLinkTranscoder do
      use ExHal.Transcoder

      deflinks "tag", param: :tag
    end

    %{tag: tags} = MyOtherMultiLinkTranscoder.decode!(doc)

    assert Enum.member?(tags, "foo:1")
    assert Enum.member?(tags, "http://2")
    assert Enum.member?(tags, "urn:1")

    encoded = MyOtherMultiLinkTranscoder.encode!(%{tag: ["urn:1", "http://2", "foo:1"]})

    assert {:ok, ["urn:1", "http://2", "foo:1"]} == ExHal.link_targets(encoded, "tag")
  end


  test "trying to extract links with value conversion", %{doc: doc} do
    defmodule MyLinkConverter do
      @behaviour ExHal.Transcoder.ValueConverter

      def to_hal(id) do
        "http://example.com/#{id}"
      end

      def from_hal(up_url) do
        {id, _} = up_url
        |> String.split("/")
        |> List.last
        |> Integer.parse
        id
      end
    end

    defmodule MyLinkConversionTranscoder do
      use ExHal.Transcoder

      deflink "up", param: :up_id, value_converter: MyLinkConverter
    end

    assert MyLinkConversionTranscoder.decode!(doc) == %{up_id: 1}

    encoded = MyLinkConversionTranscoder.encode!(%{up_id: 2})
    assert {:ok, "http://example.com/2"} == ExHal.link_target(encoded, "up")
  end

  test "composable transcoders", %{doc: doc} do
    defmodule BaseTranscoder do
      use ExHal.Transcoder
      defproperty "thing"
      deflink "up", param: :up_url
    end

    defmodule ExtTranscoder do
      use ExHal.Transcoder
      defproperty "TheOtherThing", param: :thing2
      deflinks "tag", param: :tag
    end

    decoded = BaseTranscoder.decode!(doc)
    |> ExtTranscoder.decode!(doc)

    assert %{thing: 1} = decoded
    assert %{thing2: 2} = decoded
    assert %{up_url: "http://example.com/1"} = decoded

    %{tag: tags} = decoded

    assert Enum.member?(tags, "foo:1")
    assert Enum.member?(tags, "http://2")
    assert Enum.member?(tags, "urn:1")

    params = %{thing: 1,
               tag: ["urn:1", "http://2", "foo:1"],
               thing2: 2,
               up_url: "http://example.com/1"}

    encoded = BaseTranscoder.encode!(params)
    |> ExtTranscoder.encode!(params)

    assert 1 == ExHal.get_lazy(encoded, "thing", fn -> :missing end)
    assert 2 == ExHal.get_lazy(encoded, "TheOtherThing", fn -> :missing end)

    assert {:ok, "http://example.com/1"} == ExHal.link_target(encoded, "up")
    assert {:ok, ["urn:1", "http://2", "foo:1"]} == ExHal.link_targets(encoded, "tag")
  end
end

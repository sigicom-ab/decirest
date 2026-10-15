-module(decirest_schema_tests).

-include_lib("eunit/include/eunit.hrl").

render(Schema) -> iolist_to_binary(decirest_schema:schema_to_md(Schema)).

count(Bin, Pattern) -> length(binary:matches(Bin, Pattern)).

has(Bin, Pattern) -> binary:match(Bin, Pattern) =/= nomatch.

assert_balanced(Md) ->
    %% also guards against non-utf8 binary literals in the renderer
    ?assertEqual(Md, unicode:characters_to_binary(Md)),
    ?assertEqual(count(Md, <<"<div">>), count(Md, <<"</div>">>)),
    ?assertEqual(count(Md, <<"<details">>), count(Md, <<"</details>">>)),
    ?assertEqual(count(Md, <<"<summary>">>), count(Md, <<"</summary>">>)).

%% every HTML block tag must start at column 0 or marked will misparse it
assert_tags_at_column_0(Md) ->
    ?assertNot(has(Md, <<" <div">>)),
    ?assertNot(has(Md, <<" </div>">>)),
    ?assertNot(has(Md, <<" <details">>)).

plain_object_test() ->
    Schema =
        #{<<"title">> => <<"thing">>,
          <<"type">> => <<"object">>,
          <<"required">> => [<<"zeta">>],
          <<"properties">> =>
              #{<<"alpha">> => #{<<"type">> => <<"string">>, <<"format">> => <<"date-time">>},
                <<"zeta">> => #{<<"type">> => <<"integer">>, <<"minimum">> => 0}}},
    Md = render(Schema),
    assert_balanced(Md),
    assert_tags_at_column_0(Md),
    ?assert(has(Md, <<"Schema\n---\n">>)),
    ?assert(has(Md, <<"**thing** `object`">>)),
    ?assert(has(Md, <<"**zeta** `integer` <span class=\"req\">required</span>">>)),
    ?assert(has(Md, <<"*format*: `date-time`">>)),
    ?assert(has(Md, <<"*minimum*: `0`">>)),
    {Zeta, _} = binary:match(Md, <<"**zeta**">>),
    {Alpha, _} = binary:match(Md, <<"**alpha**">>),
    % required should be before other properties
    ?assert(Zeta < Alpha).

custom_title_test() ->
    Md = iolist_to_binary(decirest_schema:schema_to_md(<<"Output schema">>, #{})),
    ?assert(has(Md, <<"Output schema\n---\n">>)).

oneof_discriminator_test() ->
    Option =
        fun(Kind, Extra) ->
                #{<<"type">> => <<"object">>,
                  <<"properties">> =>
                      #{<<"kind">> => #{<<"const">> => Kind},
                        Extra => #{<<"type">> => <<"string">>}}}
        end,
    Schema =
        #{<<"oneOf">> =>
              [Option(<<"email">>, <<"address">>),
               Option(<<"sms">>, <<"phone">>),
               Option(<<"push">>, <<"token">>)]},
    Md = render(Schema),
    assert_balanced(Md),
    assert_tags_at_column_0(Md),
    ?assert(has(Md, <<"**One of** — exactly one of these 3 options must match"/utf8>>)),
    ?assert(has(Md, <<"<summary>Option 1 · <code>kind = \"email\"</code></summary>"/utf8>>)),
    ?assert(has(Md, <<"<summary>Option 3 · <code>kind = \"push\"</code></summary>"/utf8>>)),
    ?assertEqual(3, count(Md, <<"<details">>)),
    %% three object options, collapsed by default
    ?assertNot(has(Md, <<" open>">>)),
    %% no type is guessed for a schema that is only a oneOf
    ?assertNot(has(Md, <<"`object`\n\n<div class=\"schema-children\">\n\n<div class=\"schema-combinator">>)).

oneof_title_and_required_labels_test() ->
    Schema =
        #{<<"oneOf">> =>
              [#{<<"title">> => <<"By <id>">>, <<"required">> => [<<"id">>]},
               #{<<"required">> => [<<"name">>, <<"group">>]}]},
    Md = render(Schema),
    assert_balanced(Md),
    ?assert(has(Md, <<"Option 1 · By &lt;id&gt;</summary>"/utf8>>)),
    ?assert(has(Md, <<"Option 2 · requires: <code>name</code>, <code>group</code></summary>"/utf8>>)),
    %% two options are shown open
    ?assertEqual(2, count(Md, <<"<details class=\"schema-option\" open>">>)).

properties_and_oneof_test() ->
    Schema =
        #{<<"type">> => <<"object">>,
          <<"properties">> => #{<<"id">> => #{<<"type">> => <<"integer">>}},
          <<"oneOf">> =>
              [#{<<"properties">> => #{<<"a">> => #{<<"type">> => <<"string">>}}},
               #{<<"properties">> => #{<<"b">> => #{<<"type">> => <<"string">>}}}]},
    Md = render(Schema),
    assert_balanced(Md),
    assert_tags_at_column_0(Md),
    {Id, _} = binary:match(Md, <<"**id**">>),
    {OneOf, _} = binary:match(Md, <<"**One of**">>),
    ?assert(Id < OneOf).

array_items_oneof_test() ->
    Schema =
        #{<<"type">> => <<"array">>,
          <<"items">> =>
              #{<<"oneOf">> => [#{<<"type">> => <<"string">>}, #{<<"type">> => <<"integer">>}]}},
    Md = render(Schema),
    assert_balanced(Md),
    ?assert(has(Md, <<"`array`">>)),
    ?assert(has(Md, <<"**items**">>)),
    ?assert(has(Md, <<"Option 1 · <code>string</code>"/utf8>>)),
    ?assert(has(Md, <<"Option 2 · <code>integer</code>"/utf8>>)).

array_of_plain_type_test() ->
    Schema = #{<<"type">> => <<"array">>, <<"items">> => #{<<"type">> => <<"string">>}},
    Md = render(Schema),
    ?assert(has(Md, <<"`array of string`">>)),
    ?assertNot(has(Md, <<"**items**">>)).

scalar_oneof_test() ->
    Schema =
        #{<<"oneOf">> =>
              [#{<<"type">> => <<"string">>},
               #{<<"type">> => <<"null">>},
               #{<<"enum">> => [1, 2]}]},
    Md = render(Schema),
    assert_balanced(Md),
    ?assert(has(Md, <<"Option 2 · <code>null</code>"/utf8>>)),
    ?assert(has(Md, <<"Option 3 · <code>enum</code>"/utf8>>)),
    ?assert(has(Md, <<"*allowed values*: `1`, `2`">>)),
    %% scalar options have nothing to hide, so they are open
    ?assertEqual(3, count(Md, <<" open>">>)).

anyof_allof_test() ->
    Schema =
        #{<<"anyOf">> => [#{<<"type">> => <<"string">>}],
          <<"allOf">> => [#{<<"$ref">> => <<"#/definitions/base">>}]},
    Md = render(Schema),
    assert_balanced(Md),
    ?assert(has(Md, <<"**Any of** — this schema must match"/utf8>>)),
    ?assert(has(Md, <<"**All of** — this schema must match"/utf8>>)),
    ?assert(has(Md, <<"Part 1 · <code>#/definitions/base</code>"/utf8>>)).

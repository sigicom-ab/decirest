%%%-------------------------------------------------------------------
%%% @author jonathan
%%% @copyright (C) 2020
%%% @doc
%%% Render a JSON schema as markdown for the API documentation.
%%%
%%% The output mixes markdown with HTML blocks. To keep marked from
%%% misparsing it, every HTML tag is put on its own line at column 0,
%%% surrounded by blank lines, and nesting is expressed with wrapper
%%% elements (styled in documentation_style.css) instead of indentation.
%%% @end
%%% Created : 26. Oct 2020 20:14
%%%-------------------------------------------------------------------
-module(decirest_schema).

-author("jonathan").

%% API
-export([schema_to_md/1,
         schema_to_md/2]).

-define(COMBINATORS, [<<"oneOf">>, <<"anyOf">>, <<"allOf">>]).

schema_to_md(Json) -> schema_to_md(<<"Schema">>, Json).

schema_to_md(Title, Json) ->
    [Title,
     <<"\n---\n\n">>,
     node_md(maps:get(<<"title">>, as_map(Json), undefined), Json, false, <<"schema-node">>)].

%%%===================================================================
%%% Nodes
%%%===================================================================

node_md(Name, Json0, Required, Class) ->
    Json = as_map(Json0),
    [<<"<div class=\"">>, Class, <<"\">\n\n">>,
     header_md(Name, Json, Required),
     description_md(Json),
     constraints_md(Json),
     children_md(Json),
     <<"</div>\n\n">>].

header_md(Name, Json, Required) ->
    Parts =
        [P
         || P <- [name_md(Name),
                  type_md(type_label(Json)),
                  required_md(Required)],
            P =/= []],
    case Parts of
        [] -> [];
        _ -> [lists:join(<<" ">>, Parts), <<"\n\n">>]
    end.

name_md(undefined) -> [];
name_md(<<>>) -> [];
name_md(Name) -> [<<"**">>, Name, <<"**">>].

type_md(undefined) -> [];
type_md(Label) -> code_md(Label).

required_md(true) -> <<"<span class=\"req\">required</span>">>;
required_md(false) -> [].

description_md(#{<<"description">> := Description}) -> [Description, <<"\n\n">>];
description_md(_) -> [].

%% Infer a human readable type; a schema without "type" is not
%% necessarily an object (it can be a oneOf, a const, a $ref...).
type_label(#{<<"type">> := Types}) when is_list(Types) ->
    iolist_to_binary(lists:join(<<" | ">>, Types));
type_label(#{<<"type">> := <<"array">>} = Json) -> array_label(Json);
type_label(#{<<"type">> := Type}) -> Type;
type_label(#{<<"$ref">> := Ref}) -> Ref;
type_label(#{<<"properties">> := _}) -> <<"object">>;
type_label(#{<<"items">> := _} = Json) -> array_label(Json);
type_label(#{<<"const">> := _}) -> <<"const">>;
type_label(#{<<"enum">> := _}) -> <<"enum">>;
type_label(_) -> undefined.

array_label(#{<<"items">> := Items}) when is_map(Items) ->
    case type_label(Items) of
        undefined -> <<"array">>;
        ItemType -> <<"array of ", ItemType/binary>>
    end;
array_label(_) -> <<"array">>.

%%%===================================================================
%%% Constraints
%%%===================================================================

constraints_md(Json) ->
    Constraints =
        [C
         || C <- [constraint(K, Json)
                  || K <- [<<"const">>,
                           <<"enum">>,
                           <<"default">>,
                           <<"format">>,
                           <<"pattern">>,
                           <<"minimum">>,
                           <<"exclusiveMinimum">>,
                           <<"maximum">>,
                           <<"exclusiveMaximum">>,
                           <<"minLength">>,
                           <<"maxLength">>,
                           <<"minItems">>,
                           <<"maxItems">>,
                           <<"uniqueItems">>,
                           <<"additionalProperties">>]],
            C =/= []],
    case Constraints of
        [] -> [];
        _ -> [lists:join(<<" · "/utf8>>, Constraints), <<"\n\n">>]
    end.

constraint(<<"enum">>, #{<<"enum">> := Values}) ->
    [<<"*allowed values*: ">>, lists:join(<<", ">>, [code_md(json(V)) || V <- Values])];
constraint(<<"default">>, #{<<"default">> := #{<<"element">> := _}}) -> [];
constraint(<<"format">>, #{<<"format">> := Format}) ->
    [<<"*format*: ">>, code_md(Format)];
constraint(<<"pattern">>, #{<<"pattern">> := Pattern}) ->
    [<<"*pattern*: ">>, code_md(Pattern)];
constraint(<<"uniqueItems">>, #{<<"uniqueItems">> := true}) -> <<"*unique items*">>;
constraint(<<"uniqueItems">>, _) -> [];
constraint(<<"additionalProperties">>, #{<<"additionalProperties">> := false}) ->
    <<"*no additional properties*">>;
constraint(<<"additionalProperties">>, _) -> [];
constraint(Key, Json) ->
    case Json of
        #{Key := Value} -> [<<"*">>, Key, <<"*: ">>, code_md(json(Value))];
        _ -> []
    end.

%%%===================================================================
%%% Children: properties, array items and combinators
%%%===================================================================

children_md(Json) ->
    case [properties_md(Json), items_md(Json), combinators_md(Json)] of
        [[], [], []] -> [];
        Children -> [<<"<div class=\"schema-children\">\n\n">>, Children, <<"</div>\n\n">>]
    end.

properties_md(Json) ->
    Properties = maps:get(<<"properties">>, Json, #{}),
    Required = maps:get(<<"required">>, Json, []),
    Sorted =
        lists:sort(fun({A, _}, {B, _}) ->
                           {not lists:member(A, Required), A} =< {not lists:member(B, Required), B}
                   end,
                   maps:to_list(Properties)),
    [node_md(Name, Prop, lists:member(Name, Required), <<"schema-node">>)
     || {Name, Prop} <- Sorted].

%% A plain item type is already shown in the "array of X" type label,
%% only render the items as a node if there is more to say about them.
items_md(#{<<"items">> := Items}) when is_map(Items) ->
    case maps:without([<<"type">>, <<"title">>], Items) of
        Empty when map_size(Empty) =:= 0 -> [];
        _ -> node_md(<<"items">>, Items, false, <<"schema-node">>)
    end;
items_md(_) -> [].

combinators_md(Json) ->
    [combinator_md(Kind, Options) || Kind <- ?COMBINATORS, {ok, Options} <- [maps:find(Kind, Json)]].

combinator_md(Kind, Options) ->
    N = length(Options),
    Discriminator = discriminator(Options),
    {Heading, OptionName} = combinator_text(Kind),
    [<<"<div class=\"schema-combinator schema-">>, string:lowercase(Kind), <<"\">\n\n">>,
     <<"**">>, Heading, <<"** — "/utf8>>, combinator_explanation(Kind, N), <<"\n\n">>,
     [option_md(OptionName, I, as_map(Option), Discriminator, N)
      || {I, Option} <- lists:zip(lists:seq(1, N), Options)],
     <<"</div>\n\n">>].

combinator_text(<<"oneOf">>) -> {<<"One of">>, <<"Option">>};
combinator_text(<<"anyOf">>) -> {<<"Any of">>, <<"Option">>};
combinator_text(<<"allOf">>) -> {<<"All of">>, <<"Part">>}.

combinator_explanation(_Kind, 1) -> <<"this schema must match">>;
combinator_explanation(<<"oneOf">>, N) ->
    [<<"exactly one of these ">>, integer_to_binary(N), <<" options must match">>];
combinator_explanation(<<"anyOf">>, N) ->
    [<<"at least one of these ">>, integer_to_binary(N), <<" options must match">>];
combinator_explanation(<<"allOf">>, N) ->
    [<<"all of these ">>, integer_to_binary(N), <<" schemas must match">>].

option_md(OptionName, I, Option, Discriminator, N) ->
    Open =
        case N =< 2 orelse not has_nested(Option) of
            true -> <<" open">>;
            false -> <<>>
        end,
    Summary =
        case option_label(Option, Discriminator) of
            [] -> [OptionName, <<" ">>, integer_to_binary(I)];
            Label -> [OptionName, <<" ">>, integer_to_binary(I), <<" · "/utf8>>, Label]
        end,
    [<<"<details class=\"schema-option\"">>, Open, <<">\n">>,
     <<"<summary>">>, Summary, <<"</summary>\n\n">>,
     node_md(undefined, Option, false, <<"schema-node schema-option-body">>),
     <<"</details>\n\n">>].

has_nested(Json) ->
    lists:any(fun(K) -> maps:is_key(K, Json) end,
              [<<"properties">>, <<"items">> | ?COMBINATORS]).

%% The summary is inside an HTML block, so the label is HTML, not markdown.
option_label(#{<<"title">> := Title}, _) -> html_escape(Title);
option_label(Option, {ok, Prop}) ->
    {ok, Value} = discriminator_value(Option, Prop),
    [<<"<code>">>, html_escape(Prop), <<" = ">>, html_escape(json(Value)), <<"</code>">>];
option_label(#{<<"required">> := [_ | _] = Required}, _) ->
    [<<"requires: ">>,
     lists:join(<<", ">>, [[<<"<code>">>, html_escape(R), <<"</code>">>] || R <- Required])];
option_label(Option, _) ->
    case type_label(Option) of
        undefined -> [];
        Type -> [<<"<code>">>, html_escape(Type), <<"</code>">>]
    end.

%% A discriminator is a property that every option pins to a single
%% value (const or one-element enum), with a different value per option.
discriminator(Options = [First, _ | _]) ->
    case lists:all(fun is_map/1, Options) of
        false -> undefined;
        true ->
            Candidates = lists:sort(maps:keys(maps:get(<<"properties">>, First, #{}))),
            find_discriminator(Candidates, Options)
    end;
discriminator(_) -> undefined.

find_discriminator([], _Options) -> undefined;
find_discriminator([Prop | Props], Options) ->
    Values = [discriminator_value(O, Prop) || O <- Options],
    case lists:all(fun(V) -> V =/= undefined end, Values)
         andalso length(lists:usort(Values)) =:= length(Values) of
        true -> {ok, Prop};
        false -> find_discriminator(Props, Options)
    end.

discriminator_value(Option, Prop) ->
    case maps:get(Prop, maps:get(<<"properties">>, Option, #{}), undefined) of
        #{<<"const">> := Value} -> {ok, Value};
        #{<<"enum">> := [Value]} -> {ok, Value};
        _ -> undefined
    end.

%%%===================================================================
%%% Helpers
%%%===================================================================

%% boolean schemas (true/false) have nothing to document
as_map(Json) when is_map(Json) -> Json;
as_map(_) -> #{}.

json(Value) -> iolist_to_binary(jiffy:encode(Value)).

code_md(Text0) ->
    Text = iolist_to_binary(Text0),
    case binary:match(Text, <<"`">>) of
        nomatch -> [<<"`">>, Text, <<"`">>];
        _ -> [<<"`` ">>, Text, <<" ``">>]
    end.

html_escape(Text) ->
    lists:foldl(fun({From, To}, Acc) -> binary:replace(Acc, From, To, [global]) end,
                iolist_to_binary(Text),
                [{<<"&">>, <<"&amp;">>}, {<<"<">>, <<"&lt;">>}, {<<">">>, <<"&gt;">>}]).

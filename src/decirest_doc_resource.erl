%%%-------------------------------------------------------------------
%%% @author mikael
%%% @copyright (C) 2020, SIGICOM
%%% @doc
%%%
%%% @end
%%% Created : 23. Nov 2020 22:57
%%%-------------------------------------------------------------------
-module(decirest_doc_resource).

-author("jso").

%% API
-export([name/0,
         paths/0,
         child_of/0,
         resource_exists/2,
         fetch_data/2,
         to_fun/2,
         to_html/2,
         doc_map_to_md/1]).

-type req() :: cowboy_req:req().

name() -> <<"documentation">>.

paths() ->
    [{"/apidoc/path/[...]", decirest_single_handler},
     {"/apidoc/name/:name", decirest_single_handler}].

child_of() -> [].

resource_exists(Req = #{path := <<"/apidoc/path", Path/binary>>},
                State =
                    #{ref := Ref,
                      mro_call := true}) ->
    PathDoc = decirest_doc_lib:fetch_doc_by_path(Ref, Req#{path => Path}, State),
    parse_doc_output(PathDoc, Req, State);
resource_exists(Req,
                State =
                    #{ref := Ref,
                      mro_call := true}) ->
    %% fetch by name
    Name = decirest_req:binding(name, Req),
    Module = get_module_from_doc_name(Ref, Name),
    ModuleDoc = decirest_doc_lib:fetch_doc_by_module(Ref, Module, Req, State),
    parse_doc_output(ModuleDoc, Req, State);
resource_exists(Req, State) -> {run_default, [Req, State]}.

fetch_data(_Filter, #{docs := Docs}) -> {ok, [Docs]}.

to_fun(Req,
       State =
           #{module := Module,
             rstate := RState}) ->
    #{Module := #{data := Data}} = RState,
    Body = doc_map_to_md(Data),
    {Body, Req, State}.

to_html(Req, State) ->
    {Body, Req, _State} = to_fun(Req, State),
    {ok, Css} = get_css_file(),
    PreMd =
        <<"<!doctype html>  <html>  <head>",
          "<meta charset='utf-8'/>  <title>API DOC</title> <style>",
          Css/binary,
          "</style> </head>  <body>  <div id='content'></div>  <script type='text/markdown' id='raw'>">>,
    %% the markdown is kept in a non-executed script tag so the browser
    %% hands it to marked untouched, only "</script" has to be escaped
    Script =
        <<"<script src='https://cdn.jsdelivr.net/npm/marked@18.1.1/lib/marked.umd.js'></script>",
          "<script>document.getElementById('content').innerHTML=marked.parse(",
          "document.getElementById('raw').textContent.split('<\\\\/script').join('<' + '/script'));",
          "</script>">>,
    PostMd = <<"</script>", Script/binary, "</body></html>">>,
    {<<PreMd/binary, (escape_script_end(Body))/binary, PostMd/binary>>, Req, State}.

escape_script_end(Body) ->
    re:replace(Body, "</script", "<\\\\/script", [global, caseless, {return, binary}]).

parse_doc_output(Docs = #{module := Module}, Req, #{ref := Ref} = State) ->
    D = maps:merge(Docs, get_extra_docs(Ref, Module)),
    TmpState = State#{docs => maybe_fix_paths(D)},
    decirest_single_handler:resource_exists_default(Req, TmpState);
parse_doc_output(_, Req, State) -> {stop, Req, State}.

get_module_from_doc_name(Ref, Name) ->
    Modules = decirest:get_modules(Ref),
    get_module_from_doc_name(Ref, Modules, Name).

get_module_from_doc_name(Ref, [Module | Modules], Name) ->
    case decirest:apply_with_default(Module, doc, [], #{name => decirest:t2b(Module)}) of
        #{name := Name} -> Module;
        _ -> get_module_from_doc_name(Ref, Modules, Name)
    end;
get_module_from_doc_name(_Ref, [], _Name) -> undefined.

get_css_file() ->
    Path = code:priv_dir(decirest),
    F = filename:join([Path, "documentation_style.css"]),
    file:read_file(F).

get_extra_docs(Ref, Module) ->
    case code:priv_dir(Ref) of
        {error, _} ->
            lager:critical("no priv dir for ~p", [Ref]),
            #{};
        Path ->
            F = filename:join([Path, "doc", [atom_to_list(Module) | ".md"]]),
            case file:read_file(F) of
                {error, _} ->
                    lager:info("no data, ~p", [F]),
                    #{};
                {ok, Markdown} -> #{markdown_extra => Markdown}
            end
    end.

-spec maybe_fix_paths(req()) -> req().
maybe_fix_paths(Map = #{paths := Paths}) ->
    Map#{paths => [P || P = <<"/api", _/binary>> <- Paths]}.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%                                                                       %%
%%                          Markdown generation                          %%
%%                                                                       %%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

doc_map_to_md(Map = #{name := Name}) ->
    Sections =
        [{description, fun desc_md/1},
         {allowed_methods, fun am_md/1},
         {paths, fun paths_md/1},
         {content_types_provided, fun ctp_md/1},
         {content_types_accepted, fun cta_md/1},
         {action_schema, schema_md(<<"Action schema (POST)">>)},
         {schema, schema_md(<<"Schema">>)},
         {output_schema, schema_md(<<"Output schema">>)},
         {children, children_md(Name)},
         {markdown_extra, fun extra_md/1}],
    doc_map_to_md(Sections, Map, [<<"Resource documentation: ", Name/binary, "\n===\n\n">>]).

doc_map_to_md([{Section, Fun} | Sections], Map, Body) ->
    case Map of
        #{Section := Data} -> doc_map_to_md(Sections, Map, [Body, Fun(Data), <<"\n">>]);
        _ -> doc_map_to_md(Sections, Map, Body)
    end;
doc_map_to_md([], _Map, Body) -> iolist_to_binary(Body).

desc_md(Data) -> [<<"Description\n---\n">>, Data, <<"\n">>].

am_md(Data) -> [<<"Allowed methods\n---\n">>, md_list(Data)].

paths_md(Paths) -> ["Paths\n---\n", md_link_list(Paths)].

ctp_md(Data) -> [<<"Content-Type provided\n---\n">>, md_list(Data)].

cta_md(Data) -> [<<"Content-Type accepted\n---\n">>, md_list(Data)].

children_md(_Name) ->
    fun(ChildUrls) -> [<<"Child resources\n---\n">>, md_link_list(ChildUrls)] end.

extra_md(Data) -> Data.

schema_md(Title) -> fun(Schema) -> decirest_schema:schema_to_md(Title, Schema) end.

md_link_list(DataList) ->
    [["* [", Data, "](/apidoc/path", Data, ") \n"] || Data <- DataList].

md_list(DataList) -> [["* ", Data, "\n"] || Data <- DataList].

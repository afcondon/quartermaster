%% The BEAM twin of IO.js: read the deployment sources and the argument list.
%%
%% YAML is read by yamerl (pure Erlang, fetched and built by beam/build.sh) and
%% converted to the same `Json` js-yaml gives node. The conversion is a COPY of
%% the one in bosun/cli/src/Bosun/CLI/IO.erl, without Bosun's ${BOSUN_ROOT}
%% expansion, which Quartermaster's IO.js has never done. Two copies is a known
%% debt: the right home is one purerl YAML package that both take by path.
%% beam/conformance.sh holds this reader to js-yaml over every Bosun fixture.
-module(quartermaster_cLI_iO@foreign).
-export([readYamlImpl/0, readJsonImpl/0, readTextImpl/0, argv/0]).

readYamlImpl() -> fun(Path) -> read_yaml(Path) end.

readJsonImpl() ->
    fun(Path) ->
        Text = read(Path),
        (data_argonaut_parser@foreign:'_jsonParser'())(
          fun(Problem) -> erlang:error({not_json, Path, Problem}) end,
          fun(Json) -> Json end,
          Text)
    end.

readTextImpl() -> fun(Path) -> read(Path) end.

%% The arguments after `-extra` on the erl command line.
argv() ->
    fun() -> array:from_list([unicode:characters_to_binary(A) || A <- init:get_plain_arguments()]) end.

read(Path) ->
    case file:read_file(Path) of
        {ok, Text} -> Text;
        {error, Reason} -> erlang:error({cannot_read, Path, Reason})
    end.

read_yaml(Path) ->
    case code:ensure_loaded(yamerl_constr) of
        {module, _} -> ok;
        _ -> erlang:error({no_yaml_reader, Path,
                           <<"yamerl is not on the code path: run beam/build.sh">>})
    end,
    {ok, _} = application:ensure_all_started(yamerl),
    Text = read(Path),
    %% yamerl 0.10.0 misreads an anchor on a FLOW collection (`&name {a: 1}`):
    %% the anchor lands on the first element. A loud refusal beats a silent
    %% misreading; an anchor on a block collection is fine.
    case re:run(Text, "&[A-Za-z0-9_-]+[ \t]*[\[{]", [{capture, none}]) of
        match -> erlang:error({yaml_anchor_on_a_flow_collection, Path,
                               <<"yamerl misreads these: write the collection in block style">>});
        nomatch -> ok
    end,
    case yamerl_constr:string(Text, [{detailed_constr, true}, {str_node_as_binary, true}]) of
        [] -> null;
        [{yamerl_doc, Root} | _] -> from_yaml(Root)
    end.

%% A yamerl node -> a `Json`. Mappings keep document order, as js-yaml's do,
%% and the YAML 1.1 merge key `<<` is applied js-yaml's way.
from_yaml({yamerl_map, _, _, _, Pairs}) ->
    Explicit = [yaml_key(K) || {K, _} <- Pairs],
    lists:foldl(
      fun({K, V}, Acc) ->
          case {yaml_key(K), from_yaml(V)} of
              {<<"<<">>, Source} -> merge(sources(Source), Explicit, Acc);
              {Key, Value} -> foreign_object@foreign:put(Key, Value, Acc)
          end
      end, [], Pairs);
from_yaml({yamerl_seq, _, _, _, Items, _}) -> array:from_list([from_yaml(I) || I <- Items]);
from_yaml({yamerl_str, _, _, _, Text}) -> Text;
from_yaml({yamerl_int, _, _, _, N}) -> float(N);
from_yaml({yamerl_float, _, _, _, N}) when is_float(N) -> N;
from_yaml({yamerl_bool, _, _, _, B}) -> B;
from_yaml({yamerl_null, _, _, _}) -> null;
from_yaml(Other) -> erlang:error({yaml_node_with_no_json_form, Other}).

sources(Source) when is_list(Source) -> [Source];
sources(Source) when is_tuple(Source) ->
    Items = array:to_list(Source),
    case lists:all(fun is_list/1, Items) of
        true -> Items;
        false -> erlang:error({yaml_merge_needs_mappings, Source})
    end;
sources(Source) -> erlang:error({yaml_merge_needs_mappings, Source}).

merge(Sources, Explicit, Acc0) ->
    lists:foldl(
      fun(Source, Acc1) ->
          lists:foldl(
            fun({K, V}, Acc) ->
                case lists:member(K, Explicit) orelse lists:keymember(K, 1, Acc) of
                    true -> Acc;
                    false -> foreign_object@foreign:put(K, V, Acc)
                end
            end, Acc1, Source)
      end, Acc0, Sources).

yaml_key({yamerl_str, _, _, _, Text}) -> Text;
yaml_key(Node) ->
    case from_yaml(Node) of
        null -> <<"null">>;
        true -> <<"true">>;
        false -> <<"false">>;
        N when is_float(N) -> data_argonaut_core@foreign:stringify(N);
        Other -> erlang:error({yaml_key_with_no_string_form, Other})
    end.

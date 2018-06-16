%%% @doc Module dht_proto handles syntactical DHT protocol encoding/decoding.
%%% @end
%%% @private
-module(dht_proto).

-export([encode/1, decode/1]).

-define(VERSION1, <<175,64,13,52,167,136,55,45>>).

-type query() ::
	ping |
	{find, node | value, non_neg_integer()} |
	{store, dht:token(), dht:id(), inet:port_number()}.

-type response() ::
	ping |
	{find, node, dht:token(), [dht:peer()]} |
	{find, value, dht:token(), [dht:endpoint()]} |
	store.

-type msg() ::
	{query, dht:tag(), dht:id(), query()} |
	{response, dht:tag(), dht:id(), response()} |
	{error, dht:tag(), integer(), binary()}.

-export_type([msg/0, query/0, response/0]).

%% Encoding on the wire
%% ------------------------
header(Tag, ID) -> <<?VERSION1:8/binary, Tag/binary, ID:256>>.

encode_query(ping) -> <<$p>>;
encode_query({find, node, ID}) -> <<$f, $n, ID:256>>;
encode_query({find, value, ID}) -> <<$f, $v, ID:256>>;
encode_query({store, Token, ID, Port}) -> <<$s, Token/binary, ID:256, Port:16>>.

encode_response(ping) -> $p;
encode_response({find, node, Token, Ns}) ->
    L = length(Ns),
    [<<$f, $n, Token/binary, L:8>>, encode_nodes(Ns)];
encode_response({find, value, Token, Vs}) ->
    L = length(Vs),
    [<<$f, $v, Token/binary, L:8>>, encode_peers(Vs)];
encode_response(store) ->
    $s.

encode_peers(Vs) -> iolist_to_binary(encode_ps(Vs)).

encode_ps([]) -> [];
encode_ps([{{B1, B2, B3, B4, B5, B6, B7, B8}, Port} | Ns]) ->
    [<<6,
       B1:16/integer, B2:16/integer, B3:16/integer, B4:16/integer,
       B5:16/integer, B6:16/integer, B7:16/integer, B8:16/integer,
       Port:16/integer>> | encode_ps(Ns)];
encode_ps([{{B1, B2, B3, B4}, Port} | Ns]) ->
    [<<4,
       B1:8/integer, B2:8/integer, B3:8/integer, B4:8/integer,
       Port:16/integer>> | encode_ps(Ns)].

encode_nodes(Ns) -> iolist_to_binary(encode_ns(Ns)).

encode_ns([]) -> [];
encode_ns([{ID, {B1, B2, B3, B4, B5, B6, B7, B8}, Port} | Ns]) ->
    [<<6, ID:256,
       B1:16/integer, B2:16/integer, B3:16/integer, B4:16/integer,
       B5:16/integer, B6:16/integer, B7:16/integer, B8:16/integer,
       Port:16/integer>> | encode_ns(Ns)];
encode_ns([{ID, {B1, B2, B3, B4}, Port} | Ns]) ->
    [<<4, ID:256/integer,
       B1:8/integer, B2:8/integer, B3:8/integer, B4:8/integer,
       Port:16/integer>> | encode_ns(Ns)].

-spec encode(msg()) -> iolist().
encode({query, Tag, ID, Q}) -> [header(Tag, ID), $q, encode_query(Q)];
encode({response, Tag, ID, R}) -> [header(Tag, ID), $r, encode_response(R)];
encode({error, Tag, ID, ErrCode, ErrStr}) -> [header(Tag, ID), $e, <<ErrCode:16, ErrStr/binary>>].

%% Decoding from the wire
%% -----------------------

decode_query(<<$p>>) -> ping;
decode_query(<<$f, $n, ID:256>>) -> {find, node, ID};
decode_query(<<$f, $v, ID:256>>) -> {find, value, ID};
decode_query(<<$s, Token:8/binary, ID:256, Port:16>>) -> {store, Token, ID, Port}.

decode_response(<<$p>>) -> ping;
decode_response(<<$f, $n, Token:8/binary, L:8, Pack/binary>>) -> {find, node, Token, decode_nodes(L, Pack)};
decode_response(<<$f, $v, Token:8/binary, L:8, Pack/binary>>) -> {find, value, Token, decode_endpoints(L, Pack)};
decode_response(<<$s>>) -> store.

%% Force recognition of the correct number of incoming arguments.
decode_nodes(0, <<>>) -> [];
decode_nodes(K, <<4, ID:256, B1, B2, B3, B4, Port:16, Nodes/binary>>) ->
    [{ID, {B1, B2, B3, B4}, Port} | decode_nodes(K-1, Nodes)];
decode_nodes(K, <<6, ID:256, B1:16, B2:16, B3:16, B4:16, B5:16, B6:16, B7:16, B8:16, Port:16, Nodes/binary>>) ->
    [{ID, {B1, B2, B3, B4, B5, B6, B7, B8}, Port} | decode_nodes(K-1, Nodes)].

%% Force recognition of the correct number of incoming arguments.
decode_endpoints(0, <<>>) -> [];
decode_endpoints(K, <<4, B1, B2, B3, B4, Port:16, Nodes/binary>>) ->
    [{{B1, B2, B3, B4}, Port} | decode_endpoints(K-1, Nodes)];
decode_endpoints(K, <<6, B1:16, B2:16, B3:16, B4:16, B5:16, B6:16, B7:16, B8:16, Port:16, Nodes/binary>>) ->
    [{{B1, B2, B3, B4, B5, B6, B7, B8}, Port} | decode_endpoints(K-1, Nodes)].

-spec decode(binary()) -> msg().
decode(<<175,64,13,52,167,136,55,45, Tag:2/binary, ID:256, $q, Query/binary>>) ->
    {query, Tag, ID, decode_query(Query)};
decode(<<175,64,13,52,167,136,55,45, Tag:2/binary, ID:256, $r, Response/binary>>) ->
    {response, Tag, ID, decode_response(Response)};
decode(<<175,64,13,52,167,136,55,45, Tag:2/binary, ID:256, $e, ErrCode:16, ErrorString/binary>>) ->
    {error, Tag, ID, ErrCode, ErrorString};
decode(<<"EDHT-KDM-", 0:8, _Rest/binary>>) ->
    {error, {old_version, <<0,0,0,0,0,0,0,0>>}}.

-module(dht_eqc).

-compile(export_all).

-include_lib("eqc/include/eqc.hrl").

%% Generators
id(Min, Max) -> choose(Min, Max).

id() ->
    ?LET(<<ID:160>>, binary(20),
        ID).

ip() -> ipv4_address(). %% ipv6 support later :P
    
ipv4_address() ->
    ?LET(L, vector(4, choose(0, 255)),
        list_to_tuple(L)).
        
ipv6_address() ->
    ?LET(L, vector(8, choose(0, 255)),
        list_to_tuple(L)).

port() ->
    choose(0, 1024*64 - 1).

socket() ->
    {ip(), port()}.

peer() ->
    ?LET({ID, IP, Port}, {id(), ip(), port()},
        {ID, IP, Port}).

tag() ->
    ?LET(ID, choose(0, 16#FFFF),
        <<ID:16>>).

unique_id_pair() ->
    ?SUCHTHAT({X, Y}, {id(), id()},
      X /= Y).

range() ->
    ?LET({X, Y}, unique_id_pair(),
      {min(X,Y),
       max(X,Y)}).

token() ->
    ?LET([L, U], [choose(0, 16#FFFF), choose(0, 16#FFFF)],
        <<L:16, U:16>>).

%% Operation properties
prop_op_refl() ->
    ?FORALL(X, id(),
        dht_metric:d(X, X) == 0).

prop_op_sym() ->
    ?FORALL({X, Y}, {id(), id()},
        dht_metric:d(X, Y) == dht_metric:d(Y, X)).

prop_op_triangle_ineq() ->
    ?FORALL({X, Y, Z}, {id(), id(), id()},
        dht_metric:d(X, Y) + dht_metric:d(Y, Z) >= dht_metric:d(X, Z)).

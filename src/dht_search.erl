%%% @doc Implements recursive searching in the DHT
%%% @end
%%% @private
-module(dht_search).

%% API for iterative search functions
-export([
    run/2
]).

-define(SEARCH_WIDTH, 32).
-define(SEARCH_RETRIES, 3).

-record(search_state, {
    query_type :: find_node | find_value,
    done = gb_sets:empty() :: gb_sets:set(dht:peer()),
    alive = gb_sets:empty() :: gb_sets:set(dht:peer()),
    acc = [] :: [ {dht:peer(), dht:token(), [dht:endpoint()]} ]
}).

%% SEARCH API
%% ---------------------------------------------------

-spec run(find_node | find_value, dht:id()) -> FindNodeRes | FindValueRes
  when
      FindNodeRes :: list ( dht:peer() ),
      FindValueRes :: #{ atom() => [term()] }.
run(Type, ID) ->
    search_iterate(Type, ID, ?SEARCH_WIDTH, dht_state:closest_to(ID, ?SEARCH_WIDTH)).

%% Internal functions
%% -----------------------------

search_iterate(QType, Target, Width, Nodes)  ->
    NodeID = dht_state:node_id(),
    dht_iter_search(NodeID, Target, Width, ?SEARCH_RETRIES, Nodes,
        #search_state{ query_type = QType }).

dht_iter_search(_NodeID, _Target, _Width, 0, _Todo,
	#search_state { query_type = find_node, alive = A }) ->
    gb_sets:to_list(A);
dht_iter_search(_NodeID, _Target, _Width, 0, _Todo,
	#search_state { query_type = find_value, alive = A } = State) ->
    Res = res(State),
    #{
      store => [{N, Token} || {N, Token, _Vs} <- Res],
      found => lists:usort([V || {_, _, Vs} <- Res, V <- Vs]),
      alive => A
    };
dht_iter_search(NodeID, Target, Width, Retries, Todo, #search_state{ query_type = QType } = State) ->
    %% Call the DHT in parallel to speed up the search:
    Call = fun({_, IP, Port} = N) ->
        {N, apply(dht_net, QType, [{IP, Port}, Target])}
    end,
    CallRes = dht_par:pmap(Call, Todo),

    %% Assert there are no errors, since workers are not to die here
    {Results, [] = _Errors} = dht_par:partition(CallRes),

    %% Maintain invariants for the next round by updating the necessary data structures:
    #{ new := New, next := NextState } = track_state(Results, Todo, State),

    WorkQueue = lists:usort(dht_metric:neighborhood(Target, New, Width)),
    Retry = update_retries(NodeID, Retries, WorkQueue, NextState),
    dht_iter_search(NodeID, Target, Width, Retry, WorkQueue, NextState).

%% If the work queue contains the closest node, we are converging toward our target.
%% If not, then we decrease the retry-count by one, since it is not likely we will hit
%% a better target.
update_retries(NodeID, K, WorkQueue, State) ->
      case view_closest_node(NodeID, alive(State), WorkQueue) of
          work_queue -> ?SEARCH_RETRIES;
          alive_set -> K - 1
      end.

%% Once a round completes, track the state of the round in the #search_state{} record.
%%
%% Rules:
%% • Nodes which responded as being alive are added to the alive-set
%% • Track which nodes has been processed
%% • Accumulate the results
%%
%% Returns the next state as well as the set of newly found nodes (for the work-queue)
%%
track_state(Results, Processed,
	#search_state {
		query_type = QType,
		alive = Alive,
		done = Done,
		acc = Acc } = State) ->
    Next = State#search_state {
        alive = gb_sets:union(Alive, gb_sets:from_list( alive_nodes(Results)) ),
        done = Queried = gb_sets:union(Done, gb_sets:from_list(Processed)),
        acc = accum_peers(QType, Acc, Results)
    },
    New = [N || N <- all_nodes(Results), not gb_sets:is_member(N, Queried)],

    #{ new => New, next => Next }.

%% Select nodes from a response
resp_nodes({nodes, _, Ns}) -> Ns;
resp_nodes(_) -> [].

%% all_nodes/1 gathers nodes from a set of parallel queries
all_nodes(Resp) -> lists:concat([resp_nodes(R) || {_N, R} <- Resp]).

%% Compute if a response is ok, for use in a predicate
ok({error, _}) -> false;
ok({error, _ID, _Code, _Msg}) -> false;
ok(_) -> true.

%% alive_nodes/1 returns the nodes returned positive results
alive_nodes(Resp) -> [N || {N, R} <- Resp, ok(R)].

%% accum_peers/2 accumulates new targets with the value present
accum_peers(find_node, [], _Results) ->
    %% find_node never has results to accumulate
    [];
accum_peers(find_value, Acc, Results) ->
    New = accum_results(Results),
    New ++ Acc.

accum_results([]) -> [];
accum_results([ {_Node, {error, timeout}} | Rs ]) ->
    %% Skip if the node timed out
    accum_results(Rs);
accum_results([ {Node, {values, _, Token, Vs}} | Rs ]) ->
    [{Node, Token, Vs} | accum_results(Rs)];
accum_results([ {Node, {nodes, _, Token, _}} | Rs ]) ->
    [{Node, Token, []} | accum_results(Rs)].

%% view_closest_node/3 determines if the closest node is in the work_queue or in the alive set
view_closest_node(ID, AliveNodes, WorkQueue) ->
    DistFun = fun({NID, _, _}, Incumbent) ->
        min(dht_metric:d(ID, NID), Incumbent)
    end,

    MinAlive = gb_sets:fold(DistFun, infinity, AliveNodes),
    MinWork = lists:foldl(DistFun, infinity, WorkQueue),
    case MinWork < MinAlive of
        true -> work_queue;
        false -> alive_set
    end.

%% find the nodes/values which are alive
alive(#search_state { alive = A }) -> A.

%% obtain the final result of the query
res(#search_state { acc = A }) -> A.

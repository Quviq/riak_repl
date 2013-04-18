%% Riak EnterpriseDS
%% Copyright 2013 Basho Technologies, Inc. All Rights Reserved.

-module(riak_repl_aae_source).
-behaviour(gen_fsm).

-include("riak_repl.hrl").
-include("riak_repl_aae_fullsync.hrl").

%% API
-export([start_link/6, start_exchange/1]).

%% FSM states
-export([prepare_exchange/2,
         update_trees/2,
         cancel_fullsync/1,
         key_exchange/2]).

%% gen_fsm callbacks
-export([init/1, handle_event/3, handle_sync_event/4, handle_info/3,
         terminate/3, code_change/4]).

-type index() :: non_neg_integer().
-type index_n() :: {index(), pos_integer()}.

-record(state, {cluster,
                client,     %% riak:local_client()
                transport,
                socket,
                index       :: index(),
                indexns     :: [index_n()],
                tree_pid    :: pid(),
                built       :: non_neg_integer(),
                timeout     :: pos_integer(),
                wire_ver    :: atom(),
                owner       :: pid()
               }).

%% Per state transition timeout used by certain transitions
-define(DEFAULT_ACTION_TIMEOUT, 300000). %% 5 minutes

%%%===================================================================
%%% API
%%%===================================================================

-spec start_link(term(), term(), term(), term(), index(), pid())
                -> {ok,pid()} | ignore | {error, term()}.
start_link(Cluster, Client, Transport, Socket, Partition, OwnerPid) ->
    gen_fsm:start(?MODULE, [Cluster, Client, Transport, Socket, Partition, OwnerPid], []).

start_exchange(AAESource) ->
    lager:info("Send start_exchange to AAE fullsync sink worker"),
    gen_fsm:send_event(AAESource, start_exchange).

cancel_fullsync(Pid) ->
    gen_fsm:send_event(Pid, cancel_fullsync).

%%%===================================================================
%%% gen_fsm callbacks
%%%===================================================================

init([Cluster, Client, Transport, Socket, Partition, OwnerPid]) ->
    %% Get the list of IndexNs for this partition. We'll lock the tree just once
    %% for all combined IndexNs and iterate over them. When finished, send
    %% COMPLETE msg to signal sink to die and unlock tree.

    lager:info("AAE fullsync source worker started for partition ~p", [Partition]),

    Timeout = app_helper:get_env(riak_kv,
                                 anti_entropy_timeout,
                                 ?DEFAULT_ACTION_TIMEOUT),

    {ok, TreePid} = riak_kv_vnode:hashtree_pid(Partition),

    %% monitor(process, Manager),
    monitor(process, TreePid),

    %% List of IndexNs to iterate over.
    IndexNs = riak_kv_util:responsible_preflists(Partition),

    lager:info("AAE fullsync source partition ~p has Indexes ~p", [Partition, IndexNs]),

    State = #state{cluster=Cluster,
                   client=Client,
                   transport=Transport,
                   socket=Socket,
                   index=Partition,
                   indexns=IndexNs,
                   tree_pid=TreePid,
                   timeout=Timeout,
                   built=0,
                   owner=OwnerPid,
                   wire_ver=w1}, %% can't be w0 because they don't do AAE
    {ok, prepare_exchange, State}.

handle_event(_Event, StateName, State) ->
    {next_state, StateName, State}.

handle_sync_event(status, _From, StateName, State) ->
    Res = [{state, StateName},
           {partition_syncing, State#state.index},
           {wire_ver, State#state.wire_ver},
           {trees_built, State#state.built}
          ],
    {reply, Res, StateName, State};

handle_sync_event(_Event, _From, StateName, State) ->
    {reply, ok, StateName, State}.

handle_info(Error={'DOWN', _, _, _, _}, _StateName, State) ->
    %% Either the entropy manager, local hashtree, or remote hashtree has
    %% exited. Stop exchange.
    lager:info("Something went down ~p", [Error]),
    send_complete(State),
    {stop, something_went_down, State};
handle_info(_Info, StateName, State) ->
    {next_state, StateName, State}.

terminate(_Reason, _StateName, _State) ->
    ok.

code_change(_OldVsn, StateName, State, _Extra) ->
    {ok, StateName, State}.

%%%===================================================================
%%% gen_fsm states
%%%===================================================================

%% @doc Initial state. Attempt to acquire all necessary exchange locks.
%%      In order, acquire local concurrency lock, local tree lock,
%%      remote concurrency lock, and remote tree lock. Exchange will
%%      timeout if locks cannot be acquired in a timely manner.
prepare_exchange(cancel_fullsync, State) ->
    larger:info("AAE fullsync source cancelled for partition ~p", [State#state.index]),
    send_complete(State),
    {stop, normal, State};
prepare_exchange(start_exchange, State=#state{transport=Transport,
                                              socket=Socket,
                                              index=Partition}) ->
    TcpOptions = [{keepalive, true},
                  {packet, 4},
                  {active, once},
                  {nodelay, true},
                  {header, 1}],
    lager:info("Prepare exchange for partition ~p", [Partition]),
    ok = Transport:setopts(Socket, TcpOptions),
    case riak_kv_index_hashtree:get_lock(State#state.tree_pid,
                                         fullsync_source) of
        ok ->
            %% TODO: Normal AAE has a timeout in this phase of the
            %%       protocol. Do we want similar for fullsync?
            ok = send_synchronous_msg(?MSG_INIT, Partition, State),
            case send_synchronous_msg(?MSG_LOCK_TREE, State) of
                ok ->
                    update_trees(start_exchange, State);
                Error ->
                    lager:info("lock tree for partition ~p failed, got ~p",
                               [Partition, Error]),
                    send_complete(State),
                    send_exchange_status({remote, Error}, State),
                    {stop, {remote, Error}, State}
            end;
        Error ->
            lager:info("AAE source failed get_lock for partition ~p, got ~p",
                       [Partition, Error]),
            send_complete(State),
            send_exchange_status(Error, State),
            {stop, Error, State}
    end.

%% @doc Now that locks have been acquired, ask both the local and remote
%%      hashtrees to perform a tree update. If updates do not occur within
%%      a timely manner, the exchange will timeout. Since the trees will
%%      continue to finish the update even after the exchange times out,
%%      a future exchange should eventually make progress.
update_trees(cancel_fullsync, State) ->
    larger:info("AAE fullsync source cancelled for partition ~p", [State#state.index]),
    send_complete(State),
    {stop, normal, State};
update_trees(start_exchange, State=#state{indexns=IndexN, owner=Owner}) when IndexN == [] ->
    send_complete(State),
    lager:info("AAE fullsync source completed partition ~p. Stopping.",
               [State#state.index]),
    riak_repl2_fssource:fullsync_complete(Owner),
    {stop, normal, State};
update_trees(start_exchange, State=#state{tree_pid=TreePid,
                                          index=Partition,
                                          indexns=[IndexN|_IndexNs]}) ->
    lager:info("Start exchange for partition,IndexN ~p,~p", [Partition, IndexN]),
    update_request(TreePid, {Partition, undefined}, IndexN),
    case send_synchronous_msg(?MSG_UPDATE_TREE, IndexN, State) of
        ok ->
            update_trees({tree_built, Partition, IndexN}, State);
        not_responsible ->
            update_trees({not_responsible, Partition, IndexN}, State)
    end;

update_trees({not_responsible, Partition, IndexN}, State) ->
    lager:info("VNode ~p does not cover preflist ~p", [Partition, IndexN]),
    send_complete(State),
    send_exchange_status({not_responsible, Partition, IndexN}, State),
    {stop, not_responsible, State};
update_trees({tree_built, _, _}, State) ->
    Built = State#state.built + 1,
    case Built of
        2 ->
            lager:info("Moving to key exchange state"),
            gen_fsm:send_event(self(), start_key_exchange),
            {next_state, key_exchange, State};
        _ ->
            {next_state, update_trees, State#state{built=Built}}
    end.

%% @doc Now that locks have been acquired and both hashtrees have been updated,
%%      perform a key exchange and trigger replication for any divergent keys.
key_exchange(cancel_fullsync, State) ->
    larger:info("AAE fullsync source cancelled for partition ~p", [State#state.index]),
    send_complete(State),
    {stop, normal, State};
key_exchange(start_key_exchange, State=#state{cluster=Cluster,
                                              transport=Transport,
                                              socket=Socket,
                                              index=Partition,
                                              tree_pid=TreePid,
                                              indexns=[IndexN|IndexNs]}) ->
    lager:info("Starting fullsync key exchange with ~p for ~p/~p",
               [Cluster, Partition, IndexN]),

    SourcePid = self(),

    %% A function that receives callbacks from the hashtree:compare engine.
    %% This will send messages to ourself, handled in compare_loop(), that
    %% allow us to pass control of the TCP socket around. This is needed so
    %% that the process needing to send/receive on that socket has ownership
    %% of it.
    Remote = fun(init, _) ->
                     %% cause control of the socket to be given to AAE so that
                     %% the get_bucket and key_hashes can send messages via the
                     %% socket (with correct ownership).
                     SourcePid ! {'$aae_src', worker_pid, self()};
                (get_bucket, {L, B}) ->
                     %% 
                     send_synchronous_msg(?MSG_GET_AAE_BUCKET, {L,B,IndexN}, State);
                (key_hashes, Segment) ->
                     send_synchronous_msg(?MSG_GET_AAE_SEGMENT, {Segment,IndexN}, State);
                (final, _) ->
                     %% give ourself control of the socket again
                     ok = Transport:controlling_process(Socket, SourcePid)
             end,

    %% Unclear if we should allow exchange to run indefinitely or enforce
    %% a timeout. The problem is that depending on the number of keys and
    %% key differences, exchange can take arbitrarily long. For now, go with
    %% unbounded exchange, with the ability to cancel exchanges through the
    %% entropy manager if needed.

    %% accumulates a list of one element that is the count of
    %% keys that differed. We can't prime the accumulator. It
    %% always starts as the empty list. KeyDiffs is a list of hashtree::keydiff()
    AccFun = fun(KeyDiffs, Acc0) ->
                     %% fold over key differences. We could batch up all the diffs
                     %% and send as a giant blob, but let's do one at a time for now.
                     lists:foldl(fun(KeyDiff, AccIn) ->
                                         replicate_diff(KeyDiff, AccIn, State) end,
                                 Acc0,
                                 KeyDiffs)
             end,

    %% TODO: Add stats for AAE
    lager:info("Starting compare for partition ~p", [Partition]),
    spawn_link(fun() ->
                       Acc = riak_kv_index_hashtree:compare(IndexN, Remote, AccFun, TreePid),
                       SourcePid ! {'$aae_src', done, Acc}
               end),

    {Acc, State2} = compare_loop(State),

    case Acc of
        [] ->
            %% exchange_complete(LocalVN, RemoteVN, IndexN, 0),
            lager:info("Repl'd 0 keys"),
            ok;
        [Count] ->
            %% exchange_complete(LocalVN, RemoteVN, IndexN, Count),
            lager:info("Repl'd ~b keys during fullsync to ~p of ~p/~p ",
                       [Count, Cluster, Partition, IndexN])
    end,

    %% go back for the next indexN (possibly none, which will stop normal)
    gen_fsm:send_event(self(), start_exchange),
    {next_state, update_trees, State2#state{built=0, indexns=IndexNs}}.

compare_loop(State=#state{transport=Transport,
                          socket=Socket}) ->
    receive
        {'$aae_src', worker_pid, WorkerPid} ->
            ok = Transport:controlling_process(Socket, WorkerPid),
            compare_loop(State);
        {'$aae_src', done, Acc} ->
            {Acc, State}
    end.

%%%===================================================================
%%% Internal functions
%%%===================================================================

%% @private
%% Returns accumulator as a list of one element that is the count of
%% keys that differed. Initial value of Acc is always [].
replicate_diff(KeyDiff, Acc, State=#state{index=Partition}) ->
    NumObjects =
        case KeyDiff of
            {remote_missing, Bin} ->
                %% send object and related objects to remote
                {Bucket,Key} = binary_to_term(Bin),
                lager:info("Keydiff: remote partition ~p remote missing: ~p:~p",
                            [Partition, Bucket, Key]),
                send_missing(Bucket, Key, State);
            {different, Bin} ->
                %% send object and related objects to remote
                {Bucket,Key} = binary_to_term(Bin),
                lager:info("Keydiff: remote partition ~p different: ~p:~p",
                            [Partition, Bucket, Key]),
                send_missing(Bucket, Key, State);
            {missing, Bin} ->
                %% remote has a key we don't have. Ignore it.
                {Bucket,Key} = binary_to_term(Bin),
                lager:info("Keydiff: remote partition ~p local missing: ~p:~p (ignored)",
                            [Partition, Bucket, Key]),
                0;
            Other ->
                lager:info("Keydiff: ~p (ignored)", [Other]),
                0
        end,

    case Acc of
        [] ->
            [1];
        [Count] ->
            %% accrue number of differences sent from this segment
            [Count+NumObjects];
        _Other ->
            Acc
    end.

send_missing(Bucket, Key, State=#state{client=Client, wire_ver=Ver}) ->
    case Client:get(Bucket, Key, 1, ?REPL_FSM_TIMEOUT) of
        {ok, RObj} ->
            %% we don't actually have the vclock to compare, so just send the
            %% key and let the other side sort things out.
            case riak_repl_util:repl_helper_send(RObj, Client) of
                cancel ->
                    0;
                Objects when is_list(Objects) ->
                    %% source -> sink : fs_diff_obj
                    %% binarize here instead of in the send() so that our wire
                    %% format for the riak_object is more compact.
                    [begin
                         Data = riak_repl_util:encode_obj_msg(Ver, {fs_diff_obj,O}),
                         send_asynchronous_msg(?MSG_PUT_OBJ, Data, State)
                     end || O <- Objects],
                    Data2 = riak_repl_util:encode_obj_msg(Ver, {fs_diff_obj,RObj}),
                    send_asynchronous_msg(?MSG_PUT_OBJ, Data2, State),
                    1 + length(Objects)
            end;
        {error, notfound} ->
            %% can't find the key!
            lager:warning("Can't get a key that was know to be a difference: ~p:~p", [Bucket,Key]),
            0;
        _ ->
            0
    end.

%% @private
update_request(Tree, {Index, _}, IndexN) ->
    as_event(fun() ->
                     case riak_kv_index_hashtree:update(IndexN, Tree) of
                         ok ->
                             {tree_built, Index, IndexN};
                         not_responsible ->
                             {not_responsible, Index, IndexN}
                     end
             end).

%% @private
as_event(F) ->
    Self = self(),
    spawn_link(fun() ->
                       Result = F(),
                       gen_fsm:send_event(Self, Result)
               end),
    ok.

%% @private
%% do_timeout(State=#state{local=LocalVN,
%%                         remote=RemoteVN,
%%                         index_n=IndexN}) ->
%%     lager:info("Timeout during exchange between (local) ~p and (remote) ~p, "
%%                "(preflist) ~p", [LocalVN, RemoteVN, IndexN]),
%%     send_exchange_status({timeout, RemoteVN, IndexN}, State),
%%     {stop, normal, State}.

%% @private
send_exchange_status(Status, State) ->
    throw(Status),
    State.

%% @private
%% next_state_with_timeout(StateName, State) ->
%%     next_state_with_timeout(StateName, State, State#state.timeout).
%% next_state_with_timeout(StateName, State, Timeout) ->
%%     {next_state, StateName, State, Timeout}.

%% exchange_complete({LocalIdx, _}, {RemoteIdx, RemoteNode}, IndexN, Repaired) ->
%%     riak_kv_entropy_info:exchange_complete(LocalIdx, RemoteIdx, IndexN, Repaired),
%%     rpc:call(RemoteNode, riak_kv_entropy_info, exchange_complete,
%%              [RemoteIdx, LocalIdx, IndexN, Repaired]).

send_complete(State=#state{index=Partition}) ->
    lager:info("Exchange complete for partition ~p", [Partition]),
    send_asynchronous_msg(?MSG_COMPLETE, State).

%%------------
%% Synchronous messaging with the AAE fullsync "sink" on the remote cluster
%%------------
%% send a tagged message with type and binary data. return the reply
send_synchronous_msg(MsgType, Data, State=#state{transport=Transport,
                                                 socket=Socket}) when is_binary(Data) ->
    lager:info("sending message type ~p", [MsgType]),
    ok = Transport:send(Socket, <<MsgType:8, Data/binary>>),
    Response = get_reply(State),
    lager:info("got reply ~p", [Response]),
    Response;
%% send a tagged message with type and msg. return the reply
send_synchronous_msg(MsgType, Msg, State) ->
    Data = term_to_binary(Msg),
    send_synchronous_msg(MsgType, Data, State).

%% send a message with type tag only, no data
send_synchronous_msg(MsgType, State=#state{transport=Transport,
                                           socket=Socket}) ->
    ok = Transport:send(Socket, <<MsgType:8>>),
    get_reply(State).

%% Async message send with tag and (binary or term data).
send_asynchronous_msg(MsgType, Data, #state{transport=Transport,
                                            socket=Socket}) when is_binary(Data) ->
    ok = Transport:send(Socket, <<MsgType:8, Data/binary>>);
%% send a tagged message with type and msg. return the reply
send_asynchronous_msg(MsgType, Msg, State) ->
    Data = term_to_binary(Msg),
    send_asynchronous_msg(MsgType, Data, State).

%% send a message with type tag only, no data
send_asynchronous_msg(MsgType, #state{transport=Transport,
                                      socket=Socket}) ->
    ok = Transport:send(Socket, <<MsgType:8>>).

get_reply(#state{transport=Transport, socket=Socket}) ->
    ok = Transport:setopts(Socket, [{active, once}]),
    receive
        {_, Socket, [?MSG_REPLY|Data]} ->
            binary_to_term(Data);
        {Error, Socket} ->
            throw(Error);
        {Error, Socket, Reason} ->
            throw({Error, Reason})
    end.
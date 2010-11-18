%% Riak EnterpriseDS
%% Copyright (c) 2007-2010 Basho Technologies, Inc.  All Rights Reserved.

%%
%% 'merkle' tree helper process.
%% Must exit after returning an {Ref, {error, Blah}} or {Ref, merkle_built}.
%%
%%
-module(riak_repl_merkle_helper).
-behaviour(gen_server2).

%% API
-export([start_link/1,
         make_merkle/3,
         make_keylist/3,
         merkle_to_keylist/3,
         diff/4]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-include("riak_repl.hrl").
-include("couch_db.hrl").

-record(state, {owner_fsm,
                ref,
                merkle_pid,
                folder_pid,
                kl_fp,
                filename,
                buf=[],
                size=0}).

-record(diff_state, {fsm,
                     ref,
                     preflist,
                     diff_hash = 0,
                     missing = 0,
                     errors = []}).

%% ===================================================================
%% Public API
%% ===================================================================

start_link(OwnerFsm) ->
    gen_server2:start_link(?MODULE, [OwnerFsm], []).

%% Make a couch_btree of key/object hashes.
%%
%% Return {ok, Ref} if build starts successfully, then sends
%% a gen_fsm event {Ref, merkle_built} to the OwnerFsm or
%% a {Ref, {error, Reason}} event on failures
make_merkle(Pid, Partition, Filename) ->
    gen_server2:call(Pid, {make_merkle, Partition, Filename}).

%% Make a sorted file of key/object hashes.
%% 
%% Return {ok, Ref} if build starts successfully, then sends
%% a gen_fsm event {Ref, keylist_built} to the OwnerFsm or
%% a {Ref, {error, Reason}} event on failures
make_keylist(Pid, Partition, Filename) ->
    gen_server2:call(Pid, {make_keylist, Partition, Filename}).
   
%% Convert a couch_btree to a sorted keylist file.
%%
%% Returns {ok, Ref} or {error, Reason}.
%% Sends a gen_fsm event {Ref, converted} on success or
%% {Ref, {error, Reason}} on failure
merkle_to_keylist(Pid, MerkleFn, KeyListFn) ->
    gen_server2:call(Pid, {merkle_to_keylist, MerkleFn, KeyListFn}).
    
%% Computes the difference between two keylist sorted files.
%% Returns {ok, Ref} or {error, Reason}
%% Differences are sent as {Ref, {merkle_diff, {Bkey, Vclock}}}
%% and finally {Ref, diff_done}.  Any errors as {Ref, {error, Reason}}.
diff(Pid, Partition, TheirFn, OurFn) ->
    gen_server2:call(Pid, {diff, Partition, TheirFn, OurFn}).

%% ====================================================================
%% gen_server callbacks
%% ====================================================================

init([OwnerFsm]) ->
    process_flag(trap_exit, true),
    {ok, #state{owner_fsm = OwnerFsm}}.

handle_call({make_merkle, Partition, FileName}, _From, State) ->
    {ok, Ring} = riak_core_ring_manager:get_my_ring(),
    OwnerNode = riak_core_ring:index_owner(Ring, Partition),
    case lists:member(OwnerNode, riak_core_node_watcher:nodes(riak_kv)) of
        true ->
            {ok, DMerkle} = couch_merkle:open(FileName),
            Self = self(),
            Worker = fun() ->
                             %% Spend as little time on the vnode as possible,
                             %% accept there could be a potentially huge message queue
                             Folder = fun(K, V, MPid) -> 
                                              gen_server2:cast(MPid, {merkle, K, hash_object(V)}),
                                              MPid
                                      end,
                             riak_kv_vnode:fold({Partition,OwnerNode}, Folder, Self),
                             gen_server2:cast(Self, merkle_finish)
                     end,
            FolderPid = spawn_link(Worker),
            Ref = make_ref(),
            NewState = State#state{ref = Ref, 
                                   merkle_pid = DMerkle, 
                                   folder_pid = FolderPid,
                                   filename = FileName},
            {reply, {ok, Ref}, NewState};
        false ->
            {stop, normal, {error, node_not_available}, State}
    end;
handle_call({make_keylist, Partition, Filename}, _From, State) ->
    {ok, Ring} = riak_core_ring_manager:get_my_ring(),
    OwnerNode = riak_core_ring:index_owner(Ring, Partition),
    case lists:member(OwnerNode, riak_core_node_watcher:nodes(riak_kv)) of
        true ->
            {ok, FP} = file:open(Filename, [read, write, binary, raw, delayed_write]),
            Self = self(),
            Worker = fun() ->
                             %% Spend as little time on the vnode as possible,
                             %% accept there could be a potentially huge message queue
                             Folder = fun(K, V, MPid) -> 
                                              gen_server2:cast(MPid, {kl, K, hash_object(V)}),
                                              MPid
                                      end,
                             riak_kv_vnode:fold({Partition,OwnerNode}, Folder, Self),
                             gen_server2:cast(Self, kl_finish)
                     end,
            FolderPid = spawn_link(Worker),
            Ref = make_ref(),
            NewState = State#state{ref = Ref, 
                                   folder_pid = FolderPid,
                                   filename = Filename,
                                   kl_fp = FP},
            {reply, {ok, Ref}, NewState};
        false ->
            {stop, normal, {error, node_not_available}, State}
    end;
handle_call({merkle_to_keylist, MerkleFn, KeyListFn}, From, State) ->
    %% Return to the caller immediately, if we are unable to open/
    %% write to files this process will crash and the caller
    %% will discover the problem.
    Ref = make_ref(),
    gen_server2:reply(From, {ok, Ref}),

    %% Iterate over the couch file and write out to the keyfile
    {ok, InFileBtree} = open_couchdb(MerkleFn),
    {ok, OutFile} = file:open(KeyListFn, [binary, write, raw, delayed_write]),
    couch_btree:foldl(InFileBtree, fun({K, V}, _Acc) ->
                                           B = term_to_binary({K, V}),
                                           ok = file:write(OutFile, <<(size(B)):32, B/binary>>),
                                           {ok, ok}
                                   end, ok),
    file:close(OutFile),

    %% Verify the file is really sorted
    case file_sorter:check(KeyListFn) of
        {ok, []} ->
            Msg = converted;
        {ok, Result} ->
            Msg = {error, {unsorted, Result}};
        {error, Reason} ->
            Msg = {error, Reason}
    end,
    gen_fsm:send_event(State#state.owner_fsm, {Ref, Msg}),
    {stop, normal, State};
handle_call({diff, Partition, RemoteFilename, LocalFilename}, From, State) ->
    %% Return to the caller immediately, if we are unable to open/
    %% read files this process will crash and the caller
    %% will discover the problem.
    Ref = make_ref(),
    gen_server2:reply(From, {ok, Ref}),

    {ok, RemoteFile} = file:open(RemoteFilename,
                                 [read, binary, raw, read_ahead]),
    {ok, LocalFile} = file:open(LocalFilename,
                                [read, binary, raw, read_ahead]),
    try
        {ok, Ring} = riak_core_ring_manager:get_my_ring(),
        OwnerNode = riak_core_ring:index_owner(Ring, Partition),
        case lists:member(OwnerNode, riak_core_node_watcher:nodes(riak_kv)) of
            true ->
                DiffState = diff_keys(itr_new(RemoteFile, remote_reads),
                                      itr_new(LocalFile, local_reads),
                                      #diff_state{fsm = State#state.owner_fsm,
                                                  ref = Ref,
                                                  preflist = {Partition, OwnerNode}}),
                error_logger:info_msg("Partition ~p: ~p remote / ~p local: ~p missing, ~p differences.\n",
                                      [Partition, 
                                       erlang:get(remote_reads),
                                       erlang:get(local_reads),
                                       DiffState#diff_state.missing,
                                       DiffState#diff_state.diff_hash]),
                case DiffState#diff_state.errors of
                    [] ->
                        ok;
                    Errors ->
                        error_logger:error_msg("Partition ~p: Read Errors.\n",
                                              [Partition, Errors])
                end,
                gen_fsm:send_event(State#state.owner_fsm, {Ref, diff_done});
            false ->
                gen_fsm:send_event(State#state.owner_fsm, {Ref, {error, node_not_available}})
        end
    after
        file:close(RemoteFile),
        file:close(LocalFile),
        file:delete(RemoteFilename),
        file:delete(LocalFilename)
    end,
    {stop, normal, State}.
    
handle_cast({merkle, K, H}, State) ->
    PackedKey = pack_key(K),
    NewSize = State#state.size+size(PackedKey)+4,
    NewBuf = [{PackedKey, H}|State#state.buf],
    case NewSize >= ?MERKLE_BUFSZ of 
        true ->
            couch_merkle:update_many(State#state.merkle_pid, NewBuf),
            {noreply, State#state{buf = [], size = 0}};
        false ->
            {noreply, State#state{buf = NewBuf, size = NewSize}}
    end;
handle_cast(merkle_finish, State) ->
    couch_merkle:update_many(State#state.merkle_pid, State#state.buf),
    %% Close couch - beware, the close call is a cast so the process
    %% may still be alive for a while.  Add a monitor and directly
    %% receive the message - it should only be for a short time
    %% and nothing else 
    _Mref = erlang:monitor(process, State#state.merkle_pid),
    couch_merkle:close(State#state.merkle_pid),
    {noreply, State};
handle_cast({kl, K, H}, State) ->
    Bin = term_to_binary({pack_key(K), H}),
    file:write(State#state.kl_fp, <<(size(Bin)):32, Bin/binary>>),
    {noreply, State};
handle_cast(kl_finish, State) ->
    file:sync(State#state.kl_fp),
    file:close(State#state.kl_fp),
    Filename = State#state.filename,
    {ElapsedUsec, ok} = timer:tc(file_sorter, sort, [Filename]),
    error_logger:info_msg("Sorted ~s in ~.2f seconds\n",
                          [Filename, ElapsedUsec / 1000000]),
    gen_fsm:send_event(State#state.owner_fsm, {State#state.ref, keylist_built}),
    {stop, normal, State}.

handle_info({'EXIT', Pid,  Reason}, State) when Pid =:= State#state.merkle_pid ->
    case Reason of 
        normal ->
            {noreply, State};
        _ ->
            gen_fsm:send_event(State#state.owner_fsm, 
                               {State#state.ref, {error, {merkle_died, Reason}}}),
            {stop, normal, State}
    end;
handle_info({'EXIT', Pid,  Reason}, State) when Pid =:= State#state.folder_pid ->
    case Reason of
        normal ->
            {noreply, State};
        _ ->
            gen_fsm:send_event(State#state.owner_fsm, 
                               {State#state.ref, {error, {folder_died, Reason}}}),
            {stop, normal, State}
    end;
handle_info({'DOWN', _Mref, process, Pid, Exit}, State=#state{merkle_pid = Pid}) ->
    case Exit of
        normal ->
            Msg = {State#state.ref, merkle_built};
        _ ->
            Msg = {State#state.ref, {error, {merkle_failed, Exit}}}
    end,
    gen_fsm:send_event(State#state.owner_fsm, Msg),        
    {stop, normal, State#state{buf = [], size = 0}}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%% ====================================================================
%% Internal functions
%% ====================================================================

pack_key(K) ->
    riak_repl_util:binpack_bkey(K).

unpack_key(K) ->
    riak_repl_util:binunpack_bkey(K).

%% Hash an object, making sure the vclock is in sorted order
%% as it varies depending on whether it has been pruned or not
hash_object(RObjBin) ->
    RObj = binary_to_term(RObjBin),
    Vclock = riak_object:vclock(RObj),
    UpdObj = riak_object:set_vclock(RObj, lists:sort(Vclock)),
    erlang:phash2(term_to_binary(UpdObj)).

open_couchdb(Filename) ->
    {ok, Fd} = couch_file:open(Filename),
    {ok, #db_header{local_docs_btree_state=HeaderBtree}} = couch_file:read_header(Fd),
    couch_btree:open(HeaderBtree, Fd).

itr_new(File, Tag) ->
    erlang:put(Tag, 0),
    case file:read(File, 4) of
        {ok, <<Size:32/unsigned>>} ->
            itr_next(Size, File, Tag);
        _ ->
            file:close(File),
            eof
    end.

itr_next(Size, File, Tag) ->
    case file:read(File, Size + 4) of
        {ok, <<Data:Size/bytes>>} ->
            erlang:put(Tag, erlang:get(Tag) + 1),
            file:close(File),
            {binary_to_term(Data), fun() -> eof end};
        {ok, <<Data:Size/bytes, NextSize:32/unsigned>>} ->
            erlang:put(Tag, erlang:get(Tag) + 1),
            {binary_to_term(Data), fun() -> itr_next(NextSize, File, Tag) end};
        eof ->
            file:close(File),
            eof
    end.

diff_keys({{Key, Hash}, RNext}, {{Key, Hash}, LNext}, DiffState) ->
    %% Remote and local keys/hashes match
    diff_keys(RNext(), LNext(), DiffState);
diff_keys({{Key, _}, RNext}, {{Key, _}, LNext}, DiffState) ->
    %% Both keys match, but hashes do not
    diff_keys(RNext(), LNext(), diff_hash(Key, DiffState));
diff_keys({{RKey, _RHash}, RNext}, {{LKey, _LHash}, _LNext} = L, DiffState)
  when RKey < LKey ->
    diff_keys(RNext(), L, missing_key(RKey, DiffState));
diff_keys({{RKey, _RHash}, _RNext} = R, {{LKey, _LHash}, LNext}, DiffState)
  when RKey > LKey ->
    %% Remote is ahead of local list
    %% TODO: This may represent a deleted key...
    diff_keys(R, LNext(), DiffState);
diff_keys({{RKey, _RHash}, RNext}, eof, DiffState) ->
    %% End of local stream; all keys from remote should be processed
    diff_keys(RNext(), eof, missing_key(RKey, DiffState));
diff_keys(eof, _, DiffState) ->
    %% End of remote stream; all remaining keys are local to this side or
    %% deleted ops
    DiffState.

%% Called when the hashes differ with the packed packed bkey
diff_hash(PBKey, DiffState) ->
    UpdDiffHash = DiffState#diff_state.diff_hash + 1,
    BKey = unpack_key(PBKey),
    case catch riak_kv_vnode:get_vclocks(DiffState#diff_state.preflist, 
                                         [BKey]) of
        [{BKey, _Vclock} = BkeyVclock] ->
            Fsm = DiffState#diff_state.fsm,
            Ref = DiffState#diff_state.ref,
            gen_fsm:send_event(Fsm, {Ref, {merkle_diff, BkeyVclock}}),
            DiffState#diff_state{diff_hash = UpdDiffHash};
        Reason ->
            UpdErrors = orddict:update_counter(Reason, 1, DiffState#diff_state.errors),
            DiffState#diff_state{errors = UpdErrors}
    end.
    
%% Called when the key is missing on the local side
missing_key(PBKey, DiffState) ->
    BKey = unpack_key(PBKey),
    Fsm = DiffState#diff_state.fsm,
    Ref = DiffState#diff_state.ref,
    gen_fsm:send_event(Fsm, {Ref, {merkle_diff, {BKey, vclock:fresh()}}}),
    UpdMissing = DiffState#diff_state.missing + 1,
    DiffState#diff_state{missing = UpdMissing}.

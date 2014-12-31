%% @author chenkangmin
%% @doc @todo Add description to my_group_msg_center.


-module(my_group_msg_center).
-behaviour(gen_server).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

-include("aa_data.hrl").
-include("jlib.hrl").
-include("ejabberd.hrl").

-define(USER_MSD_PID_COUNT, 128).


-record(state, {user_msd_handlers = [], group_msd_handlers = []}).

-record(group_msg, {id, group_id, from, packet, timestamp, expire_time, score}).

-record(group_id_seq, {group_id, sequence = 0}).

-record(user_group_info, {user_id, group_info_list}).

%% ====================================================================
%% API functions
%% ====================================================================
-export([start_link/0,
         add_pool/1,
         list/0,
         update_user_group_info/3,
         init_user_group_info/2,
         store_message/3,
         delete_group_msg/2,
         get_offline_msg/1,
         get_offline_msg/3,
         clear_user_group_info/2
        ]).

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

add_pool(Num) ->
    gen_server:call(?MODULE, {add_pool, Num}).

list() ->
    gen_server:call(?MODULE, {list}).


get_offline_msg(GroupId, Seq, User) ->
    case ets:lookup(my_group_msgpid_info, GroupId) of
        [] ->
            {ok, Pid} = gen_server:call(?MODULE, {attach_new_group_pid, GroupId}),
            sync_deliver_group_task(get_offline_msg, Pid, GroupId, {GroupId, Seq, User});
        [{GroupId, Pid}] ->
            sync_deliver_group_task(get_offline_msg, Pid, GroupId, {GroupId, Seq, User})
    end.

get_offline_msg(User) ->
    User1 = format_user_data(User),
    Uid = get_uid(User),
    case ets:lookup(my_user_group_msgpid_info, Uid) of
        [] ->
            {ok, Pid} = gen_server:call(?MODULE, {attach_new_user_pid, Uid}),
            sync_deliver_task(get_offline_msg, Pid, Uid, {User1});
        [{Uid, Pid}] ->
            sync_deliver_task(get_offline_msg, Pid, Uid, {User1})
    end.

update_user_group_info(User, GroupId, Seq) ->
    User1 = format_user_data(User),
    Uid = get_uid(User),
    case ets:lookup(my_user_group_msgpid_info, Uid) of
        [] ->
            {ok, Pid} = gen_server:call(?MODULE, {attach_new_user_pid, Uid}),
            sync_deliver_task(update_user_group_info, Pid, Uid, {User1, GroupId, Seq});
        [{Uid, Pid}] ->
            sync_deliver_task(update_user_group_info, Pid, Uid, {User1, GroupId, Seq})
    end.

clear_user_group_info(Uid, GroupId) ->
    case ets:lookup(my_user_group_msgpid_info, Uid) of
        [] ->
            {ok, Pid} = gen_server:call(?MODULE, {attach_new_user_pid, Uid}),
            sync_deliver_task(clear_user_group_info, Pid, Uid, {Uid, GroupId});
        [{Uid, Pid}] ->
            sync_deliver_task(clear_user_group_info, Pid, Uid, {Uid, GroupId})
    end.

delete_group_msg(GroupId, Sid) ->
    case ets:lookup(my_group_msgpid_info, GroupId) of
        [] ->
            {ok, Pid} = gen_server:call(?MODULE, {attach_new_group_pid, GroupId}),
            sync_deliver_group_task(delete_group_msg, Pid, GroupId, {GroupId, Sid});
        [{GroupId, Pid}] ->
            sync_deliver_group_task(delete_group_msg, Pid, GroupId, {GroupId, Sid})
    end.

init_user_group_info(User, GroupId) ->
    User1 = format_user_data(User),
    Uid = get_uid(User),
    case ets:lookup(my_user_group_msgpid_info, Uid) of
        [] ->
            {ok, Pid} = gen_server:call(?MODULE, {attach_new_user_pid, Uid}),
            sync_deliver_task(init_user_group_info, Pid, Uid, {User1, GroupId});
        [{Uid, Pid}] ->
            sync_deliver_task(init_user_group_info, Pid, Uid, {User1, GroupId})
    end.

store_message(User, GroupId, Packet) ->
    User1 = format_user_data(User),
    case ets:lookup(my_group_msgpid_info, GroupId) of
        [] ->
            {ok, Pid} = gen_server:call(?MODULE, {attach_new_group_pid, GroupId}),
            sync_deliver_group_task(store_msg, Pid, GroupId, {GroupId, User1, Packet});
        [{GroupId, Pid}] ->
            sync_deliver_group_task(store_msg, Pid, GroupId, {GroupId, User1, Packet})
    end.



create_or_copy_table(TableName, Opts, Copy) ->
    case mnesia:create_table(TableName, Opts) of
        {aborted,{already_exists,_}} ->
            mnesia:add_table_copy(TableName, node(), Copy);
        _ ->
            skip
    end.


format_user_data(Jid) ->
    Jid#jid{resource = [], lresource = []}.

get_uid(#jid{user = User}) when is_binary(User) ->
    binary_to_list(User);
get_uid(#jid{user = User}) ->
    User.

%% ====================================================================
%% Behavioural functions 
%% ====================================================================

init([]) ->
    [Domain|_] = ?MYHOSTS,
    case ejabberd_config:get_local_option({handle_group_msg_center, Domain}) of
        1 ->
            ets:new(my_group_msgpid_info, [{keypos, 1}, named_table, public, set]),
            ets:new(my_user_group_msgpid_info, [{keypos, 1}, named_table, public, set]),
            create_or_copy_table(group_message, [{record_name, group_msg},
                                                 {attributes, record_info(fields, group_msg)},
                                                 {ram_copies, [node()]}], ram_copies),
            create_or_copy_table(group_id_seq, [{record_name, group_id_seq},
                                                {attributes, record_info(fields, group_id_seq)},
                                                {ram_copies, [node()]}], ram_copies),
            create_or_copy_table(user_group_info, [{record_name, user_group_info},
                                                   {attributes, record_info(fields, user_group_info)},
                                                   {ram_copies, [node()]}], ram_copies);
        _ ->
            skip
    end,
    GroupPids = [begin
                     {ok, Pid} = my_group_user_msg_handler:start(),
                     {Pid, 0}
                 end || _ <- lists:duplicate(?USER_MSD_PID_COUNT, 1)],
    UserPids = [begin
                    {ok, Pid} = my_group_user_msg_handler:start(),
                    {Pid, 0}
                end || _ <- lists:duplicate(?USER_MSD_PID_COUNT, 1)],
    {ok, #state{user_msd_handlers = UserPids, group_msd_handlers = GroupPids}}.


handle_call({list}, _From, State) ->
    {reply, {ok, State}, State};

handle_call({attach_new_user_pid, Uid}, _From, #state{user_msd_handlers = Handler} = State) ->
    {Pid1, State1} = case ets:lookup(my_user_group_msgpid_info, Uid) of
                         [] ->
                             [{Pid, Count} | _] = lists:keysort(2, Handler),
                             ets:insert(my_user_group_msgpid_info, {Uid, Pid}),
                             {Pid, State#state{user_msd_handlers = lists:keyreplace(Pid, 1, Handler, {Pid, Count + 1})}};
                         [{Uid, Pid}] ->
                             case erlang:is_process_alive(Pid) of
                                 true ->
                                     {Pid, State};
                                 _ ->
                                     Handler1 = lists:keydelete(Pid, 1, Handler),
                                     Size = length(Handler1),
                                     {NewPid1, NewState} = if
                                                               Size < ?USER_MSD_PID_COUNT ->
                                                                   {ok, NewPid} = my_group_user_msg_handler:start(),
                                                                   {NewPid, State#state{user_msd_handlers = [{NewPid, 0} | Handler1]}};
                                                               true ->
                                                                   [{NewPid, Count} | _] = lists:keysort(2, Handler1),
                                                                   {NewPid, State#state{user_msd_handlers = lists:keyreplace(NewPid, 1, Handler, {NewPid, Count + 1})}}
                                                           end,
                                     ets:delete(my_user_group_msgpid_info, Uid),
                                     ets:insert(my_user_group_msgpid_info, {Uid, NewPid1}),
                                     {NewPid1, NewState}
                             end
                     end,
    {reply, {ok, Pid1}, State1};

handle_call({attach_new_group_pid, GroupId}, _From, #state{group_msd_handlers = Handler} = State) ->
    {Pid1, State1} = case ets:lookup(my_group_msgpid_info, GroupId) of
                         [] ->
                             [{Pid, Count} | _] = lists:keysort(2, Handler),
                             ets:insert(my_group_msgpid_info, {GroupId, Pid}),
                             {Pid, State#state{group_msd_handlers = lists:keyreplace(Pid, 1, Handler, {Pid, Count + 1})}};
                         [{GroupId, Pid}] ->
                             case erlang:is_process_alive(Pid) of
                                 true ->
                                     {Pid, State};
                                 _ ->
                                     Handler1 = lists:keydelete(Pid, 1, Handler),
                                     Size = length(Handler1),
                                     {NewPid1, NewState} = if
                                                               Size < ?USER_MSD_PID_COUNT ->
                                                                   {ok, NewPid} = my_group_user_msg_handler:start(),
                                                                   {NewPid, State#state{group_msd_handlers = [{NewPid, 0} | Handler1]}};
                                                               true ->
                                                                   [{NewPid, Count} | _] = lists:keysort(2, Handler1),
                                                                   {NewPid, State#state{group_msd_handlers = lists:keyreplace(NewPid, 1, Handler, {NewPid, Count + 1})}}
                                                           end,
                                     ets:delete(my_group_msgpid_info, GroupId),
                                     ets:insert(my_group_msgpid_info, {GroupId, NewPid1}),
                                     {NewPid1, NewState}
                             end
                     end,
    {reply, {ok, Pid1}, State1};

handle_call(_Request, _From, State) ->
    Reply = ok,
    {reply, Reply, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.



handle_info(_Info, State) ->
    {noreply, State}.



terminate(_Reason, _State) ->
    ok.



code_change(_OldVsn, State, _Extra) ->
    {ok, State}.


%% ====================================================================
%% Internal functions
%% ====================================================================

sync_deliver_group_task(Task, Pid, GroupId, Args) ->
    try
        deliver(Task, Pid, Args)
    catch
        _ErrorType:_ErrorReason ->
            {ok, NewPid} = gen_server:call(?MODULE, {attach_new_group_pid, GroupId}),
            sync_deliver_group_task(Task, NewPid, GroupId, Args)
    end.

sync_deliver_task(Task, Pid, Uid, Args) ->
    try
        deliver(Task, Pid, Args)
    catch
        _ErrorType:_ErrorReason ->
            {ok, NewPid} = gen_server:call(?MODULE, {attach_new_user_pid, Uid}),
            sync_deliver_task(Task, NewPid, Uid, Args)
    end.

deliver(store_msg, Pid, {GroupId, User, Message}) ->
    my_group_user_msg_handler:store_msg(Pid, GroupId, User, Message);


deliver(init_user_group_info, Pid, {User, GroupId}) ->
    my_group_user_msg_handler:init_user_group_info(Pid, GroupId, User);


deliver(update_user_group_info, Pid, {User, GroupId, Seq}) ->
    my_group_user_msg_handler:update_user_group_info(Pid, GroupId, User, Seq);

deliver(clear_user_group_info, Pid, {Uid, GroupId}) ->
    my_group_user_msg_handler:clear_user_group_info(Pid, Uid, GroupId);

deliver(get_offline_msg, Pid, {User}) ->
    my_group_user_msg_handler:get_offline_msg(Pid, User);

deliver(get_offline_msg, Pid, {GroupId, Seq, User}) ->
    my_group_user_msg_handler:get_offline_msg(Pid, GroupId, Seq, User);

deliver(delete_group_msg, Pid, {GroupId, Sid}) ->
    my_group_user_msg_handler:delete_group_msg(Pid, GroupId, Sid).

-module(aa_hookhandler).
-behaviour(gen_server).

-include("ejabberd.hrl").
-include("jlib.hrl").
-include("aa_data.hrl").
-include_lib("xmerl/include/xmerl.hrl").

-define(HTTP_HEAD,"application/x-www-form-urlencoded").
-define(TIME_OUT,1000*5).

-define(PUSH_PID_NUM, 128).

-define(ETS_ACK_TASK, ets_ack_task).

-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3,get_id/0]).

%% ====================================================================
%% API functions
%% ====================================================================

-export([
    start_link/0,
    user_send_packet_handler/3,
    send_message_to_user/3,
    send_group_msg_to_user/4,
    rlcfg/0,
    stop/0,
    get_offline_msg/1,
    reinit_pushpids/0,
    get_group_data_node/0,
    get_offline_data_node/0
	]).

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

stop() ->
    lists:foreach(
        fun(Host) ->
                ejabberd_hooks:delete(user_send_packet,Host,?MODULE, user_send_packet_handler ,80)

        end, ?MYHOSTS),
    exit(whereis(?MODULE), stop),
    ok.


reinit_pushpids() ->
    gen_server:call(?MODULE, rebuild_pushpids).

rlcfg() ->
    gen_server:call(?MODULE, reload_config).


deal_offline_msg(From, To, Packet) ->
    try
        {xmlelement, "message", Header, _} = Packet,
        D = dict:from_list(Header),
        V = dict:fetch("msgtype", D),
        case V of
            "msgStatus" ->
                ok;
            _->
                send_offline_message(From, To, Packet)
        end
    catch
        _:_ -> ok
    end.

%%离线消息推送
send_offline_message(From, To, Packet) ->
    case get_offline_data_node() of
        none ->
            skip;
        Node ->
            rpc:cast(Node, my_offline_msg_center, send_offline_msg, [From, To, Packet])
    end.


get_user_list_by_group_id(Domain, GroupId)->
    HTTPServer =  ejabberd_config:get_local_option({http_server, Domain}),
    HTTPService = ejabberd_config:get_local_option({http_server_service_client, Domain}),
    HTTPTarget = string:concat(HTTPServer, HTTPService),
    ParamObj = {obj, [{"sn", list_to_binary(get_id())},
                      {"service", list_to_binary("service.groupchat")},
                      {"method", list_to_binary("getUserList")},
                      {"params", {obj, [{"groupId", list_to_binary(GroupId)}]}}]},
    Form = "body=" ++ rfc4627:encode(ParamObj),
    try
        case httpc:request(post, {HTTPTarget ,[], ?HTTP_HEAD , Form }, [], []) of
            {ok, {_, _, Body}} ->
                DBody = rfc4627:decode(Body),
                case DBody of
                    {ok, Obj, _Re} ->
                        case rfc4627:get_field(Obj, "success") of
                            {ok, true} ->
                                rfc4627:get_field(Obj, "entity");
                            Code ->
                                {error, "success field error", Code}
                        end;
                    _ ->
                        {error, "decode body error", DBody}
                end ;
            {error, Reason} ->
                {error, "httpc request error", Reason}
        end
    catch
        ErrType:ErrReason->
            {error, "unknow error", {ErrType, ErrReason}}
    end.

get_group_members(GroupId, Domain) ->
    case mnesia:dirty_read(?GOUPR_MEMBER_TABLE, GroupId) of
        [] ->
            case get_user_list_by_group_id(Domain,GroupId) of
                {ok, UserList} ->
                    UserList1 = [binary_to_list(Usr) || Usr <- UserList],
                    Data = #group_members{gid = GroupId, members = UserList1},
                    mnesia:dirty_write(?GOUPR_MEMBER_TABLE, Data),
                    {ok, UserList1};
                Err ->
                    ?ERROR_MSG("get_group_members error : ~p~n",[Err])
            end;
        [#group_members{members = Members}] ->
            {ok, Members};
        _ ->
            error
    end.


user_send_packet_handler(#jid{server = Domain} = From, To, Packet) ->
    try
        case Packet of
            {Tag, "message", Attr, Body} ->
                %                ?INFO_MSG("user_send_packet_handler From : ~p~n, To : ~p~n, Packet : ~p~n",[From, To, Packet]),
                MT = proplists:get_value("msgtype", Attr, ""),
                {M, S, SS} = os:timestamp(),
                MsgTime = lists:sublist(erlang:integer_to_list(M*1000000000000 + S*1000000 + SS), 1, 13),
                Attr1 = [{K, V} || {K, V} <- Attr, K =/= "msgTime"],
                Attr2 = [{"msgTime", MsgTime} | Attr1],
                Packet1 = {Tag, "message", Attr2, Body},
                if MT == "groupchat" andalso "gamepro.com" == Domain ->
                        GroupId = proplists:get_value("groupid", Attr, To#jid.user),
                        case store_group_message(From, GroupId, Packet1) of
                            repeat ->
                                skip;
                            Sid ->
                                Attr3 = [{"server_id", Sid} | Attr2],
                                RPacket = {Tag, "message", Attr3, Body},
                                server_ack(From, To, RPacket),
                                spawn(?MODULE, send_group_msg_to_user, [From, GroupId, Sid, RPacket])
                        end;
                    true ->
                        server_ack(From, To, Packet1),
                        send_message_to_user(From, To, Packet1)
                end;
            _ ->
                skip
        end
    catch
        ErrType:Reason ->
            Err = erlang:get_stacktrace(),
            ?ERROR_MSG("user_send_packet_handler failed ~p:~p:> ~p",[ErrType, Reason, Err])
    end.

route_group_msg(Packet, From, #jid{user = User, server = Domain} = To, Sid, GroupId) ->
    {X,E,Attr,Body} = Packet,
    Attr1 = lists:map(fun({K,V})->
                              case K of
                                  "to" -> {K, User ++ "@" ++ Domain};
                                  "id" -> {K, Sid};
                                  "msgtype" -> {K, "groupchat"};
                                  _-> {K, V}
                              end
                      end, Attr),
    Attr2 = lists:append(Attr1, [{"groupid", GroupId}]),
    Attr3 = lists:append(Attr2, [{"g","0"}]),
    RPacket = {X, E, Attr3, Body},
    send_message_to_user(From, To, RPacket),
    case ejabberd_router:route(From, To, RPacket) of
        ok ->
            {ok, ok};
        Err ->
            ?ERROR_MSG("route_group_msg failed, From : ~p, To : ~p, Packet : ~p, err : ~p~n",[From, To, RPacket, Err]),
            {error, Err}
    end.

send_group_msg_to_user(#jid{user = User, server = Domain} = From, GroupId, Sid, Packet) ->
    case get_group_members(GroupId, Domain) of
        {ok, Members} ->
            case lists:member(User, Members) of
                true->
                    [begin
                         UID = case is_list(Member) of
                                   true ->
                                       Member;
                                   false ->
                                       binary_to_list(Member)
                               end,
                         if User == UID ->
                                 skip;
                             true ->
                                 To = #jid{user = UID, server = Domain, luser = UID, lserver = Domain, resource = [], lresource = []},
                                 spawn(fun()-> route_group_msg(Packet, From, To, Sid, GroupId) end)
                         end
                     end || Member <- Members];
                _ ->
                    %%用户不在此群，删除此消息
                    ?ERROR_MSG("send_group_msg_to_user failed, From : ~p does not exist this group : ~p~n", [From, GroupId]),
                    delete_group_msg(GroupId, Sid)
            end;
        _ ->
            %%获取群成员报错，删除此消息
            ?ERROR_MSG("send_group_msg_to_user failed, group : ~p does not exist~n", [GroupId]),
            delete_group_msg(GroupId, Sid)
    end.


send_message_to_user(#jid{user=FU, server = Domain} = From, #jid{user = ToUser} = To, Packet) ->
    {_, "message", Attr, _} = Packet,
    D = dict:from_list(Attr),
    MT = case dict:is_key("msgtype",D) of true-> dict:fetch("msgtype",D); _-> "" end,
    SRC_ID_STR = case dict:is_key("id", D) of true -> dict:fetch("id", D); _ -> "" end,
    SYNCID = SRC_ID_STR ++ "@" ++ Domain,
    if MT=/=[],MT=/="msgStatus", MT=/="frienddynamicmsg",FU=/="messageack" ->
            case if_group_msg(SRC_ID_STR) of
                true ->
                    [_, GroupId, _] = re:split(SRC_ID_STR, "_", [{return, list}]),
                    init_user_group_info(To, GroupId),
                    AckId = SRC_ID_STR ++ "_" ++ ToUser,
                    receive_ack(AckId, From, To, Packet);
                _ ->
                    store_message(SYNCID, From, To, Packet),
                    receive_ack(SYNCID, From, To, Packet)
            end;
        MT=:="msgStatus", ToUser =/= "messageack" ->
            case if_group_msg(SRC_ID_STR) of
                true ->
                    [_, GroupId, Seq] = re:split(SRC_ID_STR, "_", [{return, list}]),
                    update_user_group_info(From, GroupId, list_to_integer(Seq)),
                    AckId = SRC_ID_STR ++ "_" ++ FU,
                    ack_task({ack, AckId});
                _ ->
                    del_message(SYNCID, From),
                    ack_task({ack, SYNCID})
            end;
        true ->
            skip
    end.


if_group_msg([$m,$y,$g,$r,$o,$u,$p | _]) ->
    true;
if_group_msg(_) ->
    false.


receive_ack(SYNCID, From, To, Packet) ->
    Pid = erlang:spawn(fun()-> ack_task(SYNCID, From, To, Packet) end),
    ets:insert(?ETS_ACK_TASK, {SYNCID, Pid}).



%% ====================================================================
%% Behavioural functions 
%% ====================================================================
-record(state, {
    ecache_node,
    ecache_mod=ecache_server,
    ecache_fun=cmd,
    push_pids = []
               }).

init([]) ->
    lists:foreach(
        fun(Host) ->
                ejabberd_hooks:add(user_send_packet,Host,?MODULE, user_send_packet_handler ,80)
        end, ?MYHOSTS),
    %% 2014-3-4 : 在这个 HOOK 初始化时，启动一个thrift 客户端，同步数据到缓存服务器
    %% 启动5281端口，接收内网回调
    %    aa_inf_server:start(),
    State = #state{},
	
    ets:new(?ETS_ACK_TASK, [named_table, public, set]),
	
    %% 初始化mnesia表
    State1 = init_mnesia_tables(State),
	
    PushPids = [spawn(fun() ->
                              local_handle_offline_message()
                      end) || _ <- lists:duplicate(?PUSH_PID_NUM, 1)],
    {ok, State1#state{push_pids = PushPids}}.

handle_call(reload_config, _From, State) ->
    ejabberd_config:reload_config(),
    {reply, reload_ok, State};

handle_call(rebuild_pushpids, _From, State) ->
    [exit(Pid, kill) || Pid <- State#state.push_pids],
    PushPids = [spawn(fun() ->
                              local_handle_offline_message()
                      end) || _ <- lists:duplicate(?PUSH_PID_NUM, 1)],
    {reply, rebuild_ok, State#state{push_pids = PushPids}};

handle_call(_Call, _From, State)->
    {reply, ok, State}.

handle_cast({server_ack, #jid{server = FD} = From, _To, Packet},State)->
    Domain = FD,
    {_,"message",Attr,_} = Packet,
    D = dict:from_list(Attr),
    MT = case dict:is_key("msgtype",D) of true-> dict:fetch("msgtype",D); _-> "" end,
    SRC_ID_STR = case dict:is_key("id", D) of true -> dict:fetch("id", D); _ -> "" end,
    Sid = case dict:is_key("server_id", D) of true -> dict:fetch("server_id", D); _ -> "" end,
    MsgTime = case dict:is_key("msgTime", D) of true -> dict:fetch("msgTime", D); _ -> "" end,
    FromStr = jlib:jid_to_string(From),
    if ( (MT=:="normalchat") or (MT=:="groupchat") ) ->
            Attributes = [
                {"id",get_id()},
                {"to", FromStr},
                {"from","messageack@"++Domain},
                {"type","normal"},
                {"msgtype",""},
                {"msgTime", MsgTime},
                {"action","ack"} |
                case Sid of
                    "" ->
                        [];
                    _ ->
                        [{"server_id", Sid}]
                end
                         ],
            Child = [{xmlelement, "body", [], [
                {xmlcdata, list_to_binary("{'src_id':'" ++ SRC_ID_STR ++ "','received':'true'}")}
                                              ]}],
            Answer = {xmlelement, "message", Attributes , Child},
            FF = jlib:string_to_jid(xml:get_tag_attr_s("from", Answer)),
            TT = jlib:string_to_jid(xml:get_tag_attr_s("to", Answer)),
            case catch ejabberd_router:route(FF, TT, Answer) of
                ok ->
                    ?INFO_MSG("server_ack successed, SRC_ID_STR : ~p, From : ~p~n", [SRC_ID_STR, From]),
                    answer;
                ERROR ->
                    ?ERROR_MSG("server_ack failed, SRC_ID_STR : ~p, From : ~p, Error : ~p~n", [SRC_ID_STR, From, ERROR]),
                    skip
            end;
        true ->
            skip
    end,
    {noreply, State};

handle_cast({deal_offline_msg, From,To,Packet}, State) ->
    case State#state.push_pids of
        [_pid|_] ->
            PushPids = State#state.push_pids;
        _ ->
            PushPids = [spawn(fun() ->
                                      local_handle_offline_message()
                              end) || _ <- lists:duplicate(?PUSH_PID_NUM, 1)]
    end,
	
    Pid = random_pushpid(PushPids),
	
    case is_process_alive(Pid) of
        true ->
            Pid ! {offline_msg, From, To, Packet},
            {noreply, State#state{push_pids = PushPids}};
        false ->
            NewPids = lists:delete(Pid, PushPids),
            deal_offline_msg(From, To, Packet),
            {noreply, State#state{push_pids = NewPids}}
    end;
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


ack_task({ack,ID})->
    try
        case ets:lookup(?ETS_ACK_TASK, ID) of
            [{ID, ACKTaskPid}] ->
                ACKTaskPid ! ack;
            _ ->
                skip
        end
    catch
        _:_->
            Error = erlang:get_stacktrace(),
            ?ERROR_MSG("DO_ACK_TASK_ID=~p ; M=~p ; ERROR=~p.",[ID, ack, Error]),
            ack_err
    end.

ack_task(ID, From, To, Packet) ->
    receive
        ack ->
            ets:delete(?ETS_ACK_TASK, ID)
    after ?TIME_OUT ->
            ets:delete(?ETS_ACK_TASK, ID),
            gen_server:cast(?MODULE, {deal_offline_msg, From, To, Packet})
    end.

    
server_ack(From,To,Packet)->
    gen_server:cast(?MODULE,{server_ack, From, To, Packet}).


get_id()-> 
    {M,S,SS} = now(),
    atom_to_list(node())++"_"++integer_to_list(M)++integer_to_list(S)++integer_to_list(SS).


init_mnesia_tables(State) ->
    [Domain|_] = ?MYHOSTS,
	
    case ejabberd_config:get_local_option({store_group_members, Domain}) of
        1 ->
            create_or_copy_table(?GOUPR_MEMBER_TABLE, [{attributes, record_info(fields,?GOUPR_MEMBER_TABLE)},
                                                       {ram_copies, [node()]}], ram_copies);
        _ ->
            skip
    end,
	
    case ejabberd_config:get_local_option({handle_msg_tables, Domain}) of
        undefined ->
            skip;
        [] ->
            skip;
        MsgTables when is_list(MsgTables) ->
            [create_or_copy_table(Table, [{record_name, user_msg},
                                          {attributes, record_info(fields,user_msg)},
                                          {ram_copies, [node()]}], ram_copies) || Table <- MsgTables]
    end,
	
    case ejabberd_config:get_local_option({handle_msglist_tables, Domain}) of
        undefined ->
            skip;
        [] ->
            skip;
        MsgListTables when is_list(MsgListTables) ->
            [create_or_copy_table(Table, [{record_name, user_msg_list},
                                          {attributes, record_info(fields,user_msg_list)},
                                          {ram_copies, [node()]}], ram_copies) || Table <- MsgListTables]
    end,
	
    %% 用户数据存储表
    case ejabberd_config:get_local_option({store_user_tables_info, Domain}) of
        1 ->
            create_or_copy_table(?MY_USER_TABLES, [{attributes, record_info(fields,?MY_USER_TABLES)},
                                                   {ram_copies, [node()]}], ram_copies);
        _ ->
            skip
    end,
    State.

create_or_copy_table(TableName, Opts, Copy) ->
    case mnesia:create_table(TableName, Opts) of
        {aborted,{already_exists,_}} ->
            mnesia:add_table_copy(TableName, node(), Copy);
        _ ->
            skip
    end.

random_pushpid(Pids) ->
    Count = length(Pids),
    {A, B, C} = os:timestamp(),
    random:seed(A, B,C),
    Index = random:uniform(Count),
    lists:nth(Index, Pids).

local_handle_offline_message() ->
    receive
        {offline_msg, From, To, Packet} ->
            deal_offline_msg(From,To,Packet),
            local_handle_offline_message()
    end.


store_group_message(From, GroupId, Packet) ->
    case get_group_data_node() of
        none ->
            ok;
        Node ->
            case rpc:call(Node, my_group_msg_center, store_message, [From, GroupId, Packet]) of
                {badrpc, Reason} ->
                    ?ERROR_MSG("store_group_message failed, Node : ~p, User : ~p, Packet : ~p Reason : ~p~n",[Node, From, Packet, Reason]),
                    throw({store_message_error, Reason});
                {ok, Data} ->
                    Data
            end
    end.


delete_group_msg(GroupId, Sid) ->
    case get_group_data_node() of
        none ->
            ok;
        Node ->
            rpc:cast(Node, my_group_msg_center, delete_group_msg, [GroupId, Sid])
    end.


init_user_group_info(User, GroupId) ->
    case get_group_data_node() of
        none ->
            ok;
        Node ->
            rpc:cast(Node, my_group_msg_center, init_user_group_info, [User, GroupId])
    end.


update_user_group_info(User, GroupId, Seq) ->
    case get_group_data_node() of
        none ->
            ok;
        Node ->
            rpc:cast(Node, my_group_msg_center, update_user_group_info, [User, GroupId, Seq])
    end.
    

store_message(SYNCID, From, To, RPacket) ->
    case get_data_node(To) of
        none ->
            aa_usermsg_handler:store_msg(SYNCID, From, To, RPacket);
        Node ->
            rpc:cast(Node, my_msg_center, store_message, [To, {SYNCID, From, RPacket}])
    end.


del_message(SYNCID, User) ->
    case get_data_node(User) of
        none ->
            aa_usermsg_handler:del_msg(SYNCID, User);
        Node ->
            rpc:cast(Node, my_msg_center, delete_message, [User, SYNCID])
    end.

get_offline_msg(User) ->
    {ok, NormalList} = get_normal_msg(User),
    {ok, GroupList} = get_group_msg(User),
    {ok, lists:append(NormalList, lists:reverse(GroupList))}.


get_normal_msg(User) ->
    case get_data_node(User) of
        none ->
            aa_usermsg_handler:get_offline_msg(User);
        Node ->
            case rpc:call(Node, my_msg_center, get_offline_msg, [User]) of
                {badrpc, Reason} ->
                    ?ERROR_MSG("get_normal_msg failed, Node : ~p, User : ~p, Reason : ~p~n",[Node, User, Reason]),
                    {ok, []};
                Result ->
                    Result
            end
    end.


get_group_msg(User) ->
    case get_group_data_node() of
        none ->
            {ok, []};
        Node ->
            case rpc:call(Node, my_group_msg_center, get_offline_msg, [User]) of
                {badrpc, Reason} ->
                    ?ERROR_MSG("get_group_msg failed, Node : ~p, User : ~p, Reason : ~p~n",[Node, User, Reason]),
                    {ok, []};
                Result ->
                    Result
            end
    end.


get_offline_data_node() ->
    case catch mnesia:table_info(user_info_tab, where_to_write) of
        [Node|_] ->
            Node;
        Reason ->
            ?ERROR_MSG("get_offline_data_node failed, Reason : ~p~n",[Reason]),
            none
    end.


get_group_data_node() ->
    case catch mnesia:table_info(group_message, where_to_write) of
        [Node|_] ->
            Node;
        Reason ->
            ?ERROR_MSG("get_group_data_node failed, Reason : ~p~n",[Reason]),
            none
    end.


get_data_node(#jid{server = Domain}=User) ->
    FinalNode =
	case mnesia:dirty_read(?MY_USER_TABLES, User) of
            [ #?MY_USER_TABLES{msg_list_table = ListTableName}] ->
                test_node(ListTableName);
            [] ->
                case ejabberd_config:get_local_option({new_table, Domain}) of
                    undefined ->
                        node();
                    [TableName|_] when is_atom(TableName) ->
                        test_node(TableName);
                    [TableName|_] when is_list(TableName) ->
                        test_node(list_to_atom(TableName));
                    _ ->
                        node()
                end
	end,
    FinalNode.

test_node(TableName) ->
    case catch mnesia:table_info(TableName, where_to_write) of
        [Node|_] ->
            Node;
        _ ->
            node()
    end.
-module(aa_hookhandler_sup).

-behaviour(supervisor).

%% API
-export([start_link/0]).

%% Supervisor callbacks
-export([init/1]).

%%%===================================================================
%%% API functions
%%%===================================================================
start_link() ->
	supervisor:start_link({local, ?MODULE}, ?MODULE, []).

init([]) ->
	AAHookhandler ={ aa_hookhandler,{aa_hookhandler, start_link, []}, permanent, brutal_kill, worker, [aa_hookhandler] },
	AAOfflineMod ={ aa_offline_mod,{aa_offline_mod, start_link, []}, permanent, brutal_kill, worker, [aa_offline_mod] },
	AAGroupChatSup ={ aa_group_chat_sup,{aa_group_chat_sup, start_link, []}, temporary, brutal_kill, supervisor, [aa_group_chat_sup] },
	{ok, {{one_for_one, 5, 10}, [AAHookhandler,AAOfflineMod,AAGroupChatSup]}}.
%%%===================================================================
%%% Internal functions
%%%===================================================================

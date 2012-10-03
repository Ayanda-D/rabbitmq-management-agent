%%   The contents of this file are subject to the Mozilla Public License
%%   Version 1.1 (the "License"); you may not use this file except in
%%   compliance with the License. You may obtain a copy of the License at
%%   http://www.mozilla.org/MPL/
%%
%%   Software distributed under the License is distributed on an "AS IS"
%%   basis, WITHOUT WARRANTY OF ANY KIND, either express or implied. See the
%%   License for the specific language governing rights and limitations
%%   under the License.
%%
%%   The Original Code is RabbitMQ Management Console.
%%
%%   The Initial Developer of the Original Code is VMware, Inc.
%%   Copyright (c) 2010-2012 VMware, Inc.  All rights reserved.
%%

-module(rabbit_mgmt_external_stats).

-behaviour(gen_server).

-export([start_link/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2,
         code_change/3]).

-export([list_registry_plugins/1]).

-include_lib("rabbit_common/include/rabbit.hrl").

-define(REFRESH_RATE, 5000).
-define(KEYS, [name, os_pid, memory, memory_age, fd_used, fd_total,
               sockets_used, sockets_total, mem_used, mem_limit, mem_alarm,
               disk_free_limit, disk_free, disk_free_alarm,
               proc_used, proc_total, statistics_level,
               uptime, run_queue, processors, exchange_types,
               auth_mechanisms, applications, contexts]).

%%--------------------------------------------------------------------

-record(state, {fd_total, memory_stats, memory_last_updated}).

%%--------------------------------------------------------------------

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%%--------------------------------------------------------------------

get_used_fd_lsof() ->
    case os:find_executable("lsof") of
        false -> unknown;
        Path  -> Cmd = Path ++ " -d \"0-9999999\" -lna -p " ++ os:getpid(),
                 string:words(os:cmd(Cmd), $\n) - 1
    end.

get_used_fd() ->
    get_used_fd(os:type()).

get_used_fd({unix, linux}) ->
    case file:list_dir("/proc/" ++ os:getpid() ++ "/fd") of
        {ok, Files} -> length(Files);
        {error, _}  -> get_used_fd({unix, generic})
    end;

get_used_fd({unix, BSD})
  when BSD == openbsd; BSD == freebsd; BSD == netbsd ->
    Digit = fun (D) -> lists:member(D, "0123456789*") end,
    length(
      lists:filter(
        fun (Line) ->
            lists:all(Digit, (lists:nth(4, string:tokens(Line, " "))))
        end,
        string:tokens(os:cmd("fstat -p " ++ os:getpid()), "\n")));

get_used_fd({unix, _}) ->
    get_used_fd_lsof();

%% handle.exe can be obtained from
%% http://technet.microsoft.com/en-us/sysinternals/bb896655.aspx

%% Output looks like:

%% Handle v3.42
%% Copyright (C) 1997-2008 Mark Russinovich
%% Sysinternals - www.sysinternals.com
%%
%% Handle type summary:
%%   ALPC Port       : 2
%%   Desktop         : 1
%%   Directory       : 1
%%   Event           : 108
%%   File            : 25
%%   IoCompletion    : 3
%%   Key             : 7
%%   KeyedEvent      : 1
%%   Mutant          : 1
%%   Process         : 3
%%   Process         : 38
%%   Thread          : 41
%%   Timer           : 3
%%   TpWorkerFactory : 2
%%   WindowStation   : 2
%% Total handles: 238

%% Note that the "File" number appears to include network sockets too; I assume
%% that's the number we care about. Note also that if you omit "-s" you will
%% see a list of file handles *without* network sockets. If you then add "-a"
%% you will see a list of handles of various types, including network sockets
%% shown as file handles to \Device\Afd.

get_used_fd({win32, _}) ->
    Handle = os:cmd("handle.exe /accepteula -s -p " ++ os:getpid() ++
                        " 2> nul"),
    case Handle of
        [] -> install_handle_from_sysinternals;
        _  -> find_files_line(string:tokens(Handle, "\r\n"))
    end;

get_used_fd(_) ->
    unknown.

find_files_line([]) ->
    unknown;
find_files_line(["  File " ++ Rest | _T]) ->
    [Files] = string:tokens(Rest, ": "),
    list_to_integer(Files);
find_files_line([_H | T]) ->
    find_files_line(T).

-define(SAFE_CALL(Fun, NoProcFailResult),
    try
        Fun
    catch exit:{noproc, _} -> NoProcFailResult
    end).

get_disk_free_limit() -> ?SAFE_CALL(rabbit_disk_monitor:get_disk_free_limit(),
                                    disk_free_monitoring_disabled).

get_disk_free() -> ?SAFE_CALL(rabbit_disk_monitor:get_disk_free(),
                              disk_free_monitoring_disabled).

%%--------------------------------------------------------------------

infos(Items, State) -> [{Item, i(Item, State)} || Item <- Items].

i(fd_total,   #state{fd_total = FdTotal})       -> FdTotal;
i(memory,     #state{memory_stats = Stats})     -> Stats;
i(memory_age, #state{memory_last_updated = LU}) -> timer:now_diff(
                                                     now(), LU) / 1000;

i(name,            _State) -> node();
i(fd_used,         _State) -> get_used_fd();
i(sockets_used,    _State) ->
    proplists:get_value(sockets_used, file_handle_cache:info([sockets_used]));
i(sockets_total,   _State) ->
    proplists:get_value(sockets_limit, file_handle_cache:info([sockets_limit]));
i(os_pid,          _State) -> list_to_binary(os:getpid());
i(mem_used,        _State) -> erlang:memory(total);
i(mem_limit,       _State) -> vm_memory_monitor:get_memory_limit();
i(mem_alarm,       _State) -> resource_alarm_set(memory);
i(proc_used,       _State) -> erlang:system_info(process_count);
i(proc_total,      _State) -> erlang:system_info(process_limit);
i(run_queue,       _State) -> erlang:statistics(run_queue);
i(processors,      _State) -> erlang:system_info(logical_processors);
i(disk_free_limit, _State) -> get_disk_free_limit();
i(disk_free,       _State) -> get_disk_free();
i(disk_free_alarm, _State) -> resource_alarm_set(disk);
i(contexts,        _State) -> rabbit_mochiweb_contexts();
i(uptime, _State) ->
    {Total, _} = erlang:statistics(wall_clock),
    Total;
i(statistics_level, _State) ->
    {ok, StatsLevel} = application:get_env(rabbit, collect_statistics),
    StatsLevel;
i(exchange_types, _State) ->
    list_registry_plugins(exchange);
i(auth_mechanisms, _State) ->
    {ok, Mechanisms} = application:get_env(rabbit, auth_mechanisms),
    list_registry_plugins(
      auth_mechanism,
      fun (N) -> lists:member(list_to_atom(binary_to_list(N)), Mechanisms) end);
i(applications, _State) ->
    [format_application(A) ||
        A <- lists:keysort(1, application:which_applications(infinity))].

resource_alarm_set(Source) ->
    lists:member({{resource_limit, Source, node()},[]},
                 rabbit_alarm:get_alarms()).

list_registry_plugins(Type) ->
    list_registry_plugins(Type, fun(_) -> true end).

list_registry_plugins(Type, Fun) ->
    [registry_plugin_enabled(Module:description(), Fun) ||
        {_, Module} <- rabbit_registry:lookup_all(Type)].

registry_plugin_enabled(Desc, Fun) ->
    Desc ++ [{enabled, Fun(proplists:get_value(name, Desc))}].

format_application({Application, Description, Version}) ->
    [{name, Application},
     {description, list_to_binary(Description)},
     {version, list_to_binary(Version)}].

%%--------------------------------------------------------------------

%% This is slightly icky in that we introduce knowledge of
%% rabbit_mochiweb, which is not a dependency. But the last thing I
%% want to do is create a rabbitmq_mochiweb_management_agent plugin.
rabbit_mochiweb_contexts() ->
    [format_context(C) || C <- rabbit_mochiweb_registry_list_all()].

%% For similar reasons we don't declare a dependency on
%% rabbitmq_mochiweb - so at startup there's no guarantee it will be
%% running. So we have to catch this noproc.
rabbit_mochiweb_registry_list_all() ->
    case code:is_loaded(rabbit_mochiweb_registry) of
        false -> [];
        _     -> try
                     apply0(rabbit_mochiweb_registry, list_all, [])
                 catch exit:{noproc, _} ->
                         []
                 end
    end.

%% Fool xref. Simply using apply(M, F, A) with constants is not enough.
apply0(M, F, A) -> apply(M, F, A).

format_context({Path, Description, Rest}) ->
    [{description, list_to_binary(Description)},
     {path,        list_to_binary("/" ++ Path)} |
     format_mochiweb_option_list(Rest)].

format_mochiweb_option_list(C) ->
    [{K, format_mochiweb_option(K, V)} || {K, V} <- C].

format_mochiweb_option(ssl_opts, V) ->
    format_mochiweb_option_list(V);
format_mochiweb_option(_K, V) when is_list(V) ->
    list_to_binary(V);
format_mochiweb_option(_K, V) ->
    V.

%%--------------------------------------------------------------------

init([]) ->
    State = update_memory_stats(#state{fd_total = file_handle_cache:ulimit()}),
    {ok, emit_update(State)}.

handle_call(_Req, _From, State) ->
    {reply, unknown_request, State}.

handle_cast(_C, State) ->
    {noreply, State}.

handle_info(emit_update, State) ->
    {noreply, emit_update(State)};

handle_info(update_memory_stats, State) ->
    {noreply, update_memory_stats(State)};

handle_info(_I, State) ->
    {noreply, State}.

terminate(_, _) -> ok.

code_change(_, State, _) -> {ok, State}.

%%--------------------------------------------------------------------

emit_update(State) ->
    rabbit_event:notify(node_stats, infos(?KEYS, State)),
    erlang:send_after(?REFRESH_RATE, self(), emit_update),
    State.

update_memory_stats(State) ->
    {Stats, Interval} =
        rabbit_misc:interval_operation(
          fun rabbit_vm:memory/0, 0.01, ?REFRESH_RATE),
    State1 = State#state{memory_stats        = Stats,
                         memory_last_updated = now()},
    erlang:send_after(Interval, self(), update_memory_stats),
    State1.

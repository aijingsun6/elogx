-module(elogx_pid_h).

%% logger_h_common callbacks
-export([
  init/2,
  check_config/4,
  config_changed/3,
  reset_state/2,
  filesync/3,
  write/4,
  handle_info/3,
  terminate/3
]).

%% logger callbacks
-export([
  log/2,
  adding_handler/1,
  removing_handler/1,
  changing_config/3,
  filter_config/1
]).

-export([
  add_pid/2,
  remove_pid/2
]).

-define(DEFAULT_CALL_TIMEOUT, 5000).
-record(state, {
  name,
  starter,
  starter_ref, % Ref
  config = #{},
  monitor_map = #{} %  Ref -> Pid
}).
%%%===================================================================
%%% logger callbacks - just forward to logger_h_common
%%%===================================================================

adding_handler(Config) ->
  logger_h_common:adding_handler(Config).

changing_config(SetOrUpdate, OldConfig, NewConfig) ->
  logger_h_common:changing_config(SetOrUpdate, OldConfig, NewConfig).

removing_handler(Config) ->
  logger_h_common:removing_handler(Config).

log(LogEvent, Config) ->
  logger_h_common:log(LogEvent, Config).

filter_config(Config) ->
  logger_h_common:filter_config(Config).

%%%===================================================================
%%% logger_h_common callbacks
%%%===================================================================
init(Name, Config) ->
  case pid_ctrl_start(Name, Config) of
    {ok, CtrlPid} ->
      {ok, Config#{ctrl_pid => CtrlPid}};
    Error ->
      Error
  end.

check_config(_Name, set, undefined, NewHConfig) ->
  {ok, NewHConfig};
check_config(_Name, _SetOrUpdate, OldHConfig, NewHConfig0) ->
  {ok, maps:merge(OldHConfig, NewHConfig0)}.

config_changed(_Name, Cfg, #{ctrl_pid := Pid} = State) ->
  Pid ! {update_config, Cfg},
  State.

filesync(_Name, _SyncAsync, State) ->
  Result = ok,
  {Result, State}.

write(_Name, async, Bin, #{ctrl_pid := Pid} = State) ->
  Pid ! {log, Bin},
  {ok, State};
write(_Name, sync, Bin, #{ctrl_pid := Pid} = State) ->
  Msg = {log, Bin},
  Reply = ctrl_call(Pid, Msg),
  {Reply, State}.

reset_state(_Name, State) ->
  State.

handle_info(_Name, {'EXIT', Pid, Why}, #{ctrl_pid := Pid} = State) ->
  %% file_ctrl_pid died, file error, terminate handler
  exit({error, {write_failed, State, Why}});
handle_info(_, Msg, #{ctrl_pid := Pid} = State) ->
  Pid ! Msg,
  State;
handle_info(_, _, State) ->
  State.

terminate(_Name, _Reason, #{ctrl_pid := FWPid}) ->
  case is_process_alive(FWPid) of
    true ->
      unlink(FWPid),
      _ = pid_ctrl_stop(FWPid),
      MRef = erlang:monitor(process, FWPid),
      receive
        {'DOWN', MRef, _, _, _} ->
          ok
      after
        ?DEFAULT_CALL_TIMEOUT ->
          exit(FWPid, kill),
          ok
      end;
    false ->
      ok
  end.

%%%===================================================================
%%% Internal functions
%%%===================================================================

pid_ctrl_start(HandlerName, HConfig) ->
  Starter = self(),
  CtrlPid = spawn_link(fun() -> pid_ctrl_init(HandlerName, HConfig, Starter) end),
  receive
    {CtrlPid, ok} ->
      {ok, CtrlPid};
    {CtrlPid, Error} ->
      Error
  after
    ?DEFAULT_CALL_TIMEOUT ->
      {error, file_ctrl_process_not_started}
  end.

pid_ctrl_stop(Pid) ->
  Pid ! stop.

add_pid(HandlerID, Pid) when is_atom(HandlerID), is_pid(Pid) ->
  {ok, #{config := #{olp := OLP}}} = logger_config:get(logger, HandlerID),
  ctrl_call(logger_olp:get_pid(OLP), {add_pid, Pid}).

remove_pid(HandlerID, Pid) when is_atom(HandlerID), is_pid(Pid) ->
  {ok, #{config := #{olp := OLP}}} = logger_config:get(logger, HandlerID),
  ctrl_call(logger_olp:get_pid(OLP), {remove_pid, Pid}).

ctrl_call(Pid, Msg) ->
  MRef = monitor(process, Pid),
  Pid ! {Msg, {self(), MRef}},
  receive
    {MRef, Result} ->
      demonitor(MRef, [flush]),
      Result;
    {'DOWN', MRef, _Type, _Object, Reason} ->
      {error, Reason}
  after
    ?DEFAULT_CALL_TIMEOUT ->
      {error, {no_response, Pid}}
  end.

pid_ctrl_init(HandlerName, HConfig, Starter) ->
  process_flag(message_queue_data, off_heap),
  process_flag(trap_exit, true),
  Starter ! {self(), ok},
  Ref = erlang:monitor(process, Starter),
  S = #state{starter = Starter, starter_ref = Ref, name = HandlerName, config = HConfig},
  pid_ctrl_loop(S).

pid_ctrl_loop(#state{monitor_map = M, starter_ref = SR,starter = Starter} = S) ->
  receive
  %% asynchronous event
    {log, Bin} ->
      [P ! {log, Starter, Bin} || P <- maps:values(M)],
      pid_ctrl_loop(S);
  %% synchronous event
    {{log, Bin}, {From, MRef}} ->
      [P ! {log, Starter, Bin} || P <- maps:values(M)],
      From ! {MRef, ok},
      pid_ctrl_loop(S);
    {update_config, Cfg} ->
      pid_ctrl_loop(S#state{config = Cfg});
    {{add_pid, Pid}, {From, MRef}} ->
      {Reply, S2} = add_pid_i(Pid, S),
      From ! {MRef, Reply},
      pid_ctrl_loop(S2);
    {{remove_pid, Pid}, {From, MRef}} ->
      {Reply, S2} = remove_pid_i(Pid, S),
      From ! {MRef, Reply},
      pid_ctrl_loop(S2);
    {'DOWN', MonitorRef, _Type, _Object, _Info} when MonitorRef =:= SR ->
      stopped;
    {'DOWN', MonitorRef, _Type, _Object, _Info} ->
      S2 = pid_die(MonitorRef, S),
      pid_ctrl_loop(S2);
    stop ->
      stopped;
    _Msg ->
      io:format("~p,recv unhandled msg:~p~n", [?MODULE, _Msg]),
      pid_ctrl_loop(S)
  end.

add_pid_i(Pid, #state{monitor_map = M} = S) ->
  L = maps:values(M),
  case lists:member(Pid, L) of
    true ->
      {pid_exist, S};
    false ->
      Ref = erlang:monitor(process, Pid),
      M2 = M#{Ref => Pid},
      {ok, S#state{monitor_map = M2}}
  end.

remove_pid_i(Pid, #state{monitor_map = M} = S) ->
  L = maps:to_list(M),
  case lists:keyfind(Pid, 2, L) of
    false ->
      {pid_not_exist, S};
    {Ref, Pid} ->
      erlang:demonitor(Ref, [flush]),
      M2 = maps:remove(Ref, M),
      {ok, S#state{monitor_map = M2}}
  end.

pid_die(Ref, #state{monitor_map = M} = S) ->
  case M of
    #{Ref := _} ->
      erlang:demonitor(Ref, [flush]),
      M2 = maps:remove(Ref, M),
      S#state{monitor_map = M2};
    _ ->
      S
  end.

-module(elogx_cnt_h).

%% API
-export([]).

-include_lib("kernel/include/file.hrl").

-include_lib("kernel/src/logger_h_common.hrl").
%%
%% file = file:filename()
%% modes = [file:mode()]
%% max_no_bytes = pos_integer() | infinity (type = by_bytes)
%% rotate_interval = pos_integer() | infinity (type = by_time)
%% max_no_count = pos_integer() | infinity (type = by_count)
%% max_no_files = non_neg_integer()
%% compress_on_rotate = boolean()
%% file_check = non_neg_integer()
%% filesync_repeat_interval = pos_integer() | no_repeat
%% API
-export([filesync/1]).

%% logger_h_common callbacks
-export([init/2, check_config/4, config_changed/3, reset_state/2,
  filesync/3, write/4, handle_info/3, terminate/3]).

%% logger callbacks
-export([log/2, adding_handler/1, removing_handler/1, changing_config/3,
  filter_config/1]).

-define(DEFAULT_CALL_TIMEOUT, 5000).
-define(MAX_NO_COUNT_DEFAULT, 1024 * 10).% 10k
-define(MAX_NO_FILES_DEFAULT, 99).
%%%===================================================================
%%% API
%%%===================================================================
filesync(Name) ->
  logger_h_common:filesync(?MODULE, Name).

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
  case file_ctrl_start(Name, Config) of
    {ok, FileCtrlPid} ->
      {ok, Config#{file_ctrl_pid => FileCtrlPid}};
    Error ->
      Error
  end.

check_config(Name, set, undefined, NewHConfig) ->
  check_h_config(merge_default_config(Name, NewHConfig));
check_config(Name, SetOrUpdate, OldHConfig, NewHConfig0) ->
  WriteOnce = maps:with([type, file, modes], OldHConfig),
  Default =
    case SetOrUpdate of
      set ->
        %% Do not reset write-once fields to defaults
        merge_default_config(Name, WriteOnce);
      update ->
        OldHConfig
    end,

  NewHConfig = maps:merge(Default, NewHConfig0),

  %% Fail if write-once fields are changed
  case maps:with([type, file, modes], NewHConfig) of
    WriteOnce ->
      check_h_config(NewHConfig);
    Other ->
      {error, {illegal_config_change, ?MODULE, WriteOnce, Other}}
  end.

check_h_config(HConfig) ->
  case check_h_config_i(maps:to_list(HConfig)) of
    ok ->
      {ok, fix_file_opts(HConfig)};
    {error, {Key, Value}} ->
      {error, {invalid_config, ?MODULE, #{Key => Value}}}
  end.

check_h_config_i([]) ->
  ok;
check_h_config_i([{file, File} | Config]) when is_list(File) ->
  check_h_config_i(Config);
check_h_config_i([{modes, Modes} | Config]) when is_list(Modes) ->
  check_h_config_i(Config);
check_h_config_i([{max_no_files, Num} | Config]) when is_integer(Num) andalso Num > 0 ->
  check_h_config_i(Config);
check_h_config_i([{compress_on_rotate, Bool} | Config]) when is_boolean(Bool) ->
  check_h_config_i(Config);
check_h_config_i([{file_check, FileCheck} | Config]) when is_integer(FileCheck), FileCheck >= 0 ->
  check_h_config_i(Config);
check_h_config_i([{max_no_count, Size} | Config]) when (is_integer(Size) andalso Size > 0) orelse Size =:= infinity ->
  check_h_config_i(Config);
check_h_config_i([Other | _]) ->
  {error, Other}.

merge_default_config(Name, HConfig) ->
  maps:merge(get_default_config(Name), HConfig).

get_default_config(Name) ->
  #{
    file => atom_to_list(Name),
    modes => [raw, append],
    file_check => 0,
    max_no_files => ?MAX_NO_FILES_DEFAULT,
    compress_on_rotate => false,
    max_no_count => ?MAX_NO_COUNT_DEFAULT
  }.

fix_file_opts(#{modes := Modes} = HConfig) ->
  HConfig#{modes => fix_modes(Modes)};
fix_file_opts(HConfig) ->
  HConfig#{filesync_repeat_interval => no_repeat}.

fix_modes(Modes) ->
  %% Ensure write|append|exclusive
  Modes1 =
    case [M || M <- Modes,
      lists:member(M, [write, append, exclusive])] of
      [] -> [append | Modes];
      _ -> Modes
    end,
  %% Ensure raw
  Modes2 =
    case lists:member(raw, Modes) of
      false -> [raw | Modes1];
      true -> Modes1
    end,
  %% Ensure delayed_write
  case lists:partition(fun(delayed_write) -> true;
    ({delayed_write, _, _}) -> true;
    (_) -> false
                       end, Modes2) of
    {[], _} ->
      [delayed_write | Modes2];
    _ ->
      Modes2
  end.

config_changed(_Name, C, #{file_ctrl_pid := FileCtrlPid} = State) ->
  FileCtrlPid ! {update_config, C},
  maps:merge(State, C).

filesync(_Name, SyncAsync, #{file_ctrl_pid := FileCtrlPid} = State) ->
  Result = file_ctrl_filesync(SyncAsync, FileCtrlPid),
  {Result, State}.

write(_Name, SyncAsync, Bin, #{file_ctrl_pid := FileCtrlPid} = State) ->
  Result = file_write(SyncAsync, FileCtrlPid, Bin),
  {Result, State}.

reset_state(_Name, State) ->
  State.

handle_info(_Name, {'EXIT', Pid, Why}, #{file_ctrl_pid := Pid} = State) ->
  %% file_ctrl_pid died, file error, terminate handler
  exit({error, {write_failed, maps:with([type, file, modes], State), Why}});
handle_info(_, _, State) ->
  State.

terminate(_Name, _Reason, #{file_ctrl_pid := FWPid}) ->
  case is_process_alive(FWPid) of
    true ->
      unlink(FWPid),
      _ = file_ctrl_stop(FWPid),
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

%%%-----------------------------------------------------------------
%%%
open_log_file(HandlerName, #{
  file := FileName,
  modes := Modes,
  file_check := FileCheck} = Config) ->
  try
    case filelib:ensure_dir(FileName) of
      ok ->
        case file:open(FileName, Modes) of
          {ok, Fd} ->
            {ok, #file_info{inode = INode}} = file:read_file_info(FileName, [raw]),
            UpdateModes = [append | Modes--[write, append, exclusive]],
            State0 = #{
              handler_name => HandlerName,
              file_name => FileName,
              modes => UpdateModes,
              file_check => FileCheck,
              fd => Fd,
              inode => INode,
              last_check => timestamp(),
              synced => false,
              write_res => ok,
              sync_res => ok
            },
            State = update_rotation(Config, State0),
            {ok, State};
          Error ->
            Error
        end;
      Error ->
        Error
    end
  catch
    _:Reason -> {error, Reason}
  end.

close_log_file(#{fd := Fd}) ->
  _ = file:datasync(Fd),
  _ = file:close(Fd),
  ok;
close_log_file(_) ->
  ok.


%%%-----------------------------------------------------------------
%%% File control process

file_ctrl_start(HandlerName, HConfig) ->
  Starter = self(),
  FileCtrlPid = spawn_link(fun() -> file_ctrl_init(HandlerName, HConfig, Starter) end),
  receive
    {FileCtrlPid, ok} ->
      {ok, FileCtrlPid};
    {FileCtrlPid, Error} ->
      Error
  after
    ?DEFAULT_CALL_TIMEOUT ->
      {error, file_ctrl_process_not_started}
  end.

file_ctrl_stop(Pid) ->
  Pid ! stop.

file_write(async, Pid, Bin) ->
  Pid ! {log, Bin},
  ok;
file_write(sync, Pid, Bin) ->
  file_ctrl_call(Pid, {log, Bin}).

file_ctrl_filesync(async, Pid) ->
  Pid ! filesync,
  ok;
file_ctrl_filesync(sync, Pid) ->
  file_ctrl_call(Pid, filesync).

file_ctrl_call(Pid, Msg) ->
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

file_ctrl_init(HandlerName, #{file := FileName} = HConfig, Starter) ->
  process_flag(message_queue_data, off_heap),
  case open_log_file(HandlerName, HConfig) of
    {ok, State} ->
      Starter ! {self(), ok},
      file_ctrl_loop(State);
    {error, Reason} ->
      Starter ! {self(), {error, {open_failed, FileName, Reason}}}
  end.

file_ctrl_loop(State) ->
  receive
  %% asynchronous event
    {log, Bin} ->
      State1 = write_to_dev(Bin, State),
      file_ctrl_loop(State1);

  %% synchronous event
    {{log, Bin}, {From, MRef}} ->
      State1 = ensure_file(State),
      State2 = write_to_dev(Bin, State1),
      From ! {MRef, ok},
      file_ctrl_loop(State2);

    filesync ->
      State1 = sync_dev(State),
      file_ctrl_loop(State1);

    {filesync, {From, MRef}} ->
      State1 = ensure_file(State),
      State2 = sync_dev(State1),
      From ! {MRef, ok},
      file_ctrl_loop(State2);

    {update_config, #{file_check := FileCheck} = Config} ->
      State1 = update_rotation(Config, State),
      S2 = State1#{file_check => FileCheck},
      file_ctrl_loop(S2);

    stop ->
      close_log_file(State),
      stopped
  end.

maybe_ensure_file(#{file_check := 0} = State) ->
  ensure_file(State);
maybe_ensure_file(#{last_check := T0, file_check := CheckInt} = State) when is_integer(CheckInt) ->
  T = timestamp(),
  if T - T0 > CheckInt -> ensure_file(State);
    true -> State
  end;
maybe_ensure_file(State) ->
  State.

%% In order to play well with tools like logrotate, we need to be able
%% to re-create the file if it has disappeared (e.g. if rotated by
%% logrotate)
ensure_file(#{fd := Fd0, inode := INode0, file_name := FileName, modes := Modes} = State) ->
  case file:read_file_info(FileName, [raw]) of
    {ok, #file_info{inode = INode0}} ->
      State#{last_check => timestamp()};
    _ ->
      close_log_file(Fd0),
      case file:open(FileName, Modes) of
        {ok, Fd} ->
          {ok, #file_info{inode = INode}} = file:read_file_info(FileName, [raw]),
          State#{fd => Fd, inode => INode, last_check => timestamp(), synced => true, sync_res => ok};
        Error ->
          exit({could_not_reopen_file, Error})
      end
  end;
ensure_file(State) ->
  State.

write_to_dev(Bin, State) ->
  State1 = #{fd := Fd} = maybe_ensure_file(State),
  Result = ?file_write(Fd, Bin),
  State2 = maybe_rotate_file(Bin, State1),
  maybe_notify_error(write, Result, State2),
  State2#{synced => false, write_res => Result}.

sync_dev(#{synced := false} = State) ->
  State1 = #{fd := Fd} = maybe_ensure_file(State),
  Result = ?file_datasync(Fd),
  maybe_notify_error(filesync, Result, State1),
  State1#{synced => true, sync_res => Result};
sync_dev(State) ->
  State.

update_rotation(#{max_no_count := Size, max_no_files := Count, compress_on_rotate := Compress}, #{file_name := FileName} = State) ->
  case Size of
    infinity ->
      maybe_remove_archives(0, State),
      maps:remove(rotation, State);
    _ when is_integer(Size) ->
      maybe_remove_archives(Count, State),
      CurrSize = file_lines(FileName),
      State1 = State#{rotation =>
      #{
        size => Size,
        count => Count,
        compress => Compress,
        curr_size => CurrSize}
      },
      maybe_update_compress(0, State1),
      maybe_rotate_file(0, State1)
  end.


maybe_remove_archives(Count, #{file_name := FileName} = State) ->
  Archive = rot_file_name(FileName, Count, false),
  CompressedArchive = rot_file_name(FileName, Count, true),
  case {file:read_file_info(Archive, [raw]),
    file:read_file_info(CompressedArchive, [raw])} of
    {{error, enoent}, {error, enoent}} ->
      ok;
    _ ->
      _ = file:delete(Archive),
      _ = file:delete(CompressedArchive),
      maybe_remove_archives(Count + 1, State)
  end.

maybe_update_compress(Count, #{rotation := #{count := Count}}) ->
  ok;
maybe_update_compress(N, #{file_name := FileName, rotation := #{compress := Compress}} = State) ->
  Archive = rot_file_name(FileName, N, not Compress),
  case file:read_file_info(Archive, [raw]) of
    {ok, _} when Compress ->
      compress_file(Archive);
    {ok, _} ->
      decompress_file(Archive);
    _ ->
      ok
  end,
  maybe_update_compress(N + 1, State).

maybe_rotate_file(Bin, #{rotation := _} = State) when is_binary(Bin) ->
  maybe_rotate_file(1, State);
maybe_rotate_file(AddSize, #{rotation := #{size := RotSize, curr_size := CurrSize} = Rotation} = State) ->
  NewSize = case AddSize > 0 of
              true -> CurrSize + 1;
              false -> CurrSize
            end,
  if
    NewSize > RotSize ->
      rotate_file(State#{rotation => Rotation#{curr_size => NewSize}});
    true ->
      State#{rotation => Rotation#{curr_size => NewSize}}
  end;
maybe_rotate_file(_Bin, State) ->
  State.

rotate_file(#{fd := Fd0, file_name := FileName, modes := Modes, rotation := Rotation} = State) ->
  State1 = sync_dev(State),
  _ = file:close(Fd0),
  rotate_files(FileName, maps:get(count, Rotation), maps:get(compress, Rotation)),
  case file:open(FileName, Modes) of
    {ok, Fd} ->
      {ok, #file_info{inode = INode}} = file:read_file_info(FileName, [raw]),
      State1#{fd => Fd, inode => INode, rotation => Rotation#{curr_size => 0}};
    Error ->
      exit({could_not_reopen_file, Error})
  end.

rotate_files(FileName, 0, _Compress) ->
  _ = file:delete(FileName),
  ok;
rotate_files(FileName, 1, Compress) ->
  FileName0 = FileName ++ ".0",
  _ = file:rename(FileName, FileName0),
  if Compress -> compress_file(FileName0);
    true -> ok
  end,
  ok;
rotate_files(FileName, Count, Compress) ->
  _ = file:rename(rot_file_name(FileName, Count - 2, Compress), rot_file_name(FileName, Count - 1, Compress)),
  rotate_files(FileName, Count - 1, Compress).

rot_file_name(FileName, Count, false) ->
  FileName ++ "." ++ integer_to_list(Count);
rot_file_name(FileName, Count, true) ->
  rot_file_name(FileName, Count, false) ++ ".gz".

compress_file(FileName) ->
  {ok, In} = file:open(FileName, [read, binary]),
  {ok, Out} = file:open(FileName ++ ".gz", [write]),
  Z = zlib:open(),
  zlib:deflateInit(Z, default, deflated, 31, 8, default),
  compress_data(Z, In, Out),
  zlib:deflateEnd(Z),
  zlib:close(Z),
  _ = file:close(In),
  _ = file:close(Out),
  _ = file:delete(FileName),
  ok.

compress_data(Z, In, Out) ->
  case file:read(In, 100000) of
    {ok, Data} ->
      Compressed = zlib:deflate(Z, Data),
      _ = file:write(Out, Compressed),
      compress_data(Z, In, Out);
    eof ->
      Compressed = zlib:deflate(Z, <<>>, finish),
      _ = file:write(Out, Compressed),
      ok
  end.

decompress_file(FileName) ->
  {ok, In} = file:open(FileName, [read, binary]),
  {ok, Out} = file:open(filename:rootname(FileName, ".gz"), [write]),
  Z = zlib:open(),
  zlib:inflateInit(Z, 31),
  decompress_data(Z, In, Out),
  zlib:inflateEnd(Z),
  zlib:close(Z),
  _ = file:close(In),
  _ = file:close(Out),
  _ = file:delete(FileName),
  ok.

decompress_data(Z, In, Out) ->
  case file:read(In, 1000) of
    {ok, Data} ->
      Decompressed = zlib:inflate(Z, Data),
      _ = file:write(Out, Decompressed),
      decompress_data(Z, In, Out);
    eof ->
      ok
  end.

maybe_notify_error(_Op, ok, _State) ->
  ok;
maybe_notify_error(Op, Result, #{write_res := WR, sync_res := SR})
  when (Op == write andalso Result == WR) orelse
  (Op == filesync andalso Result == SR) ->
  %% don't report same error twice
  ok;
maybe_notify_error(Op, Error, #{handler_name := HandlerName, file_name := FileName}) ->
  logger_h_common:error_notify({HandlerName, Op, FileName, Error}),
  ok.

timestamp() ->
  erlang:monotonic_time(millisecond).

file_lines(FileName) ->
  {ok, IoDevice} = file:open(FileName, [read]),
  Acc = file_lines(IoDevice, 0),
  file:close(IoDevice),
  Acc.

file_lines(IoDevice, Acc) ->
  case file:read_line(IoDevice) of
    {ok, _} -> file_lines(IoDevice, Acc + 1);
    eof -> Acc;
    {error, _Reason} -> Acc
  end.
%% The BEAM twin of Probe.js: run one shell check and capture what it prints.
%%
%% This module also holds the two shell primitives every other BEAM edge in
%% Quartermaster uses (Apply, Build, Exec, Publish):
%%
%%   capture/2  run a line to completion under a timeout, stdout captured,
%%              stderr discarded, stdin empty.            (node: execSync + pipe)
%%   stream/2   run a line with live output and no timeout. (node: stdio inherit)
%%
%% Inheriting stdio is the one thing the BEAM cannot do the way node does: a
%% port's child always gets pipes for stdin and stdout. Only stderr really is
%% inherited. So stream/2 forwards the child's stdout as it arrives, and it
%% gives the child the terminal directly when there is one:
%%   - stdout: when the VM's stdout is a terminal, the child writes to /dev/tty
%%     itself, so progress bars and colour still work. Otherwise (a pipe or a
%%     file) its output is forwarded chunk by chunk.
%%   - stdin: the terminal when stderr is one, else /dev/null. A pipe or a
%%     redirect into `quartermaster` is NOT passed on, which is the one place
%%     this differs from node; when beam/quartermaster reports that stdin is
%%     piped (QM_STDIN), stream/2 says so on stderr rather than drop it
%%     silently. sudo is unaffected either way, since it reads /dev/tty itself.
-module(quartermaster_cLI_probe@foreign).
-export([shProbeImpl/0, capture/2, stream/2]).
-purs_ignore_exports([capture/2, stream/2]).

shProbeImpl() -> fun(Cmd) -> capture(Cmd, 10000) end.

%% {ok, out}: ok when the line exits 0; out is trimmed stdout either way. A
%% timeout kills the line's whole process group and reads as a failure.
capture(Cmd, TimeoutMs) ->
    Port = open_port({spawn_executable, "/bin/sh"},
                     [{args, ["-c", "exec 2>/dev/null </dev/null; eval \"$1\"", "sh", Cmd]},
                      exit_status, binary, hide]),
    case collect(Port, <<>>, erlang:monotonic_time(millisecond) + TimeoutMs) of
        {exit, 0, Out} -> #{ok => true, out => trim(Out)};
        {exit, _, Out} -> #{ok => false, out => trim(Out)};
        {timeout, Out} -> #{ok => false, out => trim(Out)}
    end.

collect(Port, Acc, Deadline) ->
    Left = max(0, Deadline - erlang:monotonic_time(millisecond)),
    receive
        {Port, {data, D}} -> collect(Port, <<Acc/binary, D/binary>>, Deadline);
        {Port, {exit_status, Code}} -> {exit, Code, Acc}
    after Left ->
        case erlang:port_info(Port, os_pid) of
            {os_pid, Pid} -> os:cmd("kill -KILL -- -" ++ integer_to_list(Pid) ++ " 2>/dev/null");
            _ -> ok
        end,
        catch port_close(Port),
        {timeout, Acc}
    end.

%% Run Cmd under Shell ("sh" or "bash") with live output; returns the exit code.
stream(Shell, Cmd) ->
    Exe = case os:find_executable(Shell) of
              false -> "/bin/" ++ Shell;
              Path -> Path
          end,
    Out = case stdout_is_terminal() of true -> "tty"; false -> "pipe" end,
    case os:getenv("QM_STDIN") of
        "piped" -> io:format(standard_error,
                             "quartermaster: stdin is piped, and the BEAM build cannot pass it on;"
                             " the command reads /dev/null~n", []);
        _ -> ok
    end,
    Prelude = "if [ \"$2\" = tty ]; then exec >/dev/tty; fi; "
              "if [ -t 2 ] && { true </dev/tty; } 2>/dev/null; then exec </dev/tty; "
              "else exec </dev/null; fi; eval \"$1\"",
    Port = open_port({spawn_executable, Exe},
                     [{args, ["-c", Prelude, Shell, Cmd, Out]},
                      exit_status, binary, hide, stream]),
    forward(Port, <<>>).

stdout_is_terminal() ->
    case catch io:getopts(standard_io) of
        Opts when is_list(Opts) -> proplists:get_value(terminal, Opts, false) =:= true;
        _ -> false
    end.

%% Forward the child's stdout as it arrives. A UTF-8 character split across two
%% chunks is held back until it is complete; a byte that is not UTF-8 at all is
%% written as U+FFFD rather than crashing the forwarder.
forward(Port, Pending) ->
    receive
        {Port, {data, D}} -> forward(Port, emit(<<Pending/binary, D/binary>>));
        {Port, {exit_status, Code}} ->
            _ = emit_all(Pending),
            Code
    end.

emit(Bin) ->
    case unicode:characters_to_binary(Bin) of
        Good when is_binary(Good) -> put(Good), <<>>;
        {incomplete, Good, Rest} -> put(Good), Rest;
        {error, Good, <<_, Rest/binary>>} -> put(Good), put(<<16#FFFD/utf8>>), emit(Rest)
    end.

emit_all(<<>>) -> ok;
emit_all(Bin) ->
    case emit(Bin) of
        <<>> -> ok;
        <<_, Rest/binary>> -> put(<<16#FFFD/utf8>>), emit_all(Rest)
    end.

put(<<>>) -> ok;
put(Bin) -> io:put_chars(standard_io, Bin).

trim(B) -> unicode:characters_to_binary(string:trim(unicode:characters_to_list(B))).

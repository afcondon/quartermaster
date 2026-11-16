%% The BEAM twin of Exec.js. The exit code is kept in a persistent term and the
%% launcher (beam/quartermaster) halts with it once Main returns, which is what
%% node's deferred `process.exitCode` does.
-module(quartermaster_cLI_exec@foreign).
-export([readFileImpl/0, streamImpl/0, setExitCode/0]).

readFileImpl() ->
    fun(Path) ->
        case file:read_file(Path) of
            {ok, Contents} -> #{found => true, contents => Contents};
            {error, _} -> #{found => false, contents => <<>>}
        end
    end.

streamImpl() -> fun(Cmd) -> quartermaster_cLI_probe@foreign:stream("bash", Cmd) end.

setExitCode() -> fun(Code) -> persistent_term:put(quartermaster_exit_code, Code), unit end.

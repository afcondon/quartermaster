%% The BEAM twin of Build.js: a build/ship line with live output, no timeout.
-module(quartermaster_cLI_build@foreign).
-export([runStreamImpl/0]).

runStreamImpl() ->
    fun(Cmd) -> #{ok => quartermaster_cLI_probe@foreign:stream("sh", Cmd) =:= 0} end.

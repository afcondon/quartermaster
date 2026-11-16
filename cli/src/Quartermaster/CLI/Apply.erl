%% The BEAM twin of Apply.js. A 30 s ceiling on a capture (an ssh probe
%% round-trip, not a build); a phase streams with no timeout, under bash so the
%% ssh heredoc that applyInvocation renders is read by a real shell.
-module(quartermaster_cLI_apply@foreign).
-export([captureImpl/0, streamImpl/0]).

captureImpl() -> fun(Cmd) -> quartermaster_cLI_probe@foreign:capture(Cmd, 30000) end.
streamImpl() -> fun(Cmd) -> quartermaster_cLI_probe@foreign:stream("bash", Cmd) end.

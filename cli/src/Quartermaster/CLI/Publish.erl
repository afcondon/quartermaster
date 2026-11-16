%% The BEAM twin of Publish.js.
%%
%% ensureCustomDomainImpl makes a Pages custom domain live in two parts, each
%% with the right credential, exactly as Publish.js does (read its comment for
%% the why): attach the domain with wrangler's OAuth token, then create the
%% zone CNAME with QM_CF_DNS_TOKEN. Tokens reach curl through the environment,
%% never the command line. Non-fatal throughout: the deploy is the verdict.
%%
%% NOT YET RUN LIVE on the BEAM (2026-11-16): `publish --dry-run` never reaches
%% it, and a live run talks to Cloudflare.
-module(quartermaster_cLI_publish@foreign).
-export([runStreamImpl/0, ensureCustomDomainImpl/0]).

-define(CF_API, "https://api.cloudflare.com/client/v4").

runStreamImpl() ->
    fun(Cmd) -> #{ok => quartermaster_cLI_probe@foreign:stream("sh", Cmd) =:= 0} end.

ensureCustomDomainImpl() ->
    fun(Project, Domain) ->
        try ensure(binary_to_list(Project), binary_to_list(Domain))
        catch _:Reason -> result(false, io_lib:format("~p", [Reason]))
        end
    end.

ensure(Project, Domain) ->
    Config = filename:join([os:getenv("HOME"), ".wrangler", "config", "default.toml"]),
    Cfg = case file:read_file(Config) of {ok, B} -> B; _ -> <<>> end,
    case re:run(Cfg, "oauth_token\\s*=\\s*\"([^\"]+)\"", [{capture, all_but_first, list}]) of
        nomatch -> result(false, "no wrangler oauth_token found — run `wrangler login`");
        {match, [OAuth]} -> with_account(Project, Domain, OAuth)
    end.

with_account(Project, Domain, OAuth) ->
    Oauth = [{"CF_TOKEN", OAuth}],
    case first_id(get_json(?CF_API "/accounts", "CF_TOKEN", Oauth)) of
        undefined -> result(false, "could not resolve CF account id");
        Acct ->
            Attach = post_json(?CF_API "/accounts/" ++ Acct ++ "/pages/projects/" ++ Project ++ "/domains",
                               "{\"name\":\"" ++ Domain ++ "\"}", "CF_TOKEN", Oauth),
            AttachMsg = case success(Attach) of
                            true -> "attached";
                            false -> first_error(Attach, "attach failed")
                        end,
            AttachedOk = success(Attach) orelse matches(AttachMsg, "already|exists"),
            dns(Project, Domain, AttachMsg, AttachedOk)
    end.

dns(Project, Domain, AttachMsg, AttachedOk) ->
    Labels = string:split(Domain, ".", all),
    N = length(Labels),
    ZoneName = string:join(lists:nthtail(max(0, N - 2), Labels), "."),
    Sub = case string:join(lists:sublist(Labels, max(0, N - 2)), ".") of "" -> "@"; S -> S end,
    Target = Project ++ ".pages.dev",
    case os:getenv("QM_CF_DNS_TOKEN") of
        Missing when Missing =:= false; Missing =:= "" ->
            result(AttachedOk,
                   AttachMsg ++ " (pending) — DNS not created: the wrangler OAuth token lacks Zone:DNS:Edit. "
                   "Set QM_CF_DNS_TOKEN (a Zone:DNS:Edit token on " ++ ZoneName ++ ") to automate, or add CNAME "
                   ++ Sub ++ " → " ++ Target ++ " (proxied) in " ++ ZoneName);
        Token ->
            Env = [{"CF_DNS", Token}],
            case first_id(get_json(?CF_API "/zones?name=" ++ ZoneName, "CF_DNS", Env)) of
                undefined ->
                    result(AttachedOk, AttachMsg ++ "; DNS: zone " ++ ZoneName ++ " not found with CLOUDFLARE_API_TOKEN");
                Zone ->
                    Rec = post_json(?CF_API "/zones/" ++ Zone ++ "/dns_records",
                                    "{\"type\":\"CNAME\",\"name\":\"" ++ Sub ++ "\",\"content\":\"" ++ Target
                                    ++ "\",\"proxied\":true}", "CF_DNS", Env),
                    case success(Rec) of
                        true -> result(true, "attached + CNAME " ++ Sub ++ " → " ++ Target ++ " created");
                        false ->
                            DnsMsg = first_error(Rec, "DNS create failed"),
                            case matches(DnsMsg, "already exists|identical") of
                                true -> result(true, "attached; DNS record already present");
                                false -> result(AttachedOk, AttachMsg ++ "; DNS: " ++ DnsMsg)
                            end
                    end
            end
    end.

get_json(Url, TokenVar, Env) ->
    curl("curl -s -H \"Authorization: Bearer $" ++ TokenVar ++ "\" '" ++ Url ++ "'", Env).

post_json(Url, Body, TokenVar, Env) ->
    curl("curl -s -X POST -H \"Authorization: Bearer $" ++ TokenVar ++ "\" -H \"Content-Type: application/json\" '"
         ++ Url ++ "' --data '" ++ Body ++ "'", Env).

%% Run curl with the token in the environment; decode the body (OTP 27's json).
curl(Line, Env) ->
    Port = open_port({spawn_executable, "/bin/sh"},
                     [{args, ["-c", "exec 2>/dev/null </dev/null; eval \"$1\"", "sh", Line]},
                      {env, Env}, exit_status, binary, hide]),
    Body = drain(Port, <<>>),
    try json:decode(Body) catch _:_ -> #{} end.

drain(Port, Acc) ->
    receive
        {Port, {data, D}} -> drain(Port, <<Acc/binary, D/binary>>);
        {Port, {exit_status, _}} -> Acc
    after 30000 -> catch port_close(Port), Acc
    end.

success(#{<<"success">> := true}) -> true;
success(_) -> false.

first_id(#{<<"result">> := [#{<<"id">> := Id} | _]}) -> binary_to_list(Id);
first_id(_) -> undefined.

first_error(#{<<"errors">> := [#{<<"message">> := M} | _]}, _) -> unicode:characters_to_list(M);
first_error(_, Default) -> Default.

matches(Text, Re) -> re:run(Text, Re, [caseless, unicode, {capture, none}]) =:= match.

result(Ok, Message) -> #{ok => Ok, message => unicode:characters_to_binary(Message)}.

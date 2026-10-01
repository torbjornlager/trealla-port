% SPDX-License-Identifier: MIT

:- module(deployment_start,
       [ start_node/0,
         check_config/0,
         request_maintenance/0
       ]).

/** <module> Fail-closed deployment entry point for the Trealla node

This launcher deliberately has different defaults from the development API:
private authentication, whitelist sandboxing, bounded resources, and no
remote source loading. The container entrypoint calls start_node/0; image
builds call check_config/0 without opening a listener.
*/

:- use_module(web_prolog).
:- use_module(profile_policy).
:- use_module(sandbox_policy).
:- use_module(auth_policy).
:- use_module(governance_policy).
:- use_module(resource_policy).
:- use_module(source_policy).
:- use_module(ip_policy).
:- use_module(observability).
:- use_module(library(http)).

start_node :-
    deployment_options(Port, Options),
    validate_options(Options),
    print_configuration(Port, Options),
    web_prolog_node(Port, Options).

check_config :-
    deployment_options(Port, Options),
    validate_options(Options),
    print_configuration(Port, Options),
    writeln('Configuration OK (listener not started).').

deployment_options(Port, Options) :-
    env_integer('WP_PORT', 3060, Port), positive(port, Port),
    env_atom('WP_PUBLIC_URL', 'http://localhost:8080', PublicURL),
    env_choice('WP_PROFILE', [relation,isobase,isotope,actor], actor, Profile),
    env_choice('WP_AUTH', [open,private,dev], private, Auth),
    env_atom('WP_OWNER', '', Owner),
    env_choice('WP_SANDBOX', [whitelist,blacklist], whitelist, Sandbox),
    public_acknowledged(Auth),
    admin_token(AdminToken),
    env_csv('WP_WS_ALLOWED_ORIGINS', WSOrigins),
    env_csv('WP_TRUSTED_PROXY_RANGES', TrustedProxies),
    env_csv('WP_IP_ALLOWLIST', IPAllowlist),
    env_csv('WP_IP_BLOCKLIST', IPBlocklist),
    env_csv('WP_LOAD_URI_ORIGINS', SourceOrigins),
    env_csv_default('WP_TUTORIAL_SECTIONS', [actor], TutorialSections),
    env_integer('WP_TIME_LIMIT', 10, TimeLimit), positive(time_limit, TimeLimit),
    env_integer('WP_IDLE_LIMIT', 120, IdleLimit), positive(idle_limit, IdleLimit),
    env_integer('WP_MAX_ACTORS', 128, MaxActors), positive(max_actors, MaxActors),
    env_integer('WP_MAX_SOLUTIONS', 100, MaxSolutions), positive(max_solutions, MaxSolutions),
    env_integer('WP_MAX_TERM_BYTES', 32768, MaxTermBytes), positive(max_term_text_bytes, MaxTermBytes),
    env_integer('WP_MAX_SOURCE_BYTES', 131072, MaxSourceBytes), positive(max_source_text_bytes, MaxSourceBytes),
    env_integer('WP_MAX_WS_FRAME_BYTES', 262144, MaxFrameBytes), positive(max_ws_frame_bytes, MaxFrameBytes),
    env_integer('WP_RATE_WINDOW_SECONDS', 60, RateWindow), positive(rate_window_seconds, RateWindow),
    env_integer('WP_MAX_CALLS_PER_WINDOW', 120, MaxCalls), positive(max_call_requests_per_window, MaxCalls),
    env_integer('WP_MAX_SPAWNS_PER_WINDOW', 60, MaxSpawns), positive(max_session_spawns_per_window, MaxSpawns),
    env_integer('WP_MAX_WS_COMMANDS_PER_WINDOW', 1000, MaxCommands), positive(max_ws_commands_per_window, MaxCommands),
    env_integer('WP_MAX_INFLIGHT_CALLS', 4, MaxInflight), positive(max_inflight_calls, MaxInflight),
    env_integer('WP_MAX_WS_ACTORS_PER_PRINCIPAL', 16, MaxWSActors), positive(max_ws_actors_per_principal, MaxWSActors),
    env_integer('WP_AUTO_BAN_THRESHOLD', 5, BanThreshold), nonnegative(auto_ban_threshold, BanThreshold),
    env_integer('WP_AUTO_BAN_WINDOW_SECONDS', 60, BanWindow), positive(auto_ban_window_seconds, BanWindow),
    env_integer('WP_AUTO_BAN_SECONDS', 900, BanSeconds), positive(auto_ban_seconds, BanSeconds),
    env_atom('WP_AUDIT_LOG_FILE', '/state/audit.jsonl', AuditFile),
    env_integer('WP_MAX_AUDIT_LOG_BYTES', 10485760, AuditBytes), positive(max_audit_log_bytes, AuditBytes),
    env_integer('WP_MAX_AUDIT_LOG_BACKUPS', 5, AuditBackups), nonnegative(max_audit_log_backups, AuditBackups),
    env_atom('WP_TOKENS_FILE', '/state/tokens.pl', TokensFile),
    owner_options(Auth, Owner, OwnerOptions),
    Core0 = [bind_address('0.0.0.0'),node_url(PublicURL),profile(Profile),
            sandbox(Sandbox),auth(Auth),
            bearer_token(pilot_admin,AdminToken,[execute,admin]),
            tutorial_sections(TutorialSections),
            time_limit(TimeLimit),idle_limit(IdleLimit),max_actors(MaxActors),
            max_solutions(MaxSolutions),max_term_text_bytes(MaxTermBytes),
            max_source_text_bytes(MaxSourceBytes),max_ws_frame_bytes(MaxFrameBytes),
            rate_window_seconds(RateWindow),
            max_call_requests_per_window(MaxCalls),
            max_session_spawns_per_window(MaxSpawns),
            max_ws_commands_per_window(MaxCommands),
            max_inflight_calls(MaxInflight),
            max_ws_actors_per_principal(MaxWSActors),
            auto_ban_threshold(BanThreshold),
            auto_ban_window_seconds(BanWindow),auto_ban_seconds(BanSeconds),
            audit_log_file(AuditFile),max_audit_log_bytes(AuditBytes),
            max_audit_log_backups(AuditBackups),tokens_file(TokensFile)],
    append(OwnerOptions, Core0, Core),
    optional_list(ws_allowed_origins, WSOrigins, Core, O1),
    optional_list(trusted_proxy_ranges, TrustedProxies, O1, O2),
    optional_list(ip_allowlist, IPAllowlist, O2, O3),
    optional_list(ip_blocklist, IPBlocklist, O3, O4),
    optional_list(load_uri_allowed_origins, SourceOrigins, O4, Options).

validate_options(Options) :-
    memberchk(profile(Profile), Options), normalize_profile(Profile, _),
    memberchk(sandbox(Sandbox), Options), normalize_sandbox_mode(Sandbox, _),
    configure_auth_policy(Options, _),
    configure_governance_policy(Options, _),
    configure_resource_policy(Options, _),
    configure_source_policy(Options, _),
    configure_ip_policy(Options, _),
    configure_observability(Options, _).

print_configuration(Port, Options) :-
    memberchk(node_url(URL), Options), memberchk(profile(Profile), Options),
    memberchk(sandbox(Sandbox), Options), memberchk(auth(Auth), Options),
    memberchk(max_actors(MaxActors), Options),
    memberchk(max_inflight_calls(MaxInflight), Options),
    format('Trealla Web Prolog deployment configuration:~n', []),
    format('  port: ~w~n  public_url: ~w~n', [Port, URL]),
    format('  profile: ~w~n  sandbox: ~w~n  auth: ~w~n',
           [Profile, Sandbox, Auth]),
    format('  max_actors: ~w~n  max_inflight_calls: ~w~n',
           [MaxActors, MaxInflight]),
    format('  admin token: configured (redacted)~n', []).

request_maintenance :-
    env_integer('WP_PORT', 3060, Port),
    admin_token(Token),
    format(atom(URL), 'http://127.0.0.1:~w/admin/maintenance', [Port]),
    format(atom(Authorization), 'Bearer ~w', [Token]),
    once(http_open(URL, Stream,
                   [post(string('application/json', '{"enabled":true}')),
                    request_header('Authorization'=Authorization),
                    status_code(Status),timeout(3)])),
    close(Stream),
    Status =:= 200.

admin_token(Token) :-
    env_atom('WP_ADMIN_TOKEN', '', Token),
    atom_length(Token, Length),
    ( Length >= 24 -> true
    ; throw(error(domain_error(admin_token,
                               'WP_ADMIN_TOKEN must contain at least 24 characters'),
                  deployment_start))
    ).

public_acknowledged(open) :- !,
    env_atom('WP_ACK_PUBLIC', no, Ack),
    ( Ack == yes -> true
    ; throw(error(permission_error(start, open_node, 'WP_ACK_PUBLIC=yes'),
                  deployment_start))
    ).
public_acknowledged(_).

% Match the SWI deployment's owner/1 policy: the identity asserted by the
% trusted SSO proxy receives the administrator capability (which subsumes
% execution); other authenticated identities remain unprivileged.
owner_options(private, Owner, [principal(Owner,[admin,public_read])]) :-
    Owner \== '', !.
owner_options(_, _, []).

optional_list(_, [], Options, Options) :- !.
optional_list(Name, Values, Options, [Option|Options]) :-
    Option =.. [Name,Values].

env_atom(Name, Default, Value) :-
    ( catch(getenv(Name, Found), _, fail), Found \== '' -> Value = Found
    ; Value = Default
    ).

env_integer(Name, Default, Value) :-
    env_atom(Name, '', Atom),
    ( Atom == '' -> Value = Default
    ; catch(atom_number(Atom, Number), _, fail), integer(Number)
    -> Value = Number
    ; throw(error(domain_error(integer_environment, Name=Atom),
                  deployment_start))
    ).

env_choice(Name, Choices, Default, Value) :-
    env_atom(Name, Default, Value),
    ( memberchk(Value, Choices) -> true
    ; throw(error(domain_error(Name, Value), deployment_start))
    ).

env_csv(Name, Values) :-
    env_atom(Name, '', Atom),
    ( Atom == '' -> Values = []
    ; atomic_list_concat(Values, ',', Atom),
      ( memberchk('', Values)
      -> throw(error(domain_error(csv_environment, Name=Atom), deployment_start))
      ; true )
    ).

env_csv_default(Name, Default, Values) :-
    env_csv(Name, Parsed),
    ( Parsed == [] -> Values = Default ; Values = Parsed ).

positive(_, Value) :- integer(Value), Value > 0, !.
positive(Name, Value) :-
    throw(error(domain_error(Name, Value), deployment_start)).

nonnegative(_, Value) :- integer(Value), Value >= 0, !.
nonnegative(Name, Value) :-
    throw(error(domain_error(Name, Value), deployment_start)).

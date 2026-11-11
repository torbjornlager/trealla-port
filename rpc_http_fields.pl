% HTTP option schemas and first-field precedence. No I/O or goal execution.
rpc_http_validate(request_header(Header)) :-
    rpc_http_nonvar(Header),
    (compound(Header),functor(Header,'=',2) ->
       arg(1,Header,Name),arg(2,Header,Value),
       rpc_http_name(Name),rpc_http_value(Value)
    ; rpc_http_type_error(http_request_header,Header)).
rpc_http_validate(authorization(Auth)) :-
    rpc_http_nonvar(Auth),
    (compound(Auth),functor(Auth,basic,2) ->
       arg(1,Auth,User),arg(2,Auth,Password),rpc_http_value(User),rpc_http_value(Password)
    ; compound(Auth),functor(Auth,bearer,1) -> arg(1,Auth,Token),rpc_http_value(Token)
    ; rpc_http_domain_error(http_authorization,Auth)).
rpc_http_validate(user_agent(Value)) :- rpc_http_value(Value).
rpc_http_nonvar(Value) :-
    (var(Value)->throw(error(instantiation_error,rpc_transport));true).
rpc_http_type_error(Type,Value) :- throw(error(type_error(Type,Value),rpc_transport)).
rpc_http_domain_error(Domain,Value) :- throw(error(domain_error(Domain,Value),rpc_transport)).
rpc_http_text_chars(Value,Chars) :-
    rpc_http_nonvar(Value),
    (acyclic_term(Value)->true;throw(error(representation_error(cyclic_term),rpc_transport))),
    (Value==[]->Chars=[]
    ;atom(Value)->atom_chars(Value,Chars)
    ;rpc_http_string_chars(Value,Chars)->true
    ;rpc_http_char_list(Value,Value,Chars)).
rpc_http_char_list(List,Original,Chars) :-
    rpc_http_nonvar(List),
    (List==[]->Chars=[]
    ;List=[C|Rest]->rpc_http_nonvar(C),
       (rpc_http_one_char(C,Head)->append(Head,Tail,Chars),rpc_http_char_list(Rest,Original,Tail)
       ;rpc_http_type_error(atom_or_string,Original))
    ;rpc_http_type_error(atom_or_string,Original)).
rpc_http_text_atom(Value,Atom) :- rpc_http_text_chars(Value,Chars),atom_chars(Atom,Chars).
rpc_http_value(Value) :-
    rpc_http_text_chars(Value,Chars),
    (rpc_http_field_chars(Chars)->true;rpc_http_domain_error(http_header_value,Value)).
rpc_http_field_chars([]).
rpc_http_field_chars([C|Cs]) :-
    char_code(C,N),(N=:=9;N>=32,N=\=127),N=<1114111,\+ (N>=55296,N=<57343),
    rpc_http_field_chars(Cs).
rpc_http_name(Name) :-
    rpc_http_nonvar(Name),
    (atom(Name),Name\==[]->true;rpc_http_type_error(atom,Name)),atom_codes(Name,Codes),
    (Codes\==[],rpc_http_name_codes(Codes)->true;rpc_http_domain_error(http_header_name,Name)),
    rpc_http_lower(Name,Key),rpc_http_proxy_key(Key,Canonical),
    (member(Canonical,['x-forwarded-for','x-real-ip','x-web-prolog-user',
      'x-web-prolog-principal','x-authenticated-user','x-web-prolog-capabilities',
      'x-web-prolog-caps','x-web-prolog-internal-proxy','x-web-prolog-query-budget'])
    ->throw(error(permission_error(set,proxy_header,Name),rpc_transport));true).
rpc_http_name_codes([]).
rpc_http_name_codes([C|Cs]) :-
    (C>=65,C=<90;C>=97,C=<122;C>=48,C=<57;member(C,[33,35,36,37,38,39,42,43,45,46,94,95,96,124,126])),
    rpc_http_name_codes(Cs).
rpc_http_lower(Name,Lower) :- atom_codes(Name,Codes),rpc_http_lower_codes(Codes,Out),atom_codes(Lower,Out).
rpc_http_lower_codes([],[]).
rpc_http_lower_codes([C|Cs],[L|Ls]) :- (C>=65,C=<90->L is C+32;L=C),rpc_http_lower_codes(Cs,Ls).
rpc_http_proxy_key(Key,Canonical) :- atom_codes(Key,Cs),rpc_http_proxy_codes(Cs,Out),atom_codes(Canonical,Out).
rpc_http_proxy_codes([],[]).
rpc_http_proxy_codes([C|Cs],[D|Ds]) :- (C=:=95->D=45;D=C),rpc_http_proxy_codes(Cs,Ds).
rpc_http_fields(Options,Fields) :- rpc_http_fields_(Options,[],Fields).
rpc_http_fields_([],_,[]).
rpc_http_fields_([Option|Options],Seen,Fields) :-
    (rpc_http_field(Option,Key,Value)->
      (member(Key,Seen)->rpc_http_fields_(Options,Seen,Fields)
      ;Fields=[header(Key,Value)|Rest],rpc_http_fields_(Options,[Key|Seen],Rest))
    ;rpc_http_fields_(Options,Seen,Fields)).
rpc_http_field(request_header(Name=Value0),Key,Value) :-
    rpc_http_lower(Name,Key),rpc_http_text_atom(Value0,Value).
rpc_http_field(user_agent(Value0),'user-agent',Value) :- rpc_http_text_atom(Value0,Value).
rpc_http_field(authorization(bearer(Token)),authorization,Value) :-
    rpc_http_text_atom(Token,Text),atom_concat('Bearer ',Text,Value).
rpc_http_field(authorization(basic(User,Password)),authorization,Value) :-
    rpc_http_text_chars(User,Us),rpc_http_text_chars(Password,Ps),append(Us,[':'|Ps],Chars),
    rpc_http_host_utf8(Chars,Bytes),rpc_http_base64(Bytes,Codes),atom_codes(Encoded,Codes),
    atom_concat('Basic ',Encoded,Value).
rpc_http_native_options([],[]).
rpc_http_native_options([header('user-agent',Value)|Fields],[user_agent(Wire)|Rest]) :- !,
    rpc_http_native_value(Value,Wire),rpc_http_native_options(Fields,Rest).
rpc_http_native_options([header(Name,Value)|Fields],[request_header(Name=Wire)|Rest]) :-
    rpc_http_native_value(Value,Wire),rpc_http_native_options(Fields,Rest).
rpc_http_utf8([],[]).
rpc_http_utf8([C|Cs],Bytes) :-
    char_code(C,N),
    (N<128->Bytes=[N|Rest]
    ;N<2048->A is 192+N//64,B is 128+N mod 64,Bytes=[A,B|Rest]
    ;N<65536->A is 224+N//4096,B is 128+(N//64) mod 64,D is 128+N mod 64,Bytes=[A,B,D|Rest]
    ;A is 240+N//262144,B is 128+(N//4096) mod 64,D is 128+(N//64) mod 64,E is 128+N mod 64,Bytes=[A,B,D,E|Rest]),
    rpc_http_utf8(Cs,Rest).
rpc_http_base64([],[]).
rpc_http_base64([A],[X,Y,61,61]) :- !,I is A//4,J is (A mod 4)*16,rpc_http_b64(I,X),rpc_http_b64(J,Y).
rpc_http_base64([A,B],[X,Y,Z,61]) :- !,
    I is A//4,J is (A mod 4)*16+B//16,K is (B mod 16)*4,
    rpc_http_b64(I,X),rpc_http_b64(J,Y),rpc_http_b64(K,Z).
rpc_http_base64([A,B,C|Bytes],[X,Y,Z,W|Rest]) :-
    I is A//4,J is (A mod 4)*16+B//16,K is (B mod 16)*4+C//64,L is C mod 64,
    rpc_http_b64(I,X),rpc_http_b64(J,Y),rpc_http_b64(K,Z),rpc_http_b64(L,W),rpc_http_base64(Bytes,Rest).
rpc_http_b64(N,C) :-
    (N<26->C is 65+N;N<52->C is 97+N-26;N<62->C is 48+N-52;N=:=62->C=43;C=47).

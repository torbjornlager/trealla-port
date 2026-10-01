% SPDX-License-Identifier: MIT

:- module(crypto_portable,
    [ secure_random_bytes/2,
      bytes_hex/2,
      sha256_hex/2,
      secure_equal/2
    ]).

/** <module> Small cryptographic compatibility layer

Trealla only exposes `crypto_data_hash/3` when built with OpenSSL, while its
current `crypto_n_random_bytes/2` fallback uses C `rand()` and is unsuitable
for credentials.  Token issuance therefore reads the operating system CSPRNG
and uses a portable SHA-256 implementation when the OpenSSL predicate is not
present.  `/dev/urandom` is available on the macOS and Linux deployment
targets; issuance fails closed on a platform without it.
*/

secure_random_bytes(Count, Bytes) :-
    integer(Count), Count > 0,
    catch(setup_call_cleanup(
              open('/dev/urandom', read, Stream, [type(binary)]),
              read_random_bytes(Stream, Count, Bytes),
              close(Stream)),
          _,
          throw(error(resource_error(secure_random_source),
                      context(crypto_portable:secure_random_bytes/2,
                              'OS cryptographic random source unavailable')))).

read_random_bytes(_, 0, []) :- !.
read_random_bytes(Stream, Count, [Byte|Bytes]) :-
    get_byte(Stream, Byte),
    ( Byte >= 0 -> true
    ; throw(error(resource_error(secure_random_source), crypto_portable))
    ),
    Next is Count-1,
    read_random_bytes(Stream, Next, Bytes).

bytes_hex(Bytes, Hex) :-
    bytes_hex_chars(Bytes, Chars), atom_chars(Hex, Chars).

bytes_hex_chars([], []).
bytes_hex_chars([Byte|Bytes], [High,Low|Chars]) :-
    H is (Byte >> 4) /\ 15, L is Byte /\ 15,
    hex_digit(H, High), hex_digit(L, Low),
    bytes_hex_chars(Bytes, Chars).

hex_digit(N, C) :- N < 10, !, Code is 0'0+N, char_code(C, Code).
hex_digit(N, C) :- Code is 0'a+N-10, char_code(C, Code).

%! sha256_hex(+Text, -Hex) is det.

sha256_hex(Text, Hex) :-
    text_bytes(Text, Bytes),
    ( catch(crypto_data_hash(Text, Native, [algorithm(sha256)]), _, fail)
    -> text_atom(Native, Hex)
    ; sha256_bytes(Bytes, Digest), bytes_hex(Digest, Hex)
    ).

text_bytes(Text, Bytes) :- atom(Text), !, atom_codes(Text, Bytes).
text_bytes(Text, Bytes) :- string(Text), !, string_codes(Text, Bytes).
text_bytes(Text, Text) :- is_list(Text), !.
text_bytes(Text, _) :- throw(error(type_error(text, Text), crypto_portable)).

text_atom(Text, Text) :- atom(Text), !.
text_atom(Text, Atom) :- atom_chars(Atom, Text).

sha256_bytes(Bytes, Digest) :-
    sha256_pad(Bytes, Padded),
    sha256_initial(State0),
    sha256_chunks(Padded, State0, State),
    state_bytes(State, Digest).

sha256_pad(Bytes, Padded) :-
    length(Bytes, Length), BitLength is Length*8,
    Remainder is (Length+1) mod 64,
    ZeroCount is (56-Remainder+64) mod 64,
    zeros(ZeroCount, Zeros),
    uint64_bytes(BitLength, LengthBytes),
    append(Bytes, [128|Zeros], Prefix),
    append(Prefix, LengthBytes, Padded).

zeros(0, []) :- !.
zeros(N, [0|Zeros]) :- N1 is N-1, zeros(N1, Zeros).

uint64_bytes(Value, Bytes) :- integer_bytes(Value, 8, Bytes).

integer_bytes(_, 0, []) :- !.
integer_bytes(Value, Count, [Byte|Bytes]) :-
    Shift is (Count-1)*8, Byte is (Value >> Shift) /\ 255,
    Next is Count-1, integer_bytes(Value, Next, Bytes).

sha256_initial([0x6a09e667,0xbb67ae85,0x3c6ef372,0xa54ff53a,
                0x510e527f,0x9b05688c,0x1f83d9ab,0x5be0cd19]).

sha256_chunks([], State, State).
sha256_chunks(Bytes, State0, State) :-
    take_bytes(64, Bytes, Chunk, Rest),
    chunk_words(Chunk, Words16), extend_words(Words16, Words),
    State0 = [A0,B0,C0,D0,E0,F0,G0,H0],
    sha256_constants(Constants),
    sha256_rounds(Words, Constants, A0,B0,C0,D0,E0,F0,G0,H0,
                  A,B,C,D,E,F,G,H),
    add32(A0,A,NA), add32(B0,B,NB), add32(C0,C,NC), add32(D0,D,ND),
    add32(E0,E,NE), add32(F0,F,NF), add32(G0,G,NG), add32(H0,H,NH),
    sha256_chunks(Rest, [NA,NB,NC,ND,NE,NF,NG,NH], State).

take_bytes(0, Rest, [], Rest) :- !.
take_bytes(N, [B|Bytes], [B|Chunk], Rest) :-
    N1 is N-1, take_bytes(N1, Bytes, Chunk, Rest).

chunk_words([], []).
chunk_words([A,B,C,D|Bytes], [Word|Words]) :-
    Word is ((A<<24) \/ (B<<16) \/ (C<<8) \/ D) /\ 0xffffffff,
    chunk_words(Bytes, Words).

extend_words(Words16, Words) :- extend_words(16, Words16, Words).
extend_words(64, Words, Words) :- !.
extend_words(Index, Words0, Words) :-
    I2 is Index-2, I7 is Index-7, I15 is Index-15, I16 is Index-16,
    nth0(I2, Words0, W2), nth0(I7, Words0, W7),
    nth0(I15, Words0, W15), nth0(I16, Words0, W16),
    small_sigma1(W2, S1), small_sigma0(W15, S0),
    Word is (W16+S0+W7+S1) /\ 0xffffffff,
    append(Words0, [Word], Words1), Next is Index+1,
    extend_words(Next, Words1, Words).

small_sigma0(X, S) :-
    ror32(X,7,A), ror32(X,18,B), C is X>>3, S is xor(A,xor(B,C)).
small_sigma1(X, S) :-
    ror32(X,17,A), ror32(X,19,B), C is X>>10, S is xor(A,xor(B,C)).
big_sigma0(X, S) :-
    ror32(X,2,A), ror32(X,13,B), ror32(X,22,C), S is xor(A,xor(B,C)).
big_sigma1(X, S) :-
    ror32(X,6,A), ror32(X,11,B), ror32(X,25,C), S is xor(A,xor(B,C)).

ror32(X, N, R) :-
    R is ((X>>N) \/ ((X /\ 0xffffffff)<<(32-N))) /\ 0xffffffff.

add32(A, B, Sum) :- Sum is (A+B) /\ 0xffffffff.

sha256_rounds([], [], A,B,C,D,E,F,G,H, A,B,C,D,E,F,G,H).
sha256_rounds([W|Words], [K|Constants], A,B,C,D,E,F,G,H,
              OA,OB,OC,OD,OE,OF,OG,OH) :-
    big_sigma1(E, S1),
    NotE is xor(E,0xffffffff),
    Ch is xor(E /\ F, NotE /\ G),
    T1 is (H+S1+Ch+K+W) /\ 0xffffffff,
    big_sigma0(A, S0),
    Maj is xor(A /\ B, xor(A /\ C, B /\ C)),
    T2 is (S0+Maj) /\ 0xffffffff,
    NA is (T1+T2) /\ 0xffffffff,
    NE is (D+T1) /\ 0xffffffff,
    sha256_rounds(Words, Constants, NA,A,B,C,NE,E,F,G,
                  OA,OB,OC,OD,OE,OF,OG,OH).

sha256_constants([
  0x428a2f98,0x71374491,0xb5c0fbcf,0xe9b5dba5,0x3956c25b,0x59f111f1,0x923f82a4,0xab1c5ed5,
  0xd807aa98,0x12835b01,0x243185be,0x550c7dc3,0x72be5d74,0x80deb1fe,0x9bdc06a7,0xc19bf174,
  0xe49b69c1,0xefbe4786,0x0fc19dc6,0x240ca1cc,0x2de92c6f,0x4a7484aa,0x5cb0a9dc,0x76f988da,
  0x983e5152,0xa831c66d,0xb00327c8,0xbf597fc7,0xc6e00bf3,0xd5a79147,0x06ca6351,0x14292967,
  0x27b70a85,0x2e1b2138,0x4d2c6dfc,0x53380d13,0x650a7354,0x766a0abb,0x81c2c92e,0x92722c85,
  0xa2bfe8a1,0xa81a664b,0xc24b8b70,0xc76c51a3,0xd192e819,0xd6990624,0xf40e3585,0x106aa070,
  0x19a4c116,0x1e376c08,0x2748774c,0x34b0bcb5,0x391c0cb3,0x4ed8aa4a,0x5b9cca4f,0x682e6ff3,
  0x748f82ee,0x78a5636f,0x84c87814,0x8cc70208,0x90befffa,0xa4506ceb,0xbef9a3f7,0xc67178f2]).

state_bytes([], []).
state_bytes([Word|Words], Bytes) :-
    integer_bytes(Word, 4, Head), state_bytes(Words, Tail), append(Head,Tail,Bytes).

secure_equal(A, B) :-
    text_bytes(A, ACodes), text_bytes(B, BCodes),
    length(ACodes, Length), length(BCodes, Length),
    secure_equal_codes(ACodes, BCodes, 0, Difference),
    Difference =:= 0.

secure_equal_codes([], [], Difference, Difference).
secure_equal_codes([A|As], [B|Bs], Difference0, Difference) :-
    Difference1 is Difference0 \/ xor(A,B),
    secure_equal_codes(As, Bs, Difference1, Difference).

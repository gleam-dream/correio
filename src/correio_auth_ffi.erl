-module(correio_auth_ffi).
-export([random_token/0, random_code/1, keyed_verifier/2, constant_equal/2, valid_id/1]).

random_token() -> base64:encode(crypto:strong_rand_bytes(32), #{mode => urlsafe, padding => false}).
random_code(Digits) -> list_to_binary([digit() || _ <- lists:seq(1, Digits)]).
digit() ->
    <<N>> = crypto:strong_rand_bytes(1),
    case N < 250 of true -> $0 + N rem 10; false -> digit() end.
keyed_verifier(Key, Fields) ->
    Data = [<<(byte_size(Field)):32/unsigned-big, Field/binary>> || Field <- Fields],
    binary:encode_hex(crypto:mac(hmac, sha256, Key, Data)).
constant_equal(A, B) when byte_size(A) =:= byte_size(B) -> crypto:hash_equals(A, B);
constant_equal(_, _) -> false.
valid_id(Value) ->
    byte_size(Value) =:= 43 andalso
      lists:all(fun(C) -> (C >= $A andalso C =< $Z) orelse
                         (C >= $a andalso C =< $z) orelse
                         (C >= $0 andalso C =< $9) orelse C =:= $- orelse C =:= $_ end,
                binary_to_list(Value)).

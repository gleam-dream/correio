-module(correio_postgres_ffi).
-export([protect/1]).
%% Driver exceptions and crashes must never expose foreign messages or imply that
%% an external mutation rolled back. Normal typed errors pass through unchanged.
protect(Function) ->
  try Function() catch _:_ -> {error, unknown} end.

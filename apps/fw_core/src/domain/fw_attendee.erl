-module(fw_attendee).
-moduledoc """
A participant: an unguessable id and a chosen alias.

No name, no email, no account, no location, not even a timezone, and nowhere to
put one. The alias is a label others pick out of a list — "Blue Falcon" — and
the id is a capability: whoever holds it may set that attendee's availability,
so it carries the same entropy as a room hash.
""".

-export([new/2, id/1, alias/1, availability/1, has_availability/1, with_availability/2]).
-export_type([t/0, id/0, alias/0, error/0]).

-type id() :: binary().
-type alias() :: binary().
-type error() :: bad_id | bad_alias.

-opaque t() :: #{
    id := id(),
    alias := alias(),
    availability := fw_availability:t() | undefined
}.

-define(MAX_ALIAS, 32).

-spec new(term(), term()) -> {ok, t()} | {error, error()}.
new(Id, Alias) when is_binary(Id), byte_size(Id) > 0 ->
    case is_alias(Alias) of
        true -> {ok, #{id => Id, alias => Alias, availability => undefined}};
        false -> {error, bad_alias}
    end;
new(_Id, _Alias) ->
    {error, bad_id}.

-spec id(t()) -> id().
id(#{id := Id}) -> Id.

-spec alias(t()) -> alias().
alias(#{alias := Alias}) -> Alias.

-doc "`undefined` until this attendee has said when they are free.".
-spec availability(t()) -> fw_availability:t() | undefined.
availability(#{availability := Availability}) -> Availability.

-doc """
Whether they have answered at all.

Distinct from being free all week, which is an answer. An attendee who has said
nothing must not be counted as available, or one silent invitee would make
every slot look possible.
""".
-spec has_availability(t()) -> boolean().
has_availability(#{availability := undefined}) -> false;
has_availability(#{availability := _Availability}) -> true.

-spec with_availability(fw_availability:t(), t()) -> t().
with_availability(Availability, Attendee) -> Attendee#{availability := Availability}.

%%% ---- internal ----

%% Aliases are shown to every other participant, so control characters and
%% invalid UTF-8 are refused here rather than escaped at each place they render.
is_alias(Alias) when is_binary(Alias) ->
    case unicode:characters_to_list(Alias) of
        Characters when is_list(Characters) -> is_label(Characters);
        _Invalid -> false
    end;
is_alias(_NotBinary) ->
    false.

is_label(Characters) ->
    Length = length(Characters),
    Length >= 1 andalso Length =< ?MAX_ALIAS andalso lists:all(fun is_printable/1, Characters).

is_printable(Character) -> Character >= 32 andalso Character =/= 127.

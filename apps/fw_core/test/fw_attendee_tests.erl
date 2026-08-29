-module(fw_attendee_tests).

-include_lib("eunit/include/eunit.hrl").

attendee() ->
    {ok, Attendee} = fw_attendee:new(<<"id-1">>, <<"Blue Falcon">>),
    Attendee.

free(Slots) ->
    {ok, Grid} = fw_grid:new(0, 15, 4),
    {ok, Availability} = fw_availability:from_slots(Slots, Grid),
    Availability.

an_attendee_reports_what_they_joined_with_test() ->
    ?assertEqual(<<"id-1">>, fw_attendee:id(attendee())),
    ?assertEqual(<<"Blue Falcon">>, fw_attendee:alias(attendee())).

a_new_attendee_has_not_answered_test() ->
    ?assertEqual(undefined, fw_attendee:availability(attendee())),
    ?assertNot(fw_attendee:has_availability(attendee())).

answering_records_the_availability_test() ->
    Answered = fw_attendee:with_availability(free([2]), attendee()),
    ?assert(fw_attendee:has_availability(Answered)),
    ?assertEqual([2], fw_availability:free_slots(fw_attendee:availability(Answered))).

%% Free nowhere is an answer — "none of this week works for me". Saying nothing
%% is not, and the two must not look the same.
answering_that_nothing_works_still_counts_as_answering_test() ->
    Answered = fw_attendee:with_availability(fw_availability:none(), attendee()),
    ?assert(fw_attendee:has_availability(Answered)),
    ?assertEqual([], fw_availability:free_slots(fw_attendee:availability(Answered))).

answering_again_replaces_the_previous_answer_test() ->
    Once = fw_attendee:with_availability(free([0]), attendee()),
    Twice = fw_attendee:with_availability(free([3]), Once),
    ?assertEqual([3], fw_availability:free_slots(fw_attendee:availability(Twice))).

%%% ---- aliases are shown to strangers, so they are validated here ----

an_empty_alias_is_rejected_test() ->
    ?assertEqual({error, bad_alias}, fw_attendee:new(<<"id">>, <<>>)).

an_alias_of_thirty_two_characters_is_accepted_test() ->
    ?assertMatch({ok, _}, fw_attendee:new(<<"id">>, binary:copy(<<"a">>, 32))).

an_alias_of_thirty_three_characters_is_rejected_test() ->
    ?assertEqual({error, bad_alias}, fw_attendee:new(<<"id">>, binary:copy(<<"a">>, 33))).

%% Length is counted in characters, not bytes: an emoji alias is not four times
%% shorter than a latin one.
an_alias_is_measured_in_characters_not_bytes_test() ->
    Emoji = binary:copy(<<"🦅"/utf8>>, 32),
    ?assert(byte_size(Emoji) > 32),
    ?assertMatch({ok, _}, fw_attendee:new(<<"id">>, Emoji)).

a_control_character_in_an_alias_is_rejected_test() ->
    ?assertEqual({error, bad_alias}, fw_attendee:new(<<"id">>, <<"Blue\nFalcon">>)),
    ?assertEqual({error, bad_alias}, fw_attendee:new(<<"id">>, <<"Blue", 0, "Falcon">>)).

invalid_utf8_in_an_alias_is_rejected_test() ->
    ?assertEqual({error, bad_alias}, fw_attendee:new(<<"id">>, <<255, 255>>)).

an_alias_that_is_not_a_binary_is_rejected_test() ->
    ?assertEqual({error, bad_alias}, fw_attendee:new(<<"id">>, "Blue Falcon")).

%%% ---- ids ----

an_empty_id_is_rejected_test() ->
    ?assertEqual({error, bad_id}, fw_attendee:new(<<>>, <<"Blue Falcon">>)).

an_id_that_is_not_a_binary_is_rejected_test() ->
    ?assertEqual({error, bad_id}, fw_attendee:new(nobody, <<"Blue Falcon">>)).

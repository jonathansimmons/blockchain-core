%%%-----------------------------------------------------------------------------
%%% @doc blockchain_poc_target_v3 implementation.
%%%
%%% The targeting mechanism is based on the following conditions:
%%% - Filter hotspots which haven't done a poc request for a long time
%%% - Given a map of gateway_scores, we must ALWAYS find a target
%%% - Target selection is entirely random
%%%
%%%-----------------------------------------------------------------------------
-module(blockchain_poc_target_v3).

-include("blockchain_utils.hrl").
-include("blockchain_vars.hrl").

-export([
         target/3,
         filter/5
        ]).

-type prob_map() :: #{libp2p_crypto:pubkey_bin() => float()}.

%% @doc Finds a potential target to start the path from.
%% This must always return a target.
%% Favors high scoring gateways, dependent on score^poc_v4_target_score_curve curve.
-spec target(Hash :: binary(),
             Ledger :: blockchain:ledger(),
             Vars :: map()) -> {ok, {libp2p_crypto:pubkey_bin(), rand:state()}} | {error, no_target}.
target(Hash, Ledger, Vars) ->
    %% Grab the list of parent hexes
    {ok, Hexes} = blockchain_ledger_v1:get_hexes(Ledger),
    HexList = lists:keysort(1, maps:to_list(Hexes)),

    %% choose hex via CDF
    InitRandState = blockchain_utils:rand_state(Hash),
    {HexVal, HexRandState} = rand:uniform_s(InitRandState),
    {ok, Hex} = blockchain_utils:icdf_select(HexList, HexVal),

    %% fetch from the disk the list of gateways, then the actual
    %% gateways on that list, then score them, if the weight is not 0.
    {ok, AddrList} = blockchain_ledger_v1:get_hex(Hex, Ledger),
    {ok, Height} = blockchain_ledger_v1:current_height(Ledger),
    GatewayMap =
        lists:foldl(
          fun(Addr, Acc) ->
                  {ok, Gw} = blockchain_ledger_v1:find_gateway_info(Addr, Ledger),
                  Score =
                      case prob_score_wt(Vars) of
                          0.0 ->
                              1.0;
                          _ ->
                              {_, _, Scr} = blockchain_ledger_gateway_v2:score(Addr, Gw, Height, Ledger),
                              Scr
                      end,
                  Acc#{Addr => {Gw, Score}}
          end,
          #{},
          AddrList),

    %% generate scores weights for the final CDF that does the actual selection
    ProbScores = score_prob(GatewayMap, Vars),
    ProbEdges = edge_prob(GatewayMap, Vars),
    ProbTargetMap = target_prob(ProbScores, ProbEdges, Vars),
    %% Sort the scaled probabilities in default order by gateway pubkey_bin
    %% make sure that we carry the rand_state through for determinism
    {RandVal, NewRandState} = rand:uniform_s(HexRandState),
    io:format("randval: ~p, select_target~n", [RandVal]),
    {ok, TargetPubkeybin} = blockchain_utils:icdf_select(lists:keysort(1, maps:to_list(ProbTargetMap)), RandVal),
    {ok, {TargetPubkeybin, NewRandState}}.

%% @doc Filter gateways based on these conditions:
%% - Inactive gateways (those which haven't challenged in a long time).
%% - Dont target the challenger gateway itself.
%% - Ensure that potential target is far from the challenger to avoid collusion.
-spec filter(GatewayScoreMap :: blockchain_utils:gateway_score_map(),
             ChallengerAddr :: libp2p_crypto:pubkey_bin(),
             ChallengerLoc :: h3:index(),
             Height :: pos_integer(),
             Vars :: map()) -> blockchain_utils:gateway_score_map().
filter(GatewayScoreMap, ChallengerAddr, ChallengerLoc, Height, Vars) ->
    maps:filter(fun(_Addr, {Gateway, _Score}) ->
                        valid(Gateway, ChallengerLoc, Height, Vars)
                end,
                maps:without([ChallengerAddr], GatewayScoreMap)).

-spec valid(Gateway :: blockchain_ledger_gateway_v2:gateway(),
            ChallengerLoc :: h3:h3_index(),
            Height :: pos_integer(),
            Vars :: map()) -> boolean().
valid(Gateway, ChallengerLoc, Height, Vars) ->
    case blockchain_ledger_gateway_v2:last_poc_challenge(Gateway) of
        undefined ->
            %% No POC challenge, don't include
            false;
        C ->
            %% Check challenge age is recent depending on the set chain var
            (Height - C) < challenge_age(Vars) andalso
            %% Check that the potential target is far enough from the challenger
            %% NOTE: If we have a defined poc_challenge the gateway location cannot be undefined
            %% so this should be safe.
                case application:get_env(blockchain, disable_poc_v4_target_challenge_age, false) of
                    false ->
                        check_challenger_distance(ChallengerLoc, blockchain_ledger_gateway_v2:location(Gateway), Vars);
                    true ->
                        true
                end
    end.

%%%-------------------------------------------------------------------
%% Helpers
%%%-------------------------------------------------------------------
-spec score_prob(GatewayScoreMap :: blockchain_utils:gateway_score_map(), Vars :: map()) -> prob_map().
score_prob(GatewayScoreMap, Vars) ->
    %% Assign probability to each gateway
    ProbScores = maps:map(fun(_Addr, {_G, Score}) ->
                                  score_curve(Score, Vars)
                          end,
                          GatewayScoreMap),
    %% Calculate sum of all probs
    SumScores = lists:sum([S || {_A, S} <- maps:to_list(ProbScores)]),
    %% Scale probabilities so they add up to 1.0
    maps:map(fun(_, S) ->
                     ?normalize_float((S / SumScores), Vars)
             end,
             ProbScores).

-spec edge_prob(GatewayScoreMap :: blockchain_utils:gateway_score_map(), Vars :: map()) -> prob_map().
edge_prob(GatewayScoreMap, Vars) ->
    %% Get all locations
    Sz = maps:size(GatewayScoreMap),
    case prob_edge_wt(Vars) of
        %% if we're just going to throw this away, no reason to do
        %% this work at all.
        0.0 ->
            maps:map(fun(_, _) ->
                             0.0
                     end,
                     GatewayScoreMap);
        _ when Sz == 1 ->
            maps:map(fun(_, _) ->
                             1.0
                     end,
                     GatewayScoreMap);
        _ ->
            Locations = locations(GatewayScoreMap, Vars),
            %% Assign probability to each gateway
            %% TODO: this is basically n^2
            LocSz = maps:size(Locations),
            ParentRes = parent_res(Vars),
            ProbEdges =
                maps:map(
                  fun(_Addr, {Gateway, _Score}) ->
                          Loc = blockchain_ledger_gateway_v2:location(Gateway),
                          GatewayParent = h3:parent(Loc, ParentRes),
                          PopCt = maps:get(GatewayParent, Locations),
                          ?normalize_float((1 - ?normalize_float(PopCt/LocSz, Vars)), Vars)
                  end,
                  GatewayScoreMap),
            %% Calculate sum of all probs
            SumEdgeProbs = lists:sum([S || {_A, S} <- maps:to_list(ProbEdges)]),
            %% Scale probabilities so they add up to 1.0
            maps:map(fun(_, E) ->
                             ?normalize_float((E / SumEdgeProbs), Vars)
                     end,
                     ProbEdges)
    end.

-spec target_prob(ProbScores :: prob_map(),
                  ProbEdges :: prob_map(),
                  Vars :: map()) -> prob_map().
target_prob(ProbScores, ProbEdges, Vars) ->
    case maps:get(poc_version, Vars) of
        V when is_integer(V), V > 4 ->
            %% P(Target) = ScoreWeight*P(Score) + EdgeWeight*P(Edge) + RandomnessWeight*1.0
            maps:map(fun(Addr, PScore) ->
                             ?normalize_float((prob_score_wt(Vars) * PScore), Vars) +
                             ?normalize_float((prob_edge_wt(Vars) * maps:get(Addr, ProbEdges)), Vars) +
                             %% Similar to the poc path randomness
                             %% This would determine how much randomness we want in the target selection
                             %% The weights still must add to 1.0 however.
                             %% Prior to poc_version 5, this is defaulted to 0.0, therefore has no effect
                             ?normalize_float((prob_randomness_wt(Vars) * 1.0), Vars)
                     end,
                     ProbScores);
        _ ->
            %% P(Target) = ScoreWeight*P(Score) + EdgeWeight*P(Edge)
            maps:map(fun(Addr, PScore) ->
                             ?normalize_float((prob_score_wt(Vars) * PScore), Vars) +
                             ?normalize_float((prob_edge_wt(Vars) * maps:get(Addr, ProbEdges)), Vars)
                     end,
                     ProbScores)
    end.

-spec locations(GatewayScoreMap :: blockchain_utils:gateway_score_map(),
                Vars :: #{}) -> #{h3:index() => integer()}.
locations(GatewayScoreMap, Vars) ->
    %% Get all locations from score map
    Res = parent_res(Vars),
    AllRes = [h3:parent(blockchain_ledger_gateway_v2:location(G), Res) || {G, _S} <- maps:values(GatewayScoreMap)],
    lists:foldl(fun(R, M) ->
                        maps:update_with(R, fun(V) -> V + 1 end, 1, M)
                end,
                #{},
                AllRes).

-spec challenge_age(Vars :: map()) -> pos_integer().
challenge_age(Vars) ->
    maps:get(poc_v4_target_challenge_age, Vars).

-spec prob_score_wt(Vars :: map()) -> float().
prob_score_wt(Vars) ->
    maps:get(poc_v4_target_prob_score_wt, Vars).

-spec prob_edge_wt(Vars :: map()) -> float().
prob_edge_wt(Vars) ->
    maps:get(poc_v4_target_prob_edge_wt, Vars).

-spec prob_randomness_wt(Vars :: map()) -> float().
prob_randomness_wt(Vars) ->
    maps:get(poc_v5_target_prob_randomness_wt, Vars).

-spec score_curve(Score :: float(), Vars :: map()) -> float().
score_curve(Score, Vars) ->
    Exp = maps:get(poc_v4_target_score_curve, Vars),
    %% XXX: This will blow up if poc_v4_target_score_curve is undefined
    math:pow(Score, Exp).

-spec parent_res(Vars :: map()) -> pos_integer().
parent_res(Vars) ->
    maps:get(poc_v4_parent_res, Vars).

-spec target_exclusion_cells(Vars :: map()) -> pos_integer().
target_exclusion_cells(Vars) ->
    maps:get(poc_v4_target_exclusion_cells, Vars).

-spec check_challenger_distance(ChallengerLoc :: h3:index(),
                                GatewayLoc :: h3:index(),
                                Vars :: map()) -> boolean().
check_challenger_distance(ChallengerLoc, GatewayLoc, Vars) ->
    %% Number of grid cells to exclude when considering the gateway_loc as a potential target
    ExclusionCells = target_exclusion_cells(Vars),
    %% Normalizing resolution
    ParentRes = parent_res(Vars),
    %% Parent h3 index of the challenger
    ChallengerParent = h3:parent(ChallengerLoc, ParentRes),
    %% Parent h3 index of the gateway being considered
    GatewayParent = h3:parent(GatewayLoc, ParentRes),
    %% Check that they are far
    try h3:grid_distance(ChallengerParent, GatewayParent) > ExclusionCells of
        Res -> Res
    catch
        %% Grid distance may badarg because of pentagonal distortion or
        %% non matching resolutions or just being too far.
        %% In either of those cases, we assume that the gateway
        %% is potentially legitimate to be a target.
        _:_ -> true
    end.

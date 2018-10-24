-module(test_utils).

-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").

-export([
    init/1, init_chain/2
    ,generate_keys/1
    ,wait_until/1, wait_until/3
    ,compare_chains/2
    ,create_block/2
]).

init(BaseDir) ->
    {PrivKey, PubKey} = libp2p_crypto:generate_keys(),
    SigFun = libp2p_crypto:mk_sig_fun(PrivKey),
    Opts = [
        {key, {PubKey, SigFun}}
        ,{seed_nodes, []}
        ,{port, 0}
        ,{num_consensus_members, 7}
        ,{base_dir, BaseDir}
    ],
    {ok, Sup} = blockchain_sup:start_link(Opts),
    ?assert(erlang:is_pid(blockchain_swarm:swarm())),
    {ok, Sup, {PrivKey, PubKey}, Opts}.

init_chain(Balance, {PrivKey, PubKey}) ->
    % Generate fake blockchains (just the keys)
    RandomKeys = test_utils:generate_keys(10),
    Address = blockchain_swarm:address(),
    ConsensusMembers = [
        {Address, {PubKey, PrivKey, libp2p_crypto:mk_sig_fun(PrivKey)}}
    ] ++ RandomKeys,

    % Create genesis block
    GenPaymentTxs = [blockchain_txn_coinbase:new(Addr, Balance)
                     || {Addr, _} <- ConsensusMembers],
    GenConsensusGroupTx = blockchain_txn_gen_consensus_group:new([Addr || {Addr, _} <- ConsensusMembers]),
    Txs = GenPaymentTxs ++ [GenConsensusGroupTx],
    GenesisBlock = blockchain_block:new_genesis_block(Txs),
    ok = blockchain_worker:integrate_genesis_block(GenesisBlock),

    ?assertEqual(blockchain_block:hash_block(GenesisBlock), blockchain_worker:head_hash()),
    ?assertEqual(GenesisBlock, blockchain_worker:head_block()),
    ?assertEqual(blockchain_block:hash_block(GenesisBlock), blockchain_worker:genesis_hash()),
    ?assertEqual(GenesisBlock, blockchain_worker:genesis_block()),
    ?assertEqual(1, blockchain_worker:height()),
    {ok, ConsensusMembers}.

generate_keys(N) ->
    lists:foldl(
        fun(_, Acc) ->
            {PrivKey, PubKey} = libp2p_crypto:generate_keys(),
            SigFun = libp2p_crypto:mk_sig_fun(PrivKey),
            [{libp2p_crypto:pubkey_to_address(PubKey), {PubKey, PrivKey, SigFun}}|Acc]
        end
        ,[]
        ,lists:seq(1, N)
    ).

wait_until(Fun) ->
    wait_until(Fun, 40, 100).

wait_until(Fun, Retry, Delay) when Retry > 0 ->
    Res = Fun(),
    case Res of
        true ->
            ok;
        _ when Retry == 1 ->
            {fail, Res};
        _ ->
            timer:sleep(Delay),
            wait_until(Fun, Retry-1, Delay)
    end.

compare_chains(Expected, Got) ->
    ?assertEqual(blockchain:dir(Expected), blockchain:dir(Got)),
    ?assertEqual(blockchain:head_hash(Expected), blockchain:head_hash(Got)),
    ?assertEqual(blockchain:head_block(Expected), blockchain:head_block(Got)),
    ?assertEqual(blockchain:genesis_hash(Expected), blockchain:genesis_hash(Got)),
    ?assertEqual(blockchain:genesis_block(Expected), blockchain:genesis_block(Got)),
    ?assertEqual(blockchain:ledger(Expected), blockchain:ledger(Got)),
    ok.

create_block(ConsensusMembers, Txs) ->
    PrevHash = blockchain_worker:head_hash(),
    Height = blockchain_worker:height() + 1,
    Block0 = blockchain_block:new(PrevHash, Height, Txs, <<>>, #{}),
    BinBlock = erlang:term_to_binary(blockchain_block:remove_signature(Block0)),
    Signatures = signatures(ConsensusMembers, BinBlock),
    Block1 = blockchain_block:sign_block(erlang:term_to_binary(Signatures), Block0),
    Block1.

signatures(ConsensusMembers, BinBlock) ->
    lists:foldl(
        fun({A, {_, _, F}}, Acc) ->
            Sig = F(BinBlock),
            [{A, Sig}|Acc]
        end
        ,[]
        ,ConsensusMembers
    ).
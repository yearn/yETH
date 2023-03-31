from ape.utils import to_int
import pytest

PRECISION = 1_000_000_000_000_000_000
MAX = 2**256 - 1
W_PROD_SLOT = 206
VB_PROD_SLOT = W_PROD_SLOT + 1
VB_SUM_SLOT = VB_PROD_SLOT + 1

@pytest.fixture
def deployer(accounts):
    return accounts[0]

@pytest.fixture
def alice(accounts):
    return accounts[1]

@pytest.fixture
def bob(accounts):
    return accounts[2]

@pytest.fixture
def token(project, deployer):
    return project.Token.deploy(sender=deployer)

def deploy_assets(project, deployer, n):
    assets = []
    provider = project.MockRateProvider.deploy(sender=deployer)
    for _ in range(n):
        asset = project.MockToken.deploy(sender=deployer)
        provider.set_rate(asset, PRECISION, sender=deployer)
        assets.append(asset)
    return assets, provider

def test_withdraw(project, deployer, alice, bob, token):
    amplification = 10 * PRECISION
    n = 4
    assets, provider = deploy_assets(project, deployer, n)
    pool = project.Pool.deploy(token, amplification, assets, [provider for _ in range(n)], [PRECISION//n for _ in range(n)], sender=deployer)
    token.set_minter(pool, sender=deployer)
    estimator = project.Estimator.deploy(pool, sender=deployer)

    amt = n * 100 * PRECISION
    for asset in assets:
        asset.approve(pool, MAX, sender=alice)
        asset.mint(alice, amt // n, sender=deployer)

    pool.add_liquidity([amt // n for _ in range(n)], 0, sender=alice)

    # remove liquidity
    expect = estimator.get_remove_lp(token.balanceOf(alice)//10)
    pool.remove_liquidity(token.balanceOf(alice)//10, [0 for _ in range(n)], sender=alice)

    for i in range(n):
        bal = assets[i].balanceOf(alice)
        assert bal == expect[i]
        assert abs(bal - amt // n // 10) <= 1

def test_withdraw_single(project, deployer, alice, bob, token):
    amplification = 10 * PRECISION
    n = 4
    assets, provider = deploy_assets(project, deployer, n)
    pool = project.Pool.deploy(token, amplification, assets, [provider for _ in range(n)], [PRECISION//n for _ in range(n)], sender=deployer)
    token.set_minter(pool, sender=deployer)
    estimator = project.Estimator.deploy(pool, sender=deployer)

    amt = n * 100 * PRECISION
    for asset in assets:
        asset.approve(pool, MAX, sender=alice)
        asset.mint(alice, amt // n, sender=deployer)

    pool.add_liquidity([amt // n for _ in range(n)], 0, sender=alice)
    vb_prod = to_int(project.provider.get_storage_at(pool.address, VB_PROD_SLOT))
    vb_sum = to_int(project.provider.get_storage_at(pool.address, VB_SUM_SLOT))

    # add single sided liquidity
    amt = amt // n // 10
    assets[0].approve(pool, MAX, sender=bob)
    assets[0].mint(bob, amt, sender=bob)
    amts = [amt if i == 0 else 0 for i in range(n)]
    expect = estimator.get_add_lp(amts)
    pool.add_liquidity(amts, 0, sender=bob)
    bal = token.balanceOf(bob)
    assert bal == expect

    # remove single sided liquidity
    expect = estimator.get_remove_single_lp(0, bal)
    pool.remove_liquidity_single(0, bal, 0, sender=bob)
    vb_prod2 = to_int(project.provider.get_storage_at(pool.address, VB_PROD_SLOT))
    vb_sum2 = to_int(project.provider.get_storage_at(pool.address, VB_SUM_SLOT))

    bal = assets[0].balanceOf(bob)
    assert bal == expect
    assert amt > bal
    assert (amt - bal) / amt < 2e-14
    assert abs(vb_sum2 - vb_sum) / vb_sum < 1e-15
    assert abs(vb_prod2 - vb_prod) / vb_prod < 1e-14

def test_swap(project, deployer, alice, bob, token):
    amplification = 10 * PRECISION
    n = 4
    assets, provider = deploy_assets(project, deployer, n)
    pool = project.Pool.deploy(token, amplification, assets, [provider for _ in range(n)], [PRECISION//n for _ in range(n)], sender=deployer)
    token.set_minter(pool, sender=deployer)
    estimator = project.Estimator.deploy(pool, sender=deployer)

    amt = n * 100 * PRECISION
    for asset in assets:
        asset.approve(pool, MAX, sender=alice)
        asset.mint(alice, amt // n, sender=deployer)
    pool.add_liquidity([amt // n for _ in range(n)], 0, sender=alice)

    vb_prod = to_int(project.provider.get_storage_at(pool.address, VB_PROD_SLOT))
    vb_sum = to_int(project.provider.get_storage_at(pool.address, VB_SUM_SLOT))

    # swap asset 0 for asset 1
    swap = 10 * PRECISION
    assets[0].approve(pool, MAX, sender=bob)
    assets[0].mint(bob, swap, sender=deployer)
    expect = estimator.get_dy(0, 1, swap)
    pool.swap(0, 1, swap, 0, sender=bob)
    assert assets[0].balanceOf(bob) == 0
    bal = assets[1].balanceOf(bob)
    assert bal == expect
    assert bal < swap
    # small penalty because pool is brought out of balance
    assert (swap - bal) / swap < 1e-3

    # swap back and receive ~ original amount back
    assets[1].approve(pool, MAX, sender=bob)
    pool.swap(1, 0, bal, 0, sender=bob)
    bal2 = assets[0].balanceOf(bob)
    assert bal2 > bal
    assert bal2 < swap # rounding is in favor of pool
    assert (swap - bal2) / swap < 1e-14

    vb_prod2 = to_int(project.provider.get_storage_at(pool.address, VB_PROD_SLOT))
    vb_sum2 = to_int(project.provider.get_storage_at(pool.address, VB_SUM_SLOT))

    assert abs((vb_prod2 - vb_prod) / vb_prod) < 1e-13
    assert vb_sum2 > vb_sum
    assert (vb_sum2 - vb_sum) / vb_sum < 2e-14

def test_swap_fee(project, chain, deployer, alice, bob, token):
    amplification = 10 * PRECISION
    n = 4
    assets, provider = deploy_assets(project, deployer, n)
    pool = project.Pool.deploy(token, amplification, assets, [provider for _ in range(n)], [PRECISION//n for _ in range(n)], sender=deployer)
    token.set_minter(pool, sender=deployer)
    estimator = project.Estimator.deploy(pool, sender=deployer)

    amts = [170 * PRECISION, 50 * PRECISION, 20 * PRECISION, 160 * PRECISION]
    for i in range(n):
        asset = assets[i]
        asset.approve(pool, MAX, sender=alice)
        asset.mint(alice, amts[i], sender=deployer)
    pool.add_liquidity(amts, 0, sender=alice)

    # swap without a fee
    swap = 10 * PRECISION
    assets[0].approve(pool, MAX, sender=bob)
    assets[0].mint(bob, swap, sender=deployer)

    id = chain.snapshot()
    expect = estimator.get_dy(0, 1, swap)
    pool.swap(0, 1, swap, 0, sender=bob)
    full_out = assets[1].balanceOf(bob)
    assert full_out == expect
    chain.restore(id)

    # swap with fee
    fee_rate = PRECISION * 3 // 1000 # 10%
    pool.set_staking(deployer, sender=deployer)
    pool.set_swap_fee_rate(fee_rate, sender=deployer)
    
    expect = estimator.get_dy(0, 1, swap)
    pool.swap(0, 1, swap, 0, sender=bob)
    out = assets[1].balanceOf(bob)
    assert out == expect
    actual_fee_rate = (full_out - out) * PRECISION // full_out
    # fee is charged on input so not exact on output
    assert abs(fee_rate - actual_fee_rate) / fee_rate < 0.01

def test_swap_exact_out(project, deployer, alice, bob, token):
    amplification = 10 * PRECISION
    n = 4
    assets, provider = deploy_assets(project, deployer, n)
    pool = project.Pool.deploy(token, amplification, assets, [provider for _ in range(n)], [PRECISION//n for _ in range(n)], sender=deployer)
    token.set_minter(pool, sender=deployer)
    estimator = project.Estimator.deploy(pool, sender=deployer)

    amt = n * 100 * PRECISION
    for asset in assets:
        asset.approve(pool, MAX, sender=alice)
        asset.mint(alice, amt // n, sender=deployer)
    pool.add_liquidity([amt // n for _ in range(n)], 0, sender=alice)

    vb_prod = to_int(project.provider.get_storage_at(pool.address, VB_PROD_SLOT))
    vb_sum = to_int(project.provider.get_storage_at(pool.address, VB_SUM_SLOT))

    # swap asset 0 for asset 1
    swap = 10 * PRECISION
    assets[0].approve(pool, MAX, sender=bob)
    assets[0].mint(bob, 2 * swap, sender=deployer)
    expect = estimator.get_dx(0, 1, swap)
    pool.swap_exact_out(0, 1, swap, MAX, sender=bob)
    assert assets[1].balanceOf(bob) == swap
    amt = 2 * swap - assets[0].balanceOf(bob)
    assert amt == expect
    assert amt > swap
    # small penalty because pool is brought out of balance
    assert (amt - swap) / swap < 1e-3

    # reset balance to simplify calculations
    assets[1].burn(bob, assets[1].balanceOf(bob), sender=deployer)
    assets[1].mint(bob, 2 * swap, sender=deployer)

    # swap back at a cost ~ previous swap output
    assets[1].approve(pool, MAX, sender=bob)
    pool.swap_exact_out(1, 0, amt, MAX, sender=bob)
    assert assets[0].balanceOf(bob) == 2 * swap
    amt2 = 2 * swap - assets[1].balanceOf(bob)
    assert amt > amt2
    assert amt2 > swap # rounding is in favor of pool
    assert (amt2 - swap) / swap < 1e-14

    vb_prod2 = to_int(project.provider.get_storage_at(pool.address, VB_PROD_SLOT))
    vb_sum2 = to_int(project.provider.get_storage_at(pool.address, VB_SUM_SLOT))

    assert abs((vb_prod2 - vb_prod) / vb_prod) < 2e-14
    assert vb_sum2 > vb_sum
    assert (vb_sum2 - vb_sum) / vb_sum < 2e-14

def test_swap_exact_out_fee(project, chain, deployer, alice, bob, token):
    amplification = 10 * PRECISION
    n = 4
    fee_rate = PRECISION // 10 # 10%
    assets, provider = deploy_assets(project, deployer, n)
    pool = project.Pool.deploy(token, amplification, assets, [provider for _ in range(n)], [PRECISION//n for _ in range(n)], sender=deployer)
    token.set_minter(pool, sender=deployer)
    estimator = project.Estimator.deploy(pool, sender=deployer)

    amt = n * 100 * PRECISION
    for asset in assets:
        asset.approve(pool, MAX, sender=alice)
        asset.mint(alice, amt // n, sender=deployer)
    pool.add_liquidity([amt // n for _ in range(n)], 0, sender=alice)

    # swap without a fee
    swap = 10 * PRECISION
    assets[0].approve(pool, MAX, sender=bob)
    assets[0].mint(bob, 2 * swap, sender=deployer)
    id = chain.snapshot()
    expect = estimator.get_dx(0, 1, swap)
    pool.swap_exact_out(0, 1, swap, MAX, sender=bob)
    base_amt = 2 * swap - assets[0].balanceOf(bob)
    assert base_amt == expect
    exp_fee_amt = base_amt * PRECISION // (PRECISION - fee_rate) - base_amt

    # add expected fee as liquidity
    pool.add_liquidity([exp_fee_amt if i == 0 else 0 for i in range(n)], 0, sender=bob)
    exp_staking_bal = token.balanceOf(bob)

    vb_prod = to_int(project.provider.get_storage_at(pool.address, VB_PROD_SLOT))
    vb_sum = to_int(project.provider.get_storage_at(pool.address, VB_SUM_SLOT))

    # swap with fee
    chain.restore(id)
    pool.set_staking(deployer, sender=deployer)
    pool.set_swap_fee_rate(fee_rate, sender=deployer)

    expect = estimator.get_dx(0, 1, swap)
    pool.swap_exact_out(0, 1, swap, MAX, sender=bob)
    amt = 2 * swap - assets[0].balanceOf(bob)
    assert amt == expect
    fee_amt = amt - base_amt
    assert fee_amt == exp_fee_amt
    
    staking_bal = token.balanceOf(deployer)
    assert abs(staking_bal - exp_staking_bal) / exp_staking_bal < 2e-13

    # fee is charged on input token but paid in pool token, so amount is slightly less
    assert staking_bal < fee_amt
    assert (fee_amt - staking_bal) / fee_amt < 2e-4

    vb_prod2 = to_int(project.provider.get_storage_at(pool.address, VB_PROD_SLOT))
    vb_sum2 = to_int(project.provider.get_storage_at(pool.address, VB_SUM_SLOT))
    assert abs(vb_prod2 - vb_prod) / vb_prod < 1e-14
    assert vb_sum == vb_sum2

def test_rate_update(project, deployer, alice, token):
    amplification = 10 * PRECISION
    n = 4
    assets, provider = deploy_assets(project, deployer, n)
    pool = project.Pool.deploy(token, amplification, assets, [provider for _ in range(n)], [PRECISION//n for _ in range(n)], sender=deployer)
    pool.set_staking(deployer, sender=deployer)
    token.set_minter(pool, sender=deployer)

    # add some liquidity
    amt = n * 100 * PRECISION
    for asset in assets:
        asset.approve(pool, MAX, sender=alice)
        asset.mint(alice, amt // n, sender=deployer)
    pool.add_liquidity([amt // n for _ in range(n)], 0, sender=alice)

    # update rate of one asset to 110%
    provider.set_rate(assets[0], 110 * PRECISION // 100, sender=deployer)
    pool.update_rates(1, sender=alice)

    # staking address should have ~10%/4 of token
    expect = amt / n // 10
    bal = token.balanceOf(deployer)
    assert bal < expect
    assert (expect - bal) / expect < 1e-4 # small penalty because pool is slightly out of balance now

    # adjust rate downwards to 108%
    provider.set_rate(assets[0], 108 * PRECISION // 100, sender=deployer)
    pool.update_rates(1, sender=alice)

    # staking address should now have ~8%/4 of token
    expect = amt / n * 8 // 100
    bal = token.balanceOf(deployer)
    assert bal < expect
    assert (expect - bal) / expect < 1e-4 # small penalty because pool is still out of balance

def test_storage_slot(project, deployer, alice, token):
    # quickly find storage slot of certain variables required in other tests
    amplification = 10 * PRECISION
    n = 2
    assets, provider = deploy_assets(project, deployer, n)
    pool = project.Pool.deploy(token, amplification, assets, [provider for _ in range(n)], [PRECISION//n for _ in range(n)], sender=deployer)
    token.set_minter(pool, sender=deployer)

    amt = 123 * PRECISION
    for asset in assets:
        asset.approve(pool, MAX, sender=alice)
        asset.mint(alice, amt, sender=deployer)
    pool.add_liquidity([amt for _ in range(n)], 0, sender=alice)

    slot = -1
    for i in range(256):
        val = to_int(project.provider.get_storage_at(pool.address, i))
        if val == n*amt:
            assert slot == -1
            slot = i
    assert slot - 2 == W_PROD_SLOT

def test_ramp_weight_empty(project, deployer, alice, token):
    # weights can be updated when pool is empty
    amplification = 10 * PRECISION
    n = 5
    assets, provider = deploy_assets(project, deployer, n)
    weights = [PRECISION//n for _ in range(n)]
    pool = project.Pool.deploy(token, amplification, assets, [provider for _ in range(n)], weights, sender=deployer)
    pool.set_staking(alice, sender=deployer)
    token.set_minter(pool, sender=deployer)

    diff = PRECISION//100
    weights[0] -= 4 * diff
    for i in range(1, n):
        weights[i] += diff
    pool.set_ramp(amplification, weights, 0, sender=deployer)
    pool.update_weights(sender=deployer)
    for i in range(n):
        assert pool.weight(i)[0] == weights[i]
    w_prod = to_int(project.provider.get_storage_at(pool.address, W_PROD_SLOT))
    vb_prod = to_int(project.provider.get_storage_at(pool.address, VB_PROD_SLOT))
    vb_sum = to_int(project.provider.get_storage_at(pool.address, VB_SUM_SLOT))
    assert w_prod == 0
    assert vb_prod == 0
    assert vb_sum == 0

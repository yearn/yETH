import ape
from conftest import *
import pytest

@pytest.fixture
def token(project, deployer):
    return project.Token.deploy(sender=deployer)

@pytest.fixture
def weights():
    return [PRECISION*1//10, PRECISION*2//10, PRECISION*3//10, PRECISION*4//10]

@pytest.fixture
def pool(project, deployer, token, weights):
    assets, provider = deploy_assets(project, deployer, len(weights))
    pool = project.Pool.deploy(token, calc_w_prod(weights), assets, [provider for _ in range(len(weights))], weights, sender=deployer)
    pool.set_staking(deployer, sender=deployer)
    token.set_minter(pool, sender=deployer)
    return assets, provider, pool

@pytest.fixture
def estimator(project, deployer, pool):
    return project.Estimator.deploy(pool[2], sender=deployer)

def test_round_trip(alice, bob, token, weights, pool):
    assets, provider, pool = pool
    
    # mint assets
    n = len(assets)
    total = 1_000 * PRECISION
    amts = []
    for i in range(n):
        asset = assets[i]
        asset.approve(pool, MAX, sender=alice)
        amt = total * weights[i] // provider.rate(asset)
        amts.append(amt)
        asset.mint(alice, amt, sender=alice)
    pool.add_liquidity(amts, 0, sender=alice)

    vb_prod, vb_sum = pool.vb_prod_sum()

    amt = PRECISION
    asset = assets[0]
    asset.mint(alice, amt, sender=alice)
    pool.add_liquidity([amt if i == 0 else 0 for i in range(n)], 0, bob, sender=alice)
    lp = token.balanceOf(bob)

    # slippage check
    with ape.reverts():
        pool.remove_liquidity_single(0, lp, amt, bob, sender=bob)    

    pool.remove_liquidity_single(0, lp, 0, bob, sender=bob)
    amt2 = asset.balanceOf(bob)

    # rounding in favor of pool
    assert amt2 < amt
    assert abs(amt2 - amt) / amt < 2e-13

    vb_prod2, vb_sum2 = pool.vb_prod_sum()
    assert abs(vb_prod2 - vb_prod) / vb_prod < 1e-15
    assert abs(vb_sum2 - vb_sum) / vb_sum < 1e-15

def test_penalty(chain, alice, bob, weights, pool, estimator):
    assets, provider, pool = pool
    
    # mint assets
    n = len(assets)
    total = 1_000 * PRECISION
    amts = []
    for i in range(n):
        asset = assets[i]
        asset.approve(pool, MAX, sender=alice)
        amt = total * weights[i] // provider.rate(asset)
        amts.append(amt)
        asset.mint(alice, amt, sender=alice)
    pool.add_liquidity(amts, 0, sender=alice)

    lp = total // 100
    prev = 0
    for i in range(n):
        with chain.isolate():
            asset = assets[i]
            exp = estimator.get_remove_single_lp(i, lp)
            res = pool.remove_liquidity_single(i, lp, 0, bob, sender=alice).return_value
            bal = asset.balanceOf(bob)
            assert bal == exp
            assert bal == res

            # pool out of balance, penalty applied
            amt = bal * provider.rate(asset) // PRECISION
            assert amt < lp

            # later assets have higher weight, so penalty will be lower
            assert amt > prev
            prev = amt

def test_fee(chain, deployer, alice, bob, weights, pool, estimator):
    assets, provider, pool = pool
    
    # mint assets
    n = len(assets)
    total = 1_000 * PRECISION
    amts = []
    for i in range(n):
        asset = assets[i]
        asset.approve(pool, MAX, sender=alice)
        amt = total * weights[i] // provider.rate(asset)
        amts.append(amt)
        asset.mint(alice, amt, sender=alice)
    pool.add_liquidity(amts, 0, sender=alice)

    with chain.isolate():
        base = pool.remove_liquidity_single(0, PRECISION, 0, bob, sender=alice).return_value

    # set a fee
    fee_rate = PRECISION // 100
    pool.set_swap_fee_rate(fee_rate, sender=deployer)
    exp = estimator.get_remove_single_lp(0, PRECISION)
    res = pool.remove_liquidity_single(0, PRECISION, 0, bob, sender=alice).return_value
    bal = assets[0].balanceOf(bob)
    assert bal == exp
    assert bal == res

    # doing a single sided withdrawal charges fee/2
    assert bal < base
    actual_rate = abs(bal - base) * PRECISION // base * 2
    assert abs(actual_rate - fee_rate) / fee_rate < 1e-16

def test_rate_update(chain, deployer, alice, bob, token, weights, pool, estimator):
    assets, provider, pool = pool
    
    # mint assets
    n = len(assets)
    total = 1_000_000 * PRECISION
    amts = []
    for i in range(n):
        asset = assets[i]
        asset.approve(pool, MAX, sender=alice)
        amt = total * weights[i] // provider.rate(asset)
        amts.append(amt)
        asset.mint(alice, amt, sender=alice)
    pool.add_liquidity(amts, 0, sender=alice)

    # rate update of each asset, followed by a single sided withdrawal
    factor = 1.01
    for i in range(n):
        asset = assets[i]
        with chain.isolate():
            pool.remove_liquidity_single(i, PRECISION, 0, bob, sender=alice)
            base = asset.balanceOf(bob) * provider.rate(asset) // PRECISION

        with chain.isolate():
            provider.set_rate(asset, int(provider.rate(asset) * factor), sender=alice)

            # remove liquidity after rate increase
            exp = estimator.get_remove_single_lp(i, PRECISION)
            pool.remove_liquidity_single(i, PRECISION, 0, bob, sender=alice)
            bal = asset.balanceOf(bob)
            assert bal == exp
            bal = bal * provider.rate(asset) // PRECISION

            # staking address received rewards
            exp2 = int(total * weights[i] // PRECISION*(factor-1))
            bal2 = token.balanceOf(deployer)
            assert bal2 < exp2
            assert abs(bal2 - exp2) / exp2 < 1e-3

        # the rate update brought pool out of balance so user receives bonus
        assert bal > base
        bal_factor = bal / base
        assert bal_factor < factor
        assert abs(bal_factor - factor) / factor < 1e-2

def test_ramp_weight(chain, deployer, alice, bob, weights, pool, estimator):
    assets, provider, pool = pool
    
    # mint assets
    n = len(assets)
    total = 1_000 * PRECISION
    amts = []
    for i in range(n):
        asset = assets[i]
        asset.approve(pool, MAX, sender=alice)
        amt = total * weights[i] // provider.rate(asset)
        amts.append(amt)
        asset.mint(alice, amt, sender=alice)
    pool.add_liquidity(amts, 0, deployer, sender=alice)

    with chain.isolate():
        pool.remove_liquidity_single(1, PRECISION, 0, bob, sender=deployer)
        base_1 = assets[1].balanceOf(bob)
    with chain.isolate():
        pool.remove_liquidity_single(2, PRECISION, 0, bob, sender=deployer)
        base_2 = assets[2].balanceOf(bob)

    weights2 = weights
    weights2[1] += PRECISION // 10
    weights2[2] -= PRECISION // 10

    ts = chain.pending_timestamp
    pool.set_ramp(calc_w_prod(weights2), weights2, WEEK_LENGTH, sender=deployer)

    # halfway ramp
    chain.pending_timestamp = ts + WEEK_LENGTH // 2
    with chain.isolate():
        chain.mine()
        exp = estimator.get_remove_single_lp(1, PRECISION)
    chain.pending_timestamp = ts + WEEK_LENGTH // 2
    with chain.isolate():
        pool.remove_liquidity_single(1, PRECISION, 0, bob, sender=deployer)
        mid_1 = assets[1].balanceOf(bob)
        assert abs(mid_1 - exp) <= 1
        assert mid_1 == exp
    chain.pending_timestamp = ts + WEEK_LENGTH // 2
    with chain.isolate():
        chain.mine()
        exp = estimator.get_remove_single_lp(2, PRECISION)
    chain.pending_timestamp = ts + WEEK_LENGTH // 2
    with chain.isolate():
        pool.remove_liquidity_single(2, PRECISION, 0, bob, sender=deployer)
        mid_2 = assets[2].balanceOf(bob)
        assert abs(mid_2 - exp) <= 1
    
    # asset 1 share is below weight -> penalty
    assert mid_1 < base_1
    # asset 2 share is above weight -> bonus
    assert mid_2 > base_2

    # end of ramp
    chain.pending_timestamp = ts + WEEK_LENGTH
    with chain.isolate():
        chain.mine()
        exp = estimator.get_remove_single_lp(1, PRECISION)
    chain.pending_timestamp = ts + WEEK_LENGTH
    with chain.isolate():
        pool.remove_liquidity_single(1, PRECISION, 0, bob, sender=deployer)
        end_1 = assets[1].balanceOf(bob)
        assert abs(end_1 - exp) <= 2
    chain.pending_timestamp = ts + WEEK_LENGTH
    with chain.isolate():
        chain.mine()
        exp = estimator.get_remove_single_lp(2, PRECISION)
    chain.pending_timestamp = ts + WEEK_LENGTH
    with chain.isolate():
        pool.remove_liquidity_single(2, PRECISION, 0, bob, sender=deployer)
        end_2 = assets[2].balanceOf(bob)
        assert abs(end_2 - exp) <= 2
    
    # asset 1 share is more below weight -> bigger penalty
    assert end_1 < mid_1

    # asset 2 share is more above weight -> bigger bonus
    assert end_2 > mid_2

def test_ramp_amplification(chain, deployer, alice, bob, weights, pool, estimator):
    assets, provider, pool = pool
    
    # mint assets
    n = len(assets)
    total = 1_000 * PRECISION
    amts = []
    for i in range(n):
        asset = assets[i]
        asset.approve(pool, MAX, sender=alice)
        amt = total * weights[i] // provider.rate(asset)
        amts.append(amt)
        asset.mint(alice, amt, sender=alice)
    pool.add_liquidity(amts, 0, deployer, sender=alice)

    with chain.isolate():
        pool.remove_liquidity_single(0, PRECISION, 0, bob, sender=deployer)
        base = assets[0].balanceOf(bob)

    amplification = 10 * pool.amplification()
    ts = chain.pending_timestamp
    pool.set_ramp(amplification, weights, WEEK_LENGTH, sender=deployer)

    # halfway ramp
    chain.pending_timestamp = ts + WEEK_LENGTH // 2
    with chain.isolate():
        chain.mine()
        exp = estimator.get_remove_single_lp(0, PRECISION)
    chain.pending_timestamp = ts + WEEK_LENGTH // 2
    with chain.isolate():
        pool.remove_liquidity_single(0, PRECISION, 0, bob, sender=deployer)
        mid = assets[0].balanceOf(bob)
        assert abs(mid - exp) <= 1
    
    # higher amplification -> lower penalty
    assert mid > base

    # end of ramp
    chain.pending_timestamp = ts + WEEK_LENGTH
    with chain.isolate():
        chain.mine()
        exp = estimator.get_remove_single_lp(0, PRECISION)
    chain.pending_timestamp = ts + WEEK_LENGTH
    with chain.isolate():
        pool.remove_liquidity_single(0, PRECISION, 0, bob, sender=deployer)
        end = assets[0].balanceOf(bob)
        assert abs(end - exp) <= 2
    
    # even lower penalty
    assert end > mid

def test_lower_band(chain, deployer, alice, bob, weights, pool, estimator):
    assets, provider, pool = pool
    
    # mint assets
    n = len(assets)
    total = 1_000 * PRECISION
    amts = []
    for i in range(n):
        asset = assets[i]
        asset.approve(pool, MAX, sender=alice)
        amt = total * weights[i] // provider.rate(asset)
        amts.append(amt)
        asset.mint(alice, amt, sender=alice)
    pool.add_liquidity(amts, 0, deployer, sender=alice)

    lp = total * 2 // 100 # -1.2% after withdrawal

    # withdraw will work before setting a band
    with chain.isolate():
        estimator.get_remove_single_lp(3, lp)
        pool.remove_liquidity_single(3, lp, 0, bob, sender=deployer)

    # set band
    pool.set_weight_bands([3], [PRECISION // 100], [PRECISION], sender=deployer)

    # withdrawing wont work anymore
    with ape.reverts():
        estimator.get_remove_single_lp(3, lp)
    with ape.reverts(dev_message='dev: ratio below lower band'):
        pool.remove_liquidity_single(3, lp, 0, bob, sender=deployer)

def test_upper_band(chain, deployer, alice, bob, weights, pool, estimator):
    assets, provider, pool = pool
    
    # mint assets
    n = len(assets)
    total = 1_000 * PRECISION
    amts = []
    for i in range(n):
        asset = assets[i]
        asset.approve(pool, MAX, sender=alice)
        amt = total * weights[i] // provider.rate(asset)
        amts.append(amt)
        asset.mint(alice, amt, sender=alice)
    pool.add_liquidity(amts, 0, deployer, sender=alice)

    lp = total * 4 // 100 # +1.2% after withdrawal

    # withdraw will work before setting a band
    with chain.isolate():
        estimator.get_remove_single_lp(3, lp)
        pool.remove_liquidity_single(3, lp, 0, bob, sender=deployer)

    # set band of other asset
    pool.set_weight_bands([2], [PRECISION], [PRECISION // 100], sender=deployer)

    # withdrawing wont work anymore
    with ape.reverts():
        estimator.get_remove_single_lp(3, lp)
    with ape.reverts(dev_message='dev: ratio above upper band'):
        pool.remove_liquidity_single(3, lp, 0, bob, sender=deployer)

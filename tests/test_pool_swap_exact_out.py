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

def test_round_trip(alice, bob, weights, pool):
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
    assets[0].mint(alice, 2 * amt, sender=alice)
    cost = pool.swap_exact_out(0, 1, amt, MAX, bob, sender=alice).return_value

    assets[1].mint(alice, 2 * amt, sender=alice)

    # slippage check
    with ape.reverts(dev_message='dev: slippage'):
        pool.swap_exact_out(1, 0, cost, amt, bob, sender=alice)

    amt2 = pool.swap_exact_out(1, 0, cost, MAX, bob, sender=alice).return_value

    # rounding in favor of pool
    assert amt2 > amt
    assert abs(amt2 - amt) / amt < 1e-13

    vb_prod2, vb_sum2 = pool.vb_prod_sum()
    assert abs(vb_prod2 - vb_prod) / vb_prod < 3e-16
    assert abs(vb_sum2 - vb_sum) / vb_sum < 2e-16

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

    swap_unscaled = total // 100
    assets[0].mint(alice, 10 * swap_unscaled, sender=alice)
    prev = MAX
    for i in range(1, n):
        with chain.isolate():
            asset = assets[i]
            swap = swap_unscaled * PRECISION // provider.rate(asset)
            exp = estimator.get_dx(0, i, swap)
            res = pool.swap_exact_out(0, i, swap, MAX, bob, sender=alice).return_value
            cost = 10 * swap_unscaled - assets[0].balanceOf(alice)
            assert cost == exp
            assert cost == res

            # pool out of balance, penalty applied
            assert swap_unscaled < cost * provider.rate(assets[0]) // PRECISION

            # later assets have higher weight, so penalty will be lower
            assert cost < prev
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

    amt = PRECISION
    assets[0].mint(alice, 2 * amt, sender=alice)

    with chain.isolate():
        base = pool.swap_exact_out(0, 1, amt, MAX, bob, sender=alice).return_value

    # set a fee
    fee_rate = PRECISION // 10
    pool.set_swap_fee_rate(fee_rate, sender=deployer)
    exp = estimator.get_dx(0, 1, amt)
    res = pool.swap_exact_out(0, 1, amt, MAX, bob, sender=alice).return_value
    cost = 2 * amt - assets[0].balanceOf(alice)
    assert cost == exp
    assert cost == res

    assert cost > base
    actual_rate = abs(cost - base) * PRECISION // cost
    assert abs(actual_rate - fee_rate) / fee_rate <= 1e-17

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
    pool.add_liquidity(amts, 0, deployer, sender=alice)
    bal = token.balanceOf(deployer)

    swap_unscaled = PRECISION
    assets[0].mint(alice, swap_unscaled, sender=alice)

    # rate update of each asset, followed by a swap
    factor = 1.01
    for i in range(1, n):
        asset = assets[i]
        swap = swap_unscaled * PRECISION // provider.rate(asset)
        with chain.isolate():
            pool.swap_exact_out(0, i, swap, MAX, bob, sender=alice)
            base = swap_unscaled - assets[0].balanceOf(alice)

        with chain.isolate():
            provider.set_rate(asset, int(provider.rate(asset) * factor), sender=alice)

            # swap after rate increase
            exp = estimator.get_dx(0, i, swap)
            pool.swap_exact_out(0, i, swap, MAX, bob, sender=alice)
            cost = swap_unscaled - assets[0].balanceOf(alice)
            assert cost == exp

            # staking address received rewards
            exp2 = int(total * weights[i] // PRECISION*(factor-1))
            bal2 = token.balanceOf(deployer) - bal
            assert bal2 < exp2
            assert abs(bal2 - exp2) / exp2 < 1e-4

        # the rate update makes the output asset more expensive, but also puts the pool in an inbalance
        assert cost > base
        cost_factor = cost / base
        assert cost_factor < factor
        assert abs(cost_factor - factor) / factor < 1e-3

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

    assets[0].mint(alice, 10 * PRECISION, sender=alice)

    with chain.isolate():
        base_1 = pool.swap_exact_out(0, 1, PRECISION, MAX, bob, sender=alice).return_value
    with chain.isolate():
        base_2 = pool.swap_exact_out(0, 2, PRECISION, MAX, bob, sender=alice).return_value

    weights2 = weights
    weights2[1] += PRECISION // 10
    weights2[2] -= PRECISION // 10

    ts = chain.pending_timestamp
    pool.set_ramp(calc_w_prod(weights2), weights2, WEEK_LENGTH, sender=deployer)

    # halfway ramp
    chain.pending_timestamp = ts + WEEK_LENGTH // 2
    with chain.isolate():
        chain.mine()
        exp = estimator.get_dx(0, 1, PRECISION)
    with chain.isolate():
        mid_1 = pool.swap_exact_out(0, 1, PRECISION, MAX, bob, sender=alice).return_value
        assert abs(mid_1 - exp) <= 5
    with chain.isolate():
        chain.mine()
        exp = estimator.get_dx(0, 2, PRECISION)
    with chain.isolate():
        mid_2 = pool.swap_exact_out(0, 2, PRECISION, MAX, bob, sender=alice).return_value
        assert abs(mid_2 - exp) <= 3
    
    # asset 1 share is below weight -> penalty
    assert mid_1 > base_1
    # asset 2 share is above weight -> bonus
    assert mid_2 < base_2

    # end of ramp
    chain.pending_timestamp = ts + WEEK_LENGTH
    with chain.isolate():
        chain.mine()
        exp = estimator.get_dx(0, 1, PRECISION)
    with chain.isolate():
        end_1 = pool.swap_exact_out(0, 1, PRECISION, MAX, bob, sender=alice).return_value
        assert abs(end_1 - exp) <= 9
    with chain.isolate():
        chain.mine()
        exp = estimator.get_dx(0, 2, PRECISION)
    with chain.isolate():
        end_2 = pool.swap_exact_out(0, 2, PRECISION, MAX, bob, sender=alice).return_value
        assert abs(end_2 - exp) <= 7
    
    # asset 1 share is more below weight -> bigger penalty
    assert end_1 > mid_1

    # asset 2 share is more above weight -> bigger bonus
    assert end_2 < mid_2

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

    assets[0].mint(alice, 2 * PRECISION, sender=alice)

    with chain.isolate():
        base = pool.swap_exact_out(0, 1, PRECISION, MAX, bob, sender=alice).return_value

    amplification = 10 * pool.amplification()
    ts = chain.pending_timestamp
    pool.set_ramp(amplification, weights, WEEK_LENGTH, sender=deployer)

    # halfway ramp
    chain.pending_timestamp = ts + WEEK_LENGTH // 2
    with chain.isolate():
        chain.mine()
        exp = estimator.get_dx(0, 1, PRECISION)
    with chain.isolate():
        mid = pool.swap_exact_out(0, 1, PRECISION, MAX, bob, sender=alice).return_value
        assert mid == exp
    
    # higher amplification -> lower penalty
    assert mid < base

    # end of ramp
    chain.pending_timestamp = ts + WEEK_LENGTH
    with chain.isolate():
        chain.mine()
        exp = estimator.get_dx(0, 1, PRECISION)
    with chain.isolate():
        end = pool.swap_exact_out(0, 1, PRECISION, MAX, bob, sender=alice).return_value
        assert abs(end - exp) <= 2
    
    # even lower penalty
    assert end < mid

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

    amt = total * 2 // 100 * PRECISION // provider.rate(assets[3])
    assets[0].mint(alice, 100 * PRECISION, sender=alice)

    # swap will work before setting a band
    with chain.isolate():
        estimator.get_dx(0, 3, amt)
        pool.swap_exact_out(0, 3, amt, MAX, bob, sender=alice)

    # set band
    pool.set_weight_bands([3], [PRECISION // 100], [PRECISION], sender=deployer)

    # swapping wont work anymore
    with ape.reverts():
        estimator.get_dx(0, 3, amt)
    with ape.reverts(dev_message='dev: ratio below lower band'):
        pool.swap_exact_out(0, 3, amt, MAX, bob, sender=alice)

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

    amt = total * 2 // 100 * PRECISION // provider.rate(assets[3])
    assets[0].mint(alice, 100 * PRECISION, sender=alice)

    # swap will work before setting a band
    with chain.isolate():
        estimator.get_dx(0, 3, amt)
        pool.swap_exact_out(0, 3, amt, MAX, bob, sender=alice)

    # set band
    pool.set_weight_bands([0], [PRECISION], [PRECISION // 100], sender=deployer)

    # swapping wont work anymore
    with ape.reverts():
        estimator.get_dx(0, 3, amt)
    with ape.reverts(dev_message='dev: ratio above upper band'):
        pool.swap_exact_out(0, 3, amt, MAX, bob, sender=alice)

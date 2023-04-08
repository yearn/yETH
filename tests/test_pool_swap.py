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

    vb_prod = pool.vb_prod()
    vb_sum = pool.vb_sum()

    amt = PRECISION
    assets[0].mint(alice, amt, sender=alice)
    pool.swap(0, 1, amt, 0, bob, sender=alice)

    bal = assets[1].balanceOf(bob)
    assets[1].approve(pool, MAX, sender=bob)

    # slippage check
    with ape.reverts():
        pool.swap(1, 0, bal, amt, bob, sender=bob)

    pool.swap(1, 0, bal, 0, bob, sender=bob)
    amt2 = assets[0].balanceOf(bob)

    # rounding in favor of pool
    assert amt2 < amt
    assert abs(amt2 - amt) / amt < 1e-13

    vb_prod2 = pool.vb_prod()
    vb_sum2 = pool.vb_sum()
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

    swap = total // 100
    assets[0].mint(alice, swap, sender=alice)
    prev = 0
    for i in range(1, n):
        with chain.isolate():
            asset = assets[i]
            exp = estimator.get_dy(0, i, swap)
            res = pool.swap(0, i, swap, 0, bob, sender=alice).return_value
            bal = asset.balanceOf(bob)
            assert bal == exp
            assert bal == res

            # pool out of balance, penalty applied
            amt = bal * provider.rate(asset) // PRECISION
            assert amt < swap * provider.rate(assets[0]) // PRECISION

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

    amt = PRECISION
    assets[0].mint(alice, amt, sender=alice)

    with chain.isolate():
        base = pool.swap(0, 1, amt, 0, bob, sender=alice).return_value

    # set a fee
    fee_rate = PRECISION // 10
    pool.set_swap_fee_rate(fee_rate, sender=deployer)
    exp = estimator.get_dy(0, 1, amt)
    res = pool.swap(0, 1, amt, 0, bob, sender=alice).return_value
    bal = assets[1].balanceOf(bob)
    assert bal == exp
    assert bal == res

    assert bal < base
    actual_rate = abs(bal - base) * PRECISION // base
    assert abs(actual_rate - fee_rate) / fee_rate < 0.0004

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

    assets[0].mint(alice, PRECISION, sender=alice)

    # rate update of each asset, followed by a swap
    factor = 1.01
    for i in range(1, n):
        asset = assets[i]
        with chain.isolate():
            pool.swap(0, i, PRECISION, 0, bob, sender=alice)
            base = asset.balanceOf(bob) * provider.rate(asset) // PRECISION

        with chain.isolate():
            provider.set_rate(asset, int(provider.rate(asset) * factor), sender=alice)

            # swap after rate increase
            exp = estimator.get_dy(0, i, PRECISION)
            pool.swap(0, i, PRECISION, 0, bob, sender=alice)
            bal = asset.balanceOf(bob)
            assert bal == exp
            bal = bal * provider.rate(asset) // PRECISION

            # staking address received rewards
            exp2 = int(total * weights[i] // PRECISION*(factor-1))
            bal2 = token.balanceOf(deployer)
            assert bal2 < exp2
            assert abs(bal2 - exp2) / exp2 < 1e-4

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

    assets[0].mint(alice, PRECISION, sender=alice)

    with chain.isolate():
        pool.swap(0, 1, PRECISION, 0, bob, sender=alice)
        base_1 = assets[1].balanceOf(bob)
    with chain.isolate():
        pool.swap(0, 2, PRECISION, 0, bob, sender=alice)
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
        exp = estimator.get_dy(0, 1, PRECISION)
    with chain.isolate():
        pool.swap(0, 1, PRECISION, 0, bob, sender=alice)
        mid_1 = assets[1].balanceOf(bob)
        assert abs(mid_1 - exp) <= 2
    with chain.isolate():
        chain.mine()
        exp = estimator.get_dy(0, 2, PRECISION)
    with chain.isolate():
        pool.swap(0, 2, PRECISION, 0, bob, sender=alice)
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
        exp = estimator.get_dy(0, 1, PRECISION)
    with chain.isolate():
        pool.swap(0, 1, PRECISION, 0, bob, sender=alice)
        end_1 = assets[1].balanceOf(bob)
        assert abs(end_1 - exp) <= 4
    with chain.isolate():
        chain.mine()
        exp = estimator.get_dy(0, 2, PRECISION)
    with chain.isolate():
        pool.swap(0, 2, PRECISION, 0, bob, sender=alice)
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

    assets[0].mint(alice, PRECISION, sender=alice)

    with chain.isolate():
        pool.swap(0, 1, PRECISION, 0, bob, sender=alice)
        base = assets[1].balanceOf(bob)

    amplification = 10 * pool.amplification()
    ts = chain.pending_timestamp
    pool.set_ramp(amplification, weights, WEEK_LENGTH, sender=deployer)

    # halfway ramp
    chain.pending_timestamp = ts + WEEK_LENGTH // 2
    with chain.isolate():
        chain.mine()
        exp = estimator.get_dy(0, 1, PRECISION)
    with chain.isolate():
        pool.swap(0, 1, PRECISION, 0, bob, sender=alice)
        mid = assets[1].balanceOf(bob)
        assert abs(mid - exp) <= 1
    
    # higher amplification -> lower penalty
    assert mid > base

    # end of ramp
    chain.pending_timestamp = ts + WEEK_LENGTH
    with chain.isolate():
        chain.mine()
        exp = estimator.get_dy(0, 1, PRECISION)
    with chain.isolate():
        pool.swap(0, 1, PRECISION, 0, bob, sender=alice)
        end = assets[1].balanceOf(bob)
        assert abs(end - exp) <= 1
    
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

    amt = total * 2 // 100 * PRECISION // provider.rate(assets[0])
    assets[0].mint(alice, amt, sender=alice)

    # swap will work before setting a band
    with chain.isolate():
        estimator.get_dy(0, 3, amt)
        pool.swap(0, 3, amt, 0, bob, sender=alice)

    # set band
    pool.set_weight_bands([3], [PRECISION // 100], [PRECISION], sender=deployer)

    # swapping wont work anymore
    with ape.reverts():
        estimator.get_dy(0, 3, amt)
    with ape.reverts():
        pool.swap(0, 3, amt, 0, bob, sender=alice)

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

    amt = total * 2 // 100 * PRECISION // provider.rate(assets[0])
    assets[0].mint(alice, amt, sender=alice)

    # swap will work before setting a band
    with chain.isolate():
        estimator.get_dy(0, 3, amt)
        pool.swap(0, 3, amt, 0, bob, sender=alice)

    # set band
    pool.set_weight_bands([0], [PRECISION], [PRECISION // 100], sender=deployer)

    # swapping wont work anymore
    with ape.reverts():
        estimator.get_dy(0, 3, amt)
    with ape.reverts():
        pool.swap(0, 3, amt, 0, bob, sender=alice)

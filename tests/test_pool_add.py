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
    pool = project.Pool.deploy(token, PRECISION, assets, [provider for _ in range(len(weights))], weights, sender=deployer)
    pool.set_staking(deployer, sender=deployer)
    token.set_minter(pool, sender=deployer)
    return assets, provider, pool

@pytest.fixture
def estimator(project, deployer, pool):
    return project.Estimator.deploy(pool[2], sender=deployer)

def test_initial(alice, bob, token, weights, pool):
    assets, provider, pool = pool

    # mint assets
    n = len(assets)
    total = 10_000_000 * PRECISION
    amts = []
    for i in range(n):
        asset = assets[i]
        asset.approve(pool, MAX, sender=alice)
        amt = total * weights[i] // provider.rate(asset)
        amts.append(amt)
        asset.mint(alice, amt, sender=alice)

    with ape.reverts():
        # slippage protection
        pool.add_liquidity(amts, 2 * total, sender=alice)

    # add liquidity
    ret = pool.add_liquidity(amts, 0, bob, sender=alice).return_value
    bal = token.balanceOf(bob)
    assert ret == bal
    assert abs(total - bal) / total < 1e-16 # precision
    assert token.totalSupply() == bal
    assert pool.supply() == bal
    assert abs(pool.vb_sum() - total) <= 4 # rounding

def test_multiple(alice, bob, token, weights, pool, estimator):
    assets, provider, pool = pool

    # mint assets
    n = len(assets)
    total1 = 10_000_000 * PRECISION
    total2 = PRECISION // 10_000
    amts1 = []
    amts2 = []
    for i in range(n):
        asset = assets[i]
        asset.approve(pool, MAX, sender=alice)
        amt1 = total1 * weights[i] // provider.rate(asset)
        amt2 = total2 * weights[i] // provider.rate(asset)
        amts1.append(amt1)
        amts2.append(amt2)
        asset.mint(alice, amt1 + amt2, sender=alice)
    pool.add_liquidity(amts1, 0, sender=alice)

    # second small deposit
    exp = estimator.get_add_lp(amts2)
    ret = pool.add_liquidity(amts2, 0, bob, sender=alice).return_value
    bal = token.balanceOf(bob)
    assert bal == ret
    assert bal == exp

    # rounding is in favor of pool
    assert bal < total2
    # even with 10M ETH in the pool we can reach decent precision on small amounts
    assert abs(bal - total2) / total2 < 2e-5
    assert abs(pool.vb_sum() - total1 - total2) <= 4

def test_single_sided(chain, alice, bob, token, weights, pool, estimator):
    assets, provider, pool = pool

    # mint assets
    n = len(assets)
    total = 10 * PRECISION
    amts = []
    for i in range(n):
        asset = assets[i]
        asset.approve(pool, MAX, sender=alice)
        amt = total * weights[i] // provider.rate(asset)
        amts.append(amt)
        asset.mint(alice, amt, sender=alice)
    pool.add_liquidity(amts, 0, sender=alice)
    
    prev = 0
    for i in range(n):
        # do a single sided deposit for each asset independently
        with chain.isolate():
            asset = assets[i]
            amt = PRECISION * PRECISION // provider.rate(asset)
            asset.mint(alice, amt, sender=alice)
            amts = [amt if j == i else 0 for j in range(n)]

            exp = estimator.get_add_lp(amts)
            ret = pool.add_liquidity(amts, 0, bob, sender=alice).return_value
            bal = token.balanceOf(bob)
            assert bal == exp
            assert bal == ret
            assert bal < PRECISION

            # small penalty because pool is now out of balance
            penalty = abs(bal - PRECISION) / PRECISION
            assert penalty > 0.001 and penalty < 0.01

            # later assets have a higher weight so penalty is smaller
            assert bal > prev
            prev = bal

def test_bonus(alice, bob, token, weights, pool, estimator):
    assets, provider, pool = pool

    # mint assets
    n = len(assets)
    total = 10 * PRECISION
    amts = []
    for i in range(n):
        asset = assets[i]
        asset.approve(pool, MAX, sender=alice)
        amt = total * weights[i] // provider.rate(asset)
        amts.append(amt)
        asset.mint(alice, amt, sender=alice)
    pool.add_liquidity(amts, 0, sender=alice)

    # deposit all assets but one
    amts = []
    for i in range(n):
        asset = assets[i]
        amt = PRECISION * weights[i] // provider.rate(asset)
        amts.append(amt)
        asset.mint(alice, amt, sender=alice)
    amt0 = amts[0]
    amts[0] = 0
    pool.add_liquidity(amts, 0, sender=alice)

    # deposit the other asset, receive bonus for bringing pool in balance
    amts = [amt0 if i == 0 else 0 for i in range(n)]
    exp = estimator.get_add_lp(amts)
    res = pool.add_liquidity(amts, 0, bob, sender=alice).return_value
    bal = token.balanceOf(bob)
    assert bal > weights[0]
    assert bal == exp
    assert bal == res

def test_balanced_fee(chain, deployer, alice, bob, token, weights, pool, estimator):
    assets, provider, pool = pool
    
    # mint assets
    n = len(assets)
    total1 = 1_000 * PRECISION
    total2 = PRECISION
    amts1 = []
    amts2 = []
    for i in range(n):
        asset = assets[i]
        asset.approve(pool, MAX, sender=alice)
        amt1 = total1 * weights[i] // provider.rate(asset)
        amt2 = total2 * weights[i] // provider.rate(asset)
        amts1.append(amt1)
        amts2.append(amt2)
        asset.mint(alice, amt1 + amt2, sender=alice)
    pool.add_liquidity(amts1, 0, sender=alice)

    # second small deposit
    with chain.isolate():
        # baseline: no fee
        pool.add_liquidity(amts2, 0, bob, sender=alice)
        bal_no_fee = token.balanceOf(bob)
    
    # set a fee
    pool.set_swap_fee_rate(PRECISION // 10, sender=deployer) # 10%
    exp = estimator.get_add_lp(amts2)
    pool.add_liquidity(amts2, 0, bob, sender=alice)
    bal = token.balanceOf(bob)
    assert bal == exp
    
    # balanced deposits arent charged anything
    assert abs(bal - bal_no_fee) / bal_no_fee < 1e-16

def test_fee(chain, deployer, alice, bob, token, weights, pool, estimator):
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

    # second small deposit
    amt = PRECISION * PRECISION // provider.rate(assets[0])
    assets[0].mint(alice, amt, sender=alice)
    amts = [amt if i == 0 else 0 for i in range(n)]
    with chain.isolate():
        # baseline: no fee
        pool.add_liquidity(amts, 0, bob, sender=alice)
        bal_no_fee = token.balanceOf(bob)
    
    # set a fee
    pool.set_swap_fee_rate(PRECISION // 10, sender=deployer) # 10%
    exp = estimator.get_add_lp(amts)
    pool.add_liquidity(amts, 0, bob, sender=alice)
    bal = token.balanceOf(bob)
    assert bal == exp
    
    # single sided deposit is charged half of the fee
    rate = abs(bal - bal_no_fee) / bal_no_fee
    exp = 1/20
    assert abs(rate - exp) / exp < 1e-4

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

    # rate update of each asset, followed by a single sided deposit
    factor = 1.01
    for i in range(n):
        asset = assets[i]
        amts = [PRECISION if j == i else 0 for j in range(n)]
        asset.mint(alice, PRECISION, sender=alice)
        with chain.isolate():
            pool.add_liquidity(amts, 0, bob, sender=alice)
            base = token.balanceOf(bob)

        with chain.isolate():
            provider.set_rate(asset, int(provider.rate(asset) * factor), sender=alice)

            # add liquidity after rate increase
            exp = estimator.get_add_lp(amts)
            pool.add_liquidity(amts, 0, bob, sender=alice)
            bal = token.balanceOf(bob)
            assert bal == exp

            # staking address received rewards
            exp2 = int(total * weights[i] // PRECISION*(factor-1))
            bal2 = token.balanceOf(deployer)
            assert bal2 < exp2
            assert abs(bal2 - exp2) / exp2 < 1e-3

        # the rate update brought pool out of balance so increase in lp tokens is less than `factor`
        assert bal > base
        bal_factor = bal / base
        assert bal_factor < factor
        assert abs(bal_factor - factor) / factor < 1e-3

def test_ramp_weight(chain, deployer, alice, bob, token, weights, pool, estimator):
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

    assets[1].mint(alice, PRECISION, sender=alice)
    assets[2].mint(alice, PRECISION, sender=alice)

    with chain.isolate():
        pool.add_liquidity([PRECISION if i == 1 else 0 for i in range(n)], 0, bob, sender=alice)
        base_1 = token.balanceOf(bob)
    with chain.isolate():
        pool.add_liquidity([PRECISION if i == 2 else 0 for i in range(n)], 0, bob, sender=alice)
        base_2 = token.balanceOf(bob)

    amplification = pool.amplification()
    weights2 = weights
    weights2[1] += PRECISION // 10
    with ape.reverts():
        # weights have to sum up to 1
        pool.set_ramp(amplification, weights2, WEEK_LENGTH, sender=deployer)
    weights2[2] -= PRECISION // 10

    ts = chain.pending_timestamp
    pool.set_ramp(amplification, weights2, WEEK_LENGTH, sender=deployer)

    # halfway ramp
    chain.pending_timestamp = ts + WEEK_LENGTH // 2
    amts = [PRECISION if i == 1 else 0 for i in range(n)]
    with chain.isolate():
        chain.mine()
        exp = estimator.get_add_lp(amts)
    with chain.isolate():
        pool.add_liquidity(amts, 0, bob, sender=alice)
        mid_1 = token.balanceOf(bob)
        assert abs(mid_1 - exp) <= 2 # TODO
    amts = [PRECISION if i == 2 else 0 for i in range(n)]
    with chain.isolate():
        chain.mine()
        exp = estimator.get_add_lp(amts)
    with chain.isolate():
        pool.add_liquidity(amts, 0, bob, sender=alice)
        mid_2 = token.balanceOf(bob)
        assert abs(mid_2 - exp) <= 21 # TODO
    
    # asset 1 share is below weight -> bonus
    assert mid_1 > base_1
    # asset 2 share is above weight -> penalty
    assert mid_2 < base_2

    # end of ramp
    chain.pending_timestamp = ts + WEEK_LENGTH
    amts = [PRECISION if i == 1 else 0 for i in range(n)]
    with chain.isolate():
        chain.mine()
        exp = estimator.get_add_lp(amts)
    with chain.isolate():
        pool.add_liquidity(amts, 0, bob, sender=alice)
        end_1 = token.balanceOf(bob)
        assert abs(end_1 - exp) <= 21 # TODO
    amts = [PRECISION if i == 2 else 0 for i in range(n)]
    with chain.isolate():
        chain.mine()    
        exp = estimator.get_add_lp(amts)
    with chain.isolate():
        pool.add_liquidity(amts, 0, bob, sender=alice)
        end_2 = token.balanceOf(bob)
        assert abs(end_2 - exp) <= 17 # TODO
    
    # asset 1 share is more below weight -> bigger bonus
    assert end_1 > mid_1

    # asset 2 share is more above weight -> bigger penalty
    assert end_2 < mid_2

def test_ramp_amplification(chain, deployer, alice, bob, token, weights, pool, estimator):
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

    amt = 10 * PRECISION
    assets[1].mint(alice, amt, sender=alice)

    with chain.isolate():
        pool.add_liquidity([amt if i == 1 else 0 for i in range(n)], 0, bob, sender=alice)
        base = token.balanceOf(bob)

    amplification = 10 * pool.amplification()
    ts = chain.pending_timestamp
    pool.set_ramp(amplification, weights, WEEK_LENGTH, sender=deployer)

    # halfway ramp
    chain.pending_timestamp = ts + WEEK_LENGTH // 2
    amts = [amt if i == 1 else 0 for i in range(n)]
    with chain.isolate():
        chain.mine()
        exp = estimator.get_add_lp(amts)
    with chain.isolate():
        pool.add_liquidity(amts, 0, bob, sender=alice)
        mid = token.balanceOf(bob)
        assert abs(mid - exp) <= 16 # TODO
    
    # higher amplification -> lower penalty
    assert mid > base

    # end of ramp
    chain.pending_timestamp = ts + WEEK_LENGTH
    amts = [amt if i == 1 else 0 for i in range(n)]
    with chain.isolate():
        chain.mine()
        exp = estimator.get_add_lp(amts)
    with chain.isolate():
        pool.add_liquidity(amts, 0, bob, sender=alice)
        end = token.balanceOf(bob)
        assert abs(end - exp) <= 6 # TODO
    
    # even lower penalty
    assert end > mid

def test_band(chain, deployer, alice, bob, weights, pool, estimator):
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

    amt = total * PRECISION * 21 // 100 // provider.rate(assets[3]) # +10.4% after deposit
    amts = [amt if i == 3 else 0 for i in range(n)]
    assets[3].mint(alice, amt, sender=alice)

    # deposit will work before setting a band
    with chain.isolate():
        estimator.get_add_lp(amts)
        pool.add_liquidity(amts, 0, bob, sender=alice)

    # set band
    pool.set_weight_bands([3], [PRECISION], [PRECISION // 10], sender=deployer)

    # deposit wont work
    with ape.reverts():
        estimator.get_add_lp(amts)
    with ape.reverts():
        pool.add_liquidity(amts, 0, bob, sender=alice)

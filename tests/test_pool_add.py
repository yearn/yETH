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

    with ape.reverts(dev_message='dev: slippage'):
        # slippage protection
        pool.add_liquidity(amts, 2 * total, sender=alice)

    # add liquidity
    ret = pool.add_liquidity(amts, 0, bob, sender=alice).return_value
    bal = token.balanceOf(bob)
    assert ret == bal
    assert abs(total - bal) / total < 2e-16 # precision
    assert token.totalSupply() == bal
    assert pool.supply() == bal
    assert abs(pool.vb_prod_sum()[1] - total) <= 4 # rounding

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
    assert abs(pool.vb_prod_sum()[1] - total1 - total2) <= 4

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
    ampl = PRECISION
    act = estimator.get_effective_amplification()
    tar = estimator.get_effective_target_amplification()
    assert abs(act - ampl) / ampl < 5e-16
    assert act == tar

    assets[1].mint(alice, PRECISION, sender=alice)
    assets[2].mint(alice, PRECISION, sender=alice)

    with chain.isolate():
        pool.add_liquidity([PRECISION if i == 1 else 0 for i in range(n)], 0, bob, sender=alice)
        base_1 = token.balanceOf(bob)
    with chain.isolate():
        pool.add_liquidity([PRECISION if i == 2 else 0 for i in range(n)], 0, bob, sender=alice)
        base_2 = token.balanceOf(bob)

    weights2 = weights
    weights2[1] += PRECISION // 10
    with ape.reverts(dev_message='dev: weights dont add up'):
        # weights have to sum up to 1
        pool.set_ramp(calc_w_prod(weights2), weights2, WEEK_LENGTH, sender=deployer)
    weights2[2] -= PRECISION // 10

    ts = chain.pending_timestamp
    pool.set_ramp(calc_w_prod(weights2), weights2, WEEK_LENGTH, sender=deployer)

    # estimator calculates correct target amplification
    tar = estimator.get_effective_target_amplification()
    assert abs(tar - ampl) / ampl < 3e-16
    
    # halfway ramp
    chain.pending_timestamp = ts + WEEK_LENGTH // 2
    amts = [PRECISION if i == 1 else 0 for i in range(n)]
    with chain.isolate():
        chain.mine()
        exp = estimator.get_add_lp(amts)
        ampl_mid = estimator.get_effective_amplification()
    chain.pending_timestamp = ts + WEEK_LENGTH // 2
    with chain.isolate():
        pool.add_liquidity(amts, 0, bob, sender=alice)
        mid_1 = token.balanceOf(bob)
        assert abs(mid_1 - exp) <= 5
    amts = [PRECISION if i == 2 else 0 for i in range(n)]
    chain.pending_timestamp = ts + WEEK_LENGTH // 2
    with chain.isolate():
        chain.mine()
        exp = estimator.get_add_lp(amts)
    chain.pending_timestamp = ts + WEEK_LENGTH // 2
    with chain.isolate():
        pool.add_liquidity(amts, 0, bob, sender=alice)
        mid_2 = token.balanceOf(bob)
        assert abs(mid_2 - exp) <= 21
    
    # asset 1 share is below weight -> bonus
    assert mid_1 > base_1
    # asset 2 share is above weight -> penalty
    assert mid_2 < base_2

    # effective amplification changes slightly during ramp
    assert abs(ampl_mid - ampl) / ampl < 0.04

    # end of ramp
    chain.pending_timestamp = ts + WEEK_LENGTH
    amts = [PRECISION if i == 1 else 0 for i in range(n)]
    with chain.isolate():
        chain.mine()
        exp = estimator.get_add_lp(amts)
        ampl_end = estimator.get_effective_amplification()
    chain.pending_timestamp = ts + WEEK_LENGTH
    with chain.isolate():
        pool.add_liquidity(amts, 0, bob, sender=alice)
        end_1 = token.balanceOf(bob)
        assert abs(end_1 - exp) <= 21
    amts = [PRECISION if i == 2 else 0 for i in range(n)]
    chain.pending_timestamp = ts + WEEK_LENGTH
    with chain.isolate():
        chain.mine()    
        exp = estimator.get_add_lp(amts)
    chain.pending_timestamp = ts + WEEK_LENGTH
    with chain.isolate():
        pool.add_liquidity(amts, 0, bob, sender=alice)
        end_2 = token.balanceOf(bob)
        assert abs(end_2 - exp) <= 18
    
    # asset 1 share is more below weight -> bigger bonus
    assert end_1 > mid_1

    # asset 2 share is more above weight -> bigger penalty
    assert end_2 < mid_2

    # effective amplification is back to expected value after ramp
    assert abs(ampl_end - ampl) / ampl < 3e-16

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

    ampl = 10 * PRECISION
    ts = chain.pending_timestamp
    pool.set_ramp(10 * pool.amplification(), weights, WEEK_LENGTH, sender=deployer)

    tar = estimator.get_effective_target_amplification()
    assert abs(tar - ampl) / ampl < 5e-16

    # halfway ramp
    exp_half = (ampl + PRECISION) // 2
    chain.pending_timestamp = ts + WEEK_LENGTH // 2
    amts = [amt if i == 1 else 0 for i in range(n)]
    with chain.isolate():
        chain.mine()
        exp = estimator.get_add_lp(amts)
        ampl_half = estimator.get_effective_amplification()
    chain.pending_timestamp = ts + WEEK_LENGTH // 2
    with chain.isolate():
        pool.add_liquidity(amts, 0, bob, sender=alice)
        mid = token.balanceOf(bob)
        assert abs(mid - exp) <= 16
    
    # higher amplification -> lower penalty
    assert mid > base

    # effective amplification is in between begin and target
    assert abs(ampl_half - exp_half) / exp_half < 5e-16

    # end of ramp
    chain.pending_timestamp = ts + WEEK_LENGTH
    amts = [amt if i == 1 else 0 for i in range(n)]
    with chain.isolate():
        chain.mine()
        exp = estimator.get_add_lp(amts)
        ampl_end = estimator.get_effective_amplification()
    chain.pending_timestamp = ts + WEEK_LENGTH
    with chain.isolate():
        pool.add_liquidity(amts, 0, bob, sender=alice)
        end = token.balanceOf(bob)
        assert abs(end - exp) <= 9
    
    # even lower penalty
    assert end > mid

    # effective amplification is equal to target
    assert abs(ampl_end - ampl) / ampl < 5e-16

def test_ramp_commutative(project, deployer, alice, bob, token, weights, pool):
    # check that deposit + weight ramp = weight + deposit
    assets, provider, pool = pool
    
    # mint assets
    n = len(assets)
    amts = [12 * PRECISION, 25 * PRECISION, 27 * PRECISION, 36 * PRECISION]
    for i in range(n):
        asset = assets[i]
        asset.approve(pool, MAX, sender=alice)
        amts[i] = amts[i] * PRECISION // provider.rate(asset)
        asset.mint(alice, amts[i], sender=alice)

    # deposit
    pool.add_liquidity(amts, 0, deployer, sender=alice)

    # ramp
    weights = [PRECISION * 15 // 100, PRECISION * 30 // 100, PRECISION * 20 // 100, PRECISION * 35 // 100]
    pool.set_ramp(calc_w_prod(weights), weights, 0, sender=deployer)
    pool.update_weights(sender=alice)
    bal = token.balanceOf(deployer)
    vb_prod, vb_sum = pool.vb_prod_sum()

    # second pool that has the weights from the start
    pool2 = project.Pool.deploy(token, calc_w_prod(weights), assets, [provider for _ in range(len(weights))], weights, sender=deployer)
    pool2.set_staking(deployer, sender=deployer)
    token.set_minter(pool2, sender=deployer)

    for i in range(n):
        asset = assets[i]
        asset.approve(pool2, MAX, sender=alice)
        asset.mint(alice, amts[i], sender=alice)

    pool2.add_liquidity(amts, 0, sender=alice)
    bal2 = token.balanceOf(alice)
    vb_prod2, vb_sum2 = pool2.vb_prod_sum()

    assert abs(bal - bal2) / bal2 < 2e-18
    assert abs(vb_prod - vb_prod2) / vb_prod2 < 3e-18
    assert vb_sum == vb_sum2

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
    with ape.reverts(dev_message='dev: ratio above upper band'):
        pool.add_liquidity(amts, 0, bob, sender=alice)

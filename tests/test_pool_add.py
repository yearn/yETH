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

def test_initial_deposit(alice, bob, token, weights, pool):
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

def test_multiple_deposit(alice, bob, token, weights, pool, estimator):
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

def test_single_sided_deposit(chain, alice, bob, token, weights, pool, estimator):
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

def test_deposit_bonus(alice, bob, token, weights, pool, estimator):
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

def test_balanced_deposit_fee(chain, deployer, alice, bob, token, weights, pool, estimator):
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
    pool.set_fee_rate(PRECISION // 10, sender=deployer) # 10%
    pool.add_liquidity(amts2, 0, bob, sender=alice)
    bal = token.balanceOf(bob)
    
    # balanced deposits arent charged anything
    assert abs(bal - bal_no_fee) / bal_no_fee < 1e-16

def test_deposit_fee(chain, deployer, alice, bob, token, weights, pool, estimator):
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
    pool.set_fee_rate(PRECISION // 10, sender=deployer) # 10%
    pool.add_liquidity(amts, 0, bob, sender=alice)
    bal = token.balanceOf(bob)
    
    rate = abs(bal - bal_no_fee) / bal_no_fee
    
    # single sided deposit is charged half of the fee
    exp = 1/20
    assert abs(rate - exp) / exp < 1e-4

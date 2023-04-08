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

def test_round_trip(alice, bob, token, weights, pool, estimator):
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
    pool.add_liquidity(amts, 0, bob, sender=alice)

    vb_prod, vb_sum = pool.vb_prod_sum()

    for i in range(n):
        asset = assets[i]
        amts[i] = amts[i] // 100
        asset.mint(alice, amts[i], sender=alice)
    pool.add_liquidity(amts, 0, alice, sender=alice)
    lp = token.balanceOf(alice)

    # slippage check
    for i in range(n):
        with ape.reverts():
            pool.remove_liquidity(lp, [amts[i] if i == j else 0 for j in range(n)], bob, sender=alice)

    exp = estimator.get_remove_lp(lp)

    pool.remove_liquidity(lp, [0 for _ in range(n)], bob, sender=alice)
    for i in range(n):
        # rounding in favor of pool
        amt = amts[i]
        amt2 = assets[i].balanceOf(bob)
        assert amt2 < amt
        assert amt2 == exp[i]
        assert abs(amt2 - amt) / amt < 3e-14

    vb_prod2, vb_sum2 = pool.vb_prod_sum()
    assert abs(vb_prod2 - vb_prod) / vb_prod < 1e-15
    assert abs(vb_sum2 - vb_sum) / vb_sum < 1e-15

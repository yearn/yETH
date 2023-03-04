from ape.utils import to_int
import pytest

PRECISION = 1_000_000_000_000_000_000
MAX = 2**256 - 1
W_PROD_SLOT = 41
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

def test_equal_balanced_deposit(project, deployer, alice, token):
    # multiple tokens with equal weights, balanced initial deposit
    amplification = 10 * PRECISION
    n = 4
    assets, provider = deploy_assets(project, deployer, n)
    pool = project.Pool.deploy(token, amplification, assets, [provider for _ in range(n)], [PRECISION//n for _ in range(n)], sender=deployer)
    token.set_minter(pool, sender=deployer)

    amt = n * 100 * PRECISION
    for asset in assets:
        asset.approve(pool, MAX, sender=alice)
        asset.mint(alice, amt // n, sender=deployer)

    pool.add_liquidity(assets, [amt // n for _ in range(n)], 0, sender=alice)
    bal = token.balanceOf(alice)
    assert bal < amt and (amt - bal) / amt < 1e-16

def test_equal_imbalanced_deposit(project, chain, deployer, alice, bob, token):
    # multiple tokens with equal weights, imbalanced initial deposit
    amplification = 10 * PRECISION
    n = 4
    assets, provider = deploy_assets(project, deployer, n)
    pool = project.Pool.deploy(token, amplification, assets, [provider for _ in range(n)], [PRECISION//n for _ in range(n)], sender=deployer)
    token.set_minter(pool, sender=deployer)
    id = chain.snapshot()

    amt = 400 * PRECISION
    amts = [100 * PRECISION, 80 * PRECISION, 90 * PRECISION, 130 * PRECISION]
    for i in range(len(assets)):
        asset = assets[i]
        asset.approve(pool, MAX, sender=alice)
        asset.mint(alice, amts[i], sender=deployer)

    pool.add_liquidity(assets, amts, 0, sender=alice)
    bal = token.balanceOf(alice)
    assert bal < amt # small penalty
    assert (amt - bal) / amt < 1e-4 # 0.01%

    # second deposit that equalizes balances
    amt2 = 200 * PRECISION
    amts2 = [50 * PRECISION, 70 * PRECISION, 60 * PRECISION, 20 * PRECISION]
    for i in range(len(assets)):
        asset = assets[i]
        asset.approve(pool, MAX, sender=bob)
        asset.mint(bob, amts2[i], sender=deployer)
    pool.add_liquidity(assets, amts2, 0, sender=bob)
    bal2 = token.balanceOf(bob)
    assert bal2 > amt2 # small bonus
    assert (bal2 - amt2) / amt2 < 1e-4 # 0.01%

    # because pool is now in balance, supply is equal to sum of balances
    amt_sum = amt + amt2
    supply = pool.supply()
    assert supply <= amt_sum
    assert (amt_sum - supply)/amt_sum < 1e-16

    vb_prod = to_int(project.provider.get_storage_at(pool.address, VB_PROD_SLOT))
    vb_sum = to_int(project.provider.get_storage_at(pool.address, VB_SUM_SLOT))

    # if we do a balanced deposit at once instead, everything should match
    chain.restore(id)

    amts3 = [150 * PRECISION, 150 * PRECISION, 150 * PRECISION, 150 * PRECISION]
    for i in range(len(assets)):
        asset = assets[i]
        asset.approve(pool, MAX, sender=alice)
        asset.mint(alice, amts3[i], sender=deployer)
    pool.add_liquidity(assets, amts3, 0, sender=alice)

    vb_prod2 = to_int(project.provider.get_storage_at(pool.address, VB_PROD_SLOT))
    vb_sum2 = to_int(project.provider.get_storage_at(pool.address, VB_SUM_SLOT))
    supply2 = pool.supply()
    assert abs((vb_prod2 - vb_prod) / vb_prod) < 1e-13
    assert vb_sum == vb_sum2
    assert abs((supply2 - supply)/supply) < 1e-16

def test_weighted_balanced_deposit(project, deployer, alice, bob, token):
    # multiple tokens with inequal weights, balanced initial deposit
    amplification = 10 * PRECISION
    n = 4
    assets, provider = deploy_assets(project, deployer, n)
    weights = [PRECISION*1//10, PRECISION*2//10, PRECISION*3//10, PRECISION*4//10]
    pool = project.Pool.deploy(token, amplification, assets, [provider for _ in range(n)], weights, sender=deployer)
    token.set_minter(pool, sender=deployer)

    # balanced initial deposit
    amt = 1_000_000 * PRECISION
    amts = [amt * w // PRECISION for w in weights]
    for i in range(len(assets)):
        asset = assets[i]
        asset.approve(pool, MAX, sender=alice)
        asset.mint(alice, amts[i], sender=deployer)

    pool.add_liquidity(assets, amts, 0, sender=alice)
    bal = token.balanceOf(alice)
    assert bal < amt
    assert (amt - bal) / amt < 1e-16
    assert pool.supply() == bal

    # balanced second deposit
    amt =  1000 * PRECISION
    amts = [amt * w // PRECISION for w in weights]
    for i in range(len(assets)):
        asset = assets[i]
        asset.approve(pool, MAX, sender=bob)
        asset.mint(bob, amts[i], sender=deployer)
    pool.add_liquidity(assets, amts, 0, sender=bob)

    bal = token.balanceOf(bob)
    assert bal < amt
    assert (amt - bal) / amt < 1e-13

def test_exchange(project, deployer, alice, bob, token):
    amplification = 10 * PRECISION
    n = 4
    assets, provider = deploy_assets(project, deployer, n)
    pool = project.Pool.deploy(token, amplification, assets, [provider for _ in range(n)], [PRECISION//n for _ in range(n)], sender=deployer)
    token.set_minter(pool, sender=deployer)

    amt = n * 100 * PRECISION
    for asset in assets:
        asset.approve(pool, MAX, sender=alice)
        asset.mint(alice, amt // n, sender=deployer)
    pool.add_liquidity(assets, [amt // n for _ in range(n)], 0, sender=alice)

    vb_prod = to_int(project.provider.get_storage_at(pool.address, VB_PROD_SLOT))
    vb_sum = to_int(project.provider.get_storage_at(pool.address, VB_SUM_SLOT))

    # bob swaps asset 0 for asset 1
    swap = 10 * PRECISION
    assets[0].approve(pool, MAX, sender=bob)
    assets[0].mint(bob, swap, sender=deployer)
    pool.exchange(assets[0], assets[1], swap, 0, sender=bob)
    bal = assets[1].balanceOf(bob)
    assert bal < swap
    # small penalty because pool is brought out of balance
    assert (swap - bal) / swap < 1e-3

    # bob swaps back and receives ~ his original amount back
    assets[1].approve(pool, MAX, sender=bob)
    pool.exchange(assets[1], assets[0], bal, 0, sender=bob)
    bal2 = assets[0].balanceOf(bob)
    assert bal2 > bal
    assert bal2 < swap # rounding is in favor of pool
    assert abs((swap - bal2) / swap) < 1e-15

    vb_prod2 = to_int(project.provider.get_storage_at(pool.address, VB_PROD_SLOT))
    vb_sum2 = to_int(project.provider.get_storage_at(pool.address, VB_SUM_SLOT))

    assert abs((vb_prod2 - vb_prod) / vb_prod) < 2e-14
    assert vb_sum2 > vb_sum
    assert (vb_sum2 - vb_sum) / vb_sum < 1e-17

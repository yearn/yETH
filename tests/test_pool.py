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

    amt = 100 * PRECISION
    for asset in assets:
        asset.approve(pool, MAX, sender=alice)
        asset.mint(alice, amt, sender=deployer)

    pool.add_liquidity(assets, [amt for _ in range(n)], 0, sender=alice)
    assert token.balanceOf(alice) == n * amt

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
    assert token.balanceOf(alice) < amt # small penalty
    assert 1 - token.balanceOf(alice)/amt < 0.0001 # 0.01%

    # second deposit that equalizes balances
    amt2 = 200 * PRECISION
    amts2 = [50 * PRECISION, 70 * PRECISION, 60 * PRECISION, 20 * PRECISION]
    for i in range(len(assets)):
        asset = assets[i]
        asset.approve(pool, MAX, sender=bob)
        asset.mint(bob, amts2[i], sender=deployer)
    pool.add_liquidity(assets, amts2, 0, sender=bob)
    assert token.balanceOf(bob) > amt2 # small bonus

    # because pool is now in balance, supply is equal to sum of balances
    amt_sum = amt + amt2
    assert abs(pool.supply() - amt_sum) < 10

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
    assert abs(vb_prod2 - vb_prod) < 100
    assert vb_sum == vb_sum2

def test_weighted_balanced_deposit(project, deployer, alice, bob, token, networks):
    # multiple tokens with inequal weights, balanced initial deposit
    amplification = 10 * PRECISION
    n = 4
    assets, provider = deploy_assets(project, deployer, n)
    weights = [PRECISION*1//10, PRECISION*2//10, PRECISION*3//10, PRECISION*4//10]
    pool = project.Pool.deploy(token, amplification, assets, [provider for _ in range(n)], weights, sender=deployer)
    token.set_minter(pool, sender=deployer)

    amt = 1_000_000 * PRECISION
    amts = [amt * w // PRECISION for w in weights]
    for i in range(len(assets)):
        asset = assets[i]
        asset.approve(pool, MAX, sender=alice)
        asset.mint(alice, amts[i], sender=deployer)

    pool.add_liquidity(assets, amts, 0, sender=alice)
    print(token.balanceOf(alice) / PRECISION)
    # print(token.balanceOf(alice) / amt - 1)
    # assert token.balanceOf(alice) / amt - 1 < 1e-9

    amt = PRECISION * 10
    assets[0].approve(pool, MAX, sender=bob)
    assets[0].mint(bob, amt, sender=deployer)
    pool.add_liquidity([assets[0]], [amt], 0, sender=bob)
    print(token.balanceOf(bob)/PRECISION)
    assert False

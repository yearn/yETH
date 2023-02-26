import pytest

PRECISION = 1_000_000_000_000_000_000
MAX = 2**256 - 1

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

def test_equal_imbalanced_deposit(project, deployer, alice, token):
    # multiple tokens with equal weights, imbalanced initial deposit
    amplification = 10 * PRECISION
    n = 4
    assets, provider = deploy_assets(project, deployer, n)
    pool = project.Pool.deploy(token, amplification, assets, [provider for _ in range(n)], [PRECISION//n for _ in range(n)], sender=deployer)
    token.set_minter(pool, sender=deployer)

    amt = 100 * PRECISION
    amts = [100 * PRECISION, 80 * PRECISION, 90 * PRECISION, 130 * PRECISION]
    for i in range(len(assets)):
        asset = assets[i]
        asset.approve(pool, MAX, sender=alice)
        asset.mint(alice, amts[i], sender=deployer)

    pool.add_liquidity(assets, amts, 0, sender=alice)
    assert token.balanceOf(alice) < n * amt
    assert 1 - token.balanceOf(alice)/n/amt < 0.0001 # 0.01%


def test_weighted_balanced_deposit(project, deployer, alice, bob, token):
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
    print(token.balanceOf(alice) / amt - 1)
    # assert token.balanceOf(alice) / amt - 1 < 1e-9

    amt = PRECISION * 10
    assets[0].approve(pool, MAX, sender=bob)
    assets[0].mint(bob, amt, sender=deployer)
    pool.add_liquidity([assets[0]], [amt], 0, sender=bob)
    print(token.balanceOf(bob)/PRECISION)
    assert False
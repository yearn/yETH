import math
import pytest

PRECISION = 1_000_000_000_000_000_000
MAX = 2**256 - 1
W_PROD_SLOT = 206
VB_PROD_SLOT = W_PROD_SLOT + 1
VB_SUM_SLOT = VB_PROD_SLOT + 1
DAY_LENGTH = 24 * 60 * 60
WEEK_LENGTH = 7 * DAY_LENGTH

@pytest.fixture
def deployer(accounts):
    return accounts[0]

@pytest.fixture
def alice(accounts):
    return accounts[1]

@pytest.fixture
def bob(accounts):
    return accounts[2]

def deploy_assets(project, deployer, n):
    assets = []
    provider = project.MockRateProvider.deploy(sender=deployer)
    for i in range(n):
        asset = project.MockToken.deploy(sender=deployer)
        provider.set_rate(asset, (i + 2) * PRECISION, sender=deployer)
        assets.append(asset)
    return assets, provider

def calc_w_prod(weights):
    prod = PRECISION
    n = len(weights)
    for w in weights:
        prod = int(prod / math.pow(w / PRECISION, w * n / PRECISION))
    return prod

from ape.utils import to_int
import pytest

PRECISION = 1_000_000_000_000_000_000
MAX = 2**256 - 1
W_PROD_SLOT = 43
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

    pool.add_liquidity([amt // n for _ in range(n)], 0, sender=alice)
    bal = token.balanceOf(alice)
    assert bal < amt
    assert (amt - bal) / amt < 2e-16
    vb_sum = to_int(project.provider.get_storage_at(pool.address, VB_SUM_SLOT))
    assert vb_sum == amt

def test_equal_balanced_deposit_fee(project, deployer, alice, bob, token):
    # multiple tokens with equal weights, balanced initial deposit
    amplification = 10 * PRECISION
    n = 4
    assets, provider = deploy_assets(project, deployer, n)
    pool = project.Pool.deploy(token, amplification, assets, [provider for _ in range(n)], [PRECISION//n for _ in range(n)], sender=deployer)
    pool.set_staking(deployer, sender=deployer)
    pool.set_fee_rate(PRECISION // 10, sender=deployer)
    token.set_minter(pool, sender=deployer)

    amt = n * 100 * PRECISION
    for asset in assets:
        asset.approve(pool, MAX, sender=alice)
        asset.mint(alice, amt // n, sender=deployer)
        asset.approve(pool, MAX, sender=bob)
        asset.mint(bob, amt // n // 10, sender=deployer)

    pool.add_liquidity([amt // n for _ in range(n)], 0, sender=alice)
    bal = token.balanceOf(alice)
    assert bal < amt
    assert (amt - bal) / amt < 2e-16
    vb_sum = to_int(project.provider.get_storage_at(pool.address, VB_SUM_SLOT))
    assert vb_sum == amt

    # do another balanced deposit, no fee charged
    pool.add_liquidity([amt // n // 10 for _ in range(n)], 0, sender=bob)
    assert (bal - 10 * token.balanceOf(bob)) / bal < 1e-15

def test_withdraw_single(project, deployer, alice, bob, token):
    amplification = 10 * PRECISION
    n = 4
    assets, provider = deploy_assets(project, deployer, n)
    pool = project.Pool.deploy(token, amplification, assets, [provider for _ in range(n)], [PRECISION//n for _ in range(n)], sender=deployer)
    token.set_minter(pool, sender=deployer)

    amt = n * 100 * PRECISION
    for asset in assets:
        asset.approve(pool, MAX, sender=alice)
        asset.mint(alice, amt // n, sender=deployer)

    pool.add_liquidity([amt // n for _ in range(n)], 0, sender=alice)
    vb_prod = to_int(project.provider.get_storage_at(pool.address, VB_PROD_SLOT))
    vb_sum = to_int(project.provider.get_storage_at(pool.address, VB_SUM_SLOT))

    # add single sided liquidity
    amt = amt // n // 10
    assets[0].approve(pool, MAX, sender=bob)
    assets[0].mint(bob, amt, sender=bob)
    pool.add_liquidity([amt if i == 0 else 0 for i in range(n)], 0, sender=bob)

    # remove single sided liquidity
    pool.remove_liquidity_single(assets[0], token.balanceOf(bob), sender=bob)
    vb_prod2 = to_int(project.provider.get_storage_at(pool.address, VB_PROD_SLOT))
    vb_sum2 = to_int(project.provider.get_storage_at(pool.address, VB_SUM_SLOT))

    bal = assets[0].balanceOf(bob)
    assert amt > bal
    assert (amt - bal) / amt < 1e-14
    assert abs(vb_sum2 - vb_sum) / vb_sum < 2e-16
    assert abs(vb_prod2 - vb_prod) / vb_prod < 1e-14

def test_deposit_fee(project, chain, deployer, alice, bob, token):
    amplification = PRECISION
    n = 4
    assets, provider = deploy_assets(project, deployer, n)
    pool = project.Pool.deploy(token, amplification, assets, [provider for _ in range(n)], [PRECISION//n for _ in range(n)], sender=deployer)
    token.set_minter(pool, sender=deployer)

    amt = 100 * PRECISION
    for i in range(n):
        asset = assets[i]
        asset.approve(pool, MAX, sender=alice)
        asset.mint(alice, amt, sender=deployer)
    pool.add_liquidity([amt for _ in range(n)], 0, sender=alice)

    swap_amt = amt//100
    assets[0].approve(pool, MAX, sender=bob)
    assets[0].mint(bob, swap_amt, sender=deployer)

    # add and remove single sided liquidity without fee
    id = chain.snapshot()
    pool.add_liquidity([swap_amt if i == 0 else 0 for i in range(n)], 0, sender=bob)
    pool.remove_liquidity_single(assets[1], token.balanceOf(bob), sender=bob)
    full_amt = assets[1].balanceOf(bob)
    chain.restore(id)

    fee_rate = PRECISION // 100
    pool.set_staking(deployer, sender=deployer)
    pool.set_fee_rate(fee_rate, sender=deployer) # 1%

    # add and remove single sided liquidity with fee
    pool.add_liquidity([swap_amt if i == 0 else 0 for i in range(n)], 0, sender=bob)
    pool.remove_liquidity_single(assets[1], token.balanceOf(bob), sender=bob)
    out_amt = assets[1].balanceOf(bob)
    actual_fee_rate = (full_amt - out_amt) * PRECISION / full_amt
    assert abs(fee_rate - actual_fee_rate) / fee_rate < 0.01

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

    pool.add_liquidity(amts, 0, sender=alice)
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
    pool.add_liquidity(amts2, 0, sender=bob)
    bal2 = token.balanceOf(bob)
    assert bal2 > amt2 # small bonus
    assert (bal2 - amt2) / amt2 < 1e-4 # 0.01%

    # because pool is now in balance, supply is equal to sum of balances
    amt_sum = amt + amt2
    supply = bal + bal2
    assert supply <= amt_sum
    assert abs(amt_sum - supply)/amt_sum < 2e-16

    vb_prod = to_int(project.provider.get_storage_at(pool.address, VB_PROD_SLOT))
    vb_sum = to_int(project.provider.get_storage_at(pool.address, VB_SUM_SLOT))

    # if we do a balanced deposit at once instead, everything should match
    chain.restore(id)

    amts3 = [150 * PRECISION, 150 * PRECISION, 150 * PRECISION, 150 * PRECISION]
    for i in range(len(assets)):
        asset = assets[i]
        asset.approve(pool, MAX, sender=alice)
        asset.mint(alice, amts3[i], sender=deployer)
    pool.add_liquidity(amts3, 0, sender=alice)

    vb_prod2 = to_int(project.provider.get_storage_at(pool.address, VB_PROD_SLOT))
    vb_sum2 = to_int(project.provider.get_storage_at(pool.address, VB_SUM_SLOT))
    supply2 = pool.supply()
    assert abs((vb_prod2 - vb_prod) / vb_prod) < 1e-13
    assert abs((vb_sum2 - vb_sum) / vb_sum) < 1e-13
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
    amt = 10_000_000 * PRECISION
    amts = [amt * w // PRECISION for w in weights]
    for i in range(len(assets)):
        asset = assets[i]
        asset.approve(pool, MAX, sender=alice)
        asset.mint(alice, amts[i], sender=deployer)

    pool.add_liquidity(amts, 0, sender=alice)
    bal = token.balanceOf(alice)
    assert bal < amt
    assert (amt - bal) / amt < 2e-14
    assert pool.supply() == bal

    # balanced second deposit
    amt =  1000 * PRECISION
    amts = [amt * w // PRECISION for w in weights]
    for i in range(len(assets)):
        asset = assets[i]
        asset.approve(pool, MAX, sender=bob)
        asset.mint(bob, amts[i], sender=deployer)
    pool.add_liquidity(amts, 0, sender=bob)

    bal = token.balanceOf(bob)
    assert bal < amt
    assert (amt - bal) / amt < 1e-13

def test_swap(project, deployer, alice, bob, token):
    amplification = 10 * PRECISION
    n = 4
    assets, provider = deploy_assets(project, deployer, n)
    pool = project.Pool.deploy(token, amplification, assets, [provider for _ in range(n)], [PRECISION//n for _ in range(n)], sender=deployer)
    token.set_minter(pool, sender=deployer)

    amt = n * 100 * PRECISION
    for asset in assets:
        asset.approve(pool, MAX, sender=alice)
        asset.mint(alice, amt // n, sender=deployer)
    pool.add_liquidity([amt // n for _ in range(n)], 0, sender=alice)

    vb_prod = to_int(project.provider.get_storage_at(pool.address, VB_PROD_SLOT))
    vb_sum = to_int(project.provider.get_storage_at(pool.address, VB_SUM_SLOT))

    # swap asset 0 for asset 1
    swap = 10 * PRECISION
    assets[0].approve(pool, MAX, sender=bob)
    assets[0].mint(bob, swap, sender=deployer)
    expect = pool.get_dy(assets[0], assets[1], swap)
    pool.swap(assets[0], assets[1], swap, 0, sender=bob)
    assert assets[0].balanceOf(bob) == 0
    bal = assets[1].balanceOf(bob)
    assert bal == expect
    assert bal < swap
    # small penalty because pool is brought out of balance
    assert (swap - bal) / swap < 1e-3

    # swap back and receive ~ original amount back
    assets[1].approve(pool, MAX, sender=bob)
    pool.swap(assets[1], assets[0], bal, 0, sender=bob)
    bal2 = assets[0].balanceOf(bob)
    assert bal2 > bal
    assert bal2 < swap # rounding is in favor of pool
    assert (swap - bal2) / swap < 1e-14

    vb_prod2 = to_int(project.provider.get_storage_at(pool.address, VB_PROD_SLOT))
    vb_sum2 = to_int(project.provider.get_storage_at(pool.address, VB_SUM_SLOT))

    assert abs((vb_prod2 - vb_prod) / vb_prod) < 1e-13
    assert vb_sum2 > vb_sum
    assert (vb_sum2 - vb_sum) / vb_sum < 2e-14

def test_swap_fee(project, chain, deployer, alice, bob, token):
    amplification = 10 * PRECISION
    n = 4
    assets, provider = deploy_assets(project, deployer, n)
    pool = project.Pool.deploy(token, amplification, assets, [provider for _ in range(n)], [PRECISION//n for _ in range(n)], sender=deployer)
    token.set_minter(pool, sender=deployer)

    amts = [170 * PRECISION, 50 * PRECISION, 20 * PRECISION, 160 * PRECISION]
    for i in range(n):
        asset = assets[i]
        asset.approve(pool, MAX, sender=alice)
        asset.mint(alice, amts[i], sender=deployer)
    pool.add_liquidity(amts, 0, sender=alice)

    # swap without a fee
    swap = 10 * PRECISION
    assets[0].approve(pool, MAX, sender=bob)
    assets[0].mint(bob, swap, sender=deployer)

    id = chain.snapshot()
    expect = pool.get_dy(assets[0], assets[1], swap)
    pool.swap(assets[0], assets[1], swap, 0, sender=bob)
    full_out = assets[1].balanceOf(bob)
    assert full_out == expect
    chain.restore(id)

    # swap with fee
    fee_rate = PRECISION * 3 // 1000 # 10%
    pool.set_staking(deployer, sender=deployer)
    pool.set_fee_rate(fee_rate, sender=deployer)
    
    expect = pool.get_dy(assets[0], assets[1], swap)
    pool.swap(assets[0], assets[1], swap, 0, sender=bob)
    out = assets[1].balanceOf(bob)
    assert out == expect
    actual_fee_rate = (full_out - out) * PRECISION // full_out
    # fee is charged on input so not exact on output
    assert abs(fee_rate - actual_fee_rate) / fee_rate < 0.01

def test_swap_exact_out(project, deployer, alice, bob, token):
    amplification = 10 * PRECISION
    n = 4
    assets, provider = deploy_assets(project, deployer, n)
    pool = project.Pool.deploy(token, amplification, assets, [provider for _ in range(n)], [PRECISION//n for _ in range(n)], sender=deployer)
    token.set_minter(pool, sender=deployer)

    amt = n * 100 * PRECISION
    for asset in assets:
        asset.approve(pool, MAX, sender=alice)
        asset.mint(alice, amt // n, sender=deployer)
    pool.add_liquidity([amt // n for _ in range(n)], 0, sender=alice)

    vb_prod = to_int(project.provider.get_storage_at(pool.address, VB_PROD_SLOT))
    vb_sum = to_int(project.provider.get_storage_at(pool.address, VB_SUM_SLOT))

    # swap asset 0 for asset 1
    swap = 10 * PRECISION
    assets[0].approve(pool, MAX, sender=bob)
    assets[0].mint(bob, 2 * swap, sender=deployer)
    expect = pool.get_dx(assets[0], assets[1], swap)
    pool.swap_exact_out(assets[0], assets[1], swap, MAX, sender=bob)
    assert assets[1].balanceOf(bob) == swap
    amt = 2 * swap - assets[0].balanceOf(bob)
    assert amt == expect
    assert amt > swap
    # small penalty because pool is brought out of balance
    assert (amt - swap) / swap < 1e-3

    # reset balance to simplify calculations
    assets[1].burn(bob, assets[1].balanceOf(bob), sender=deployer)
    assets[1].mint(bob, 2 * swap, sender=deployer)

    # swap back at a cost ~ previous swap output
    assets[1].approve(pool, MAX, sender=bob)
    pool.swap_exact_out(assets[1], assets[0], amt, MAX, sender=bob)
    assert assets[0].balanceOf(bob) == 2 * swap
    amt2 = 2 * swap - assets[1].balanceOf(bob)
    assert amt > amt2
    assert amt2 > swap # rounding is in favor of pool
    assert (amt2 - swap) / swap < 1e-14

    vb_prod2 = to_int(project.provider.get_storage_at(pool.address, VB_PROD_SLOT))
    vb_sum2 = to_int(project.provider.get_storage_at(pool.address, VB_SUM_SLOT))

    assert abs((vb_prod2 - vb_prod) / vb_prod) < 2e-14
    assert vb_sum2 > vb_sum
    assert (vb_sum2 - vb_sum) / vb_sum < 2e-14

def test_swap_exact_out_fee(project, chain, deployer, alice, bob, token):
    amplification = 10 * PRECISION
    n = 4
    fee_rate = PRECISION // 10 # 10%
    assets, provider = deploy_assets(project, deployer, n)
    pool = project.Pool.deploy(token, amplification, assets, [provider for _ in range(n)], [PRECISION//n for _ in range(n)], sender=deployer)
    token.set_minter(pool, sender=deployer)

    amt = n * 100 * PRECISION
    for asset in assets:
        asset.approve(pool, MAX, sender=alice)
        asset.mint(alice, amt // n, sender=deployer)
    pool.add_liquidity([amt // n for _ in range(n)], 0, sender=alice)

    # swap without a fee
    swap = 10 * PRECISION
    assets[0].approve(pool, MAX, sender=bob)
    assets[0].mint(bob, 2 * swap, sender=deployer)
    id = chain.snapshot()
    expect = pool.get_dx(assets[0], assets[1], swap)
    pool.swap_exact_out(assets[0], assets[1], swap, MAX, sender=bob)
    base_amt = 2 * swap - assets[0].balanceOf(bob)
    assert base_amt == expect
    exp_fee_amt = base_amt * PRECISION // (PRECISION - fee_rate) - base_amt

    # add expected fee as liquidity
    pool.add_liquidity([exp_fee_amt if i == 0 else 0 for i in range(n)], 0, sender=bob)
    exp_staking_bal = token.balanceOf(bob)

    vb_prod = to_int(project.provider.get_storage_at(pool.address, VB_PROD_SLOT))
    vb_sum = to_int(project.provider.get_storage_at(pool.address, VB_SUM_SLOT))

    # swap with fee
    chain.restore(id)
    pool.set_staking(deployer, sender=deployer)
    pool.set_fee_rate(fee_rate, sender=deployer)

    expect = pool.get_dx(assets[0], assets[1], swap)
    pool.swap_exact_out(assets[0], assets[1], swap, MAX, sender=bob)
    amt = 2 * swap - assets[0].balanceOf(bob)
    assert amt == expect
    fee_amt = amt - base_amt
    assert fee_amt == exp_fee_amt
    
    staking_bal = token.balanceOf(deployer)
    assert abs(staking_bal - exp_staking_bal) / exp_staking_bal < 2e-13

    # fee is charged on input token but paid in pool token, so amount is slightly less
    assert staking_bal < fee_amt
    assert (fee_amt - staking_bal) / fee_amt < 2e-4

    vb_prod2 = to_int(project.provider.get_storage_at(pool.address, VB_PROD_SLOT))
    vb_sum2 = to_int(project.provider.get_storage_at(pool.address, VB_SUM_SLOT))
    assert abs(vb_prod2 - vb_prod) / vb_prod < 1e-14
    assert vb_sum == vb_sum2

def test_rate_update(project, deployer, alice, token):
    amplification = 10 * PRECISION
    n = 4
    assets, provider = deploy_assets(project, deployer, n)
    pool = project.Pool.deploy(token, amplification, assets, [provider for _ in range(n)], [PRECISION//n for _ in range(n)], sender=deployer)
    pool.set_staking(deployer, sender=deployer)
    token.set_minter(pool, sender=deployer)

    # add some liquidity
    amt = n * 100 * PRECISION
    for asset in assets:
        asset.approve(pool, MAX, sender=alice)
        asset.mint(alice, amt // n, sender=deployer)
    pool.add_liquidity([amt // n for _ in range(n)], 0, sender=alice)

    # update rate of one asset to 110%
    provider.set_rate(assets[0], 110 * PRECISION // 100, sender=deployer)
    pool.update_rates([assets[0]], sender=alice)

    # staking address should have ~10%/4 of token
    expect = amt / n // 10
    bal = token.balanceOf(deployer)
    assert bal < expect
    assert (expect - bal) / expect < 1e-4 # small penalty because pool is slightly out of balance now

    # adjust rate downwards to 108%
    provider.set_rate(assets[0], 108 * PRECISION // 100, sender=deployer)
    pool.update_rates([assets[0]], sender=alice)

    # staking address should now have ~8%/4 of token
    expect = amt / n * 8 // 100
    bal = token.balanceOf(deployer)
    assert bal < expect
    assert (expect - bal) / expect < 1e-4 # small penalty because pool is still out of balance

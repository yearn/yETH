from ape.utils import to_int
import pytest

PRECISION = 1_000_000_000_000_000_000
MAX = 2**256 - 1
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

@pytest.fixture
def asset(project, deployer):
    return project.MockToken.deploy(sender=deployer)

@pytest.fixture
def staking(project, deployer, asset):
    return project.Staking.deploy(asset, sender=deployer)

def test_empty(staking):
    amt = PRECISION
    assert staking.convertToShares(amt) == amt
    assert staking.convertToAssets(amt) == amt
    assert staking.previewDeposit(amt) == amt
    assert staking.previewMint(amt) == amt
    assert staking.previewWithdraw(amt) == 0
    assert staking.previewRedeem(amt) == 0

def test_initial_deposit(chain, deployer, alice, bob, asset, staking):
    half_time = WEEK_LENGTH // 4
    staking.set_half_time(half_time, sender=deployer)
    amt = 3 * PRECISION
    asset.mint(alice, amt, sender=alice)
    asset.approve(staking, MAX, sender=alice)
    
    # set time to `half_time` before end of a week
    ts = (chain.pending_timestamp // WEEK_LENGTH + 2) * WEEK_LENGTH - half_time
    chain.pending_timestamp = ts

    # deposit
    staking.deposit(amt, bob, sender=alice)
    assert asset.balanceOf(alice) == 0
    assert asset.balanceOf(staking) == amt
    assert staking.balanceOf(bob) == amt
    assert staking.totalSupply() == amt
    assert staking.vote_weight(bob) == 0

    # check voting power the week after, `t=half_time`
    ts += 2 * half_time
    chain.mine(timestamp=ts)
    assert staking.vote_weight(bob) == amt // 2

    # voting power doesnt change during the week
    ts += half_time
    chain.mine(timestamp=ts)
    assert staking.vote_weight(bob) == amt // 2

    # but is increased the week after, `t=half_time+week=5*half_time`
    ts += WEEK_LENGTH
    chain.mine(timestamp=ts)
    assert staking.vote_weight(bob) == amt * 5 // 6

def test_pending_reward(alice, asset, staking):
    deposit = 2 * PRECISION
    reward = PRECISION
    asset.mint(alice, deposit, sender=alice)
    asset.approve(staking, MAX, sender=alice)
    staking.deposit(deposit, sender=alice)
    assert staking.get_amounts() == (0, 0, deposit, 0, 0) # (pending, streaming, unlocked, unclaimed, delta)

    # add reward
    asset.mint(staking, reward, sender=alice)
    assert staking.get_amounts() == (reward, 0, deposit, 0, reward)
    assert staking.update_amounts(sender=alice).return_value == (reward, 0, deposit, 0)
    assert staking.known() == reward + deposit

def test_streaming_reward(chain, alice, asset, staking):
    deposit = 2 * PRECISION
    reward = PRECISION
    asset.mint(alice, deposit, sender=alice)
    asset.approve(staking, MAX, sender=alice)
    staking.deposit(deposit, sender=alice)

    # add reward
    asset.mint(staking, reward, sender=alice)
    staking.update_amounts(sender=alice)
    assert staking.known() == reward + deposit

    # beginning of next week, pending becomes streaming
    ts = (chain.pending_timestamp // WEEK_LENGTH + 1) * WEEK_LENGTH
    chain.pending_timestamp = ts
    with chain.isolate():
        chain.mine()
        assert staking.get_amounts() == (0, reward, deposit, 0, 0)
    assert staking.update_amounts(sender=alice).return_value == (0, reward, deposit, 0)

    # streaming is unlocked during the week
    ts += WEEK_LENGTH // 10
    chain.pending_timestamp = ts
    with chain.isolate():
        chain.mine()
        unlocked = deposit + reward // 10
        assert staking.get_amounts() == (0, reward * 9 // 10, unlocked, 0, 0)

        # shares have become more valuable
        assert staking.previewDeposit(unlocked) == deposit
        assert staking.previewMint(deposit) == unlocked
        assert staking.previewWithdraw(unlocked) == deposit
        assert staking.previewRedeem(deposit) == unlocked
    assert staking.update_amounts(sender=alice).return_value == (0, reward * 9 // 10, unlocked, 0)
    assert staking.previewDeposit(unlocked) == deposit
    assert staking.previewMint(deposit) == unlocked
    assert staking.previewWithdraw(unlocked) == deposit
    assert staking.previewRedeem(deposit) == unlocked

    # .. and is fully unlocked at the end of the week
    ts += WEEK_LENGTH * 9 //10
    chain.pending_timestamp = ts
    with chain.isolate():
        chain.mine()
        unlocked = deposit + reward
        assert staking.get_amounts() == (0, 0, unlocked, 0, 0)

        assert staking.previewDeposit(unlocked) == deposit
        assert staking.previewMint(deposit) == unlocked
        assert staking.previewWithdraw(unlocked) == deposit
        assert staking.previewRedeem(deposit) == unlocked
    assert staking.update_amounts(sender=alice).return_value == (0, 0, unlocked, 0)
    assert staking.previewDeposit(unlocked) == deposit
    assert staking.previewMint(deposit) == unlocked
    assert staking.previewWithdraw(unlocked) == deposit
    assert staking.previewRedeem(deposit) == unlocked

def test_streaming_reward_grace(chain, alice, asset, staking):
    deposit = 2 * PRECISION
    reward = PRECISION
    asset.mint(alice, deposit, sender=alice)
    asset.approve(staking, MAX, sender=alice)
    staking.deposit(deposit, sender=alice)

    # add reward
    asset.mint(staking, reward, sender=alice)

    # grace period: beginning of next week, should still be counted as streaming
    ts = (chain.pending_timestamp // WEEK_LENGTH + 1) * WEEK_LENGTH + 1
    with chain.isolate():
        chain.mine(timestamp=ts)
        assert staking.get_amounts() == (0, reward, deposit, 0, reward)

    with chain.isolate():
        chain.pending_timestamp = ts
        assert staking.update_amounts(sender=alice).return_value == (0, reward, deposit, 0)

    # past the first day, rewards are counted as pending
    ts += DAY_LENGTH
    with chain.isolate():
        chain.mine(timestamp=ts)
        assert staking.get_amounts() == (reward, 0, deposit, 0, reward)

def test_reward_split(chain, alice, asset, staking):
    # if rewards havent been synced in a long time, split them fairly over all buckets
    deposit = 2 * PRECISION
    reward = PRECISION
    asset.mint(alice, deposit, sender=alice)
    asset.approve(staking, MAX, sender=alice)
    staking.deposit(deposit, sender=alice)

    # 4 days before end of week
    ts = (chain.pending_timestamp // WEEK_LENGTH + 1) * WEEK_LENGTH + 3 * DAY_LENGTH
    chain.pending_timestamp = ts
    staking.update_amounts(sender=alice)
    asset.mint(staking, reward, sender=alice)

    # 20 days = 4 days to end of week + 2 weeks + 2 days
    ts += 20 * DAY_LENGTH
    chain.pending_timestamp = ts
    with chain.isolate():
        chain.mine()
        part = reward // 20
        # pending = 2 days into current week
        # streaming = 7 days, but -2 because we are 2 days into current week
        # unlocked = remaining 13 days
        assert staking.get_amounts() == (2 * part, 5 * part, deposit + 13 * part, 0, reward)
    assert staking.update_amounts(sender=alice).return_value == (2 * part, 5 * part, deposit + 13 * part, 0)
    assert staking.known() == reward + deposit

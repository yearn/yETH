import ape
import pytest

PRECISION = 1_000_000_000_000_000_000
MAX = 2**256 - 1
DAY_LENGTH = 24 * 60 * 60
WEEK_LENGTH = 7 * DAY_LENGTH
ZERO_ADDRESS = '0x0000000000000000000000000000000000000000'

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

def test_deposit(chain, deployer, alice, bob, asset, staking):
    half_time = WEEK_LENGTH // 4
    staking.set_half_time(half_time, sender=deployer)
    amt = 3 * PRECISION
    asset.mint(alice, amt, sender=alice)
    asset.approve(staking, MAX, sender=alice)

    with ape.reverts(dev_message='dev: minimum initial deposit size'):
        staking.deposit(1, sender=alice)

    # set time to `half_time` before end of a week
    ts = (chain.pending_timestamp // WEEK_LENGTH + 2) * WEEK_LENGTH - half_time
    chain.pending_timestamp = ts

    # deposit
    staking.deposit(amt, bob, sender=alice)
    assert asset.balanceOf(alice) == 0
    assert asset.balanceOf(staking) == amt
    assert staking.balanceOf(bob) == amt
    assert staking.totalSupply() == amt
    assert staking.known() == amt
    assert staking.vote_weight(bob) == 0

    # check voting power the week after, `t = half_time`
    ts += 2 * half_time
    chain.mine(timestamp=ts)
    assert staking.vote_weight(bob) == amt // 2

    # voting power doesnt change during the week
    ts += half_time
    chain.mine(timestamp=ts)
    assert staking.vote_weight(bob) == amt // 2

    # but is increased the week after, `t = half_time+week = 5*half_time`
    ts += WEEK_LENGTH
    chain.mine(timestamp=ts)
    assert staking.vote_weight(bob) == amt * 5 // 6

def test_multiple_deposit(chain, alice, asset, staking):
    amt = PRECISION
    asset.mint(alice, 2 * amt, sender=alice)
    asset.approve(staking, MAX, sender=alice)
    
    # set time to beginning of a week
    ts = (chain.pending_timestamp // WEEK_LENGTH + 1) * WEEK_LENGTH
    chain.pending_timestamp = ts

    # one deposit at beginning of the week
    with chain.isolate():
        staking.deposit(amt, sender=alice)
        chain.mine(timestamp=ts + WEEK_LENGTH)
        low = staking.vote_weight(alice)

    # second deposit middle of the week
    with chain.isolate():
        staking.deposit(amt, sender=alice)
        chain.pending_timestamp = ts + WEEK_LENGTH // 2
        staking.deposit(amt, sender=alice)
        assert asset.balanceOf(alice) == 0
        assert asset.balanceOf(staking) == 2 * amt
        assert staking.balanceOf(alice) == 2 * amt
        assert staking.totalSupply() == 2 * amt
        assert staking.known() == 2 * amt

        chain.mine(timestamp=ts + WEEK_LENGTH)
        mid = staking.vote_weight(alice)

    # two deposits at beginning of the week
    with chain.isolate():
        staking.deposit(2 * amt, sender=alice)
        chain.mine(timestamp=ts + WEEK_LENGTH)
        high = staking.vote_weight(alice)

    assert mid > low and mid < high

def test_pending_reward(alice, asset, staking):
    deposit = 2 * PRECISION
    reward = PRECISION
    asset.mint(alice, deposit, sender=alice)
    asset.approve(staking, MAX, sender=alice)
    staking.deposit(deposit, sender=alice)
    assert staking.get_amounts() == (0, 0, deposit, 0, 0) # (pending, streaming, unlocked, fee shares, delta)

    # add reward
    asset.mint(staking, reward, sender=alice)
    assert staking.get_amounts() == (reward, 0, deposit, 0, reward)
    assert staking.update_amounts(sender=alice).return_value == (reward, 0, deposit)
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
    chain.pending_timestamp = ts
    assert staking.update_amounts(sender=alice).return_value == (0, reward, deposit)

    # streaming is unlocked during the week
    ts += WEEK_LENGTH // 10
    chain.pending_timestamp = ts
    unlocked = deposit + reward // 10
    with chain.isolate():
        chain.mine()
        assert staking.get_amounts() == (0, reward * 9 // 10, unlocked, 0, 0)

        # shares have become more valuable
        assert staking.previewDeposit(unlocked) == deposit
        assert staking.previewMint(deposit) == unlocked
        assert staking.previewWithdraw(unlocked) == deposit
        assert staking.previewRedeem(deposit) == unlocked
    chain.pending_timestamp = ts
    assert staking.update_amounts(sender=alice).return_value == (0, reward * 9 // 10, unlocked)
    assert staking.previewDeposit(unlocked) == deposit
    assert staking.previewMint(deposit) == unlocked
    assert staking.previewWithdraw(unlocked) == deposit
    assert staking.previewRedeem(deposit) == unlocked

    # .. and is fully unlocked at the end of the week
    ts += WEEK_LENGTH * 9 //10
    chain.pending_timestamp = ts
    unlocked = deposit + reward
    with chain.isolate():
        chain.mine()
        assert staking.get_amounts() == (0, 0, unlocked, 0, 0)
        assert staking.previewDeposit(unlocked) == deposit
        assert staking.previewMint(deposit) == unlocked
        assert staking.previewWithdraw(unlocked) == deposit
        assert staking.previewRedeem(deposit) == unlocked
    chain.pending_timestamp = ts
    assert staking.update_amounts(sender=alice).return_value == (0, 0, unlocked)
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
        assert staking.update_amounts(sender=alice).return_value == (0, reward, deposit)

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
    chain.pending_timestamp = ts
    assert staking.update_amounts(sender=alice).return_value == (2 * part, 5 * part, deposit + 13 * part)
    assert staking.known() == reward + deposit

def test_reward_multiple_deposit(chain, alice, bob, asset, staking):
    deposit = PRECISION
    reward = 3 * deposit

    asset.mint(alice, deposit, sender=alice)
    asset.approve(staking, MAX, sender=alice)
    ts = (chain.pending_timestamp // WEEK_LENGTH + 1) * WEEK_LENGTH
    chain.pending_timestamp = ts
    staking.deposit(deposit, sender=alice)
    asset.mint(staking, reward, sender=alice)
    staking.update_amounts(sender=alice)
    
    # fully unlock rewards
    ts += 2 * WEEK_LENGTH
    chain.mine(timestamp=ts)

    asset.mint(bob, deposit, sender=bob)
    asset.approve(staking, MAX, sender=bob)

    # shares are now more expensive
    assert staking.previewDeposit(deposit) == deposit // 4
    assert staking.deposit(deposit, sender=bob).return_value == deposit // 4
    assert staking.balanceOf(bob) == deposit // 4
    assert staking.totalSupply() == deposit * 5 // 4

def test_reward_withdraw(chain, alice, bob, asset, staking):
    deposit = PRECISION
    reward = 3 * deposit

    asset.mint(alice, deposit, sender=alice)
    asset.approve(staking, MAX, sender=alice)
    ts = (chain.pending_timestamp // WEEK_LENGTH + 1) * WEEK_LENGTH
    chain.pending_timestamp = ts
    staking.deposit(deposit, sender=alice)
    asset.mint(staking, reward, sender=alice)
    staking.update_amounts(sender=alice)
    
    # fully unlock rewards
    ts += 2 * WEEK_LENGTH
    chain.mine(timestamp=ts)

    # withdraw original deposit
    assert staking.previewWithdraw(deposit) == deposit // 4
    with chain.isolate():
        assert staking.withdraw(deposit, bob, sender=alice)
        assert staking.balanceOf(alice) == deposit * 3 // 4
        assert asset.balanceOf(bob) == deposit
    
    # cant withdraw someone else's assets without an allowance
    with ape.reverts(dev_message='dev: allowance'):
        staking.withdraw(deposit, bob, alice, sender=bob)
    
    staking.approve(bob, MAX, sender=alice)
    staking.withdraw(deposit, bob, alice, sender=bob)
    assert staking.balanceOf(alice) == deposit * 3 // 4
    assert asset.balanceOf(bob) == deposit

def test_withdraw_no_vote_weight(chain, alice, bob, asset, staking):
    amt = PRECISION
    asset.mint(alice, amt, sender=alice)
    asset.approve(staking, MAX, sender=alice)
    staking.deposit(amt, bob, sender=alice)
    
    chain.pending_timestamp += 2 * WEEK_LENGTH
    staking.withdraw(amt, sender=bob)

    chain.pending_timestamp += 2 * WEEK_LENGTH
    chain.mine()
    assert staking.vote_weight(bob) == 0

def test_withdraw_dust(alice, asset, staking):
    asset.mint(alice, PRECISION, sender=alice)
    asset.approve(staking, MAX, sender=alice)
    staking.deposit(PRECISION, sender=alice)
    with ape.reverts():
        staking.withdraw(PRECISION - 1, sender=alice)
    staking.withdraw(PRECISION, sender=alice)

def test_max_withdraw_dust(alice, bob, asset, staking):
    threshold = 1_000_000_000_000_000
    asset.mint(alice, 2 * threshold, sender=alice)
    asset.approve(staking, MAX, sender=alice)
    assert staking.maxWithdraw(alice) == 0
    staking.deposit(threshold, sender=alice)
    assert staking.maxWithdraw(alice) == threshold
    assert staking.maxWithdraw(bob) == 0
    staking.deposit(threshold * 7 // 10, bob, sender=alice)
    assert staking.maxWithdraw(alice) == threshold * 7 // 10
    assert staking.maxWithdraw(bob) == threshold * 7 // 10
    staking.withdraw(threshold * 3 // 10, sender=alice)
    assert staking.maxWithdraw(alice) == threshold * 4 // 10
    assert staking.maxWithdraw(bob) == threshold * 4 // 10
    staking.transfer(alice, threshold * 7 // 10, sender=bob)
    assert staking.maxWithdraw(alice) == threshold * 14 // 10
    assert staking.maxWithdraw(bob) == 0
    staking.withdraw(threshold * 14 // 10, sender=alice)

def test_redeem_dust(alice, asset, staking):
    asset.mint(alice, PRECISION, sender=alice)
    asset.approve(staking, MAX, sender=alice)
    staking.deposit(PRECISION, sender=alice)
    with ape.reverts():
        staking.redeem(PRECISION - 1, sender=alice)
    staking.redeem(PRECISION, sender=alice)

def test_max_redeem_dust(alice, bob, asset, staking):
    threshold = 1_000_000_000_000_000
    asset.mint(alice, 2 * threshold, sender=alice)
    asset.approve(staking, MAX, sender=alice)
    assert staking.maxRedeem(alice) == 0
    staking.deposit(threshold, sender=alice)
    assert staking.maxRedeem(alice) == threshold
    assert staking.maxRedeem(bob) == 0
    staking.deposit(threshold * 7 // 10, bob, sender=alice)
    assert staking.maxRedeem(alice) == threshold * 7 // 10
    assert staking.maxRedeem(bob) == threshold * 7 // 10
    staking.redeem(threshold * 3 // 10, sender=alice)
    assert staking.maxRedeem(alice) == threshold * 4 // 10
    assert staking.maxRedeem(bob) == threshold * 4 // 10
    staking.transfer(alice, threshold * 7 // 10, sender=bob)
    assert staking.maxRedeem(alice) == threshold * 14 // 10
    assert staking.maxRedeem(bob) == 0
    staking.redeem(threshold * 14 // 10, sender=alice)

def test_rescue(project, deployer, alice, asset, staking):
    asset.mint(alice, PRECISION, sender=alice)
    asset.approve(staking, MAX, sender=alice)
    staking.deposit(PRECISION, sender=alice)

    # cant 'rescue' vault asset
    with ape.reverts(dev_message='dev: cant rescue vault asset'):
        staking.rescue(asset, alice, sender=deployer)

    random = project.MockToken.deploy(sender=deployer)
    random.mint(staking, PRECISION, sender=deployer)

    # can rescue anything else
    staking.rescue(random, alice, sender=deployer)
    assert random.balanceOf(alice) == PRECISION

def test_transfer_management(deployer, alice, bob, staking):
    assert staking.management() == deployer
    assert staking.pending_management() == ZERO_ADDRESS

    # only current management can propose new management
    with ape.reverts():
        staking.set_management(alice, sender=alice)

    # propose new management
    staking.set_management(alice, sender=deployer)
    assert staking.management() == deployer
    assert staking.pending_management() == alice

    # only proposed management can accept
    with ape.reverts():
        staking.accept_management(sender=bob)

    # accept new management
    staking.accept_management(sender=alice)
    assert staking.management() == alice
    assert staking.pending_management() == ZERO_ADDRESS

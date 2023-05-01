# @version 0.3.7
"""
@title yETH staking contract
@author 0xkorin, Yearn Finance
@license Copyright (c) Yearn Finance, 2023 - all rights reserved
"""

from vyper.interfaces import ERC20
from vyper.interfaces import ERC4626
implements: ERC20
implements: ERC4626

struct Weight:
    week: uint16
    t: uint56
    updated: uint56
    shares: uint128

updated: public(uint256)
pending: uint256
streaming: uint256
unlocked: uint256
management: public(address)

# fees
performance_fee_rate: public(uint256)
treasury: public(address)

# voting
half_time: public(uint256)
previous_weights: HashMap[address, Weight]
weights: HashMap[address, Weight]

# ERC20 state
totalSupply: public(uint256)
balanceOf: public(HashMap[address, uint256])
allowance: public(HashMap[address, HashMap[address, uint256]])

name: public(constant(String[18])) = "Staked Yearn Ether"
symbol: public(constant(String[7])) = "st-yETH"
decimals: public(constant(uint8)) = 18

# ERC4626 state
asset: public(immutable(address))

FEE_PRECISION: constant(uint256) = 10_000
MINIMUM_INITIAL_DEPOSIT: constant(uint256) = 1_000_000_000_000_000
DAY_LENGTH: constant(uint256) = 24 * 60 * 60
WEEK_LENGTH: constant(uint256) = 7 * DAY_LENGTH

event Rewards:
    pending: uint256
    streaming: uint256
    unlocked: uint256
    delta: int256

event SetFeeRate:
    fee_rate: uint256

event SetMinter:
    account: indexed(address)
    minter: bool

# ERC20 events
event Transfer:
    sender: indexed(address)
    receiver: indexed(address)
    value: uint256

event Approval:
    owner: indexed(address)
    spender: indexed(address)
    value: uint256

# ERC4626 events
event Deposit:
    sender: indexed(address)
    owner: indexed(address)
    assets: uint256
    shares: uint256

event Withdraw:
    sender: indexed(address)
    receiver: indexed(address)
    owner: indexed(address)
    assets: uint256
    shares: uint256

INCREMENT: constant(bool) = True
DECREMENT: constant(bool) = False

@external
def __init__(_asset: address):
    """
    @notice Constructor
    @param _asset The underlying asset
    """
    asset = _asset
    self.updated = block.timestamp
    self.half_time = WEEK_LENGTH
    self.management = msg.sender
    self.treasury = msg.sender
    log Transfer(empty(address), msg.sender, 0)

# ERC20 functions
@external
def transfer(_to: address, _value: uint256) -> bool:
    """
    @notice Transfer to another account
    @param _to Account to transfer to
    @param _value Amount to transfer
    @return Flag indicating whether the transfer was successful
    """
    assert _to != empty(address) and _to != self
    assert _value > 0
    self._update_account_shares(msg.sender, _value, DECREMENT)
    self._update_account_shares(_to, _value, INCREMENT)
    log Transfer(msg.sender, _to, _value)
    return True

@external
def transferFrom(_from: address, _to: address, _value: uint256) -> bool:
    """
    @notice Transfer from one account to another account
    @param _from Account to transfe from
    @param _to Account to transfer to
    @param _value Amount to transfer
    @return Flag indicating whether the transfer was successful
    """
    assert _to != empty(address) and _to != self
    assert _value > 0
    self.allowance[_from][msg.sender] -= _value
    self._update_account_shares(_from, _value, DECREMENT)
    self._update_account_shares(_to, _value, INCREMENT)
    log Transfer(_from, _to, _value)
    return True

@external
def approve(_spender: address, _value: uint256) -> bool:
    """
    @notice Approve another account to spend. Beware that changing an allowance 
        with this method brings the risk that someone may use both the old and 
        the new allowance by unfortunate transaction ordering. 
        See https://github.com/ethereum/EIPs/issues/20#issuecomment-263524729
    @param _spender Account that is allowed to spend
    @param _value Amount that the spender is allowed to transfer
    @return Flag indicating whether the approval was successful
    """
    self.allowance[msg.sender][_spender] = _value
    log Approval(msg.sender, _spender, _value)
    return True

@external
def increaseAllowance(_spender: address, _value: uint256) -> bool:
    """
    @notice Increase the allowance of another account to spend. This method mitigates 
        the risk that someone may use both the old and the new allowance by unfortunate 
        transaction ordering.
        See https://github.com/ethereum/EIPs/issues/20#issuecomment-263524729
    @param _spender Account that is allowed to spend
    @param _value The amount of tokens to increase the allowance by
    @return True
    """
    allowance: uint256 = self.allowance[msg.sender][_spender] + _value
    self.allowance[msg.sender][_spender] = allowance
    log Approval(msg.sender, _spender, allowance)
    return True

@external
def decreaseAllowance(_spender: address, _value: uint256) -> bool:
    """
    @notice Decrease the allowance of another account to spend. This method mitigates 
        the risk that someone may use both the old and the new allowance by unfortunate 
        transaction ordering.
        See https://github.com/ethereum/EIPs/issues/20#issuecomment-263524729
    @param _spender Account that is allowed to spend
    @param _value The amount of tokens to increase the allowance by
    @return True
    """
    allowance: uint256 = self.allowance[msg.sender][_spender] - _value
    self.allowance[msg.sender][_spender] = allowance
    log Approval(msg.sender, _spender, allowance)
    return True

# ERC4626 functions
@external
@view
def totalAssets() -> uint256:
    """
    @notice Get the total assets in the contract
    @return Total assets in the contract
    """
    total_shares: uint256 = 0
    total_assets: uint256 = 0
    total_shares, total_assets = self._get_totals()
    return total_assets

@external
@view
def convertToShares(_assets: uint256) -> uint256:
    """
    @notice Convert amount of assets to amount of shares
    @param _assets Amount of assets
    @return Amount of shares
    """
    total_shares: uint256 = 0
    total_assets: uint256 = 0
    total_shares, total_assets = self._get_totals()
    if total_shares == 0 or total_assets == 0:
        return _assets
    return _assets * total_shares / total_assets

@external
@view
def convertToAssets(_shares: uint256) -> uint256:
    """
    @notice Convert amount of shares to amount of assets
    @param _shares Amount of shares
    @return Amount of assets
    """
    total_shares: uint256 = 0
    total_assets: uint256 = 0
    total_shares, total_assets = self._get_totals()
    if total_shares == 0 or total_assets == 0:
        return _shares
    return _shares * total_assets / total_shares

@external
@view
def maxDeposit(_receiver: address) -> uint256:
    """
    @notice Get the maximum amount of assets an account is allowed to deposit
    @param _receiver Account
    @return Maximum amount the account is allowed to deposit
    """
    return max_value(uint256)

@external
@view
def previewDeposit(_assets: uint256) -> uint256:
    """
    @notice Simulate the effect of a deposit
    @param _assets Amount of assets to deposit
    @return Amount of shares that will be minted
    """
    total_shares: uint256 = 0
    total_assets: uint256 = 0
    total_shares, total_assets = self._get_totals()
    return self._preview_deposit(_assets, total_shares, total_assets)

@external
def deposit(_assets: uint256, _receiver: address = msg.sender) -> uint256:
    """
    @notice Deposit assets
    @param _assets Amount of assets to deposit
    @param _receiver Account that will receive the shares
    @return Amount of shares minted
    """
    assert _assets > 0
    total_shares: uint256 = 0
    total_assets: uint256 = 0
    total_shares, total_assets = self._update_totals()
    shares: uint256 = self._preview_deposit(_assets, total_shares, total_assets)
    assert shares > 0
    self._deposit(_assets, shares, _receiver)
    return shares

@external
@view
def maxMint(_receiver: address) -> uint256:
    """
    @notice Get the maximum amount of shares an account is allowed to mint
    @param _receiver Account
    @return Maximum amount the account is allowed to mint
    """
    return max_value(uint256)

@external
@view
def previewMint(_shares: uint256) -> uint256:
    """
    @notice Simulate the effect of a mint
    @param _shares Amount of shares to mint
    @return Amount of assets that will be taken
    """
    total_shares: uint256 = 0
    total_assets: uint256 = 0
    total_shares, total_assets = self._get_totals()
    return self._preview_mint(_shares, total_shares, total_assets)

@external
def mint(_shares: uint256, _receiver: address = msg.sender) -> uint256:
    """
    @notice Mint shares
    @param _shares Amount of shares to mint
    @param _receiver Account that will receive the shares
    @return Amount of assets taken
    """
    assert _shares > 0
    total_shares: uint256 = 0
    total_assets: uint256 = 0
    total_shares, total_assets = self._update_totals()
    assets: uint256 = self._preview_mint(_shares, total_shares, total_assets)
    assert assets > 0
    self._deposit(assets, _shares, _receiver)
    return assets

@external
@view
def maxWithdraw(_owner: address) -> uint256:
    """
    @notice Get the maximum amount of assets an account is allowed to withdraw
    @param _owner Account
    @return Maximum amount the account is allowed to withdraw
    """
    return max_value(uint256)

@external
@view
def previewWithdraw(_assets: uint256) -> uint256:
    """
    @notice Simulate the effect of a withdrawal
    @param _assets Amount of assets to withdraw
    @return Amount of shares that will be redeemed
    """
    total_shares: uint256 = 0
    total_assets: uint256 = 0
    total_shares, total_assets = self._get_totals()
    return self._preview_withdraw(_assets, total_shares, total_assets)

@external
def withdraw(_assets: uint256, _receiver: address = msg.sender, _owner: address = msg.sender) -> uint256:
    """
    @notice Withdraw assets
    @param _assets Amount of assets to withdraw
    @param _receiver Account that will receive the assets
    @param _owner Owner of the shares that will be redeemed
    @return Amount of shares redeemed
    """
    assert _assets > 0
    total_shares: uint256 = 0
    total_assets: uint256 = 0
    total_shares, total_assets = self._update_totals()
    shares: uint256 = self._preview_withdraw(_assets, total_shares, total_assets)
    assert shares > 0
    self._withdraw(_assets, shares, _receiver, _owner)
    return shares

@external
@view
def maxRedeem(_owner: address) -> uint256:
    """
    @notice Get the maximum amount of shares an account is allowed to redeem
    @param _owner Account
    @return Maximum amount the account is allowed to redeem
    """
    return max_value(uint256)

@external
@view
def previewRedeem(_shares: uint256) -> uint256:
    """
    @notice Simulate the effect of a redemption
    @param _shares Amount of shares to redeem
    @return Amount of assets that will be withdrawn
    """
    total_shares: uint256 = 0
    total_assets: uint256 = 0
    total_shares, total_assets = self._get_totals()
    return self._preview_redeem(_shares, total_shares, total_assets)

@external
def redeem(_shares: uint256, _receiver: address = msg.sender, _owner: address = msg.sender) -> uint256:
    """
    @notice Redeem shares
    @param _shares Amount of shares to redeem
    @param _receiver Account that will receive the assets
    @param _owner Owner of the shares that will be redeemed
    @return Amount of assets withdrawn
    """
    assert _shares > 0
    total_shares: uint256 = 0
    total_assets: uint256 = 0
    total_shares, total_assets = self._update_totals()
    assets: uint256 = self._preview_redeem(_shares, total_shares, total_assets)
    assert assets > 0
    self._withdraw(assets, _shares, _receiver, _owner)
    return assets

# external functions
@external
def update_amounts() -> (uint256, uint256, uint256):
    """
    @notice Update the amount in each bucket
    @return Tuple with pending, streaming and unlocked amounts
    """
    self._update_totals()
    return self.pending, self.streaming, self.unlocked

@external
@view
def get_amounts() -> (uint256, uint256, uint256, uint256, int256):
    """
    @notice Simulate an update to the buckets
    @return Tuple with pending, streaming, unlocked amounts, new fee shares and balance changes since last update
    """
    return self._get_amounts(ERC20(asset).balanceOf(self))

@external
@view
def vote_weight(_account: address) -> uint256:
    """
    @notice Get the voting weight of an account
    @dev Vote weights are always evaluated at the end of last week
    @param _account Account to find get the vote weight for
    @return Vote weight
    """
    week: uint16 = convert(block.timestamp / WEEK_LENGTH, uint16) - 1
    weight: Weight = self.weights[_account]
    if weight.week > week or weight.week == 0:
        weight = self.previous_weights[_account]
    
    t: uint256 = convert(weight.t, uint256)
    if weight.week > 0:
        t += block.timestamp / WEEK_LENGTH * WEEK_LENGTH - convert(weight.updated, uint256)

    return convert(weight.shares, uint256) * t / (t + self.half_time)

@external
@view
def known() -> uint256:
    return self.pending + self.streaming + self.unlocked

@external
def rescue(_token: address, _receiver: address):
    assert msg.sender == self.management
    assert _token != asset # dev: cant rescue vault asset
    amount: uint256 = ERC20(_token).balanceOf(self)
    assert ERC20(_token).transfer(_receiver, amount, default_return_value=True)

@external
def set_performance_fee_rate(_fee_rate: uint256):
    """
    @notice Set the performance fee rate
    @param _fee_rate Performance fee rate (in 18 decimals)
    """
    assert msg.sender == self.management
    self.performance_fee_rate = _fee_rate
    log SetFeeRate(_fee_rate)

@external
def set_half_time(_half_time: uint256):
    """
    @notice Set the time to reach half the voting weights
    @param _half_time Time to reach half voting weight (in seconds)
    """
    assert msg.sender == self.management
    assert _half_time > 0
    self.half_time = _half_time

@external
def set_management(_management: address):
    """
    @notice Set the management
    @param _management The new management address
    """
    assert msg.sender == self.management
    self.management = _management

@external
def set_treasury(_treasury: address):
    """
    @notice Set the performance fee beneficiary
    @param _treasury The new treasury address
    """
    assert msg.sender == self.management or msg.sender == self.treasury
    self.treasury = _treasury

# internal functions
@internal
@view
def _preview_deposit(_assets: uint256, _total_shares: uint256, _total_assets: uint256) -> uint256:
    if _total_shares == 0:
        assert _assets >= MINIMUM_INITIAL_DEPOSIT # dev: minimum initial deposit size
        return _assets
    if _total_assets == 0:
        return 0
    return _assets * _total_shares / _total_assets

@internal
@view
def _preview_mint(_shares: uint256, _total_shares: uint256, _total_assets: uint256) -> uint256:
    if _total_shares == 0:
        assert _shares >= MINIMUM_INITIAL_DEPOSIT # dev: minimum initial deposit size
        return _shares
    if _total_assets == 0:
        return 0
    return _shares * _total_assets / _total_shares

@internal
def _deposit(_assets: uint256, _shares: uint256, _receiver: address):
    self.unlocked += _assets
    self.totalSupply += _shares
    self._update_account_shares(_receiver, _shares, INCREMENT)
    
    assert ERC20(asset).transferFrom(msg.sender, self, _assets, default_return_value=True)
    log Deposit(msg.sender, _receiver, _assets, _shares)

@internal
@view
def _preview_withdraw(_assets: uint256, _total_shares: uint256, _total_assets: uint256) -> uint256:
    if _total_assets == 0:
        return 0
    return _assets * _total_shares / _total_assets

@internal
@view
def _preview_redeem(_shares: uint256, _total_shares: uint256, _total_assets: uint256) -> uint256:
    if _total_shares == 0:
        return 0
    return _shares * _total_assets / _total_shares

@internal
def _withdraw(_assets: uint256, _shares: uint256, _receiver: address, _owner: address):
    if _owner != msg.sender:
        self.allowance[_owner][msg.sender] -= _shares # dev: allowance
    
    self.unlocked -= _assets
    self.totalSupply -= _shares
    self._update_account_shares(_owner, _shares, DECREMENT)

    assert ERC20(asset).transfer(_receiver, _assets, default_return_value=True)
    log Withdraw(msg.sender, _receiver, _owner, _assets, _shares)

@internal
@view
def _get_totals() -> (uint256, uint256):
    pending: uint256 = 0
    streaming: uint256 = 0
    unlocked: uint256 = 0
    new_fee_shares: uint256 = 0
    delta: int256 = 0
    pending, streaming, unlocked, new_fee_shares, delta = self._get_amounts(ERC20(asset).balanceOf(self))
    return self.totalSupply + new_fee_shares, unlocked

@internal
def _update_totals() -> (uint256, uint256):
    current: uint256 = ERC20(asset).balanceOf(self)
    pending: uint256 = 0
    streaming: uint256 = 0
    unlocked: uint256 = 0
    new_fee_shares: uint256 = 0
    delta: int256 = 0
    pending, streaming, unlocked, new_fee_shares, delta = self._get_amounts(current)

    if delta != 0:
        log Rewards(pending, streaming, unlocked, delta)

    self.updated = block.timestamp
    self.pending = pending
    self.streaming = streaming
    self.unlocked = unlocked

    total_shares: uint256 = self.totalSupply
    if new_fee_shares > 0:
        total_shares += new_fee_shares
        self.totalSupply = total_shares
        treasury: address = self.treasury
        self.balanceOf[treasury] += new_fee_shares
        log Transfer(empty(address), treasury, new_fee_shares)

    return total_shares, unlocked

@internal
@view
def _get_amounts(_current: uint256) -> (uint256, uint256, uint256, uint256, int256):
    updated: uint256 = self.updated
    if updated == block.timestamp:
        return self.pending, self.streaming, self.unlocked, 0, 0

    new_fee: uint256 = 0
    current: uint256 = _current
    pending: uint256 = self.pending
    streaming: uint256 = self.streaming
    unlocked: uint256 = self.unlocked
    last: uint256 = pending + streaming + unlocked

    delta: int256 = 0
    weeks: uint256 = block.timestamp / WEEK_LENGTH - updated / WEEK_LENGTH
    if weeks > 0:
        if weeks == 1:
            # new week
            unlocked += streaming
            streaming = pending
            pending = 0
        else:
            # week number has changed by at least 2 - function hasnt been called in at least a week
            span: uint256 = block.timestamp - updated
            unlocked += streaming + pending
            if current > last:
                # net rewards generated, distribute over buckets
                rewards: uint256 = current - last
                fee: uint256 = rewards * self.performance_fee_rate / FEE_PRECISION
                rewards -= fee
                new_fee += fee

                delta = convert(rewards, int256)
                last = current

                # streaming bucket: 7 days
                streaming = rewards * WEEK_LENGTH / span
                span -= WEEK_LENGTH
                rewards -= streaming

                # pending bucket: time since new week
                pending = rewards * (block.timestamp % WEEK_LENGTH) / span
                rewards -= pending

                # unlocked bucket: rest
                unlocked += rewards
            else:
                # net penalty - deal with it below
                streaming = 0
                pending = 0

        # set to beginning of the week
        updated = block.timestamp / WEEK_LENGTH * WEEK_LENGTH

    # time between last update and end of week
    duration: uint256 = WEEK_LENGTH - (updated % WEEK_LENGTH)
    # time that has passed since last update
    span: uint256 = block.timestamp - updated

    # unlock funds
    streamed: uint256 = streaming * span / duration
    streaming -= streamed
    unlocked += streamed

    if current >= last:
        # rewards
        rewards: uint256 = current - last
        fee: uint256 = rewards * self.performance_fee_rate / FEE_PRECISION
        rewards -= fee
        new_fee += fee
        if weeks == 1 and block.timestamp % WEEK_LENGTH <= DAY_LENGTH:
            # if first update in new week is in first day, add to streaming
            streaming += rewards
        else:
            pending += rewards
        delta += convert(rewards, int256)
    else:
        # penalty
        shortage: uint256 = last - current
        delta -= convert(shortage, int256)
        if pending >= shortage:
            # there are enough pending assets to cover the penalty
            pending -= shortage
        else:
            shortage -= pending
            pending = 0
            if streaming >= shortage:
                # there are enough streaming assets to cover the penalty
                streaming -= shortage
            else:
                # as a last resort, take from unlocked funds
                shortage -= streaming
                streaming = 0
                unlocked -= shortage

    new_fee_shares: uint256 = 0
    if new_fee > 0:
        if unlocked == 0:
            new_fee_shares = new_fee
        else:
            new_fee_shares = new_fee * self.totalSupply / unlocked

        unlocked += new_fee

    return pending, streaming, unlocked, new_fee_shares, delta

@internal
def _update_account_shares(_account: address, _change: uint256, _add: bool):
    prev_shares: uint256 = self.balanceOf[_account]
    shares: uint256 = prev_shares
    if _add:
        shares += _change
    else:
        shares -= _change
    self.balanceOf[_account] = shares

    week: uint16 = convert(block.timestamp / WEEK_LENGTH, uint16)
    weight: Weight = self.weights[_account]
    if weight.week > 0 and week > weight.week:
        self.previous_weights[_account] = weight

    if shares == 0:
        weight.t = 0
        weight.shares = 0

    t: uint256 = convert(weight.t, uint256)
    if weight.shares > 0:
        t += block.timestamp - convert(weight.updated, uint256)
        if shares > convert(weight.shares, uint256):
            # amount has increased, calculate effective time that results in same weight
            half_time: uint256 = self.half_time
            t = prev_shares * t * half_time / (shares * (t + half_time) - prev_shares * t)

    weight.week = week
    weight.t = convert(t, uint56)
    weight.updated = convert(block.timestamp, uint56)
    weight.shares = convert(shares, uint128)
    self.weights[_account] = weight

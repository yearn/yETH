# @version 0.3.7

from vyper.interfaces import ERC20
from vyper.interfaces import ERC4626
implements: ERC20
implements: ERC4626

# State
updated: public(uint256)
known: public(uint256)
pending: public(uint256)
streaming: public(uint256)
unlocked: public(uint256)

# ERC20 state
totalSupply: public(uint256)
balanceOf: public(HashMap[address, uint256])
allowance: public(HashMap[address, HashMap[address, uint256]])

name: public(constant(String[16])) = "Staked Yearn ETH"
symbol: public(constant(String[7])) = "st-yETH"
decimals: public(constant(uint8)) = 18

# ERC4626 state
asset: public(immutable(address))

DAY_LENGTH: constant(uint256) = 24 * 60 * 60
WEEK_LENGTH: constant(uint256) = 7 * DAY_LENGTH

# ERC20 events
event Transfer:
    sender: indexed(address)
    receiver: indexed(address)
    value: uint256

event Approval:
    owner: indexed(address)
    spender: indexed(address)
    value: uint256

event SetMinter:
    account: indexed(address)
    minter: bool

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

@external
def __init__(_asset: address):
    asset = _asset
    self.updated = block.timestamp
    log Transfer(empty(address), msg.sender, 0)

@external
def update():
    self._update_unlocked()

# ERC20 functions
@external
def transfer(_to: address, _value: uint256) -> bool:
    assert _to != empty(address)
    self.balanceOf[msg.sender] -= _value
    self.balanceOf[_to] += _value
    log Transfer(msg.sender, _to, _value)
    return True

@external
def transferFrom(_from: address, _to: address, _value: uint256) -> bool:
    assert _to != empty(address)
    self.allowance[_from][msg.sender] -= _value
    self.balanceOf[_from] -= _value
    self.balanceOf[_to] += _value
    log Transfer(_from, _to, _value)
    return True

@external
def approve(_spender: address, _value: uint256) -> bool:
    self.allowance[msg.sender][_spender] = _value
    log Approval(msg.sender, _spender, _value)
    return True

# ERC4626 functions
@external
@view
def totalAssets() -> uint256:
    return self._get_unlocked()

@external
@view
def convertToShares(_assets: uint256) -> uint256:
    shares: uint256 = self.totalSupply
    assets: uint256 = self._get_unlocked()
    if shares == 0 or assets == 0:
        return _assets
    return _assets * shares / assets

@external
@view
def convertToAssets(_shares: uint256) -> uint256:
    shares: uint256 = self.totalSupply
    assets: uint256 = self._get_unlocked()
    if shares == 0 or assets == 0:
        return _shares
    return _shares * assets / shares

@external
@view
def maxDeposit(_receiver: address) -> uint256:
    return max_value(uint256)

@external
@view
def previewDeposit(_assets: uint256) -> uint256:
    return self._preview_deposit(_assets, self._get_unlocked())

@external
def deposit(_assets: uint256, _receiver: address = msg.sender) -> uint256:
    assert _assets > 0
    shares: uint256 = self._preview_deposit(_assets, self._update_unlocked())
    assert shares > 0
    self._deposit(_assets, shares, _receiver)
    return shares

@external
@view
def maxMint(_receiver: address) -> uint256:
    return max_value(uint256)

@external
@view
def previewMint(_shares: uint256) -> uint256:
    return self._preview_mint(_shares, self._get_unlocked())

@external
def mint(_shares: uint256, _receiver: address = msg.sender) -> uint256:
    assert _shares > 0
    assets: uint256 = self._preview_mint(_shares, self._update_unlocked())
    assert assets > 0
    self._deposit(assets, _shares, _receiver)
    return assets

@external
@view
def maxWithdraw(_owner: address) -> uint256:
    return max_value(uint256)

@external
@view
def previewWithdraw(_assets: uint256) -> uint256:
    return self._preview_withdraw(_assets, self._get_unlocked())

@external
def withdraw(_assets: uint256, _receiver: address = msg.sender, _owner: address = msg.sender) -> uint256:
    assert _assets > 0
    shares: uint256 = self._preview_withdraw(_assets, self._update_unlocked())
    assert shares > 0
    self._withdraw(_assets, shares, _receiver, _owner)
    return shares

@external
@view
def maxRedeem(_owner: address) -> uint256:
    return max_value(uint256)

@external
@view
def previewRedeem(_shares: uint256) -> uint256:
    return self._preview_redeem(_shares, self._get_unlocked())

@external
def redeem(_shares: uint256, _receiver: address = msg.sender, _owner: address = msg.sender) -> uint256:
    assert _shares > 0
    assets: uint256 = self._preview_redeem(_shares, self._update_unlocked())
    assert assets > 0
    self._withdraw(assets, _shares, _receiver, _owner)
    return assets

# Internal functions
@internal
@view
def _preview_deposit(_assets: uint256, _total_assets: uint256) -> uint256:
    total_shares: uint256 = self.totalSupply
    if total_shares == 0:
        return _assets
    if _total_assets == 0:
        return 0
    return _assets * total_shares / _total_assets

@internal
@view
def _preview_mint(_shares: uint256, _total_assets: uint256) -> uint256:
    total_shares: uint256 = self.totalSupply
    if total_shares == 0:
        return _shares
    if _total_assets == 0:
        return 0
    return _shares * _total_assets / total_shares

@internal
def _deposit(_assets: uint256, _shares: uint256, _receiver: address):
    self.unlocked += _assets
    self.known += _assets
    self.totalSupply += _shares
    self.balanceOf[_receiver] += _shares
    
    assert ERC20(asset).transferFrom(msg.sender, self, _assets, default_return_value=True)
    log Deposit(msg.sender, _receiver, _assets, _shares)

@internal
@view
def _preview_withdraw(_assets: uint256, _total_assets: uint256) -> uint256:
    if _total_assets == 0:
        return 0
    return _assets * self.totalSupply / _total_assets

@internal
@view
def _preview_redeem(_shares: uint256, _total_assets: uint256) -> uint256:
    _total_shares: uint256 = self.totalSupply
    if _total_shares == 0:
        return 0
    return _shares * _total_assets / _total_shares

@internal
def _withdraw(_assets: uint256, _shares: uint256, _receiver: address, _owner: address):
    if _owner != msg.sender:
        self.allowance[_owner][msg.sender] -= _shares
    
    self.unlocked -= _assets
    self.known -= _assets
    self.totalSupply -= _shares
    self.balanceOf[_owner] -= _shares

    assert ERC20(asset).transfer(_receiver, _assets, default_return_value=True)
    log Withdraw(msg.sender, _receiver, _owner, _assets, _shares)

@internal
@view
def _get_unlocked() -> uint256:
    pending: uint256 = 0
    streaming: uint256 = 0
    unlocked: uint256 = 0
    delta: int256 = 0
    pending, streaming, unlocked, delta = self._get_amounts(ERC20(asset).balanceOf(self))
    return unlocked

@internal
def _update_unlocked() -> uint256:
    current: uint256 = ERC20(asset).balanceOf(self)
    pending: uint256 = 0
    streaming: uint256 = 0
    unlocked: uint256 = 0
    delta: int256 = 0
    pending, streaming, unlocked, delta = self._get_amounts(current)

    # TODO: emit event

    self.updated = block.timestamp
    self.known = current
    self.pending = pending
    self.streaming = streaming
    self.unlocked = unlocked
    return unlocked

@internal
@view
def _get_amounts(_current: uint256) -> (uint256, uint256, uint256, int256):
    updated: uint256 = self.updated
    if updated == block.timestamp:
        return self.pending, self.streaming, self.unlocked, 0

    last: uint256 = self.known
    pending: uint256 = self.pending
    streaming: uint256 = self.streaming
    unlocked: uint256 = self.unlocked

    delta: int256 = 0
    weeks: uint256 = block.timestamp / WEEK_LENGTH - updated / WEEK_LENGTH
    if weeks > 0:
        if weeks == 1:
            # new week
            unlocked += streaming
            streaming = pending
            pending = 0
        else:
            # week number has changed by >= 2 - function hasnt been called in at least a week
            span: uint256 = block.timestamp - updated
            unlocked += streaming + pending
            if _current > last:
                # net rewards generated, distribute over buckets
                rewards: uint256 = _current - last
                delta = convert(rewards, int256)
                last = _current

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
                # net slashing - deal with it below
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

    if _current >= last:
        # rewards
        pending += _current - last
        delta += convert(_current - last, int256)
    else:
        # slashing
        shortage: uint256 = last - _current
        delta -= convert(shortage, int256)
        if pending >= shortage:
            # there are enough pending assets to cover the slashing
            pending -= shortage
        else:
            shortage -= pending
            pending = 0
            if streaming >= shortage:
                # there are enough streaming assets to cover the slashing
                streaming -= shortage
            else:
                # take from unlocked funds
                shortage -= streaming
                streaming = 0
                unlocked -= shortage
    return pending, streaming, unlocked, delta

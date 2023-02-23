# @version 0.3.7

from vyper.interfaces import ERC20
from vyper.interfaces import ERC4626
implements: ERC20
implements: ERC4626

# State
unlockedAssets: public(uint256)
knownAssets: public(uint256)
pendingAssets: public(uint256)
streamingAssets: public(uint256)


# ERC20 state
totalSupply: public(uint256)
balanceOf: public(HashMap[address, uint256])
allowance: public(HashMap[address, HashMap[address, uint256]])

name: public(constant(String[16])) = "Staked Yearn ETH"
symbol: public(constant(String[7])) = "st-yETH"
decimals: public(constant(uint8)) = 18

# ERC4626 state
asset: public(immutable(address))

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
    log Transfer(empty(address), msg.sender, 0)

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
    return self._availableAssets()

@external
@view
def convertToShares(_assets: uint256) -> uint256:
    totalShares: uint256 = self.totalSupply
    totalAssets: uint256 = self._availableAssets()
    if totalShares == 0 or totalAssets == 0:
        return _assets
    return _assets * totalShares / totalAssets

@external
@view
def convertToAssets(_shares: uint256) -> uint256:
    totalShares: uint256 = self.totalSupply
    totalAssets: uint256 = self._availableAssets()
    if totalShares == 0 or totalAssets == 0:
        return _shares
    return _shares * totalAssets / totalShares

@external
@view
def maxDeposit(_receiver: address) -> uint256:
    return max_value(uint256)

@external
@view
def previewDeposit(_assets: uint256) -> uint256:
    return self._previewDeposit(_assets, self._availableAssets())

@external
def deposit(_assets: uint256, _receiver: address = msg.sender) -> uint256:
    assert _assets > 0
    shares: uint256 = self._previewDeposit(_assets, self._updateAvailableAssets())
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
    return self._previewMint(_shares, self._availableAssets())

@external
def mint(_shares: uint256, _receiver: address = msg.sender) -> uint256:
    assert _shares > 0
    assets: uint256 = self._previewMint(_shares, self._updateAvailableAssets())
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
    return self._previewWithdraw(_assets, self._availableAssets())

@external
def withdraw(_assets: uint256, _receiver: address = msg.sender, _owner: address = msg.sender) -> uint256:
    assert _assets > 0
    shares: uint256 = self._previewWithdraw(_assets, self._updateAvailableAssets())
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
    return self._previewRedeem(_shares, self._availableAssets())

@external
def redeem(_shares: uint256, _receiver: address = msg.sender, _owner: address = msg.sender) -> uint256:
    assert _shares > 0
    assets: uint256 = self._previewRedeem(_shares, self._updateAvailableAssets())
    assert assets > 0
    self._withdraw(assets, _shares, _receiver, _owner)
    return assets

# Internal functions
@internal
@view
def _previewDeposit(_assets: uint256, _totalAssets: uint256) -> uint256:
    totalShares: uint256 = self.totalSupply
    if totalShares == 0:
        return _assets
    if _totalAssets == 0:
        return 0
    return _assets * totalShares / _totalAssets

@internal
@view
def _previewMint(_shares: uint256, _totalAssets: uint256) -> uint256:
    totalShares: uint256 = self.totalSupply
    if totalShares == 0:
        return _shares
    if _totalAssets == 0:
        return 0
    return _shares * _totalAssets / totalShares

@internal
def _deposit(_assets: uint256, _shares: uint256, _receiver: address):
    self.unlockedAssets += _assets
    self.totalSupply += _shares
    self.balanceOf[_receiver] += _shares
    
    assert ERC20(asset).transferFrom(msg.sender, self, _assets, default_return_value=True)
    log Deposit(msg.sender, _receiver, _assets, _shares)

@internal
@view
def _previewWithdraw(_assets: uint256, _totalAssets: uint256) -> uint256:
    if _totalAssets == 0:
        return 0
    return _assets * self.totalSupply / _totalAssets

@internal
@view
def _previewRedeem(_shares: uint256, _totalAssets: uint256) -> uint256:
    totalShares: uint256 = self.totalSupply
    if totalShares == 0:
        return 0
    return _shares * _totalAssets / totalShares

@internal
def _withdraw(_assets: uint256, _shares: uint256, _receiver: address, _owner: address):
    if _owner != msg.sender:
        self.allowance[_owner][msg.sender] -= _shares
    
    # TODO: buckets
    self.unlockedAssets -= _assets
    self.totalSupply -= _shares
    self.balanceOf[_owner] -= _shares

    assert ERC20(asset).transfer(_receiver, _assets, default_return_value=True)
    log Withdraw(msg.sender, _receiver, _owner, _assets, _shares)

@internal
@view
def _availableAssets() -> uint256:
    # TODO: streaming bucket
    return self.unlockedAssets

@internal
def _updateAvailableAssets() -> uint256:
    # TODO: update knownAssets and other buckets
    return self.unlockedAssets

# @version 0.3.7
"""
@title yETH token
@author 0xkorin, Yearn Finance
@license Copyright (c) Yearn Finance, 2023 - all rights reserved
"""

from vyper.interfaces import ERC20
implements: ERC20

totalSupply: public(uint256)
balanceOf: public(HashMap[address, uint256])
allowance: public(HashMap[address, HashMap[address, uint256]])

name: public(constant(String[11])) = "Yearn Ether"
symbol: public(constant(String[4])) = "yETH"
decimals: public(constant(uint8)) = 18

minters: public(HashMap[address, bool])
management: public(address)

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

@external
def __init__():
    self.management = msg.sender
    log Transfer(empty(address), msg.sender, 0)

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

@external
def set_minter(_account: address, _minter: bool = True):
    assert self.management == msg.sender
    self.minters[_account] = _minter
    log SetMinter(_account, _minter)

@external
def mint(_account: address, _value: uint256):
    assert self.minters[msg.sender]
    self.totalSupply += _value
    self.balanceOf[_account] += _value
    log Transfer(empty(address), _account, _value)

@external
def burn(_account: address, _value: uint256):
    assert self.minters[msg.sender]
    self.totalSupply -= _value
    self.balanceOf[_account] -= _value
    log Transfer(_account, empty(address), _value)

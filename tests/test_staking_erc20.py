import ape
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
def charlie(accounts):
    return accounts[3]

@pytest.fixture
def underlying(project, deployer):
    token = project.Token.deploy(sender=deployer)
    token.set_minter(deployer, sender=deployer)
    return token

@pytest.fixture
def token(project, deployer, underlying):
    token = project.Staking.deploy(underlying, sender=deployer)
    underlying.mint(deployer, 1_000 * PRECISION, sender=deployer)
    underlying.approve(token, MAX, sender=deployer)
    return token

def mint(token, accounts, receiver, amount):
    token.mint(amount, receiver, sender=accounts[0])

def test_transfer(accounts, alice, bob, token):
    assert token.balanceOf(alice) == 0
    mint(token, accounts, alice, 3 * PRECISION)
    assert token.totalSupply() == 3 * PRECISION
    assert token.balanceOf(alice) == 3 * PRECISION

    token.transfer(bob, 2 * PRECISION, sender=alice)
    assert token.totalSupply() == 3 * PRECISION
    assert token.balanceOf(alice) == PRECISION
    assert token.balanceOf(bob) == 2 * PRECISION

def test_transfer_exceed(accounts, alice, bob, token):
    mint(token, accounts, alice, PRECISION)
    with ape.reverts():
        token.transfer(bob, 2 * PRECISION, sender=alice)

def test_approve(alice, bob, token):
    assert token.allowance(alice, bob) == 0
    assert token.allowance(bob, alice) == 0
    token.approve(bob, PRECISION, sender=alice)
    assert token.allowance(alice, bob) == PRECISION
    assert token.allowance(bob, alice) == 0

def test_increase_allowance(alice, bob, token):
    token.approve(bob, PRECISION, sender=alice)
    token.increaseAllowance(bob, 2 * PRECISION, sender=alice)
    assert token.allowance(alice, bob) == 3 * PRECISION
    assert token.allowance(bob, alice) == 0

def test_decrease_allowance(alice, bob, token):
    token.approve(bob, 3 * PRECISION, sender=alice)
    token.decreaseAllowance(bob, 2 * PRECISION, sender=alice)
    assert token.allowance(alice, bob) == PRECISION
    assert token.allowance(bob, alice) == 0

def test_transfer_from(accounts, alice, bob, charlie, token):
    mint(token, accounts, alice, 3 * PRECISION)
    token.approve(bob, 5 * PRECISION, sender=alice)

    token.transferFrom(alice, charlie, 2 * PRECISION, sender=bob)
    assert token.totalSupply() == 3 * PRECISION
    assert token.balanceOf(alice) == PRECISION
    assert token.balanceOf(bob) == 0
    assert token.balanceOf(charlie) == 2 * PRECISION
    assert token.allowance(alice, bob) == 3 * PRECISION

def test_transfer_from_exceed(accounts, alice, bob, charlie, token):
    mint(token, accounts, alice, 3 * PRECISION)
    token.approve(bob, PRECISION, sender=alice)
    
    with ape.reverts():
        token.transferFrom(alice, charlie, 2 * PRECISION, sender=bob)

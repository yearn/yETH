# @version 0.3.7

from vyper.interfaces import ERC20

interface RateProvider:
    def rate(_asset: address) -> uint256: nonpayable

interface PoolToken:
    def mint(_account: address, _value: uint256): nonpayable
    def burn(_account: address, _value: uint256): nonpayable

token: public(address)
supply: public(uint256)
amplification: public(uint256)
staking: public(address)
num_assets: public(uint256)
assets: public(address[MAX_NUM_ASSETS])
rate_providers: public(HashMap[address, address])
balances: public(HashMap[address, uint256]) # x_i r_i
rates: public(HashMap[address, uint256]) # r_i
weights: public(HashMap[address, uint256]) # w_i

w_prod: uint256 # weight product: product(w_i^(w_i * n))
vb_prod: uint256 # virtual balance product: product((x_i r_i)^(w_i * n))
vb_sum: uint256 # virtual balance sum: sum(x_i r_i)

PRECISION: constant(uint256) = 1_000_000_000_000_000_000
MAX_NUM_ASSETS: constant(uint256) = 32

@external
def get_dy(_i: address, _j: address, _dx: uint256) -> uint256:
    # TODO
    return 0

@external
def exchange(_i: address, _j: address, _dx: uint256, _min_dy: uint256, _receiver: address = msg.sender) -> uint256:
    # update rates for from and to assets
    # reverts if either is not part of the pool
    assets: DynArray[address, MAX_NUM_ASSETS] = [_i, _j]
    self._update_rates(assets)
    self._update_supply()

    # TODO: solve invariant for x_j
    # TODO: check safety range

    self.balances[_i] += _dx * self.rates[_i] / PRECISION
    dy: uint256 = self.balances[_j] * PRECISION / self.rates[_j] - self._calc_y(_j)
    assert dy >= _min_dy

    assert ERC20(_i).transferFrom(msg.sender, self, _dx, default_return_value=True)
    assert ERC20(_j).transfer(_receiver, dy, default_return_value=True)

    return dy

@external
def add_liquidity(_assets: DynArray[address, MAX_NUM_ASSETS], _amounts: DynArray[uint256, MAX_NUM_ASSETS], _min_lp_amount: uint256, _receiver: address = msg.sender):
    assert len(_assets) == len(_amounts)
    self._update_rates(_assets)

    # TODO: fees

    # update supply to account for changes in r/w/A
    prev_supply: uint256 = self._update_supply()
    if prev_supply == 0:
        # initial deposit, must contain all assets
        assert len(_assets) == self.num_assets

    vb_prod: uint256 = self.vb_prod
    vb_sum: uint256 = self.vb_sum
    num_assets: uint256 = self.num_assets
    for i in range(MAX_NUM_ASSETS):
        if i == len(_assets):
            break

        asset: address = _assets[i]
        amount: uint256 = _amounts[i]
        assert amount > 0 # dev: amounts must be non-zero

        # update stored virtual balance
        prev_bal: uint256 = self.balances[asset]
        dbal: uint256 = amount * self.rates[asset] / PRECISION
        bal: uint256 = prev_bal + dbal
        self.balances[asset] = bal

        if prev_supply == 0:
            # initial deposit, must contain all assets
            assert asset == self.assets[i]
        else:
            # update product and sum of virtual balances
            vb_prod = vb_prod * self._pow(bal * PRECISION / prev_bal, self.weights[asset] * num_assets) / PRECISION
            vb_sum += dbal
            # TODO: check safety range

        assert ERC20(asset).transferFrom(msg.sender, self, amount, default_return_value=True)
    
    if prev_supply == 0:
        # initital deposit, calculate product of virtual balances
        vb_prod, vb_sum = self._calc_vb_prod_sum()
        assert vb_prod > 0 # dev: amounts must be non-zero
    self.vb_prod = vb_prod
    self.vb_sum = vb_sum

    # update supply
    supply: uint256 = self._calc_supply()
    self.supply = supply

    # mint LP tokens
    mint: uint256 = supply - prev_supply
    assert mint > 0 and mint >= _min_lp_amount # dev: slippage
    PoolToken(self.token).mint(_receiver, mint)

@external
def remove_liquidity():
    pass

@external
def remove_liquidity_single():
    pass

@internal
def _update_rates(_assets: DynArray[address, MAX_NUM_ASSETS]):
    # TODO: weight changes

    vb_prod: uint256 = self.vb_prod
    num_assets: uint256 = self.num_assets
    for asset in _assets:
        provider: address = self.rate_providers[asset]
        assert provider != empty(address) # dev: asset not whitelisted
        prev_rate: uint256 = self.rates[asset]
        rate: uint256 = RateProvider(provider).rate(asset)
        if rate == prev_rate:
            continue
        self.rates[asset] = rate
        
        if vb_prod > 0:
            ratio: uint256 = self._pow(rate * PRECISION / prev_rate, self.weights[asset] * num_assets)
            vb_prod = ratio * vb_prod / PRECISION

    if vb_prod == self.vb_prod:
        return
    self.vb_prod = vb_prod
    self._update_supply()

@internal
def _update_supply() -> uint256:
    # calculate new supply and burn or mint the difference from the staking contract
    prev_supply: uint256 = self.supply
    if prev_supply == 0:
        return 0

    supply: uint256 = self._calc_supply()
    if supply > prev_supply:
        PoolToken(self.token).mint(self.staking, supply - prev_supply)
    else:
        PoolToken(self.token).burn(self.staking, prev_supply - supply)
    self.supply = supply
    return supply


@internal
def _calc_vb_prod_sum() -> (uint256, uint256):
    prod: uint256 = PRECISION
    sum: uint256 = 0
    num_assets: uint256 = self.num_assets
    for asset in self.assets:
        bal: uint256 = self.balances[asset]
        prod = prod * self._pow(bal, self.weights[asset] * num_assets) / PRECISION
        sum += bal
    return prod, sum

@internal
@view
def _calc_supply() -> uint256:
    # TODO: weight changes
    # TODO: amplification changes
    # TODO: solve invariant for supply
    return PRECISION

@internal
@view
def _calc_y(_j: address) -> uint256:
    # TODO: solve invariant for x_j
    return PRECISION

@internal
@pure
def _pow(x: uint256, y: uint256) -> uint256:
    # TODO: x^y
    return 1

# @version 0.3.7

from vyper.interfaces import ERC20

interface RateProvider:
    def rate(_asset: address) -> uint256: nonpayable

interface PoolToken:
    def mint(_account: address, _value: uint256): nonpayable
    def burn(_account: address, _value: uint256): nonpayable

token: public(immutable(address))
supply: public(uint256)
amplification: public(uint256)
staking: public(address)
num_assets: public(uint256)
assets: public(address[MAX_NUM_ASSETS])
rate_providers: public(HashMap[address, address])
balances: public(HashMap[address, uint256]) # x_i r_i
rates: public(HashMap[address, uint256]) # r_i
weights: public(HashMap[address, uint256]) # w_i

w_prod: uint256 # weight product: product(w_i^(w_i n)) = 1/w^n
vb_prod: uint256 # virtual balance product: D^n / product((x_i r_i / w_i)^(w_i n))
vb_sum: uint256 # virtual balance sum: sum(x_i r_i)

PRECISION: constant(uint256) = 1_000_000_000_000_000_000
MAX_NUM_ASSETS: constant(uint256) = 32

# powers of 10
E3: constant(int256)          = 1_000
E6: constant(int256)          = E3 * E3
E9: constant(int256)          = E3 * E6
E12: constant(int256)         = E3 * E9
E15: constant(int256)         = E3 * E12
E18: constant(int256)         = E3 * E15
E20: constant(int256)         = 100 * E18
MIN_NAT_EXP: constant(int256) = -41 * E18
MAX_NAT_EXP: constant(int256) = 130 * E18

# x_n = 2^(7-n), a_n = exp(x_n)
# in 20 decimals for n >= 2
X0: constant(int256)  = 128 * E18 # 18 decimals
A0: constant(int256)  = 38_877_084_059_945_950_922_200 * E15 * E18 # no decimals
X1: constant(int256)  = X0 / 2 # 18 decimals
A1: constant(int256)  = 6_235_149_080_811_616_882_910 * E6 # no decimals
X2: constant(int256)  = X1 * 100 / 2
A2: constant(int256)  = 7_896_296_018_268_069_516_100 * E12
X3: constant(int256)  = X2 / 2
A3: constant(int256)  = 888_611_052_050_787_263_676 * E6
X4: constant(int256)  = X3 / 2
A4: constant(int256)  = 298_095_798_704_172_827_474 * E3
X5: constant(int256)  = X4 / 2
A5: constant(int256)  = 5_459_815_003_314_423_907_810
X6: constant(int256)  = X5 / 2
A6: constant(int256)  = 738_905_609_893_065_022_723
X7: constant(int256)  = X6 / 2
A7: constant(int256)  = 271_828_182_845_904_523_536
X8: constant(int256)  = X7 / 2
A8: constant(int256)  = 164_872_127_070_012_814_685
X9: constant(int256)  = X8 / 2
A9: constant(int256)  = 128_402_541_668_774_148_407
X10: constant(int256) = X9 / 2
A10: constant(int256) = 11_331_4845_306_682_631_683
X11: constant(int256) = X10 / 2
A11: constant(int256) = 1_064_49_445_891_785_942_956

@external
def __init__(
    _token: address, 
    _amplification: uint256,
    _assets: DynArray[address, MAX_NUM_ASSETS], 
    _rate_providers: DynArray[address, MAX_NUM_ASSETS], 
    _weights: DynArray[uint256, MAX_NUM_ASSETS]
):
    num_assets: uint256 = len(_assets)
    assert len(_rate_providers) == num_assets and len(_weights) == num_assets

    token = _token
    self.amplification = _amplification
    self.num_assets = num_assets
    
    weight_sum: uint256 = 0
    for i in range(MAX_NUM_ASSETS):
        if i == num_assets:
            break
        asset: address = _assets[i]
        assert asset != empty(address)
        self.assets[i] = asset
        assert _rate_providers[i] != empty(address)
        assert self.rate_providers[asset] == empty(address)
        self.rate_providers[asset] = _rate_providers[i]
        assert _weights[i] > 0
        self.weights[asset] = _weights[i]
        weight_sum += _weights[i]
    assert weight_sum == PRECISION

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
@nonreentrant('lock')
def add_liquidity(_assets: DynArray[address, MAX_NUM_ASSETS], _amounts: DynArray[uint256, MAX_NUM_ASSETS], _min_lp_amount: uint256, _receiver: address = msg.sender) -> uint256:
    assert len(_assets) == len(_amounts)
    assert len(_assets) > 0
    self._update_rates(_assets) # also checks that the assets are all whitelisted

    # TODO: fees for imbalanced deposits
    # TODO: safety range

    prev_supply: uint256 = self.supply
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
            vb_prod = vb_prod * self._pow(prev_bal * PRECISION / bal, self.weights[asset] * num_assets) / PRECISION
            # the `D^n` factor will be updated in `_calc_supply()`
            vb_sum += dbal
            # TODO: check safety range

        assert ERC20(asset).transferFrom(msg.sender, self, amount, default_return_value=True)
    
    if prev_supply == 0:
        # initital deposit, calculate necessary variables
        self.w_prod = self._calc_w_prod()
        vb_prod, vb_sum = self._calc_vb_prod_sum()
        assert vb_prod > 0 # dev: amounts must be non-zero
        self.supply = vb_sum
    self.vb_prod = vb_prod
    self.vb_sum = vb_sum

    # update supply
    supply: uint256 = 0
    supply, self.vb_prod = self._calc_supply()
    self.supply = supply

    # mint LP tokens
    mint: uint256 = supply - prev_supply
    assert mint > 0 and mint >= _min_lp_amount # dev: slippage
    PoolToken(token).mint(_receiver, mint)

    return mint

@external
@nonreentrant('lock')
def remove_liquidity(_amount: uint256, _receiver: address = msg.sender):
    assets: DynArray[address, MAX_NUM_ASSETS] = []
    for asset in self.assets:
        if asset == empty(address):
            break
        assets.append(asset)
    self._update_rates(assets)

    # update supply
    prev_supply: uint256 = self.supply
    supply: uint256 = prev_supply - _amount
    self.supply = supply
    PoolToken(token).burn(msg.sender, _amount)

    vb_prod: uint256 = self.vb_prod
    vb_sum: uint256 = self.vb_sum
    num_assets: uint256 = self.num_assets
    for asset in assets:
        prev_bal: uint256 = self.balances[asset]
        dbal: uint256 = prev_bal * _amount / prev_supply
        bal: uint256 = prev_bal - dbal
        vb_prod = vb_prod * prev_supply / supply * self._pow(prev_bal * PRECISION / bal, self.weights[asset] * num_assets) / PRECISION
        vb_sum -= dbal
        self.balances[asset] = bal
        assert ERC20(asset).transfer(_receiver, dbal * PRECISION / self.rates[asset], default_return_value=True)
    self.vb_prod = vb_prod
    self.vb_sum = vb_sum

@external
@nonreentrant('lock')
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
        assert rate > 0
        if rate == prev_rate:
            continue
        self.rates[asset] = rate

        if prev_rate > 0:
            # multiply out old rate and divide by new
            vb_prod = vb_prod * self._pow(prev_rate * PRECISION / rate, self.weights[asset] * num_assets) / PRECISION

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

    supply: uint256 = 0
    supply, self.vb_prod = self._calc_supply()
    if supply > prev_supply:
        PoolToken(token).mint(self.staking, supply - prev_supply)
    else:
        PoolToken(token).burn(self.staking, prev_supply - supply)
    self.supply = supply
    return supply

# MATH FUNCTIONS
# make sure to keep in sync with Math.vy

@internal
def _calc_w_prod() -> uint256:
    prod: uint256 = PRECISION
    num_assets: uint256 = self.num_assets
    for asset in self.assets:
        weight: uint256 = self.weights[asset]
        prod = prod * self._pow(weight, weight * num_assets) / PRECISION
    return prod

@internal
def _calc_vb_prod_sum() -> (uint256, uint256):
    p: uint256 = PRECISION
    s: uint256 = 0
    for asset in self.assets:
        if asset == empty(address):
            break
        s += self.balances[asset]
    num_assets: uint256 = self.num_assets
    for asset in self.assets:
        if asset == empty(address):
            break
        weight: uint256 = self.weights[asset]
        p = p * s / self._pow(self.balances[asset] * PRECISION / weight, weight * num_assets)
    return p, s

@internal
@view
def _calc_supply() -> (uint256, uint256):
    # TODO: weight changes
    # TODO: amplification changes

    # s[n+1] = (A w^n sum - s^(n+1)/(w^n prod^n)) / (A w^n - 1)
    #        = (l - s r) / d

    l: uint256 = self.amplification * PRECISION / self.w_prod
    d: uint256 = l - PRECISION
    s: uint256 = self.supply
    r: uint256 = self.vb_prod
    l = l * self.vb_sum

    num_assets: uint256 = self.num_assets
    for _ in range(255):
        sp: uint256 = (l - s * r) / d
        for i in range(MAX_NUM_ASSETS):
            if i == num_assets:
                break
            r = r * sp / s
        if sp >= s:
            if sp - s <= 1:
                return sp, r
        else:
            if s - sp == 1:
                return sp, r
        s = sp

    raise # dev: no convergence

@internal
@view
def _calc_y(_j: address) -> uint256:
    # TODO: solve invariant for x_j
    return PRECISION

@internal
@pure
def _pow(_x: uint256, _y: uint256) -> uint256:
    # x^y
    if _y == 0:
        return convert(E18, uint256)

    if _x == 0:
        return 0
    
    assert shift(_x, -255) == 0 # dev: out of bounds

    # x^y = e^log(x^y)) = e^(y log x)
    # TODO: ln36
    l: int256 = self._log(convert(_x, int256)) * convert(_y, int256) / E18
    return convert(self._exp(l), uint256)

@internal
@pure
def _log(_a: int256) -> int256:
    if _a < E18:
        # 1/a > 1, log(a) = -log(1/a)
        return -self.__log(E18 * E18 / _a)
    return self.__log(_a)

@internal
@pure
def __log(_a: int256) -> int256:
    # log a = sum(k_n x_n) + log(rem)
    #       = log(product(a_n^k_n) * rem)
    # k_n = {0,1}, x_n = 2^(7-n), log(a_n) = x_n
    a: int256 = _a
    s: int256 = 0

    # divide out a_ns
    if a >= A0 * E18:
        a /= A0
        s += X0
    if a >= A1 * E18:
        a /= A1
        s += X1
    
    # other terms are in 20 decimals
    a *= 100
    s *= 100

    if a >= A2:
        a = a * E20 / A2
        s += X2
    if a >= A3:
        a = a * E20 / A3
        s += X3
    if a >= A4:
        a = a * E20 / A4
        s += X4
    if a >= A5:
        a = a * E20 / A5
        s += X5
    if a >= A6:
        a = a * E20 / A6
        s += X6
    if a >= A7:
        a = a * E20 / A7
        s += X7
    if a >= A8:
        a = a * E20 / A8
        s += X8
    if a >= A9:
        a = a * E20 / A9
        s += X9
    if a >= A10:
        a = a * E20 / A10
        s += X10
    if a >= A11:
        a = a * E20 / A11
        s += X11

    # a < A11 (1.06), taylor series for remainder
    # z = (a - 1) / (a + 1)
    # c = log a = 2 * sum(z^(2n + 1) / (2n + 1))
    z: int256 = (a - E20) * E20 / (a + E20)
    zsq: int256 = z * z / E20
    n: int256 = z
    c: int256 = z

    n = n * zsq / E20
    c += n / 3
    n = n * zsq / E20
    c += n / 5
    n = n * zsq / E20
    c += n / 7
    n = n * zsq / E20
    c += n / 9
    n = n * zsq / E20
    c += n / 11

    c *= 2
    return (s + c) / 100

@internal
@pure
def _exp(_x: int256) -> int256:
    assert _x >= MIN_NAT_EXP and _x <= MAX_NAT_EXP
    if _x < 0:
        # exp(-x) = 1/exp(x)
        return E18 * E18 / self.__exp(-_x)
    return self.__exp(_x)

@internal
@pure
def __exp(_x: int256) -> int256:
    # e^x = e^(sum(k_n x_n) + rem)
    #     = product(e^(k_n x_n)) * e^(rem)
    #     = product(a_n^k_n) * e^(rem)
    # k_n = {0,1}, x_n = 2^(7-n), a_n = exp(x_n)
    x: int256 = _x

    # subtract out x_ns
    f: int256 = 1
    if x >= X0:
        x -= X0
        f = A0
    elif x >= X1:
        x -= X1
        f = A1

    # other terms are in 20 decimals
    x *= 100

    p: int256 = E20
    if x >= X2:
        x -= X2
        p = p * A2 / E20
    if x >= X3:
        x -= X3
        p = p * A3 / E20
    if x >= X4:
        x -= X4
        p = p * A4 / E20
    if x >= X5:
        x -= X5
        p = p * A5 / E20
    if x >= X6:
        x -= X6
        p = p * A6 / E20
    if x >= X7:
        x -= X7
        p = p * A7 / E20
    if x >= X8:
        x -= X8
        p = p * A8 / E20
    if x >= X9:
        x -= X9
        p = p * A9 / E20
    
    # x < X9 (0.25), taylor series for remainder
    # c = e^x = sum(x^n / n!)
    n: int256 = x
    c: int256 = E20 + x

    n = n * x / E20 / 2
    c += n
    n = n * x / E20 / 3
    c += n
    n = n * x / E20 / 4
    c += n
    n = n * x / E20 / 5
    c += n
    n = n * x / E20 / 6
    c += n
    n = n * x / E20 / 7
    c += n
    n = n * x / E20 / 8
    c += n
    n = n * x / E20 / 9
    c += n
    n = n * x / E20 / 10
    c += n
    n = n * x / E20 / 11
    c += n
    n = n * x / E20 / 12
    c += n

    return p * c / E20 * f / 100

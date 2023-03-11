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
management: public(address)
fee_rate: public(uint256)

w_prod: uint256 # weight product: product(w_i^(w_i n)) = w^n
vb_prod: uint256 # virtual balance product: D^n / product((x_i r_i / w_i)^(w_i n))
vb_sum: uint256 # virtual balance sum: sum(x_i r_i)

PRECISION: constant(uint256) = 1_000_000_000_000_000_000
MAX_NUM_ASSETS: constant(uint256) = 32

# powers of 10
E3: constant(int256)               = 1_000
E6: constant(int256)               = E3 * E3
E9: constant(int256)               = E3 * E6
E12: constant(int256)              = E3 * E9
E15: constant(int256)              = E3 * E12
E17: constant(int256)              = 100 * E15
E18: constant(int256)              = E3 * E15
E20: constant(int256)              = 100 * E18
E36: constant(int256)              = E18 * E18
MAX_POW_REL_ERR: constant(uint256) = 10_000 # 1e-14
MIN_NAT_EXP: constant(int256)      = -41 * E18
MAX_NAT_EXP: constant(int256)      = 130 * E18
LOG36_LOWER: constant(int256)      = E18 - E17
LOG36_UPPER: constant(int256)      = E18 + E17
MILD_EXP_BOUND: constant(uint256)  = 2**254 / 100_000_000_000_000_000_000

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
    assert num_assets > 0
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

    self.management = msg.sender

@external
def get_dx(_i: address, _j: address, _dy: uint256) -> uint256:
    # TODO
    return 0

@external
def get_dy(_i: address, _j: address, _dx: uint256) -> uint256:
    # TODO
    return 0

@external
@nonreentrant('lock')
def swap(_i: address, _j: address, _dx: uint256, _min_dy: uint256, _receiver: address = msg.sender) -> uint256:
    assert _i != _j # dev: same input and output asset
    assert _dx > 0 # dev: zero amount
    num_assets: uint256 = self.num_assets

    prev_vbx: uint256 = 0
    dvbx: uint256 = 0
    vbx: uint256 = 0
    vb_prod: uint256 = self.vb_prod
    vb_sum: uint256 = self.vb_sum

    dx_fee: uint256 = _dx * self.fee_rate / PRECISION
    if dx_fee > 0:
        # add fee to pool
        prev_vbx = self.balances[_i]
        dvbx = dx_fee * self.rates[_i] / PRECISION
        vbx = prev_vbx + dvbx
        self.balances[_i] = vbx
        vb_prod = vb_prod * PRECISION / self._pow_down(vbx * PRECISION / prev_vbx, self.weights[_i] * num_assets)
        vb_sum += dvbx
    # TODO: consider adding fee after swap

    # update rates for from and to assets
    # reverts if either is not part of the pool
    assets: DynArray[address, MAX_NUM_ASSETS] = [_i, _j]
    vb_prod, vb_sum = self._update_rates(assets, 3, vb_prod, vb_sum, dx_fee > 0)

    # TODO: check safety range

    prev_vbx = self.balances[_i]
    prev_vby: uint256 = self.balances[_j]

    dvbx = (_dx - dx_fee) * self.rates[_i] / PRECISION
    vbx = prev_vbx + dvbx
    
    # update x_i and remove x_j from variables
    self.balances[_i] = vbx
    vb_prod = vb_prod * self._pow_up(prev_vby, self.weights[_j] * num_assets) / self._pow_down(vbx * PRECISION / prev_vbx, self.weights[_i] * num_assets)
    vb_sum = vb_sum + dvbx - prev_vby

    # calulate new balance of out token
    vby: uint256 = self._calc_vb(_j, vb_prod, vb_sum)
    dy: uint256 = (prev_vby - vby) * PRECISION / self.rates[_j]
    assert dy >= _min_dy

    # update variables
    self.balances[_j] = vby
    self.vb_prod = vb_prod * PRECISION / self._pow_up(vby, self.weights[_j] * num_assets)
    self.vb_sum = vb_sum + vby

    # transfer tokens
    assert ERC20(_i).transferFrom(msg.sender, self, _dx, default_return_value=True)
    assert ERC20(_j).transfer(_receiver, dy, default_return_value=True)

    return dy

@external
@nonreentrant('lock')
def swap_exact_out(_i: address, _j: address, _dy: uint256, _max_dx: uint256, _receiver: address = msg.sender) -> uint256:
    # update rates for from and to assets
    # reverts if either is not part of the pool
    vb_prod: uint256 = 0
    vb_sum: uint256 = 0
    assets: DynArray[address, MAX_NUM_ASSETS] = [_i, _j]
    vb_prod, vb_sum = self._update_rates(assets, 3, self.vb_prod, self.vb_sum, False)

    # TODO: check safety range
    # TODO: fees

    num_assets: uint256 = self.num_assets
    prev_vbx: uint256 = self.balances[_i]
    prev_vby: uint256 = self.balances[_j]

    dvby: uint256 = _dy * self.rates[_j] / PRECISION
    vby: uint256 = prev_vby - dvby

    # update x_j and remove x_i from variables
    self.balances[_j] = vby
    vb_prod = vb_prod * self._pow_up(prev_vbx, self.weights[_i] * num_assets) / self._pow_down(vby * PRECISION / prev_vby, self.weights[_j] * num_assets)
    vb_sum = vb_sum - dvby - prev_vbx

    # calulate new balance of in token
    vbx: uint256 = self._calc_vb(_i, vb_prod, vb_sum)
    dx: uint256 = (vbx - prev_vbx) * PRECISION / self.rates[_i]
    dx_fee: uint256 = self.fee_rate
    dx_fee = dx * dx_fee / (PRECISION - dx_fee)
    dx += dx_fee
    vbx += dx_fee * self.rates[_i] / PRECISION
    assert dx <= _max_dx

    # update variables
    self.balances[_i] = vbx
    vb_prod = vb_prod * PRECISION / self._pow_up(vbx, self.weights[_i] * num_assets)
    vb_sum += vbx

    if dx_fee > 0:
        supply: uint256 = 0
        supply, vb_prod = self._update_supply(self.supply, vb_prod, vb_sum)

    self.vb_prod = vb_prod
    self.vb_sum = vb_sum

    assert ERC20(_i).transferFrom(msg.sender, self, dx, default_return_value=True)
    assert ERC20(_j).transfer(_receiver, _dy, default_return_value=True)

    return dx

@external
@nonreentrant('lock')
def add_liquidity(_amounts: DynArray[uint256, MAX_NUM_ASSETS], _min_lp_amount: uint256, _receiver: address = msg.sender) -> uint256:
    num_assets: uint256 = self.num_assets
    assert len(_amounts) == num_assets

    vb_prod: uint256 = self.vb_prod
    vb_sum: uint256 = self.vb_sum

    assets: DynArray[address, MAX_NUM_ASSETS] = []
    lowest: uint256 = max_value(uint256)
    flags: uint256 = 0
    for i in range(MAX_NUM_ASSETS):
        if i == num_assets:
            break
        asset: address = self.assets[i]
        assets.append(asset)
        if _amounts[i] > 0:
            flags += shift(1, convert(i, int256))
            if vb_sum > 0 and lowest > 0:
                # find lowest increase in balance - a fee is applied on anything above it
                lowest = min(_amounts[i] * self.rates[asset] / self.balances[asset], lowest)
        else:
            lowest = 0
    assert flags > 0 # dev: need to deposit at least one asset
        
    # update rates
    vb_prod, vb_sum = self._update_rates(assets, flags, vb_prod, vb_sum, False)
    prev_supply: uint256 = self.supply

    vb_prod_final: uint256 = vb_prod
    vb_sum_final: uint256 = vb_sum
    fee_rate: uint256 = self.fee_rate
    for i in range(MAX_NUM_ASSETS):
        if i == num_assets:
            break

        amount: uint256 = _amounts[i]
        if amount == 0:
            assert prev_supply > 0 # dev: initial deposit amounts must be non-zero
            continue

        asset: address = assets[i]

        # update stored virtual balance
        prev_vb: uint256 = self.balances[asset]
        dvb: uint256 = amount * self.rates[asset] / PRECISION
        vb: uint256 = prev_vb + dvb
        self.balances[asset] = vb

        if prev_supply > 0:
            weight: uint256 = self.weights[asset] * num_assets

            # update product and sum of virtual balances
            vb_prod_final = vb_prod_final * self._pow_up(prev_vb * PRECISION / vb, weight) / PRECISION
            # the `D^n` factor will be updated in `_calc_supply()`
            vb_sum_final += dvb

            # remove fees from balance and recalculate sum and product
            fee: uint256 = (dvb - prev_vb * lowest / PRECISION) * fee_rate / PRECISION
            vb_prod = vb_prod * self._pow_up(prev_vb * PRECISION / (vb - fee), weight) / PRECISION
            vb_sum += dvb - fee
        
        # TODO: check safety range

        assert ERC20(asset).transferFrom(msg.sender, self, amount, default_return_value=True)
    
    supply: uint256 = prev_supply
    if prev_supply == 0:
        # initital deposit, calculate necessary variables
        self.w_prod = self._calc_w_prod()
        vb_prod, vb_sum = self._calc_vb_prod_sum()
        assert vb_prod > 0 # dev: amounts must be non-zero
        supply = vb_sum

    # mint LP tokens
    supply, vb_prod = self._calc_supply(supply, vb_prod, vb_sum)
    mint: uint256 = supply - prev_supply
    assert mint > 0 and mint >= _min_lp_amount # dev: slippage
    PoolToken(token).mint(_receiver, mint)

    supply_final: uint256 = supply
    if prev_supply > 0:
        # mint fees
        supply_final, vb_prod_final = self._calc_supply(prev_supply, vb_prod_final, vb_sum_final)
        PoolToken(token).mint(self.staking, supply_final - supply)
    else:
        vb_prod_final = vb_prod
        vb_sum_final = vb_sum

    self.supply = supply_final
    self.vb_prod = vb_prod_final
    self.vb_sum = vb_sum_final

    return mint

@external
@nonreentrant('lock')
def remove_liquidity(_amount: uint256, _receiver: address = msg.sender):
    # update rates
    assets: DynArray[address, MAX_NUM_ASSETS] = []
    num_assets: uint256 = self.num_assets
    for i in range(MAX_NUM_ASSETS):
        if i == num_assets:
            break
        assets.append(self.assets[i])
    vb_prod: uint256 = 0
    vb_sum: uint256 = 0
    vb_prod, vb_sum = self._update_rates(assets, shift(1, convert(num_assets, int256)) - 1, self.vb_prod, self.vb_sum, False)

    # update supply
    prev_supply: uint256 = self.supply
    supply: uint256 = prev_supply - _amount
    self.supply = supply
    PoolToken(token).burn(msg.sender, _amount)

    # update necessary variables and transfer assets
    for asset in assets:
        prev_bal: uint256 = self.balances[asset]
        dbal: uint256 = prev_bal * _amount / prev_supply
        bal: uint256 = prev_bal - dbal
        vb_prod = vb_prod * prev_supply / supply * self._pow_down(prev_bal * PRECISION / bal, self.weights[asset] * num_assets) / PRECISION
        vb_sum -= dbal
        self.balances[asset] = bal
        assert ERC20(asset).transfer(_receiver, dbal * PRECISION / self.rates[asset], default_return_value=True)

    self.vb_prod = vb_prod
    self.vb_sum = vb_sum

@external
@nonreentrant('lock')
def remove_liquidity_single(_asset: address, _amount: uint256, _receiver: address = msg.sender):
    # update rate
    vb_prod: uint256 = 0
    vb_sum: uint256 = 0
    assets: DynArray[address, MAX_NUM_ASSETS] = [_asset]
    vb_prod, vb_sum = self._update_rates(assets, 1, self.vb_prod, self.vb_sum, False)

    # update supply
    prev_supply: uint256 = self.supply
    supply: uint256 = prev_supply - _amount
    self.supply = supply
    PoolToken(token).burn(msg.sender, _amount)

    weight: uint256 = self.weights[_asset] * self.num_assets
    prev_vb: uint256 = self.balances[_asset]

    # update variables
    num_assets: uint256 = self.num_assets
    vb_prod = vb_prod * self._pow_up(prev_vb, weight) / PRECISION
    for i in range(MAX_NUM_ASSETS):
        if i == num_assets:
            break
        vb_prod = vb_prod * supply / prev_supply
    vb_sum = vb_sum - prev_vb

    # calculate new balance of asset
    vb: uint256 = self._calc_vb(_asset, vb_prod, vb_sum)
    dx: uint256 = (prev_vb - vb) * PRECISION / self.rates[_asset]

    # update variables
    self.balances[_asset] = vb
    self.vb_prod = vb_prod * PRECISION / self._pow_up(vb, weight)
    self.vb_sum = vb_sum + vb

    assert ERC20(_asset).transfer(_receiver, dx, default_return_value=True)

@external
def update_rates(_assets: DynArray[address, MAX_NUM_ASSETS]):
    assert len(_assets) > 0
    self.vb_prod, self.vb_sum = self._update_rates(_assets, shift(1, convert(len(_assets), int256)) - 1, self.vb_prod, self.vb_sum, False)

@external
def set_fee_rate(_fee_rate: uint256):
    assert msg.sender == self.management
    # TODO: reasonable bounds
    self.fee_rate = _fee_rate

@external
def set_staking(_staking: address):
    assert msg.sender == self.management
    self.staking = _staking

@external
def set_management(_management: address):
    assert msg.sender == self.management
    self.management = _management

@internal
def _update_rates(_assets: DynArray[address, MAX_NUM_ASSETS], _flags: uint256, _vb_prod: uint256, _vb_sum: uint256, _force: bool) -> (uint256, uint256):
    # TODO: weight changes

    vb_prod: uint256 = _vb_prod
    vb_sum: uint256 = _vb_sum
    num_assets: uint256 = self.num_assets
    for i in range(MAX_NUM_ASSETS):
        if i == len(_assets):
            break
        if _flags & shift(1, convert(i, int256)) == 0:
            continue
        asset: address = _assets[i]
        provider: address = self.rate_providers[asset]
        assert provider != empty(address) # dev: asset not whitelisted
        prev_rate: uint256 = self.rates[asset]
        rate: uint256 = RateProvider(provider).rate(asset)
        assert rate > 0 # dev: no rate
        if rate == prev_rate:
            continue
        self.rates[asset] = rate

        if prev_rate > 0:
            # factor out old rate and factor in new
            vb_prod = vb_prod * self._pow_up(prev_rate * PRECISION / rate, self.weights[asset] * num_assets) / PRECISION

            prev_bal: uint256 = self.balances[asset]
            bal: uint256 = prev_bal * rate / prev_rate
            self.balances[asset] = bal
            vb_sum = vb_sum + bal - prev_bal

    if not _force and vb_prod == _vb_prod and vb_sum == _vb_sum:
        return vb_prod, vb_sum

    supply: uint256 = 0
    supply, vb_prod = self._update_supply(self.supply, vb_prod, vb_sum)
    return vb_prod, vb_sum

@internal
def _update_supply(_supply: uint256, _vb_prod: uint256, _vb_sum: uint256) -> (uint256, uint256):
    # calculate new supply and burn or mint the difference from the staking contract
    if _supply == 0:
        return 0, _vb_prod

    supply: uint256 = 0
    vb_prod: uint256 = 0
    supply, vb_prod = self._calc_supply(_supply, _vb_prod, _vb_sum)
    if supply > _supply:
        PoolToken(token).mint(self.staking, supply - _supply)
    elif supply < _supply:
        PoolToken(token).burn(self.staking, _supply - supply)
    self.supply = supply
    return supply, vb_prod

# MATH FUNCTIONS
# make sure to keep in sync with Math.vy

@internal
def _calc_w_prod() -> uint256:
    prod: uint256 = PRECISION
    num_assets: uint256 = self.num_assets
    for asset in self.assets:
        weight: uint256 = self.weights[asset]
        prod = prod * self._pow_up(weight, weight * num_assets) / PRECISION
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
        p = p * s / self._pow_down(self.balances[asset] * PRECISION / weight, weight * num_assets)
    return p, s

@internal
@view
def _calc_supply(_supply: uint256, _vb_prod: uint256, _vb_sum: uint256) -> (uint256, uint256):
    # TODO: weight changes
    # TODO: amplification changes

    # s[n+1] = (A sum / w^n - s^(n+1) w^n /prod^n)) / (A w^n - 1)
    #        = (l - s r) / d

    l: uint256 = self.amplification * PRECISION / self.w_prod
    d: uint256 = l - PRECISION
    s: uint256 = _supply
    r: uint256 = _vb_prod
    l = l * _vb_sum

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
def _calc_vb(_j: address, _vb_prod: uint256, _vb_sum: uint256) -> uint256:
    # y = x_j, sum' = sum(x_i, i != j), prod' = prod(x_i^w_i, i != j)
    # w = product(w_i), v_i = w_i n, f_i = 1/v_i
    # Iteratively find root of g(y) using Newton's method
    # g(y) = y^(v_j + 1) + (sum' + (w^n / A - 1) D y^(w_j n) - D^(n+1) w^2n / prod'^n
    #      = y^(v_j + 1) + b y^(v_j) - c
    # y[n+1] = y[n] - g(y[n])/g'(y[n])
    #        = (y[n]^2 + b (1 - f_j) y[n] + c f_j y[n]^(1 - v_j)) / (f_j + 1) y[n] + b)

    d: uint256 = self.supply
    b: uint256 = d * self.w_prod / self.amplification
    c: uint256 = _vb_prod * b / PRECISION
    b += _vb_sum
    v: uint256 = self.weights[_j] * self.num_assets
    f: uint256 = PRECISION * PRECISION / v

    y: uint256 = self.balances[_j]
    for _ in range(255):
        yp: uint256 = (y + b + d * f / PRECISION + c * f / self._pow_up(y, v) - b * f / PRECISION - d) * y / (f * y / PRECISION + y + b - d)
        if yp >= y:
            if yp - y <= 1:
                return yp
        else:
            if y - yp <= 1:
                return yp
        y = yp
    
    raise # dev: no convergence

@internal
@pure
def _pow_up(_x: uint256, _y: uint256) -> uint256:
    # guaranteed to be >= the actual value
    p: uint256 = self._pow(_x, _y)
    if p == 0:
        return 0
    return p + (p * MAX_POW_REL_ERR - 1) / PRECISION + 1

@internal
@pure
def _pow_down(_x: uint256, _y: uint256) -> uint256:
    # guaranteed to be <= the actual value
    p: uint256 = self._pow(_x, _y)
    if p == 0:
        return 0
    e: uint256 = (p * MAX_POW_REL_ERR - 1) / PRECISION + 1
    if p < e:
        return 0
    return p - e

@internal
@pure
def _pow(_x: uint256, _y: uint256) -> uint256:
    # x^y
    if _y == 0:
        return convert(E18, uint256)

    if _x == 0:
        return 0
    
    assert shift(_x, -255) == 0 # dev: x out of bounds
    assert _y < MILD_EXP_BOUND # dev: y out of bounds

    # x^y = e^log(x^y)) = e^(y log x)
    x: int256 = convert(_x, int256)
    y: int256= convert(_y, int256)
    l: int256 = 0
    if x > LOG36_LOWER and x < LOG36_UPPER:
        l = self._log36(x)
        l = l / E18 * y + (l % E18) * y / E18
    else:
        l = self._log(x) * y
    l /= E18
    return convert(self._exp(l), uint256)

@internal
@pure
def _log36(_x: int256) -> int256:
    x: int256 = _x * E18
    
    # Taylor series
    # z = (x - 1) / (x + 1)
    # c = log x = 2 * sum(z^(2n + 1) / (2n + 1))

    z: int256 = (x - E36) * E36 / (x + E36)
    zsq: int256 = z * z / E36
    n: int256 = z
    c: int256 = z

    n = n * zsq / E36
    c += n / 3
    n = n * zsq / E36
    c += n / 5
    n = n * zsq / E36
    c += n / 7
    n = n * zsq / E36
    c += n / 9
    n = n * zsq / E36
    c += n / 11
    n = n * zsq / E36
    c += n / 13
    n = n * zsq / E36
    c += n / 15

    return c * 2

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

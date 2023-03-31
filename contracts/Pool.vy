# @version 0.3.7

from vyper.interfaces import ERC20

interface ERC20Ext:
    def decimals() -> uint8: view

interface RateProvider:
    def rate(_asset: address) -> uint256: view

interface PoolToken:
    def mint(_account: address, _value: uint256): nonpayable
    def burn(_account: address, _value: uint256): nonpayable

token: public(immutable(address))
supply: public(uint256)
amplification: public(uint256)
staking: public(address)
num_assets: public(uint256)
assets: public(address[MAX_NUM_ASSETS])
rate_providers: public(address[MAX_NUM_ASSETS])
balances: public(uint256[MAX_NUM_ASSETS]) # x_i r_i
rates: public(uint256[MAX_NUM_ASSETS]) # r_i
weights: uint256[MAX_NUM_ASSETS] # (w_i * n, lower * n, upper * n)
management: public(address)
guardian: public(address)
paused: public(bool)
killed: public(bool)
fee_rate: public(uint256)
ramp_step: public(uint256)
ramp_last_time: public(uint256)
ramp_stop_time: public(uint256)
target_amplification: public(uint256)
target_weights: public(uint256[MAX_NUM_ASSETS])

w_prod: public(uint256) # weight product: product(w_i^(w_i n)) = w^n
vb_prod: public(uint256) # virtual balance product: D^n / product((x_i r_i / w_i)^(w_i n))
vb_sum: public(uint256) # virtual balance sum: sum(x_i r_i)

prev_ratio: public(uint256)
ratio: public(uint256)

PRECISION: constant(uint256) = 1_000_000_000_000_000_000
MAX_NUM_ASSETS: constant(uint256) = 32
ALL_ASSETS_FLAG: constant(uint256) = 14528991250861404666834535435384615765856667510756806797353855100662256435713
WEIGHT_MASK: constant(uint256) = 2**85 - 1
LOWER_BAND_SHIFT: constant(int128) = -85
UPPER_BAND_SHIFT: constant(int128) = -170

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
MAX_POW_REL_ERR: constant(uint256) = 100 # 1e-16
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
    assert num_assets >= 2
    assert len(_rate_providers) == num_assets and len(_weights) == num_assets

    token = _token
    self.amplification = _amplification
    self.num_assets = num_assets
    
    weight_sum: uint256 = 0
    for asset in range(MAX_NUM_ASSETS):
        if asset == num_assets:
            break
        assert _assets[asset] != empty(address)
        assert ERC20Ext(_assets[asset]).decimals() == 18
        self.assets[asset] = _assets[asset]
        assert _rate_providers[asset] != empty(address)
        self.rate_providers[asset] = _rate_providers[asset]
        assert _weights[asset] > 0
        self.weights[asset] = self._pack_weight(_weights[asset] * num_assets, PRECISION * num_assets, PRECISION * num_assets)
        weight_sum += _weights[asset]
    assert weight_sum == PRECISION

    self.ramp_step = 1
    self.management = msg.sender
    self.guardian = msg.sender

@external
@nonreentrant('lock')
def swap(_i: uint256, _j: uint256, _dx: uint256, _min_dy: uint256, _receiver: address = msg.sender) -> uint256:
    assert _i != _j # dev: same input and output asset
    assert _i < MAX_NUM_ASSETS and _j < MAX_NUM_ASSETS # dev: index out of bounds
    assert _dx > 0 # dev: zero amount

    # update rates for from and to assets
    assets: DynArray[uint256, MAX_NUM_ASSETS] = [_i, _j]
    vb_prod: uint256 = 0
    vb_sum: uint256 = 0
    vb_prod, vb_sum = self._update_rates(unsafe_add(_i, 1) | shift(unsafe_add(_j, 1), 8), self.vb_prod, self.vb_sum)
    prev_vb_sum: uint256 = vb_sum

    prev_vbx: uint256 = self.balances[_i]
    prev_vby: uint256 = self.balances[_j]
    weight_x: uint256 = self.weights[_i]
    weight_y: uint256 = self.weights[_j]

    dx_fee: uint256 = _dx * self.fee_rate / PRECISION
    dvbx: uint256 = (_dx - dx_fee) * self.rates[_i] / PRECISION
    vbx: uint256 = prev_vbx + dvbx
    
    # update x_i and remove x_j from variables
    vb_prod = vb_prod * self._pow_up(prev_vby, weight_y & WEIGHT_MASK) / self._pow_down(vbx * PRECISION / prev_vbx, weight_x & WEIGHT_MASK)
    vb_sum = vb_sum + dvbx - prev_vby

    # calulate new balance of out token
    vby: uint256 = self._calc_vb(weight_y, prev_vby, self.supply, self.amplification, self.w_prod, vb_prod, vb_sum)
    vb_sum += vby

    # check bands
    num_assets: uint256 = self.num_assets
    self._check_bands(num_assets, prev_vbx * PRECISION / prev_vb_sum, vbx * PRECISION / vb_sum, weight_x)
    self._check_bands(num_assets, prev_vby * PRECISION / prev_vb_sum, vby * PRECISION / vb_sum, weight_y)

    dy: uint256 = (prev_vby - vby) * PRECISION / self.rates[_j]
    assert dy >= _min_dy

    if dx_fee > 0:
        # add fee to pool
        dvbx = dx_fee * self.rates[_i] / PRECISION
        vb_prod = vb_prod * PRECISION / self._pow_down((vbx + dvbx) * PRECISION / vbx, weight_x & WEIGHT_MASK)
        vbx += dvbx
        vb_sum += dvbx

    # update variables
    self.balances[_i] = vbx
    self.balances[_j] = vby
    vb_prod = vb_prod * PRECISION / self._pow_up(vby, weight_y & WEIGHT_MASK)
    
    # mint fees
    if dx_fee > 0:
        supply: uint256 = 0
        supply, vb_prod = self._update_supply(self.supply, vb_prod, vb_sum)

    self.vb_prod = vb_prod
    self.vb_sum = vb_sum

    # transfer tokens
    assert ERC20(self.assets[_i]).transferFrom(msg.sender, self, _dx, default_return_value=True)
    assert ERC20(self.assets[_j]).transfer(_receiver, dy, default_return_value=True)

    return dy

@external
@nonreentrant('lock')
def swap_exact_out(_i: uint256, _j: uint256, _dy: uint256, _max_dx: uint256, _receiver: address = msg.sender) -> uint256:
    assert _i != _j # dev: same input and output asset
    assert _i < MAX_NUM_ASSETS and _j < MAX_NUM_ASSETS # dev: index out of bounds
    assert _dy > 0 # dev: zero amount

    # update rates for from and to assets
    # reverts if either is not part of the pool
    vb_prod: uint256 = 0
    vb_sum: uint256 = 0
    vb_prod, vb_sum = self._update_rates(unsafe_add(_i, 1) | shift(unsafe_add(_j, 1), 8), self.vb_prod, self.vb_sum)
    prev_vb_sum: uint256 = vb_sum

    prev_vbx: uint256 = self.balances[_i]
    prev_vby: uint256 = self.balances[_j]
    weight_x: uint256 = self.weights[_i]
    weight_y: uint256 = self.weights[_j]

    dvby: uint256 = _dy * self.rates[_j] / PRECISION
    vby: uint256 = prev_vby - dvby

    # update x_j and remove x_i from variables
    vb_prod = vb_prod * self._pow_up(prev_vbx, weight_x & WEIGHT_MASK) / self._pow_down(vby * PRECISION / prev_vby, weight_y & WEIGHT_MASK)
    vb_sum = vb_sum - dvby - prev_vbx

    # calulate new balance of in token
    vbx: uint256 = self._calc_vb(weight_x, prev_vbx, self.supply, self.amplification, self.w_prod, vb_prod, vb_sum)
    dx: uint256 = (vbx - prev_vbx) * PRECISION / self.rates[_i]
    dx_fee: uint256 = self.fee_rate
    dx_fee = dx * dx_fee / (PRECISION - dx_fee)
    dx += dx_fee
    vbx += dx_fee * self.rates[_i] / PRECISION
    assert dx <= _max_dx

    # update variables
    self.balances[_i] = vbx
    self.balances[_j] = vby
    vb_prod = vb_prod * PRECISION / self._pow_up(vbx, weight_x & WEIGHT_MASK)
    vb_sum += vbx

    # check bands
    num_assets: uint256 = self.num_assets
    self._check_bands(num_assets, prev_vbx * PRECISION / prev_vb_sum, vbx * PRECISION / vb_sum, weight_x)
    self._check_bands(num_assets, prev_vby * PRECISION / prev_vb_sum, vby * PRECISION / vb_sum, weight_y)

    # mint fees
    if dx_fee > 0:
        supply: uint256 = 0
        supply, vb_prod = self._update_supply(self.supply, vb_prod, vb_sum)

    self.vb_prod = vb_prod
    self.vb_sum = vb_sum

    assert ERC20(self.assets[_i]).transferFrom(msg.sender, self, dx, default_return_value=True)
    assert ERC20(self.assets[_j]).transfer(_receiver, _dy, default_return_value=True)

    return dx

@external
@nonreentrant('lock')
def add_liquidity(_amounts: DynArray[uint256, MAX_NUM_ASSETS], _min_lp_amount: uint256, _receiver: address = msg.sender) -> uint256:
    num_assets: uint256 = self.num_assets
    assert len(_amounts) == num_assets

    vb_prod: uint256 = self.vb_prod
    vb_sum: uint256 = self.vb_sum

    # find lowest relative increase in balance
    assets: uint256 = 0
    lowest: uint256 = max_value(uint256)
    sh: int128 = 0
    for asset in range(MAX_NUM_ASSETS):
        if asset == num_assets:
            break
        if _amounts[asset] > 0:
            assets = assets | shift(unsafe_add(asset, 1), sh)
            sh = unsafe_add(sh, 8)
            if vb_sum > 0 and lowest > 0:
                lowest = min(_amounts[asset] * self.rates[asset] / self.balances[asset], lowest)
        else:
            lowest = 0
    assert sh > 0 # dev: need to deposit at least one asset

    # update rates
    vb_prod, vb_sum = self._update_rates(assets, vb_prod, vb_sum)
    prev_supply: uint256 = self.supply

    vb_prod_final: uint256 = vb_prod
    vb_sum_final: uint256 = vb_sum
    fee_rate: uint256 = self.fee_rate / 2
    prev_vb_sum: uint256 = vb_sum
    prev_ratios: DynArray[uint256, MAX_NUM_ASSETS] = []
    for asset in range(MAX_NUM_ASSETS):
        if asset == num_assets:
            break

        amount: uint256 = _amounts[asset]
        if amount == 0:
            assert prev_supply > 0 # dev: initial deposit amounts must be non-zero
            continue

        # update stored virtual balance
        prev_vb: uint256 = self.balances[asset]
        dvb: uint256 = amount * self.rates[asset] / PRECISION
        vb: uint256 = prev_vb + dvb
        self.balances[asset] = vb

        if prev_supply > 0:
            prev_ratios.append(prev_vb * PRECISION / prev_vb_sum)
            weight: uint256 = self.weights[asset] & WEIGHT_MASK

            # update product and sum of virtual balances
            vb_prod_final = vb_prod_final * self._pow_up(prev_vb * PRECISION / vb, weight) / PRECISION
            # the `D^n` factor will be updated in `_calc_supply()`
            vb_sum_final += dvb

            # remove fees from balance and recalculate sum and product
            fee: uint256 = (dvb - prev_vb * lowest / PRECISION) * fee_rate / PRECISION
            vb_prod = vb_prod * self._pow_up(prev_vb * PRECISION / (vb - fee), weight) / PRECISION
            vb_sum += dvb - fee
        assert ERC20(self.assets[asset]).transferFrom(msg.sender, self, amount, default_return_value=True)

    supply: uint256 = prev_supply
    if prev_supply == 0:
        # initital deposit, calculate necessary variables
        self.w_prod = self._calc_w_prod()
        vb_prod, vb_sum = self._calc_vb_prod_sum()
        assert vb_prod > 0 # dev: amounts must be non-zero
        supply = vb_sum
    else:
        # check bands
        j: uint256 = 0
        for asset in range(MAX_NUM_ASSETS):
            if asset == num_assets:
                break
            if _amounts[asset] == 0:
                continue
            self.prev_ratio = prev_ratios[j]
            self.ratio = self.balances[asset] * PRECISION / vb_sum_final
            self._check_bands(num_assets, prev_ratios[j], self.balances[asset] * PRECISION / vb_sum_final, self.weights[asset])
            j = unsafe_add(j, 1)

    # mint LP tokens
    supply, vb_prod = self._calc_supply(num_assets, supply, self.amplification, self.w_prod, vb_prod, vb_sum, prev_supply == 0)
    mint: uint256 = supply - prev_supply
    assert mint > 0 and mint >= _min_lp_amount # dev: slippage
    PoolToken(token).mint(_receiver, mint)

    supply_final: uint256 = supply
    if prev_supply > 0:
        # mint fees
        supply_final, vb_prod_final = self._calc_supply(num_assets, prev_supply, self.amplification, self.w_prod, vb_prod_final, vb_sum_final, True)
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
def remove_liquidity(_lp_amount: uint256, _min_amounts: DynArray[uint256, MAX_NUM_ASSETS], _receiver: address = msg.sender):
    num_assets: uint256 = self.num_assets
    vb_prod: uint256 = self.vb_prod
    vb_sum: uint256 = self.vb_sum

    # update supply
    prev_supply: uint256 = self.supply
    supply: uint256 = prev_supply - _lp_amount
    self.supply = supply
    PoolToken(token).burn(msg.sender, _lp_amount)

    # update necessary variables and transfer assets
    for asset in range(MAX_NUM_ASSETS):
        if asset == num_assets:
            break
        prev_bal: uint256 = self.balances[asset]
        dbal: uint256 = prev_bal * _lp_amount / prev_supply
        bal: uint256 = prev_bal - dbal
        vb_prod = vb_prod * prev_supply / supply * self._pow_down(prev_bal * PRECISION / bal, self.weights[asset] & WEIGHT_MASK) / PRECISION
        vb_sum -= dbal
        self.balances[asset] = bal
        amount: uint256 = dbal * PRECISION / self.rates[asset]
        assert amount >= _min_amounts[asset] # dev: slippage
        assert ERC20(self.assets[asset]).transfer(_receiver, amount, default_return_value=True)

    self.vb_prod = vb_prod
    self.vb_sum = vb_sum

@external
@nonreentrant('lock')
def remove_liquidity_single(_asset: uint256, _lp_amount: uint256, _min_amount: uint256, _receiver: address = msg.sender) -> uint256:
    assert _asset < MAX_NUM_ASSETS # dev: index out of bounds

    # update rate
    vb_prod: uint256 = 0
    vb_sum: uint256 = 0
    vb_prod, vb_sum = self._update_rates(unsafe_add(_asset, 1), self.vb_prod, self.vb_sum)
    prev_vb_sum: uint256 = vb_sum

    # update supply
    prev_supply: uint256 = self.supply
    supply: uint256 = prev_supply - _lp_amount
    self.supply = supply
    PoolToken(token).burn(msg.sender, _lp_amount)

    prev_vb: uint256 = self.balances[_asset]
    weight: uint256 = self.weights[_asset] & WEIGHT_MASK

    # update variables
    num_assets: uint256 = self.num_assets
    vb_prod = vb_prod * self._pow_up(prev_vb, weight) / PRECISION
    for i in range(MAX_NUM_ASSETS):
        if i == num_assets:
            break
        vb_prod = vb_prod * supply / prev_supply
    vb_sum = vb_sum - prev_vb

    # calculate new balance of asset
    vb: uint256 = self._calc_vb(weight, prev_vb, supply, self.amplification, self.w_prod, vb_prod, vb_sum)
    dvb: uint256 = prev_vb - vb
    fee: uint256 = dvb * self.fee_rate / 2 / PRECISION
    dvb -= fee
    vb += fee
    dx: uint256 = dvb * PRECISION / self.rates[_asset]
    assert dx > _min_amount # dev: slippage

    # update variables
    self.balances[_asset] = vb
    vb_prod = vb_prod * PRECISION / self._pow_up(vb, weight)
    vb_sum = vb_sum + vb

    for asset in range(MAX_NUM_ASSETS):
        if asset == num_assets:
            break
        if asset == _asset:
            self._check_bands(num_assets, prev_vb * PRECISION / prev_vb_sum, vb * PRECISION / vb_sum, self.weights[asset])
        else:
            bal: uint256 = self.balances[asset]
            self._check_bands(num_assets, bal * PRECISION / prev_vb_sum, bal * PRECISION / vb_sum, self.weights[asset])

    if fee > 0:
        # mint fee
        supply, vb_prod = self._update_supply(supply, vb_prod, vb_sum)

    self.vb_prod = vb_prod
    self.vb_sum = vb_sum

    assert ERC20(self.assets[_asset]).transfer(_receiver, dx, default_return_value=True)
    return dx

@external
def update_rates(_assets: uint256):
    assets: uint256 = _assets
    if _assets == 0:
        assets = ALL_ASSETS_FLAG
    self.vb_prod, self.vb_sum = self._update_rates(assets, self.vb_prod, self.vb_sum)

@external
def update_weights() -> bool:
    updated: bool = False
    vb_prod: uint256 = 0
    vb_sum: uint256 = self.vb_sum
    vb_prod, updated = self._update_weights(self.vb_prod, vb_sum)
    if updated and vb_sum > 0:
        supply: uint256 = 0
        supply, vb_prod = self._update_supply(self.supply, vb_prod, vb_sum)
        self.vb_prod = vb_prod
    return updated

@external
@view
def weight(_asset: uint256) -> (uint256, uint256, uint256):
    num_assets: uint256 = self.num_assets
    weight: uint256 = 0
    lower: uint256 = 0
    upper: uint256 = 0
    weight, lower, upper = self._unpack_weight(self.weights[_asset])
    return weight / num_assets, lower / num_assets, upper / num_assets

@external
@view
def weight_packed(_asset: uint256) -> uint256:
    return self.weights[_asset]

@external
def pause():
    assert msg.sender == self.management or msg.sender == self.guardian
    assert not self.paused
    self.paused = True

@external
def unpause():
    assert msg.sender == self.management or msg.sender == self.guardian
    assert self.paused and not self.killed
    self.paused = False

@external
def kill():
    assert msg.sender == self.management
    assert self.paused and not self.killed
    self.killed = True

@external
def add_asset(
    _asset: address, 
    _rate_provider: address, 
    _weight: uint256, 
    _lower: uint256, 
    _upper: uint256, 
    _amount: uint256, 
    _receiver: address = msg.sender
):
    assert msg.sender == self.management

    assert _amount > 0
    prev_num_assets: uint256 = self.num_assets
    assert prev_num_assets < MAX_NUM_ASSETS # dev: pool is full
    assert self.ramp_last_time == 0 # dev: ramp active
    assert self.vb_sum > 0 # dev: pool empty

    rate: uint256 = RateProvider(_rate_provider).rate(_asset)
    assert rate > 0 # dev: no rate
    assert _weight < PRECISION
    assert _lower <= PRECISION
    assert _upper <= PRECISION

    # update weights for existing assets
    num_assets: uint256 = prev_num_assets + 1
    for i in range(MAX_NUM_ASSETS):
        if i == prev_num_assets:
            break
        assert self.assets[i] != _asset # dev: asset already part of pool
        prev_weight: uint256 = 0
        lower: uint256 = 0
        upper: uint256 = 0
        prev_weight, lower, upper = self._unpack_weight(self.weights[i])
        prev_weight = prev_weight * num_assets / prev_num_assets
        lower = lower * num_assets / prev_num_assets
        upper = upper * num_assets / prev_num_assets
        self.weights[i] = self._pack_weight(prev_weight - prev_weight * _weight / PRECISION, lower, upper)
    
    # set parameters for new asset
    self.num_assets = num_assets
    self.assets[prev_num_assets] = _asset
    self.rate_providers[prev_num_assets] = _rate_provider
    self.balances[prev_num_assets] = _amount * rate / PRECISION
    self.rates[prev_num_assets] = rate
    self.weights[prev_num_assets] = self._pack_weight(_weight * num_assets, _lower * num_assets, _upper * num_assets)

    # recalculate variables
    w_prod: uint256 = self._calc_w_prod()
    vb_prod: uint256 = 0
    vb_sum: uint256 = 0
    vb_prod, vb_sum = self._calc_vb_prod_sum()

    # update supply
    prev_supply: uint256 = self.supply
    supply: uint256 = 0
    supply, vb_prod = self._calc_supply(num_assets, vb_sum, self.amplification, w_prod, vb_prod, vb_sum, True)

    self.supply = supply
    self.w_prod = w_prod
    self.vb_prod = vb_prod
    self.vb_sum = vb_sum

    PoolToken(token).mint(_receiver, supply - prev_supply)

@external
def set_fee_rate(_fee_rate: uint256):
    assert msg.sender == self.management
    # TODO: reasonable bounds
    self.fee_rate = _fee_rate

@external
def set_weight_bands(
    _assets: DynArray[uint256, MAX_NUM_ASSETS], 
    _lower: DynArray[uint256, MAX_NUM_ASSETS], 
    _upper: DynArray[uint256, MAX_NUM_ASSETS]
):
    assert msg.sender == self.management
    assert len(_lower) == len(_assets) and len(_upper) == len(_assets)

    num_assets: uint256 = self.num_assets
    for i in range(MAX_NUM_ASSETS):
        if i == len(_assets):
            break
        asset: uint256 = _assets[i]
        assert asset < num_assets # dev: index out of bounds
        weight: uint256 = self.weights[asset] & WEIGHT_MASK
        assert _lower[i] <= PRECISION and _upper[i] <= PRECISION # dev: bands out of bounds
        self.weights[asset] = self._pack_weight(weight, _lower[i] * num_assets, _upper[i] * num_assets)

@external
def set_rate_provider(_asset: uint256, _rate_provider: address):
    assert msg.sender == self.management
    assert _asset < self.num_assets # dev: index out of bounds

    self.rate_providers[_asset] = _rate_provider
    self.vb_prod, self.vb_sum = self._update_rates(_asset + 1, self.vb_prod, self.vb_sum)

@external
def set_ramp(
    _amplification: uint256, 
    _weights: DynArray[uint256, MAX_NUM_ASSETS], 
    _duration: uint256, 
    _start: uint256 = block.timestamp
):
    assert msg.sender == self.management

    num_assets: uint256 = self.num_assets
    assert _amplification > 0
    assert len(_weights) == num_assets
    assert _start >= block.timestamp

    updated: bool = False
    vb_prod: uint256 = 0
    vb_sum: uint256 = self.vb_sum
    vb_prod, updated = self._update_weights(self.vb_prod, vb_sum)
    if updated:
        supply: uint256 = 0
        supply, vb_prod = self._update_supply(self.supply, vb_prod, vb_sum)
        self.vb_prod = vb_prod
    
    assert self.ramp_last_time == 0 # dev: ramp active

    self.ramp_last_time = _start
    self.ramp_stop_time = _start + _duration
    self.target_amplification = _amplification
    total: uint256 = 0
    for asset in range(MAX_NUM_ASSETS):
        if asset == num_assets:
            break
        assert _weights[asset] < PRECISION # dev: weight out of bounds
        total += _weights[asset]
        self.target_weights[asset] = _weights[asset] * num_assets
    assert total == PRECISION # dev: weights dont add up

@external
def set_ramp_step(_ramp_step: uint256):
    assert msg.sender == self.management
    assert _ramp_step > 0
    self.ramp_step = _ramp_step

@external
def stop_ramp():
    assert msg.sender == self.management
    self.ramp_last_time = 0
    self.ramp_stop_time = 0

@external
def set_staking(_staking: address):
    assert msg.sender == self.management
    self.staking = _staking

@external
def set_management(_management: address):
    assert msg.sender == self.management
    self.management = _management

@external
def set_guardian(_guardian: address):
    assert msg.sender == self.management or msg.sender == self.guardian
    self.guardian = _guardian

@internal
def _update_rates(_assets: uint256, _vb_prod: uint256, _vb_sum: uint256) -> (uint256, uint256):
    assert not self.paused # dev: paused
    
    vb_prod: uint256 = 0
    vb_sum: uint256 = _vb_sum
    updated: bool = False
    vb_prod, updated = self._update_weights(_vb_prod, vb_sum)
    num_assets: uint256 = self.num_assets
    for i in range(MAX_NUM_ASSETS):
        asset: uint256 = shift(_assets, unsafe_mul(-8, convert(i, int128))) & 255
        if asset == 0 or asset > num_assets:
            break
        asset = unsafe_sub(asset, 1)
        provider: address = self.rate_providers[asset]
        prev_rate: uint256 = self.rates[asset]
        rate: uint256 = RateProvider(provider).rate(self.assets[asset])
        assert rate > 0 # dev: no rate
        if rate == prev_rate:
            continue
        self.rates[asset] = rate

        if prev_rate > 0 and vb_sum > 0:
            # factor out old rate and factor in new
            vb_prod = vb_prod * self._pow_up(prev_rate * PRECISION / rate, self.weights[asset] & WEIGHT_MASK) / PRECISION

            prev_bal: uint256 = self.balances[asset]
            bal: uint256 = prev_bal * rate / prev_rate
            self.balances[asset] = bal
            vb_sum = vb_sum + bal - prev_bal

    if not updated and vb_prod == _vb_prod and vb_sum == _vb_sum:
        return vb_prod, vb_sum

    supply: uint256 = 0
    supply, vb_prod = self._update_supply(self.supply, vb_prod, vb_sum)
    return vb_prod, vb_sum

@internal
def _update_weights(_vb_prod: uint256, _vb_sum: uint256) -> (uint256, bool):
    span: uint256 = self.ramp_last_time
    duration: uint256 = self.ramp_stop_time
    if span == 0 or span > block.timestamp or (block.timestamp - span < self.ramp_step and duration > block.timestamp):
        # scenarios:
        #  1) no ramp is active
        #  2) ramp is scheduled for in the future
        #  3) weights have been updated too recently and ramp hasnt finished yet
        return _vb_prod, False

    if block.timestamp < duration:
        # ramp in progress
        duration -= span
        self.ramp_last_time = block.timestamp
    else:
        # ramp has finished
        duration = 0
        self.ramp_last_time = 0
        self.ramp_stop_time = 0
    span = block.timestamp - span
    
    # update amplification
    current: uint256 = self.amplification
    target: uint256 = self.target_amplification
    if duration == 0:
        self.amplification = target
    else:
        if current > target:
            self.amplification = current - (current - target) * span / duration
        else:
            self.amplification = current + (target - current) * span / duration

    # update weights
    num_assets: uint256 = self.num_assets
    lower: uint256 = 0
    upper: uint256 = 0
    for asset in range(MAX_NUM_ASSETS):
        if asset == num_assets:
            break
        current, lower, upper = self._unpack_weight(self.weights[asset])
        target = self.target_weights[asset]
        if duration == 0:
            current = target
        else:
            if current > target:
                current -= (current - target) * span / duration
            else:
                current += (target - current) * span / duration
        self.weights[asset] = self._pack_weight(current, lower, upper)

    vb_prod: uint256 = 0
    if _vb_sum > 0:
        self.w_prod = self._calc_w_prod()
        vb_prod = self._calc_vb_prod(_vb_sum)
    return vb_prod, True

@internal
def _update_supply(_supply: uint256, _vb_prod: uint256, _vb_sum: uint256) -> (uint256, uint256):
    # calculate new supply and burn or mint the difference from the staking contract
    if _supply == 0:
        return 0, _vb_prod

    supply: uint256 = 0
    vb_prod: uint256 = 0
    supply, vb_prod = self._calc_supply(self.num_assets, _supply, self.amplification, self.w_prod, _vb_prod, _vb_sum, True)
    if supply > _supply:
        PoolToken(token).mint(self.staking, supply - _supply)
    elif supply < _supply:
        PoolToken(token).burn(self.staking, _supply - supply)
    self.supply = supply
    return supply, vb_prod

@internal
@pure
def _check_bands(_num_assets: uint256, _prev_ratio: uint256, _ratio: uint256, _weight: uint256):
    ratio: uint256 = unsafe_mul(_ratio, _num_assets)
    weight: uint256 = _weight & WEIGHT_MASK

    # lower limit check
    limit: uint256 = shift(_weight, LOWER_BAND_SHIFT) & WEIGHT_MASK
    if limit > weight:
        limit = 0
    else:
        limit = unsafe_sub(weight, limit)
    if ratio < limit:
        assert _ratio > _prev_ratio # dev: ratio below lower band
        return

    # upper limit check
    limit = min(unsafe_add(weight, shift(_weight, UPPER_BAND_SHIFT)), unsafe_mul(_num_assets, PRECISION))
    if ratio > limit:
        assert _ratio < _prev_ratio # dev: ratio above upper band

# MATH FUNCTIONS
# make sure to keep in sync with Math.vy

@internal
@view
def _calc_w_prod() -> uint256:
    prod: uint256 = PRECISION
    num_assets: uint256 = self.num_assets
    for asset in range(MAX_NUM_ASSETS):
        if asset == num_assets:
            break
        weight: uint256 = self.weights[asset] & WEIGHT_MASK
        prod = unsafe_div(unsafe_mul(prod, self._pow_up(unsafe_div(weight, num_assets), weight)), PRECISION)
    return prod

@internal
@view
def _calc_vb_prod_sum() -> (uint256, uint256):
    s: uint256 = 0
    num_assets: uint256 = self.num_assets
    for asset in range(MAX_NUM_ASSETS):
        if asset == num_assets:
            break
        s = unsafe_add(s, self.balances[asset])
    p: uint256 = self._calc_vb_prod(s)
    return p, s

@internal
@view
def _calc_vb_prod(_s: uint256) -> uint256:
    num_assets: uint256 = self.num_assets
    p: uint256 = PRECISION
    for asset in range(MAX_NUM_ASSETS):
        if asset == num_assets:
            break
        weight: uint256 = self.weights[asset] & WEIGHT_MASK
        vb: uint256 = self.balances[asset]
        assert weight > 0 and vb > 0 # dev: borked
        # p = product(D / (vb_i / w_i)^(w_i n))
        p = unsafe_div(unsafe_mul(p, _s), self._pow_down(unsafe_div(unsafe_mul(vb, PRECISION), unsafe_div(weight, num_assets)), weight))
    return p

@internal
@pure
def _calc_supply(
    _num_assets: uint256, 
    _supply: uint256, 
    _amplification: uint256, 
    _w_prod: uint256, 
    _vb_prod: uint256, 
    _vb_sum: uint256, 
    _up: bool
) -> (uint256, uint256):
    # s[n+1] = (A sum / w^n - s^(n+1) w^n /prod^n)) / (A w^n - 1)
    #        = (l - s r) / d

    l: uint256 = _amplification * PRECISION / _w_prod
    d: uint256 = l - PRECISION
    s: uint256 = _supply
    r: uint256 = _vb_prod
    l = l * _vb_sum

    num_assets: uint256 = _num_assets
    for _ in range(255):
        sp: uint256 = unsafe_div(unsafe_sub(l, unsafe_mul(s, r)), d) # (l - s * r) / d
        for i in range(MAX_NUM_ASSETS):
            if i == num_assets:
                break
            r = unsafe_div(unsafe_mul(r, sp), s) # r * sp / s
        if sp >= s:
            if (sp - s) * PRECISION / s <= MAX_POW_REL_ERR:
                if _up:
                    sp += sp * MAX_POW_REL_ERR / PRECISION
                else:
                    sp -= sp * MAX_POW_REL_ERR / PRECISION
                return sp, r
        else:
            if (s - sp) * PRECISION / s <= MAX_POW_REL_ERR:
                if _up:
                    sp += sp * MAX_POW_REL_ERR / PRECISION
                else:
                    sp -= sp * MAX_POW_REL_ERR / PRECISION
                return sp, r
        s = sp

    raise # dev: no convergence

@internal
@pure
def _calc_vb(
    _weight: uint256, 
    _y: uint256, 
    _supply: uint256, 
    _amplification: uint256, 
    _w_prod: uint256, 
    _vb_prod: uint256, 
    _vb_sum: uint256
) -> uint256:
    # y = x_j, sum' = sum(x_i, i != j), prod' = prod(x_i^w_i, i != j)
    # w = product(w_i), v_i = w_i n, f_i = 1/v_i
    # Iteratively find root of g(y) using Newton's method
    # g(y) = y^(v_j + 1) + (sum' + (w^n / A - 1) D) y^(v_j) - D^(n+1) w^2n / prod'^n
    #      = y^(v_j + 1) + b y^(v_j) - c
    # y[n+1] = y[n] - g(y[n])/g'(y[n])
    #        = (y[n]^2 + b (1 - f_j) y[n] + c f_j y[n]^(1 - v_j)) / ((f_j + 1) y[n] + b))

    d: uint256 = _supply
    b: uint256 = d * _w_prod / _amplification # actually b + D
    c: uint256 = _vb_prod * b / PRECISION
    b += _vb_sum
    v: uint256 = _weight & WEIGHT_MASK
    f: uint256 = PRECISION * PRECISION / v

    y: uint256 = _y
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
def _pack_weight(_weight: uint256, _lower: uint256, _upper: uint256) -> uint256:
    return _weight | shift(_lower, -LOWER_BAND_SHIFT) | shift(_upper, -UPPER_BAND_SHIFT)

@internal
@pure
def _unpack_weight(_packed: uint256) -> (uint256, uint256, uint256):
    return _packed & WEIGHT_MASK, shift(_packed, LOWER_BAND_SHIFT) & WEIGHT_MASK, shift(_packed, UPPER_BAND_SHIFT)

@internal
@pure
def _pow_up(_x: uint256, _y: uint256) -> uint256:
    # guaranteed to be >= the actual value
    p: uint256 = self._pow(_x, _y)
    if p == 0:
        return 0
    # p + (p * MAX_POW_REL_ERR - 1) / PRECISION + 1
    return unsafe_add(unsafe_add(p, unsafe_div(unsafe_sub(unsafe_mul(p, MAX_POW_REL_ERR), 1), PRECISION)), 1)

@internal
@pure
def _pow_down(_x: uint256, _y: uint256) -> uint256:
    # guaranteed to be <= the actual value
    p: uint256 = self._pow(_x, _y)
    if p == 0:
        return 0
    # (p * MAX_POW_REL_ERR - 1) / PRECISION + 1
    e: uint256 = unsafe_add(unsafe_div(unsafe_sub(unsafe_mul(p, MAX_POW_REL_ERR), 1), PRECISION), 1)
    if p < e:
        return 0
    return unsafe_sub(p, e)

@internal
@pure
def _pow(_x: uint256, _y: uint256) -> uint256:
    # x^y
    if _y == 0:
        return convert(E18, uint256) # x^0 == 1

    if _x == 0:
        return 0 # 0^y == 0
    
    assert shift(_x, -255) == 0 # dev: x out of bounds
    assert _y < MILD_EXP_BOUND # dev: y out of bounds

    # x^y = e^log(x^y)) = e^(y log x)
    x: int256 = convert(_x, int256)
    y: int256= convert(_y, int256)
    l: int256 = 0
    if x > LOG36_LOWER and x < LOG36_UPPER:
        l = self._log36(x)
        # l / E18 * y + (l % E18) * y / E18
        l = unsafe_add(unsafe_mul(unsafe_div(l, E18), y), unsafe_div(unsafe_mul(l % E18, y), E18))
    else:
        l = unsafe_mul(self._log(x), y)
    l = unsafe_div(l, E18)
    return convert(self._exp(l), uint256)

@internal
@pure
def _log36(_x: int256) -> int256:
    x: int256 = unsafe_mul(_x, E18)
    
    # Taylor series
    # z = (x - 1) / (x + 1)
    # c = log x = 2 * sum(z^(2n + 1) / (2n + 1))

    z: int256 = unsafe_div(unsafe_mul(unsafe_sub(x, E36), E36), unsafe_add(x, E36)) # (x - E36) * E36 / (x + E36)
    zsq: int256 = unsafe_div(unsafe_mul(z, z), E36)
    n: int256 = z
    c: int256 = z

    n = unsafe_div(unsafe_mul(n, zsq), E36) # n * zsq / E36
    c = unsafe_add(c, n / 3)
    n = unsafe_div(unsafe_mul(n, zsq), E36)
    c = unsafe_add(c, n / 5)
    n = unsafe_div(unsafe_mul(n, zsq), E36)
    c = unsafe_add(c, n / 7)
    n = unsafe_div(unsafe_mul(n, zsq), E36)
    c = unsafe_add(c, n / 9)
    n = unsafe_div(unsafe_mul(n, zsq), E36)
    c = unsafe_add(c, n / 11)
    n = unsafe_div(unsafe_mul(n, zsq), E36)
    c = unsafe_add(c, n / 13)
    n = unsafe_div(unsafe_mul(n, zsq), E36)
    c = unsafe_add(c, n / 15)

    return unsafe_mul(c, 2)

@internal
@pure
def _log(_a: int256) -> int256:
    if _a < E18:
        # 1/a > 1, log(a) = -log(1/a)
        return -self.__log(unsafe_div(unsafe_mul(E18, E18), _a))
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
    if a >= unsafe_mul(A0, E18):
        a = unsafe_div(a, A0)
        s = unsafe_add(s, X0)
    if a >= unsafe_mul(A1, E18):
        a = unsafe_div(a, A1)
        s = unsafe_add(s, X1)
    
    # other terms are in 20 decimals
    a = unsafe_mul(a, 100)
    s = unsafe_mul(s, 100)

    if a >= A2:
        a = unsafe_div(unsafe_mul(a, E20), A2) # a * E20 / A2
        s = unsafe_add(s, X2)
    if a >= A3:
        a = unsafe_div(unsafe_mul(a, E20), A3)
        s = unsafe_add(s, X3)
    if a >= A4:
        a = unsafe_div(unsafe_mul(a, E20), A4)
        s = unsafe_add(s, X4)
    if a >= A5:
        a = unsafe_div(unsafe_mul(a, E20), A5)
        s = unsafe_add(s, X5)
    if a >= A6:
        a = unsafe_div(unsafe_mul(a, E20), A6)
        s = unsafe_add(s, X6)
    if a >= A7:
        a = unsafe_div(unsafe_mul(a, E20), A7)
        s = unsafe_add(s, X7)
    if a >= A8:
        a = unsafe_div(unsafe_mul(a, E20), A8)
        s = unsafe_add(s, X8)
    if a >= A9:
        a = unsafe_div(unsafe_mul(a, E20), A9)
        s = unsafe_add(s, X9)
    if a >= A10:
        a = unsafe_div(unsafe_mul(a, E20), A10)
        s = unsafe_add(s, X10)
    if a >= A11:
        a = unsafe_div(unsafe_mul(a, E20), A11)
        s = unsafe_add(s, X11)

    # a < A11 (1.06), taylor series for remainder
    # z = (a - 1) / (a + 1)
    # c = log a = 2 * sum(z^(2n + 1) / (2n + 1))
    z: int256 = unsafe_div(unsafe_mul(unsafe_sub(a, E20),  E20), unsafe_add(a, E20)) # (a - E20) * E20 / (a + E20)
    zsq: int256 = unsafe_div(unsafe_mul(z, z), E20) # z * z / E20
    n: int256 = z
    c: int256 = z

    n = unsafe_div(unsafe_mul(n, zsq), E20) # n * zsq / E20
    c = unsafe_add(c, unsafe_div(n, 3)) # c + n / 3
    n = unsafe_div(unsafe_mul(n, zsq), E20)
    c = unsafe_add(c, unsafe_div(n, 5))
    n = unsafe_div(unsafe_mul(n, zsq), E20)
    c = unsafe_add(c, unsafe_div(n, 7))
    n = unsafe_div(unsafe_mul(n, zsq), E20)
    c = unsafe_add(c, unsafe_div(n, 9))
    n = unsafe_div(unsafe_mul(n, zsq), E20)
    c = unsafe_add(c, unsafe_div(n, 11))

    c = unsafe_mul(c, 2)
    return unsafe_div(unsafe_add(s, c), 100) # (s + c) / 100

@internal
@pure
def _exp(_x: int256) -> int256:
    assert _x >= MIN_NAT_EXP and _x <= MAX_NAT_EXP
    if _x < 0:
        # exp(-x) = 1/exp(x)
        return unsafe_mul(E18, E18) / self.__exp(-_x)
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
        x = unsafe_sub(x, X0)
        f = A0
    elif x >= X1:
        x = unsafe_sub(x, X1)
        f = A1

    # other terms are in 20 decimals
    x = unsafe_mul(x, 100)

    p: int256 = E20
    if x >= X2:
        x = unsafe_sub(x, X2)
        p = unsafe_div(unsafe_mul(p, A2), E20) # p * A2 / E20
    if x >= X3:
        x = unsafe_sub(x, X3)
        p = unsafe_div(unsafe_mul(p, A3), E20)
    if x >= X4:
        x = unsafe_sub(x, X4)
        p = unsafe_div(unsafe_mul(p, A4), E20)
    if x >= X5:
        x = unsafe_sub(x, X5)
        p = unsafe_div(unsafe_mul(p, A5), E20)
    if x >= X6:
        x = unsafe_sub(x, X6)
        p = unsafe_div(unsafe_mul(p, A6), E20)
    if x >= X7:
        x = unsafe_sub(x, X7)
        p = unsafe_div(unsafe_mul(p, A7), E20)
    if x >= X8:
        x = unsafe_sub(x, X8)
        p = unsafe_div(unsafe_mul(p, A8), E20)
    if x >= X9:
        x = unsafe_sub(x, X9)
        p = unsafe_div(unsafe_mul(p, A9), E20)
    
    # x < X9 (0.25), taylor series for remainder
    # c = e^x = sum(x^n / n!)
    n: int256 = x
    c: int256 = unsafe_add(E20, x)

    n = unsafe_div(unsafe_div(unsafe_mul(n, x), E20), 2) # n * x / E20 / 2
    c = unsafe_add(c, n)
    n = unsafe_div(unsafe_div(unsafe_mul(n, x), E20), 3)
    c = unsafe_add(c, n)
    n = unsafe_div(unsafe_div(unsafe_mul(n, x), E20), 4)
    c = unsafe_add(c, n)
    n = unsafe_div(unsafe_div(unsafe_mul(n, x), E20), 5)
    c = unsafe_add(c, n)
    n = unsafe_div(unsafe_div(unsafe_mul(n, x), E20), 6)
    c = unsafe_add(c, n)
    n = unsafe_div(unsafe_div(unsafe_mul(n, x), E20), 7)
    c = unsafe_add(c, n)
    n = unsafe_div(unsafe_div(unsafe_mul(n, x), E20), 8)
    c = unsafe_add(c, n)
    n = unsafe_div(unsafe_div(unsafe_mul(n, x), E20), 9)
    c = unsafe_add(c, n)
    n = unsafe_div(unsafe_div(unsafe_mul(n, x), E20), 10)
    c = unsafe_add(c, n)
    n = unsafe_div(unsafe_div(unsafe_mul(n, x), E20), 11)
    c = unsafe_add(c, n)
    n = unsafe_div(unsafe_div(unsafe_mul(n, x), E20), 12)
    c = unsafe_add(c, n)

    # p * c / E20 * f / 100
    return unsafe_div(unsafe_mul(unsafe_div(unsafe_mul(p, c), E20), f), 100)

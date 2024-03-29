# @version 0.3.7

interface Pool:
    def supply() -> uint256: view
    def amplification() -> uint256: view
    def num_assets() -> uint256: view
    def assets(_i: uint256) -> address: view
    def rate_providers(_i: uint256) -> address: view
    def virtual_balance(_i: uint256) -> uint256: view
    def rate(_i: uint256) -> uint256: view
    def weight(_i: uint256) -> (uint256, uint256, uint256, uint256): view
    def packed_weight(_i: uint256) -> uint256: view
    def swap_fee_rate() -> uint256: view
    def ramp_step() -> uint256: view
    def ramp_last_time() -> uint256: view
    def ramp_stop_time() -> uint256: view
    def target_amplification() -> uint256: view
    def vb_prod_sum() -> (uint256, uint256): view

interface RateProvider:
    def rate(_asset: address) -> uint256: view

pool: public(immutable(Pool))

PRECISION: constant(uint256) = 1_000_000_000_000_000_000
MAX_NUM_ASSETS: constant(uint256) = 32

WEIGHT_SCALE: constant(uint256) = 1_000_000_000_000
WEIGHT_MASK: constant(uint256) = 2**20 - 1
TARGET_WEIGHT_SHIFT: constant(int128) = -20
LOWER_BAND_SHIFT: constant(int128) = -40
UPPER_BAND_SHIFT: constant(int128) = -60

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
def __init__(_pool: address):
    pool = Pool(_pool)

@external
@view
def get_effective_amplification() -> uint256:
    vb_prod: uint256 = 0
    vb_sum: uint256 = 0
    amplification: uint256 = 0
    packed_weights: DynArray[uint256, MAX_NUM_ASSETS] = []
    updated: bool = False
    vb_prod, vb_sum = pool.vb_prod_sum()
    amplification, vb_prod, packed_weights, updated = self._get_packed_weights(vb_prod, vb_sum)

    num_assets: uint256 = pool.num_assets()
    for asset in range(MAX_NUM_ASSETS):
        if asset == num_assets:
            break
        weight: uint256 = 0
        if updated:
            weight = packed_weights[asset]
        else:
            weight = pool.packed_weight(asset)
        weight = self._unpack_wn(weight, 1)
        amplification = amplification * self._pow_down(weight, weight * num_assets) / PRECISION
    return amplification

@external
@view
def get_effective_target_amplification() -> uint256:
    amplification: uint256 = 0
    if pool.ramp_last_time() == 0:
        amplification = pool.amplification()
    else:
        amplification = pool.target_amplification()

    num_assets: uint256 = pool.num_assets()
    for asset in range(MAX_NUM_ASSETS):
        if asset == num_assets:
            break
        weight: uint256 = unsafe_mul(shift(pool.packed_weight(asset), TARGET_WEIGHT_SHIFT) & WEIGHT_MASK, WEIGHT_SCALE)
        amplification = amplification * self._pow_down(weight, weight * num_assets) / PRECISION
    return amplification

@external
@view
def get_dy(_i: uint256, _j: uint256, _dx: uint256) -> uint256:
    num_assets: uint256 = pool.num_assets()
    assert _i != _j # dev: same input and output asset
    assert _i < num_assets and _j < num_assets # dev: index out of bounds
    assert _dx > 0 # dev: zero amount

    # update rates for from and to assets
    supply: uint256 = 0
    amplification: uint256 = 0
    vb_prod: uint256 = 0
    vb_sum: uint256 = 0
    vb_prod, vb_sum = pool.vb_prod_sum()
    packed_weights: DynArray[uint256, MAX_NUM_ASSETS] = []
    rates: DynArray[uint256, MAX_NUM_ASSETS] = []
    supply, amplification, vb_prod, vb_sum, packed_weights, rates = self._get_rates(unsafe_add(_i, 1) | shift(unsafe_add(_j, 1), 8), vb_prod, vb_sum)
    prev_vb_sum: uint256 = vb_sum

    prev_vb_x: uint256 = pool.virtual_balance(_i) * rates[0] / pool.rate(_i)
    wn_x: uint256 = self._unpack_wn(packed_weights[_i], num_assets)

    prev_vb_y: uint256 = pool.virtual_balance(_j) * rates[1] / pool.rate(_j)
    wn_y: uint256 = self._unpack_wn(packed_weights[_j], num_assets)

    dx_fee: uint256 = _dx * pool.swap_fee_rate() / PRECISION
    dvb_x: uint256 = (_dx - dx_fee) * rates[0] / PRECISION
    vb_x: uint256 = prev_vb_x + dvb_x
    
    # update x_i and remove x_j from variables
    vb_prod = vb_prod * self._pow_up(prev_vb_y, wn_y) / self._pow_down(vb_x * PRECISION / prev_vb_x, wn_x)
    vb_sum = vb_sum + dvb_x - prev_vb_y

    # calulate new balance of out token
    vb_y: uint256 = self._calc_vb(wn_y, prev_vb_y, supply, amplification, vb_prod, vb_sum)
    vb_sum += vb_y + dx_fee * rates[0] / PRECISION

    # check bands
    self._check_bands(prev_vb_x * PRECISION / prev_vb_sum, vb_x * PRECISION / vb_sum, packed_weights[_i])
    self._check_bands(prev_vb_y * PRECISION / prev_vb_sum, vb_y * PRECISION / vb_sum, packed_weights[_j])

    return (prev_vb_y - vb_y) * PRECISION / rates[1]

@external
@view
def get_dx(_i: uint256, _j: uint256, _dy: uint256) -> uint256:
    num_assets: uint256 = pool.num_assets()
    assert _i != _j # dev: same input and output asset
    assert _i < num_assets and _j < num_assets # dev: index out of bounds
    assert _dy > 0 # dev: zero amount
    
    # update rates for from and to assets
    supply: uint256 = 0
    amplification: uint256 = 0
    vb_prod: uint256 = 0
    vb_sum: uint256 = 0
    vb_prod, vb_sum = pool.vb_prod_sum()
    packed_weights: DynArray[uint256, MAX_NUM_ASSETS] = []
    rates: DynArray[uint256, MAX_NUM_ASSETS] = []
    supply, amplification, vb_prod, vb_sum, packed_weights, rates = self._get_rates(unsafe_add(_i, 1) | shift(unsafe_add(_j, 1), 8), vb_prod, vb_sum)
    prev_vb_sum: uint256 = vb_sum

    prev_vb_x: uint256 = pool.virtual_balance(_i) * rates[0] / pool.rate(_i)
    wn_x: uint256 = self._unpack_wn(packed_weights[_i], num_assets)
    prev_vb_y: uint256 = pool.virtual_balance(_j) * rates[1] / pool.rate(_j)
    wn_y: uint256 = self._unpack_wn(packed_weights[_j], num_assets)

    dvb_y: uint256 = _dy * rates[1] / PRECISION
    vb_y: uint256 = prev_vb_y - dvb_y

    # update x_j and remove x_i from variables
    vb_prod = vb_prod * self._pow_up(prev_vb_x, wn_x) / self._pow_down(vb_y * PRECISION / prev_vb_y, wn_y)
    vb_sum = vb_sum - dvb_y - prev_vb_x

    # calulate new balance of in token
    vb_x: uint256 = self._calc_vb(wn_x, prev_vb_x, supply, amplification, vb_prod, vb_sum)
    dx: uint256 = (vb_x - prev_vb_x) * PRECISION / rates[0]
    dx_fee: uint256 = pool.swap_fee_rate()
    dx_fee = dx * dx_fee / (PRECISION - dx_fee)
    dx += dx_fee
    vb_x += dx_fee * rates[0] / PRECISION
    vb_sum += vb_x

    # check bands
    self._check_bands(prev_vb_x * PRECISION / prev_vb_sum, vb_x * PRECISION / vb_sum, packed_weights[_i])
    self._check_bands(prev_vb_y * PRECISION / prev_vb_sum, vb_y * PRECISION / vb_sum, packed_weights[_j])
    
    return dx

@external
@view
def get_add_lp(_amounts: DynArray[uint256, MAX_NUM_ASSETS]) -> uint256:
    num_assets: uint256 = pool.num_assets()
    assert len(_amounts) == num_assets

    vb_prod: uint256 = 0
    vb_sum: uint256 = 0
    vb_prod, vb_sum = pool.vb_prod_sum()
    assert vb_sum > 0
    # for simplicity we dont give estimates for the first deposit

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
                lowest = min(_amounts[asset] * pool.rate(asset) / pool.virtual_balance(asset), lowest)
        else:
            lowest = 0
    assert sh > 0 # dev: need to deposit at least one asset

    # update rates
    prev_supply: uint256 = 0
    amplification: uint256 = 0
    packed_weights: DynArray[uint256, MAX_NUM_ASSETS] = []
    rates: DynArray[uint256, MAX_NUM_ASSETS] = []
    prev_supply, amplification, vb_prod, vb_sum, packed_weights, rates = self._get_rates(assets, vb_prod, vb_sum)

    vb_prod_final: uint256 = vb_prod
    vb_sum_final: uint256 = vb_sum
    fee_rate: uint256 = pool.swap_fee_rate() / 2
    prev_vb_sum: uint256 = vb_sum
    balances: DynArray[uint256, MAX_NUM_ASSETS] = []
    j: uint256 = 0
    for asset in range(MAX_NUM_ASSETS):
        if asset == num_assets:
            break

        amount: uint256 = _amounts[asset]
        if amount == 0:
            continue
        prev_vb: uint256 = pool.virtual_balance(asset) * rates[j] / pool.rate(asset)

        dvb: uint256 = amount * rates[j] / PRECISION
        vb: uint256 = prev_vb + dvb
        balances.append(vb)

        if prev_supply > 0:
            wn: uint256 = self._unpack_wn(packed_weights[asset], num_assets)

            # update product and sum of virtual balances
            vb_prod_final = vb_prod_final * self._pow_up(prev_vb * PRECISION / vb, wn) / PRECISION
            # the `D^n` factor will be updated in `_calc_supply()`
            vb_sum_final += dvb

            # remove fees from balance and recalculate sum and product
            fee: uint256 = (dvb - prev_vb * lowest / PRECISION) * fee_rate / PRECISION
            vb_prod = vb_prod * self._pow_up(prev_vb * PRECISION / (vb - fee), wn) / PRECISION
            vb_sum += dvb - fee
        j = unsafe_add(j, 1)

    # check bands
    j = 0
    for asset in range(MAX_NUM_ASSETS):
        if asset == num_assets:
            break
        if _amounts[asset] == 0:
            continue
        self._check_bands(pool.virtual_balance(asset) * rates[j] / pool.rate(asset) * PRECISION / prev_vb_sum, balances[j] * PRECISION / vb_sum_final, packed_weights[asset])
        j = unsafe_add(j, 1)

    supply: uint256 = 0
    supply, vb_prod = self._calc_supply(num_assets, prev_supply, amplification, vb_prod, vb_sum, prev_supply == 0)
    return supply - prev_supply

@external
@view
def get_remove_lp(_lp_amount: uint256) -> DynArray[uint256, MAX_NUM_ASSETS]:
    amounts: DynArray[uint256, MAX_NUM_ASSETS] = []
    num_assets: uint256 = pool.num_assets()
    prev_supply: uint256 = pool.supply()
    assert _lp_amount <= prev_supply
    for asset in range(MAX_NUM_ASSETS):
        if asset == num_assets:
            break
        prev_bal: uint256 = pool.virtual_balance(asset)
        dbal: uint256 = prev_bal * _lp_amount / prev_supply
        amount: uint256 = dbal * PRECISION / pool.rate(asset)
        amounts.append(amount)

    return amounts

@external
@view
def get_remove_single_lp(_asset: uint256, _lp_amount: uint256) -> uint256:
    num_assets: uint256 = pool.num_assets()
    assert _asset < num_assets # dev: index out of bounds

    # update rate
    prev_supply: uint256 = 0
    amplification: uint256 = 0
    vb_prod: uint256 = 0
    vb_sum: uint256 = 0
    vb_prod, vb_sum = pool.vb_prod_sum()
    packed_weights: DynArray[uint256, MAX_NUM_ASSETS] = []
    rates: DynArray[uint256, MAX_NUM_ASSETS] = []
    prev_supply, amplification, vb_prod, vb_sum, packed_weights, rates = self._get_rates(unsafe_add(_asset, 1), vb_prod, vb_sum)
    prev_vb_sum: uint256 = vb_sum

    supply: uint256 = prev_supply - _lp_amount
    prev_vb: uint256 = pool.virtual_balance(_asset) * rates[0] / pool.rate(_asset)
    wn: uint256 = self._unpack_wn(packed_weights[_asset], num_assets)

    # update variables
    vb_prod = vb_prod * self._pow_up(prev_vb, wn) / PRECISION
    for i in range(MAX_NUM_ASSETS):
        if i == num_assets:
            break
        vb_prod = vb_prod * supply / prev_supply
    vb_sum = vb_sum - prev_vb

    # calculate new balance of asset
    vb: uint256 = self._calc_vb(wn, prev_vb, supply, amplification, vb_prod, vb_sum)
    dvb: uint256 = prev_vb - vb
    fee: uint256 = dvb * pool.swap_fee_rate() / 2 / PRECISION
    dvb -= fee
    vb += fee
    dx: uint256 = dvb * PRECISION / rates[0]
    vb_sum = vb_sum + vb

    for asset in range(MAX_NUM_ASSETS):
        if asset == num_assets:
            break
        if asset == _asset:
            self._check_bands(prev_vb * PRECISION / prev_vb_sum, vb * PRECISION / vb_sum, packed_weights[asset])
        else:
            bal: uint256 = pool.virtual_balance(asset)
            self._check_bands(bal * PRECISION / prev_vb_sum, bal * PRECISION / vb_sum, packed_weights[asset])

    return dx

@external
@view
def get_vb(_amounts: DynArray[uint256, MAX_NUM_ASSETS]) -> uint256:
    num_assets: uint256 = pool.num_assets()
    assert len(_amounts) == num_assets

    vb: uint256 = 0
    for asset in range(MAX_NUM_ASSETS):
        if asset == num_assets:
            break
        amount: uint256 = _amounts[asset]
        if amount == 0:
            continue
        provider: address = pool.rate_providers(asset)
        rate: uint256 = RateProvider(provider).rate(pool.assets(asset))
        vb += amount * rate / PRECISION

    return vb

@internal
@view
def _get_rates(_assets: uint256, _vb_prod: uint256, _vb_sum: uint256) -> (uint256, uint256, uint256, uint256, DynArray[uint256, MAX_NUM_ASSETS], DynArray[uint256, MAX_NUM_ASSETS]):
    packed_weights: DynArray[uint256, MAX_NUM_ASSETS] = []
    rates: DynArray[uint256, MAX_NUM_ASSETS] = []

    amplification: uint256 = 0
    vb_prod: uint256 = 0
    vb_sum: uint256 = _vb_sum
    updated: bool = False
    amplification, vb_prod, packed_weights, updated = self._get_packed_weights(_vb_prod, _vb_sum)
    num_assets: uint256 = pool.num_assets()

    if not updated:
        for asset in range(MAX_NUM_ASSETS):
            if asset == num_assets:
                break
            packed_weights.append(pool.packed_weight(asset))

    for i in range(MAX_NUM_ASSETS):
        asset: uint256 = shift(_assets, unsafe_mul(-8, convert(i, int128))) & 255
        if asset == 0 or asset > num_assets:
            break
        asset = unsafe_sub(asset, 1)
        provider: address = pool.rate_providers(asset)
        prev_rate: uint256 = pool.rate(asset)
        rate: uint256 = RateProvider(provider).rate(pool.assets(asset))
        assert rate > 0 # dev: no rate
        rates.append(rate)

        if rate == prev_rate:
            continue

        if prev_rate > 0 and vb_sum > 0:
            # factor out old rate and factor in new
            wn: uint256 = self._unpack_wn(packed_weights[asset], num_assets)
            vb_prod = vb_prod * self._pow_up(prev_rate * PRECISION / rate, wn) / PRECISION

            prev_bal: uint256 = pool.virtual_balance(asset)
            bal: uint256 = prev_bal * rate / prev_rate
            vb_sum = vb_sum + bal - prev_bal

    if not updated and vb_prod == _vb_prod and vb_sum == _vb_sum:
        return pool.supply(), amplification, vb_prod, vb_sum, packed_weights, rates
    
    supply: uint256 = 0
    supply, vb_prod = self._calc_supply(num_assets, pool.supply(), amplification, vb_prod, vb_sum, True)
    return supply, amplification, vb_prod, vb_sum, packed_weights, rates

@internal
@view
def _get_packed_weights(_vb_prod: uint256, _vb_sum: uint256) -> (uint256, uint256, DynArray[uint256, MAX_NUM_ASSETS], bool):
    packed_weights: DynArray[uint256, MAX_NUM_ASSETS] = []
    span: uint256 = pool.ramp_last_time()
    duration: uint256 = pool.ramp_stop_time()
    if span == 0 or span > block.timestamp or (block.timestamp - span < pool.ramp_step() and duration > block.timestamp):
        return pool.amplification(), _vb_prod, packed_weights, False

    if block.timestamp < duration:
        # ramp in progress
        duration -= span
    else:
        # ramp has finished
        duration = 0
    span = block.timestamp - span
    
    # update amplification
    current: uint256 = pool.amplification()
    target: uint256 = pool.target_amplification()
    if duration == 0:
        current = target
    else:
        if current > target:
            current = current - (current - target) * span / duration
        else:
            current = current + (target - current) * span / duration
    amplification: uint256 = current

    # update weights
    num_assets: uint256 = pool.num_assets()
    supply: uint256 = pool.supply()
    vb_prod: uint256 = 0
    if _vb_sum > 0:
        vb_prod = PRECISION
    lower: uint256 = 0
    upper: uint256 = 0
    for asset in range(MAX_NUM_ASSETS):
        if asset == num_assets:
            break
        current, target, lower, upper = pool.weight(asset)
        if duration == 0:
            current = target
        else:
            if current > target:
                current -= (current - target) * span / duration
            else:
                current += (target - current) * span / duration
        packed_weights.append(self._pack_weight(current, target, lower, upper))
        if _vb_sum > 0:
            vb_prod = unsafe_div(unsafe_mul(vb_prod, self._pow_down(unsafe_div(unsafe_mul(supply, current), pool.virtual_balance(asset)), unsafe_mul(current, num_assets))), PRECISION)

    return amplification, vb_prod, packed_weights, True

@internal
@pure
def _check_bands(_prev_ratio: uint256, _ratio: uint256, _packed_weight: uint256):
    weight: uint256 = unsafe_mul(_packed_weight & WEIGHT_MASK, WEIGHT_SCALE)

    # lower limit check
    limit: uint256 = unsafe_mul(shift(_packed_weight, LOWER_BAND_SHIFT) & WEIGHT_MASK, WEIGHT_SCALE)
    if limit > weight:
        limit = 0
    else:
        limit = unsafe_sub(weight, limit)
    if _ratio < limit:
        assert _ratio > _prev_ratio # dev: ratio below lower band

    # upper limit check
    limit = min(unsafe_add(weight, unsafe_mul(shift(_packed_weight, UPPER_BAND_SHIFT), WEIGHT_SCALE)), PRECISION)
    if _ratio > limit:
        assert _ratio < _prev_ratio # dev: ratio above upper band

@internal
@pure
def _calc_supply(_num_assets: uint256, _supply: uint256, _amplification: uint256, _vb_prod: uint256, _vb_sum: uint256, _up: bool) -> (uint256, uint256):
    # s[n+1] = (A sum / w^n - s^(n+1) w^n /prod^n)) / (A w^n - 1)
    #        = (l - s r) / d

    l: uint256 = _amplification
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
def _calc_vb(_wn: uint256, _y: uint256, _supply: uint256, _amplification: uint256, _vb_prod: uint256, _vb_sum: uint256) -> uint256:
    # y = x_j, sum' = sum(x_i, i != j), prod' = prod(x_i^w_i, i != j)
    # w = product(w_i), v_i = w_i n, f_i = 1/v_i
    # Iteratively find root of g(y) using Newton's method
    # g(y) = y^(v_j + 1) + (sum' + (w^n / A - 1) D y^(w_j n) - D^(n+1) w^2n / prod'^n
    #      = y^(v_j + 1) + b y^(v_j) - c
    # y[n+1] = y[n] - g(y[n])/g'(y[n])
    #        = (y[n]^2 + b (1 - f_j) y[n] + c f_j y[n]^(1 - v_j)) / (f_j + 1) y[n] + b)

    d: uint256 = _supply
    b: uint256 = d * PRECISION / _amplification # actually b + D
    c: uint256 = _vb_prod * b / PRECISION
    b += _vb_sum
    f: uint256 = PRECISION * PRECISION / _wn

    y: uint256 = _y
    for _ in range(255):
        yp: uint256 = (y + b + d * f / PRECISION + c * f / self._pow_up(y, _wn) - b * f / PRECISION - d) * y / (f * y / PRECISION + y + b - d)
        if yp >= y:
            if (yp - y) * PRECISION / y <= MAX_POW_REL_ERR:
                yp += yp * MAX_POW_REL_ERR / PRECISION
                return yp
        else:
            if (y - yp) * PRECISION / y <= MAX_POW_REL_ERR:
                yp += yp * MAX_POW_REL_ERR / PRECISION
                return yp
        y = yp
    
    raise # dev: no convergence

@internal
@pure
def _pack_weight(_weight: uint256, _target: uint256, _lower: uint256, _upper: uint256) -> uint256:
    return unsafe_div(_weight, WEIGHT_SCALE) | shift(unsafe_div(_target, WEIGHT_SCALE), -TARGET_WEIGHT_SHIFT) | shift(unsafe_div(_lower, WEIGHT_SCALE), -LOWER_BAND_SHIFT) | shift(unsafe_div(_upper, WEIGHT_SCALE), -UPPER_BAND_SHIFT)

@internal
@pure
def _unpack_weight(_packed: uint256) -> (uint256, uint256, uint256, uint256):
    return unsafe_mul(_packed & WEIGHT_MASK, WEIGHT_SCALE), unsafe_mul(shift(_packed, TARGET_WEIGHT_SHIFT) & WEIGHT_MASK, WEIGHT_SCALE), unsafe_mul(shift(_packed, LOWER_BAND_SHIFT) & WEIGHT_MASK, WEIGHT_SCALE), unsafe_mul(shift(_packed, UPPER_BAND_SHIFT), WEIGHT_SCALE)

@internal
@pure
def _unpack_wn(_packed: uint256, _num_assets: uint256) -> uint256:
    return unsafe_mul(unsafe_mul(_packed & WEIGHT_MASK, WEIGHT_SCALE), _num_assets)

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

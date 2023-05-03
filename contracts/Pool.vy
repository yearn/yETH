# @version 0.3.7
"""
@title yETH weighted stableswap pool
@author 0xkorin, Yearn Finance
@license Copyright (c) Yearn Finance, 2023 - all rights reserved
"""

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
amplification: public(uint256) # A f^n
staking: public(address)
num_assets: public(uint256)
assets: public(address[MAX_NUM_ASSETS])
rate_providers: public(address[MAX_NUM_ASSETS])
packed_vbs: uint256[MAX_NUM_ASSETS] # x_i = b_i r_i (96) | r_i (80) | w_i (20) | target w_i (20) | lower (20) | upper (20)
management: public(address)
guardian: public(address)
paused: public(bool)
killed: public(bool)
swap_fee_rate: public(uint256)
ramp_step: public(uint256)
ramp_last_time: public(uint256)
ramp_stop_time: public(uint256)
target_amplification: public(uint256)
packed_pool_vb: uint256 # vb_prod (128) | vb_sum (128)
# vb_prod: pi, product term `product((w_i * D / x_i)^(w_i n))`
# vb_sum: sigma, sum term `sum(x_i)`

event Swap:
    account: indexed(address)
    receiver: address
    asset_in: indexed(uint256)
    asset_out: indexed(uint256)
    amount_in: uint256
    amount_out: uint256

event AddLiquidity:
    account: indexed(address)
    receiver: indexed(address)
    amounts_in: DynArray[uint256, MAX_NUM_ASSETS]
    lp_amount: uint256

event RemoveLiquidity:
    account: indexed(address)
    receiver: indexed(address)
    lp_amount: uint256

event RemoveLiquiditySingle:
    account: indexed(address)
    receiver: indexed(address)
    asset: indexed(uint256)
    amount_out: uint256
    lp_amount: uint256

event RateUpdate:
    asset: indexed(uint256)
    rate: uint256

event Pause:
    account: indexed(address)

event Unpause:
    account: indexed(address)

event Kill: pass

event AddAsset:
    index: uint256
    asset: address
    rate_provider: address
    rate: uint256
    weight: uint256
    amount: uint256

event SetSwapFeeRate:
    rate: uint256

event SetWeightBand:
    asset: indexed(uint256)
    lower: uint256
    upper: uint256

event SetRateProvider:
    asset: uint256
    rate_provider: address

event SetRamp:
    amplification: uint256
    weights: DynArray[uint256, MAX_NUM_ASSETS]
    duration: uint256
    start: uint256

event SetRampStep:
    ramp_step: uint256

event StopRamp: pass

event SetStaking:
    staking: address

event SetManagement:
    management: address

event SetGuardian:
    acount: indexed(address)
    guardian: address

PRECISION: constant(uint256) = 1_000_000_000_000_000_000
MAX_NUM_ASSETS: constant(uint256) = 32
ALL_ASSETS_FLAG: constant(uint256) = 14528991250861404666834535435384615765856667510756806797353855100662256435713 # sum((i+1) << 8*i)
POOL_VB_MASK: constant(uint256) = 2**128 - 1
POOL_VB_SHIFT: constant(int128) = -128

VB_MASK: constant(uint256) = 2**96 - 1
RATE_MASK: constant(uint256) = 2**80 - 1
RATE_SHIFT: constant(int128) = -96
PACKED_WEIGHT_SHIFT: constant(int128) = -176

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
def __init__(
    _token: address, 
    _amplification: uint256,
    _assets: DynArray[address, MAX_NUM_ASSETS], 
    _rate_providers: DynArray[address, MAX_NUM_ASSETS], 
    _weights: DynArray[uint256, MAX_NUM_ASSETS]
):
    """
    @notice Constructor
    @param _token The address of the pool LP token
    @param _amplification The pool amplification factor (in 18 decimals)
    @param _assets Array of addresses of tokens in the pool
    @param _rate_providers Array of addresses of rate provider for each asset
    @param _weights Weight of each asset (in 18 decimals)
    @dev Only non-rebasing assets with 18 decimals are supported
    @dev Weights need to sum to unity
    """
    num_assets: uint256 = len(_assets)
    assert num_assets >= 2
    assert len(_rate_providers) == num_assets and len(_weights) == num_assets
    assert _amplification > 0

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
        packed_weight: uint256 = self._pack_weight(_weights[asset], _weights[asset], PRECISION, PRECISION)
        self.packed_vbs[asset] = self._pack_vb(0, 0, packed_weight)
        weight_sum += _weights[asset]
    assert weight_sum == PRECISION

    self.ramp_step = 1
    self.management = msg.sender
    self.guardian = msg.sender

@external
@nonreentrant('lock')
def swap(
    _i: uint256, 
    _j: uint256, 
    _dx: uint256, 
    _min_dy: uint256, 
    _receiver: address = msg.sender
) -> uint256:
    """
    @notice Swap one pool asset for another
    @param _i Index of the input asset
    @param _j Index of the output asset
    @param _dx Amount of input asset to take from caller
    @param _min_dy Minimum amount of output asset to send
    @param _receiver Account to receive the output asset
    @return The amount of output asset sent
    """
    num_assets: uint256 = self.num_assets
    assert _i != _j # dev: same input and output asset
    assert _i < num_assets and _j < num_assets # dev: index out of bounds
    assert _dx > 0 # dev: zero amount

    # update rates for from and to assets
    vb_prod: uint256 = 0
    vb_sum: uint256 = 0
    vb_prod, vb_sum = self._unpack_pool_vb(self.packed_pool_vb)
    vb_prod, vb_sum = self._update_rates(unsafe_add(_i, 1) | shift(unsafe_add(_j, 1), 8), vb_prod, vb_sum)
    prev_vb_sum: uint256 = vb_sum

    prev_vb_x: uint256 = 0
    rate_x: uint256 = 0
    packed_weight_x: uint256 = 0
    prev_vb_x, rate_x, packed_weight_x = self._unpack_vb(self.packed_vbs[_i])
    wn_x: uint256 = self._unpack_wn(packed_weight_x, num_assets)

    prev_vb_y: uint256 = 0
    rate_y: uint256 = 0
    packed_weight_y: uint256 = 0
    prev_vb_y, rate_y, packed_weight_y = self._unpack_vb(self.packed_vbs[_j])
    wn_y: uint256 = self._unpack_wn(packed_weight_y, num_assets)

    dx_fee: uint256 = _dx * self.swap_fee_rate / PRECISION
    dvb_x: uint256 = (_dx - dx_fee) * rate_x / PRECISION
    vb_x: uint256 = prev_vb_x + dvb_x
    
    # update x_i and remove x_j from variables
    vb_prod = vb_prod * self._pow_up(prev_vb_y, wn_y) / self._pow_down(vb_x * PRECISION / prev_vb_x, wn_x)
    vb_sum = vb_sum + dvb_x - prev_vb_y

    # calulate new balance of out token
    vb_y: uint256 = self._calc_vb(wn_y, prev_vb_y, self.supply, self.amplification, vb_prod, vb_sum)
    vb_sum += vb_y

    # check bands
    self._check_bands(prev_vb_x * PRECISION / prev_vb_sum, vb_x * PRECISION / vb_sum, packed_weight_x)
    self._check_bands(prev_vb_y * PRECISION / prev_vb_sum, vb_y * PRECISION / vb_sum, packed_weight_y)

    dy: uint256 = (prev_vb_y - vb_y) * PRECISION / rate_y
    assert dy >= _min_dy # dev: slippage

    if dx_fee > 0:
        # add fee to pool
        dvb_x = dx_fee * rate_x / PRECISION
        vb_prod = vb_prod * PRECISION / self._pow_down((vb_x + dvb_x) * PRECISION / vb_x, wn_x)
        vb_x += dvb_x
        vb_sum += dvb_x

    # update variables
    self.packed_vbs[_i] = self._pack_vb(vb_x, rate_x, packed_weight_x)
    self.packed_vbs[_j] = self._pack_vb(vb_y, rate_y, packed_weight_y)
    vb_prod = vb_prod * PRECISION / self._pow_up(vb_y, wn_y)
    
    # mint fees
    if dx_fee > 0:
        supply: uint256 = 0
        supply, vb_prod = self._update_supply(self.supply, vb_prod, vb_sum)

    self.packed_pool_vb = self._pack_pool_vb(vb_prod, vb_sum)

    # transfer tokens
    assert ERC20(self.assets[_i]).transferFrom(msg.sender, self, _dx, default_return_value=True)
    assert ERC20(self.assets[_j]).transfer(_receiver, dy, default_return_value=True)
    log Swap(msg.sender, _receiver, _i, _j, _dx, dy)

    return dy

@external
@nonreentrant('lock')
def swap_exact_out(
    _i: uint256, 
    _j: uint256, 
    _dy: uint256, 
    _max_dx: uint256, 
    _receiver: address = msg.sender
) -> uint256:
    """
    @notice Swap one pool asset for another, with a fixed output amount
    @param _i Index of the input asset
    @param _j Index of the output asset
    @param _dy Amount of input asset to send
    @param _max_dx Maximum amount of output asset to take from caller
    @param _receiver Account to receive the output asset
    @return The amount of input asset taken
    """
    num_assets: uint256 = self.num_assets
    assert _i != _j # dev: same input and output asset
    assert _i < num_assets and _j < num_assets # dev: index out of bounds
    assert _dy > 0 # dev: zero amount

    # update rates for from and to assets
    vb_prod: uint256 = 0
    vb_sum: uint256 = 0
    vb_prod, vb_sum = self._unpack_pool_vb(self.packed_pool_vb)
    vb_prod, vb_sum = self._update_rates(unsafe_add(_i, 1) | shift(unsafe_add(_j, 1), 8), vb_prod, vb_sum)
    prev_vb_sum: uint256 = vb_sum

    prev_vb_x: uint256 = 0
    rate_x: uint256 = 0
    packed_weight_x: uint256 = 0
    prev_vb_x, rate_x, packed_weight_x = self._unpack_vb(self.packed_vbs[_i])
    wn_x: uint256 = self._unpack_wn(packed_weight_x, num_assets)

    prev_vb_y: uint256 = 0
    rate_y: uint256 = 0
    packed_weight_y: uint256 = 0
    prev_vb_y, rate_y, packed_weight_y = self._unpack_vb(self.packed_vbs[_j])
    wn_y: uint256 = self._unpack_wn(packed_weight_y, num_assets)

    dvb_y: uint256 = _dy * rate_y / PRECISION
    vb_y: uint256 = prev_vb_y - dvb_y

    # update x_j and remove x_i from variables
    vb_prod = vb_prod * self._pow_up(prev_vb_x, wn_x) / self._pow_down(vb_y * PRECISION / prev_vb_y, wn_y)
    vb_sum = vb_sum - dvb_y - prev_vb_x

    # calulate new balance of in token
    vb_x: uint256 = self._calc_vb(wn_x, prev_vb_x, self.supply, self.amplification, vb_prod, vb_sum)
    dx: uint256 = (vb_x - prev_vb_x) * PRECISION / rate_x
    dx_fee: uint256 = self.swap_fee_rate
    dx_fee = dx * dx_fee / (PRECISION - dx_fee)
    dx += dx_fee
    vb_x += dx_fee * rate_x / PRECISION
    vb_sum += vb_x
    assert dx <= _max_dx # dev: slippage

    # check bands
    self._check_bands(prev_vb_x * PRECISION / prev_vb_sum, vb_x * PRECISION / vb_sum, packed_weight_x)
    self._check_bands(prev_vb_y * PRECISION / prev_vb_sum, vb_y * PRECISION / vb_sum, packed_weight_y)

    # update variables
    self.packed_vbs[_i] = self._pack_vb(vb_x, rate_x, packed_weight_x)
    self.packed_vbs[_j] = self._pack_vb(vb_y, rate_y, packed_weight_y)
    vb_prod = vb_prod * PRECISION / self._pow_up(vb_x, wn_x)

    # mint fees
    if dx_fee > 0:
        supply: uint256 = 0
        supply, vb_prod = self._update_supply(self.supply, vb_prod, vb_sum)

    self.packed_pool_vb = self._pack_pool_vb(vb_prod, vb_sum)

    assert ERC20(self.assets[_i]).transferFrom(msg.sender, self, dx, default_return_value=True)
    assert ERC20(self.assets[_j]).transfer(_receiver, _dy, default_return_value=True)
    log Swap(msg.sender, _receiver, _i, _j, dx, _dy)

    return dx

@external
@nonreentrant('lock')
def add_liquidity(
    _amounts: DynArray[uint256, MAX_NUM_ASSETS], 
    _min_lp_amount: uint256, 
    _receiver: address = msg.sender
) -> uint256:
    """
    @notice Deposit assets into the pool
    @param _amounts Array of amount for each asset to take from caller
    @param _min_lp_amount Minimum amount of LP tokens to mint
    @param _receiver Account to receive the LP tokens
    @return The amount of LP tokens minted
    """
    num_assets: uint256 = self.num_assets
    assert len(_amounts) == num_assets

    vb_prod: uint256 = 0
    vb_sum: uint256 = 0
    vb_prod, vb_sum = self._unpack_pool_vb(self.packed_pool_vb)

    prev_vb: uint256 = 0
    rate: uint256 = 0
    packed_weight: uint256 = 0

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
                prev_vb, rate, packed_weight = self._unpack_vb(self.packed_vbs[asset])
                lowest = min(_amounts[asset] * rate / prev_vb, lowest)
        else:
            lowest = 0
    assert sh > 0 # dev: need to deposit at least one asset

    # update rates
    vb_prod, vb_sum = self._update_rates(assets, vb_prod, vb_sum)
    prev_supply: uint256 = self.supply

    vb_prod_final: uint256 = vb_prod
    vb_sum_final: uint256 = vb_sum
    fee_rate: uint256 = self.swap_fee_rate / 2
    prev_vb_sum: uint256 = vb_sum
    prev_ratios: DynArray[uint256, MAX_NUM_ASSETS] = []
    vb: uint256 = 0
    for asset in range(MAX_NUM_ASSETS):
        if asset == num_assets:
            break

        amount: uint256 = _amounts[asset]
        if amount == 0:
            assert prev_supply > 0 # dev: initial deposit amounts must be non-zero
            continue

        # update stored virtual balance
        prev_vb, rate, packed_weight = self._unpack_vb(self.packed_vbs[asset])
        dvb: uint256 = amount * rate / PRECISION
        vb = prev_vb + dvb
        self.packed_vbs[asset] = self._pack_vb(vb, rate, packed_weight)

        if prev_supply > 0:
            prev_ratios.append(prev_vb * PRECISION / prev_vb_sum)
            wn: uint256 = self._unpack_wn(packed_weight, num_assets)

            # update product and sum of virtual balances
            vb_prod_final = vb_prod_final * self._pow_up(prev_vb * PRECISION / vb, wn) / PRECISION
            # the `D^n` factor will be updated in `_calc_supply()`
            vb_sum_final += dvb

            # remove fees from balance and recalculate sum and product
            fee: uint256 = (dvb - prev_vb * lowest / PRECISION) * fee_rate / PRECISION
            vb_prod = vb_prod * self._pow_up(prev_vb * PRECISION / (vb - fee), wn) / PRECISION
            vb_sum += dvb - fee
        assert ERC20(self.assets[asset]).transferFrom(msg.sender, self, amount, default_return_value=True)

    supply: uint256 = prev_supply
    if prev_supply == 0:
        # initital deposit, calculate necessary variables
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
            vb, rate, packed_weight = self._unpack_vb(self.packed_vbs[asset])
            self._check_bands(prev_ratios[j], vb * PRECISION / vb_sum_final, packed_weight)
            j = unsafe_add(j, 1)

    # mint LP tokens
    supply, vb_prod = self._calc_supply(num_assets, supply, self.amplification, vb_prod, vb_sum, prev_supply == 0)
    mint: uint256 = supply - prev_supply
    assert mint > 0 and mint >= _min_lp_amount # dev: slippage
    PoolToken(token).mint(_receiver, mint)
    log AddLiquidity(msg.sender, _receiver, _amounts, mint)

    supply_final: uint256 = supply
    if prev_supply > 0:
        # mint fees
        supply_final, vb_prod_final = self._calc_supply(num_assets, prev_supply, self.amplification, vb_prod_final, vb_sum_final, True)
        PoolToken(token).mint(self.staking, supply_final - supply)
    else:
        vb_prod_final = vb_prod
        vb_sum_final = vb_sum

    self.supply = supply_final
    self.packed_pool_vb = self._pack_pool_vb(vb_prod_final, vb_sum_final)

    return mint

@external
@nonreentrant('lock')
def remove_liquidity(
    _lp_amount: uint256, 
    _min_amounts: DynArray[uint256, MAX_NUM_ASSETS], 
    _receiver: address = msg.sender
):
    """
    @notice Withdraw assets from the pool in a balanced manner
    @param _lp_amount Amount of LP tokens to burn
    @param _min_amounts Array of minimum amount of each asset to send
    @param _receiver Account to receive the assets
    """
    num_assets: uint256 = self.num_assets
    assert len(_min_amounts) == num_assets

    # update supply
    prev_supply: uint256 = self.supply
    supply: uint256 = prev_supply - _lp_amount
    self.supply = supply
    PoolToken(token).burn(msg.sender, _lp_amount)
    log RemoveLiquidity(msg.sender, _receiver, _lp_amount)

    # update necessary variables and transfer assets
    vb_prod: uint256 = PRECISION
    vb_sum: uint256 = 0

    prev_vb: uint256 = 0
    rate: uint256 = 0
    packed_weight: uint256 = 0
    for asset in range(MAX_NUM_ASSETS):
        if asset == num_assets:
            break
        prev_vb, rate, packed_weight = self._unpack_vb(self.packed_vbs[asset])
        weight: uint256 = self._unpack_wn(packed_weight, 1)

        dvb: uint256 = prev_vb * _lp_amount / prev_supply
        vb: uint256 = prev_vb - dvb
        self.packed_vbs[asset] = self._pack_vb(vb, rate, packed_weight)
        
        vb_prod = unsafe_div(unsafe_mul(vb_prod, self._pow_down(unsafe_div(unsafe_mul(supply, weight), vb), unsafe_mul(weight, num_assets))), PRECISION)
        vb_sum = unsafe_add(vb_sum, vb)

        amount: uint256 = dvb * PRECISION / rate
        assert amount >= _min_amounts[asset] # dev: slippage
        assert ERC20(self.assets[asset]).transfer(_receiver, amount, default_return_value=True)

    self.packed_pool_vb = self._pack_pool_vb(vb_prod, vb_sum)

@external
@nonreentrant('lock')
def remove_liquidity_single(
    _asset: uint256, 
    _lp_amount: uint256, 
    _min_amount: uint256, 
    _receiver: address = msg.sender
) -> uint256:
    """
    @notice Withdraw a single asset from the pool
    @param _asset Index of the asset to withdraw
    @param _lp_amount Amount of LP tokens to burn
    @param _min_amount Minimum amount of asset to send
    @param _receiver Account to receive the asset
    @return The amount of asset sent
    """
    num_assets: uint256 = self.num_assets
    assert _asset < num_assets # dev: index out of bounds

    # update rate
    vb_prod: uint256 = 0
    vb_sum: uint256 = 0
    vb_prod, vb_sum = self._unpack_pool_vb(self.packed_pool_vb)
    vb_prod, vb_sum = self._update_rates(unsafe_add(_asset, 1), vb_prod, vb_sum)
    prev_vb_sum: uint256 = vb_sum

    # update supply
    prev_supply: uint256 = self.supply
    supply: uint256 = prev_supply - _lp_amount
    self.supply = supply
    PoolToken(token).burn(msg.sender, _lp_amount)

    prev_vb: uint256 = 0
    rate: uint256 = 0
    packed_weight: uint256 = 0
    prev_vb, rate, packed_weight = self._unpack_vb(self.packed_vbs[_asset])
    wn: uint256 = self._unpack_wn(packed_weight, num_assets)

    # update variables
    vb_prod = vb_prod * self._pow_up(prev_vb, wn) / PRECISION
    for i in range(MAX_NUM_ASSETS):
        if i == num_assets:
            break
        vb_prod = vb_prod * supply / prev_supply
    vb_sum = vb_sum - prev_vb

    # calculate new balance of asset
    vb: uint256 = self._calc_vb(wn, prev_vb, supply, self.amplification, vb_prod, vb_sum)
    dvb: uint256 = prev_vb - vb
    fee: uint256 = dvb * self.swap_fee_rate / 2 / PRECISION
    dvb -= fee
    vb += fee
    dx: uint256 = dvb * PRECISION / rate
    assert dx > _min_amount # dev: slippage

    # update variables
    self.packed_vbs[_asset] = self._pack_vb(vb, rate, packed_weight)
    vb_prod = vb_prod * PRECISION / self._pow_up(vb, wn)
    vb_sum = vb_sum + vb

    for asset in range(MAX_NUM_ASSETS):
        if asset == num_assets:
            break
        if asset == _asset:
            self._check_bands(prev_vb * PRECISION / prev_vb_sum, vb * PRECISION / vb_sum, packed_weight)
        else:
            vb_loop: uint256 = 0
            rate_loop: uint256 = 0
            packed_weight_loop: uint256 = 0
            vb_loop, rate_loop, packed_weight_loop = self._unpack_vb(self.packed_vbs[asset])
            self._check_bands(vb_loop * PRECISION / prev_vb_sum, vb_loop * PRECISION / vb_sum, packed_weight_loop)

    if fee > 0:
        # mint fee
        supply, vb_prod = self._update_supply(supply, vb_prod, vb_sum)

    self.packed_pool_vb = self._pack_pool_vb(vb_prod, vb_sum)

    assert ERC20(self.assets[_asset]).transfer(_receiver, dx, default_return_value=True)
    log RemoveLiquiditySingle(msg.sender, _receiver, _asset, dx, _lp_amount)
    return dx

@external
def update_rates(_assets: DynArray[uint256, MAX_NUM_ASSETS]):
    """
    @notice Update the stored rate of any of the pool's assets
    @param _assets Array of indices of assets to update
    @dev If no assets are passed in, every asset will be updated
    """
    num_assets: uint256 = self.num_assets
    assets: uint256 = 0
    for i in range(MAX_NUM_ASSETS):
        if i == len(_assets):
            break
        assert _assets[i] < num_assets # dev: index out of bounds
        assets = assets | shift(_assets[i] + 1, unsafe_mul(8, convert(i, int128)))

    if len(_assets) == 0:
        assets = ALL_ASSETS_FLAG
    vb_prod: uint256 = 0
    vb_sum: uint256 = 0
    vb_prod, vb_sum = self._unpack_pool_vb(self.packed_pool_vb)
    vb_prod, vb_sum = self._update_rates(assets, vb_prod, vb_sum)
    self.packed_pool_vb = self._pack_pool_vb(vb_prod, vb_sum)

@external
def update_weights() -> bool:
    """
    @notice Update weights and amplification factor, if possible
    @return Boolean to indicate whether the weights and amplification factor have been updated
    @dev Will only update the weights if a ramp is active and at least the minimum time step has been reached
    """
    assert not self.paused # dev: paused
    updated: bool = False
    vb_prod: uint256 = 0
    vb_sum: uint256 = 0
    vb_prod, vb_sum = self._unpack_pool_vb(self.packed_pool_vb)
    vb_prod, updated = self._update_weights(vb_prod)
    if updated and vb_sum > 0:
        supply: uint256 = 0
        supply, vb_prod = self._update_supply(self.supply, vb_prod, vb_sum)
        self.packed_pool_vb = self._pack_pool_vb(vb_prod, vb_sum)
    return updated

@external
@view
def vb_prod_sum() -> (uint256, uint256):
    """
    @notice Get the pool's virtual balance product (pi) and sum (sigma)
    @return Tuple with product and sum
    """
    return self._unpack_pool_vb(self.packed_pool_vb)

@external
@view
def virtual_balance(_asset: uint256) -> uint256:
    """
    @notice Get the virtual balance of an asset
    @param _asset Index of the asset
    @return Virtual balance of asset
    """
    assert _asset < self.num_assets # dev: index out of bounds
    return self.packed_vbs[_asset] & VB_MASK

@external
@view
def rate(_asset: uint256) -> uint256:
    """
    @notice Get the rate of an asset
    @param _asset Index of the asset
    @return Rate of asset
    """
    assert _asset < self.num_assets # dev: index out of bounds
    return shift(self.packed_vbs[_asset], RATE_SHIFT) & RATE_MASK

@external
@view
def weight(_asset: uint256) -> (uint256, uint256, uint256, uint256):
    """
    @notice Get the weight of an asset
    @param _asset Index of the asset
    @return Tuple with weight, target weight, lower band width and upper weight band width
    @dev Does not take into account any active ramp
    """
    assert _asset < self.num_assets # dev: index out of bounds
    weight: uint256 = 0
    target: uint256 = 0
    lower: uint256 = 0
    upper: uint256 = 0
    weight, target, lower, upper = self._unpack_weight(shift(self.packed_vbs[_asset], PACKED_WEIGHT_SHIFT))
    if self.ramp_last_time == 0:
        target = weight
    return weight, target, lower, upper

@external
@view
def packed_weight(_asset: uint256) -> uint256:
    """
    @notice Get the packed weight of an asset in a packed format
    @param _asset Index of the asset
    @return Weight in packed format
    @dev Does not take into account any active ramp
    """
    assert _asset < self.num_assets # dev: index out of bounds
    return shift(self.packed_vbs[_asset], PACKED_WEIGHT_SHIFT)

# PRIVILEGED FUNCTIONS

@external
def pause():
    """
    @notice Pause the pool
    """
    assert msg.sender == self.management or msg.sender == self.guardian
    assert not self.paused # dev: already paused
    self.paused = True
    log Pause(msg.sender)

@external
def unpause():
    """
    @notice Unpause the pool
    """
    assert msg.sender == self.management or msg.sender == self.guardian
    assert self.paused # dev: not paused
    assert not self.killed # dev: killed
    self.paused = False
    log Unpause(msg.sender)

@external
def kill():
    """
    @notice Kill the pool
    """
    assert msg.sender == self.management
    assert self.paused # dev: not paused
    assert not self.killed # dev: already killed
    self.killed = True
    log Kill()

@external
def add_asset(
    _asset: address, 
    _rate_provider: address, 
    _weight: uint256, 
    _lower: uint256, 
    _upper: uint256, 
    _amount: uint256, 
    _amplification: uint256,
    _receiver: address = msg.sender
):
    """
    @notice Add a new asset to the pool
    @param _asset Address of the asset to add
    @param _rate_provider Rate provider for asset
    @param _weight Weight of the new asset
    @param _lower Lower band width
    @param _upper Upper band width
    @param _amount Amount of tokens
    @param _amplification New pool amplification factor
    @param _receiver Account to receive the LP tokens minted
    @dev Can only be called if no ramp is currently active
    @dev Every other asset will have their weight reduced pro rata
    @dev Caller should assure that effective amplification before and after call are the same
    """
    assert msg.sender == self.management

    assert _amount > 0
    prev_num_assets: uint256 = self.num_assets
    assert prev_num_assets < MAX_NUM_ASSETS # dev: pool is full
    assert _amplification > 0
    assert self.ramp_last_time == 0 # dev: ramp active
    assert self.supply > 0 # dev: pool empty

    assert _weight < PRECISION
    assert _lower <= PRECISION
    assert _upper <= PRECISION

    # update weights for existing assets
    num_assets: uint256 = prev_num_assets + 1
    vb: uint256 = 0
    rate: uint256 = 0
    packed_weight: uint256 = 0
    prev_weight: uint256 = 0
    target: uint256 = 0
    lower: uint256 = 0
    upper: uint256 = 0
    for i in range(MAX_NUM_ASSETS):
        if i == prev_num_assets:
            break
        assert self.assets[i] != _asset # dev: asset already part of pool
        vb, rate, packed_weight = self._unpack_vb(self.packed_vbs[i])
        prev_weight, target, lower, upper = self._unpack_weight(packed_weight)
        packed_weight = self._pack_weight(prev_weight - prev_weight * _weight / PRECISION, target, lower, upper)
        self.packed_vbs[i] = self._pack_vb(vb, rate, packed_weight)
    
    assert ERC20Ext(_asset).decimals() == 18
    rate = RateProvider(_rate_provider).rate(_asset)
    assert rate > 0 # dev: no rate

    vb = _amount * rate / PRECISION
    packed_weight = self._pack_weight(_weight, _weight, _lower, _upper)

    # set parameters for new asset
    self.num_assets = num_assets
    self.assets[prev_num_assets] = _asset
    self.rate_providers[prev_num_assets] = _rate_provider
    self.packed_vbs[prev_num_assets] = self._pack_vb(vb, rate, packed_weight)

    # recalculate variables
    vb_prod: uint256 = 0
    vb_sum: uint256 = 0
    vb_prod, vb_sum = self._calc_vb_prod_sum()

    # update supply
    prev_supply: uint256 = self.supply
    supply: uint256 = 0
    supply, vb_prod = self._calc_supply(num_assets, vb_sum, _amplification, vb_prod, vb_sum, True)

    self.amplification = _amplification
    self.supply = supply
    self.packed_pool_vb = self._pack_pool_vb(vb_prod, vb_sum)

    assert ERC20(_asset).transferFrom(msg.sender, self, _amount, default_return_value=True)
    PoolToken(token).mint(_receiver, supply - prev_supply)
    log AddAsset(prev_num_assets, _asset, _rate_provider, rate, _weight, _amount)

@external
def rescue(_token: address, _receiver: address):
    """
    @notice Rescue tokens from this contract
    @param _token The token to be rescued
    @param _receiver Receiver of rescued tokens
    @dev Can't be used to rescue pool assets
    """
    assert msg.sender == self.management
    num_assets: uint256 = self.num_assets
    for asset in range(MAX_NUM_ASSETS):
        if asset == num_assets:
            break
        assert _token != self.assets[asset] # dev: cant rescue pool asset
    amount: uint256 = ERC20(_token).balanceOf(self)
    assert ERC20(_token).transfer(_receiver, amount, default_return_value=True)

@external
def skim(_asset: uint256, _receiver: address):
    """
    @notice Skim surplus of a pool asset
    @param _asset Index of the asset
    @param _receiver Receiver of skimmed tokens
    """
    assert msg.sender == self.management
    assert _asset < self.num_assets # dev: index out of bounds
    vb: uint256 = 0
    rate: uint256 = 0
    packed_weight: uint256 = 0
    vb, rate, packed_weight = self._unpack_vb(self.packed_vbs[_asset])
    expected: uint256 = vb * PRECISION / rate + 1
    token_: address = self.assets[_asset]
    actual: uint256 = ERC20(token_).balanceOf(self)
    assert actual > expected # dev: no surplus
    assert ERC20(token_).transfer(_receiver, actual - expected, default_return_value=True)

@external
def set_swap_fee_rate(_fee_rate: uint256):
    """
    @notice Set the swap fee rate
    @param _fee_rate New swap fee rate (in 18 decimals)
    """
    assert msg.sender == self.management
    assert _fee_rate <= PRECISION
    self.swap_fee_rate = _fee_rate
    log SetSwapFeeRate(_fee_rate)

@external
def set_weight_bands(
    _assets: DynArray[uint256, MAX_NUM_ASSETS], 
    _lower: DynArray[uint256, MAX_NUM_ASSETS], 
    _upper: DynArray[uint256, MAX_NUM_ASSETS]
):
    """
    @notice Set safety weight bands
            If any user operation puts the weight outside of the bands, the transaction will revert
    @param _assets Array of indices of the assets to set the bands for
    @param _lower Array of widths of the lower band
    @param _upper Array of widths of the upper band
    """
    assert msg.sender == self.management
    assert len(_lower) == len(_assets) and len(_upper) == len(_assets)

    num_assets: uint256 = self.num_assets
    for i in range(MAX_NUM_ASSETS):
        if i == len(_assets):
            break
        asset: uint256 = _assets[i]
        assert asset < num_assets # dev: index out of bounds
        assert _lower[i] <= PRECISION and _upper[i] <= PRECISION # dev: bands out of bounds

        vb: uint256 = 0
        rate: uint256 = 0
        packed_weight: uint256 = 0
        vb, rate, packed_weight = self._unpack_vb(self.packed_vbs[asset])
        weight: uint256 = 0
        target: uint256 = 0
        lower: uint256 = 0
        upper: uint256 = 0
        weight, target, lower, upper = self._unpack_weight(packed_weight)
        packed_weight = self._pack_weight(weight, target, _lower[i], _upper[i])
        self.packed_vbs[asset] = self._pack_vb(vb, rate, packed_weight)
        log SetWeightBand(asset, _lower[i], _upper[i])

@external
def set_rate_provider(_asset: uint256, _rate_provider: address):
    """
    @notice Set a rate provider for an asset
    @param _asset Index of the assets
    @param _rate_provider New rate provider for the asset
    """
    assert msg.sender == self.management
    assert _asset < self.num_assets # dev: index out of bounds

    self.rate_providers[_asset] = _rate_provider
    vb_prod: uint256 = 0
    vb_sum: uint256 = 0
    vb_prod, vb_sum = self._unpack_pool_vb(self.packed_pool_vb)
    vb_prod, vb_sum = self._update_rates(_asset + 1, vb_prod, vb_sum)
    self.packed_pool_vb = self._pack_pool_vb(vb_prod, vb_sum)
    log SetRateProvider(_asset, _rate_provider)

@external
def set_ramp(
    _amplification: uint256, 
    _weights: DynArray[uint256, MAX_NUM_ASSETS], 
    _duration: uint256, 
    _start: uint256 = block.timestamp
):
    """
    @notice Schedule an amplification and/or weight change
    @param _amplification New amplification factor (in 18 decimals)
    @param _weights Array of new weight for each asset (in 18 decimals)
    @param _duration Duration of the ramp (in seconds)
    @param _start Ramp start time
    @dev Effective amplification at any time is `self.amplification/f^n`
    """
    assert msg.sender == self.management

    num_assets: uint256 = self.num_assets
    assert _amplification > 0
    assert len(_weights) == num_assets
    assert _start >= block.timestamp

    updated: bool = False
    vb_prod: uint256 = 0
    vb_sum: uint256 = 0
    vb_prod, vb_sum = self._unpack_pool_vb(self.packed_pool_vb)
    vb_prod, updated = self._update_weights(vb_prod)
    if updated:
        supply: uint256 = 0
        supply, vb_prod = self._update_supply(self.supply, vb_prod, vb_sum)
        self.packed_pool_vb = self._pack_pool_vb(vb_prod, vb_sum)
    
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

        vb: uint256 = 0
        rate: uint256 = 0
        packed_weight: uint256 = 0
        vb, rate, packed_weight = self._unpack_vb(self.packed_vbs[asset])
        weight: uint256 = 0
        target: uint256 = 0
        lower: uint256 = 0
        upper: uint256 = 0
        weight, target, lower, upper = self._unpack_weight(packed_weight)
        packed_weight = self._pack_weight(weight, _weights[asset], lower, upper)
        self.packed_vbs[asset] = self._pack_vb(vb, rate, packed_weight)
    assert total == PRECISION # dev: weights dont add up
    log SetRamp(_amplification, _weights, _duration, _start)

@external
def set_ramp_step(_ramp_step: uint256):
    """
    @notice Set minimum time between ramp step
    @param _ramp_step Minimum step time (in seconds)
    """
    assert msg.sender == self.management
    assert _ramp_step > 0
    self.ramp_step = _ramp_step
    log SetRampStep(_ramp_step)

@external
def stop_ramp():
    """
    @notice Stop an active ramp
    """
    assert msg.sender == self.management
    self.ramp_last_time = 0
    self.ramp_stop_time = 0
    log StopRamp()

@external
def set_staking(_staking: address):
    """
    @notice Set the address that receives yield, slashings and swap fees
    @param _staking New staking address
    """
    assert msg.sender == self.management
    self.staking = _staking
    log SetStaking(_staking)

@external
def set_management(_management: address):
    """
    @notice Set the management address
    @param _management New management address
    """
    assert msg.sender == self.management
    self.management = _management
    log SetManagement(_management)

@external
def set_guardian(_guardian: address):
    """
    @notice Set the guardian address
    @param _guardian New guardian address
    """
    assert msg.sender == self.management or msg.sender == self.guardian
    self.guardian = _guardian
    log SetGuardian(msg.sender, _guardian)

# INTERNAL FUNCTIONS

@internal
def _update_rates(_assets: uint256, _vb_prod: uint256, _vb_sum: uint256) -> (uint256, uint256):
    """
    @notice Update rates of specific assets
    @param _assets Integer where each byte represents an asset index offset by one
    @param _vb_prod Product term (pi) before update
    @param _vb_sum Sum term (sigma) before update
    @return Tuple with new product and sum term
    @dev Loops through the bytes in `_assets` until a zero or a number larger than the number of assets is encountered
    @dev Update weights (if needed) prior to checking any rates
    @dev Will recalculate supply and mint/burn to staking contract if any weight or rate has updated
    @dev Will revert if any rate increases by more than 10%, unless called by management
    """
    assert not self.paused # dev: paused
    
    vb_prod: uint256 = 0
    vb_sum: uint256 = _vb_sum
    updated: bool = False
    vb_prod, updated = self._update_weights(_vb_prod)
    num_assets: uint256 = self.num_assets
    for i in range(MAX_NUM_ASSETS):
        asset: uint256 = shift(_assets, unsafe_mul(-8, convert(i, int128))) & 255
        if asset == 0 or asset > num_assets:
            break
        asset = unsafe_sub(asset, 1)
        provider: address = self.rate_providers[asset]

        prev_vb: uint256 = 0
        prev_rate: uint256 = 0
        packed_weight: uint256 = 0
        prev_vb, prev_rate, packed_weight = self._unpack_vb(self.packed_vbs[asset])

        rate: uint256 = RateProvider(provider).rate(self.assets[asset])
        assert rate > 0 # dev: no rate
        if rate == prev_rate:
            # no rate change
            continue

        # cap upward rate movements to 10%
        if rate > prev_rate * 11 / 10 and prev_rate > 0:
            assert msg.sender == self.management # dev: rate increase cap

        vb: uint256 = 0
        if prev_rate > 0 and vb_sum > 0:
            # factor out old rate and factor in new
            wn: uint256 = self._unpack_wn(packed_weight, num_assets)
            vb_prod = vb_prod * self._pow_up(prev_rate * PRECISION / rate, wn) / PRECISION
            vb = prev_vb * rate / prev_rate
            vb_sum = vb_sum + vb - prev_vb
        self.packed_vbs[asset] = self._pack_vb(vb, rate, packed_weight)
        log RateUpdate(asset, rate)

    if not updated and vb_prod == _vb_prod and vb_sum == _vb_sum:
        # no weight and no rate changes
        return vb_prod, vb_sum

    # recalculate supply and mint/burn token to staking address
    supply: uint256 = 0
    supply, vb_prod = self._update_supply(self.supply, vb_prod, vb_sum)
    return vb_prod, vb_sum

@internal
def _update_weights(_vb_prod: uint256) -> (uint256, bool):
    """
    @notice Apply a step in amplitude and weight ramp, if applicable
    @param _vb_prod Product term (pi) before update
    @return Tuple with new product term and flag indicating if a step has been taken
    @dev Caller is responsible for updating supply if a step has been taken
    """
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
        current = target
    else:
        if current > target:
            current = current - (current - target) * span / duration
        else:
            current = current + (target - current) * span / duration
    self.amplification = current

    # update weights
    num_assets: uint256 = self.num_assets
    vb: uint256 = 0
    rate: uint256 = 0
    packed_weight: uint256 = 0
    lower: uint256 = 0
    upper: uint256 = 0
    for asset in range(MAX_NUM_ASSETS):
        if asset == num_assets:
            break
        vb, rate, packed_weight = self._unpack_vb(self.packed_vbs[asset])
        current, target, lower, upper = self._unpack_weight(packed_weight)
        if duration == 0:
            current = target
        else:
            if current > target:
                current -= (current - target) * span / duration
            else:
                current += (target - current) * span / duration
        packed_weight = self._pack_weight(current, target, lower, upper)
        self.packed_vbs[asset] = self._pack_vb(vb, rate, packed_weight)

    vb_prod: uint256 = 0
    supply: uint256 = self.supply
    if supply > 0:
        vb_prod = self._calc_vb_prod(supply)
    return vb_prod, True

@internal
def _update_supply(_supply: uint256, _vb_prod: uint256, _vb_sum: uint256) -> (uint256, uint256):
    """
    @notice Calculate supply and burn or mint difference from the staking contract
    @param _supply Previous supply
    @param _vb_prod Product term (pi)
    @param _vb_sum Sum term (sigma)
    @return Tuple with new supply and product term
    """
    if _supply == 0:
        return 0, _vb_prod

    supply: uint256 = 0
    vb_prod: uint256 = 0
    supply, vb_prod = self._calc_supply(self.num_assets, _supply, self.amplification, _vb_prod, _vb_sum, True)
    if supply > _supply:
        PoolToken(token).mint(self.staking, supply - _supply)
    elif supply < _supply:
        PoolToken(token).burn(self.staking, _supply - supply)
    self.supply = supply
    return supply, vb_prod

@internal
@pure
def _check_bands(_prev_ratio: uint256, _ratio: uint256, _packed_weight: uint256):
    """
    @notice Check whether asset is within safety band, or if previously outside, moves closer to it
    @param _prev_ratio Asset ratio before user action
    @param _ratio Asset ratio after user action
    @param _packed_weight Packed weight
    @dev Reverts if condition not met
    """
    weight: uint256 = unsafe_mul(_packed_weight & WEIGHT_MASK, WEIGHT_SCALE)

    # lower limit check
    limit: uint256 = unsafe_mul(shift(_packed_weight, LOWER_BAND_SHIFT) & WEIGHT_MASK, WEIGHT_SCALE)
    if limit > weight:
        limit = 0
    else:
        limit = unsafe_sub(weight, limit)
    if _ratio < limit:
        assert _ratio > _prev_ratio # dev: ratio below lower band
        return

    # upper limit check
    limit = min(unsafe_add(weight, unsafe_mul(shift(_packed_weight, UPPER_BAND_SHIFT), WEIGHT_SCALE)), PRECISION)
    if _ratio > limit:
        assert _ratio < _prev_ratio # dev: ratio above upper band

# MATH FUNCTIONS

@internal
@view
def _calc_vb_prod_sum() -> (uint256, uint256):
    """
    @notice Calculate product term (pi) and sum term (sigma)
    @return Tuple with product term and sum term
    """
    s: uint256 = 0
    num_assets: uint256 = self.num_assets
    for asset in range(MAX_NUM_ASSETS):
        if asset == num_assets:
            break
        s = unsafe_add(s, self.packed_vbs[asset] & VB_MASK)
    p: uint256 = self._calc_vb_prod(s)
    return p, s

@internal
@view
def _calc_vb_prod(_s: uint256) -> uint256:
    """
    @notice Calculate product term (pi)
    @param _s Supply to use in product term
    @param Product term
    """
    num_assets: uint256 = self.num_assets
    p: uint256 = PRECISION
    for asset in range(MAX_NUM_ASSETS):
        if asset == num_assets:
            break
        vb: uint256 = 0
        rate: uint256 = 0
        weight: uint256 = 0
        vb, rate, weight = self._unpack_vb(self.packed_vbs[asset])
        weight = self._unpack_wn(weight, 1)
        
        assert weight > 0 and vb > 0 # dev: borked
        # p = product((D * w_i / vb_i)^(w_i n))
        p = unsafe_div(unsafe_mul(p, self._pow_down(unsafe_div(unsafe_mul(_s, weight), vb), unsafe_mul(weight, num_assets))), PRECISION)
    return p

@internal
@pure
def _calc_supply(
    _num_assets: uint256, 
    _supply: uint256, 
    _amplification: uint256,
    _vb_prod: uint256, 
    _vb_sum: uint256, 
    _up: bool
) -> (uint256, uint256):
    """
    @notice Calculate supply iteratively
    @param _num_assets Number of assets in pool
    @param _supply Supply as used in product term
    @param _amplification Amplification factor `A f^n`
    @param _vb_prod Product term (pi)
    @param _vb_sum Sum term (sigma)
    @param _up Whether to round up
    @return Tuple with new supply and product term
    """
    
    # D[m+1] = (A f^n sigma - D[m] pi[m] )) / (A f^n - 1)
    #        = (l - s r) / d

    l: uint256 = _amplification # left: A f^n sigma
    d: uint256 = l - PRECISION # denominator: A f^n - 1
    l = l * _vb_sum
    s: uint256 = _supply # supply: D[m]
    r: uint256 = _vb_prod # right: pi[m]

    for _ in range(255):
        sp: uint256 = unsafe_div(unsafe_sub(l, unsafe_mul(s, r)), d) # D[m+1] = (l - s * r) / d
        # update product term pi[m+1] = (D[m+1]/D[m])^n pi[m]
        for i in range(MAX_NUM_ASSETS):
            if i == _num_assets:
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
    _wn: uint256, 
    _y: uint256, 
    _supply: uint256, 
    _amplification: uint256,
    _vb_prod: uint256, 
    _vb_sum: uint256
) -> uint256:
    """
    @notice Calculate a single asset's virtual balance iteratively using Newton's method
    @param _wn Asset weight times number of assets
    @param _y Starting value
    @param _supply Supply
    @param _amplification Amplification factor `A f^n`
    @param _vb_prod Intermediary product term (pi~), pi with previous balances factored out and new balance factored in
    @param _vb_sum Intermediary sum term (sigma~), sigma with previous balances subtracted and new balance added
    @return New asset virtual balance
    """

    # y = x_j, sum' = sum(x_i, i != j), prod' = D^n w_j^(v_j) prod((w_i/x_i)^v_i, i != j)
    # Iteratively find root of g(y) using Newton's method
    # g(y) = y^(v_j + 1) + (sum' + (1 / (A f^n) - 1) D) y^(v_j) - D prod' / (A f^n)
    #      = y^(v_j + 1) + b y^(v_j) - c
    # y[n+1] = y[n] - g(y[n])/g'(y[n])
    #        = (y[n]^2 + b (1 - q) y[n] + c q y[n]^(1 - v_j)) / ((q + 1) y[n] + b))

    b: uint256 = _supply * PRECISION / _amplification # b' = sigma + D / (A f^n)
    c: uint256 = _vb_prod * b / PRECISION # c = D / (A f^n) * pi
    b += _vb_sum
    q: uint256 = PRECISION * PRECISION / _wn # q = 1/v_i = 1/(w_i n)

    y: uint256 = _y
    for _ in range(255):
        yp: uint256 = (y + b + _supply * q / PRECISION + c * q / self._pow_up(y, _wn) - b * q / PRECISION - _supply) * y / (q * y / PRECISION + y + b - _supply)
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
def _pack_vb(_vb: uint256, _rate: uint256, _packed_weight: uint256) -> uint256:
    """
    @notice Pack virtual balance of asset along with other related variables
    @param _vb Asset virtual balance
    @param _rate Asset rate
    @param _packed_weight Asset packed weight
    @return Packed variable
    """
    assert _vb <= VB_MASK and _rate <= RATE_MASK
    return _vb | shift(_rate, -RATE_SHIFT) | shift(_packed_weight, -PACKED_WEIGHT_SHIFT)

@internal
@pure
def _unpack_vb(_packed: uint256) -> (uint256, uint256, uint256):
    """
    @notice Unpack variable to its components
    @param _packed Packed variable
    @return Tuple with virtual balance, rate and packed weight
    """
    return _packed & VB_MASK, shift(_packed, RATE_SHIFT) & RATE_MASK, shift(_packed, PACKED_WEIGHT_SHIFT)

@internal
@pure
def _pack_weight(_weight: uint256, _target: uint256, _lower: uint256, _upper: uint256) -> uint256:
    """
    @notice Pack weight with target and bands
    @param _weight Weight (18 decimals)
    @param _target Target weight (18 decimals)
    @param _lower Lower band, allowed distance from weight in negative direction (18 decimals)
    @param _upper Upper band, allowed distance from weight in positive direction (18 decimals)
    @return Packed weight
    """
    return unsafe_div(_weight, WEIGHT_SCALE) | shift(unsafe_div(_target, WEIGHT_SCALE), -TARGET_WEIGHT_SHIFT) | shift(unsafe_div(_lower, WEIGHT_SCALE), -LOWER_BAND_SHIFT) | shift(unsafe_div(_upper, WEIGHT_SCALE), -UPPER_BAND_SHIFT)

@internal
@pure
def _unpack_weight(_packed: uint256) -> (uint256, uint256, uint256, uint256):
    """
    @notice Unpack weight to its components
    @param _packed Packed weight
    @return Tuple with weight, target weight, lower band and upper band (all in 18 decimals)
    """
    return unsafe_mul(_packed & WEIGHT_MASK, WEIGHT_SCALE), unsafe_mul(shift(_packed, TARGET_WEIGHT_SHIFT) & WEIGHT_MASK, WEIGHT_SCALE), unsafe_mul(shift(_packed, LOWER_BAND_SHIFT) & WEIGHT_MASK, WEIGHT_SCALE), unsafe_mul(shift(_packed, UPPER_BAND_SHIFT), WEIGHT_SCALE)

@internal
@pure
def _unpack_wn(_packed: uint256, _num_assets: uint256) -> uint256:
    """
    @notice Unpack weight and multiply by number of assets
    @param _packed Packed weight
    @param _num_assets Number of assets
    @return Weight multiplied by number of assets (18 decimals)
    """
    return unsafe_mul(unsafe_mul(_packed & WEIGHT_MASK, WEIGHT_SCALE), _num_assets)

@internal
@pure
def _pack_pool_vb(_prod: uint256, _sum: uint256) -> uint256:
    """
    @notice Pack pool product and sum term
    @param _prod Product term (pi)
    @param _sum Sum term (sigma)
    @return Packed terms
    """
    assert _prod <= POOL_VB_MASK and _sum <= POOL_VB_MASK
    return _prod | shift(_sum, -POOL_VB_SHIFT)

@internal
@pure
def _unpack_pool_vb(_packed: uint256) -> (uint256, uint256):
    """
    @notice Unpack pool product and sum term
    @param _packed Packed terms
    @return Tuple with pool product term (pi) and sum term (sigma)
    """
    return _packed & POOL_VB_MASK, shift(_packed, POOL_VB_SHIFT)

@internal
@pure
def _pow_up(_x: uint256, _y: uint256) -> uint256:
    """
    @notice Calculate `x` to power of `y`, rounded up
    @param _x Base (18 decimals)
    @param _y Exponent (18 decimals)
    @return `x^y` in 18 decimals, rounded up
    @dev Guaranteed to be at least as big as the actual value
    """
    p: uint256 = self._pow(_x, _y)
    if p == 0:
        return 0
    # p + (p * MAX_POW_REL_ERR - 1) / PRECISION + 1
    return unsafe_add(unsafe_add(p, unsafe_div(unsafe_sub(unsafe_mul(p, MAX_POW_REL_ERR), 1), PRECISION)), 1)

@internal
@pure
def _pow_down(_x: uint256, _y: uint256) -> uint256:
    """
    @notice Calculate `x` to power of `y`, rounded down
    @param _x Base (18 decimals)
    @param _y Exponent (18 decimals)
    @return `x^y` in 18 decimals, rounded down
    @dev Guaranteed to be at most as big as the actual value
    """
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
    """
    @notice Calculate `x` to power of `y`
    @param _x Base (18 decimals)
    @param _y Exponent (18 decimals)
    @return `x^y` in 18 decimals
    @dev Only accurate until 10^-16, use rounded variants for consistent results
    """
    # adapted from Balancer at https://github.com/balancer-labs/balancer-v2-monorepo/blob/599b0cd8f744e1eabef3600d79a2c2b0aea3ddcb/pkg/solidity-utils/contracts/math/LogExpMath.sol
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
    """
    @notice Calculate natural logarithm in double precision
    @param _x Argument of logarithm (18 decimals)
    @return Natural logarithm in 36 decimals
    @dev Caller should perform bounds checks before calling this function
    """
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
    """
    @notice Calculate natural logarithm
    @param _a Argument of logarithm (18 decimals)
    @return Natural logarithm in 18 decimals
    """
    if _a < E18:
        # 1/a > 1, log(a) = -log(1/a)
        return -self.__log(unsafe_div(unsafe_mul(E18, E18), _a))
    return self.__log(_a)

@internal
@pure
def __log(_a: int256) -> int256:
    """
    @notice Calculate natural logarithm, assuming the argument is larger than one
    @param _a Argument of logarithm (18 decimals)
    @return Natural logarithm in 18 decimals
    @dev Caller should perform bounds checks before calling this function
    """
    
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
    """
    @notice Calculate natural exponent `e^x`
    @param _x Exponent (18 decimals)
    @return Natural exponent in 18 decimals
    """
    assert _x >= MIN_NAT_EXP and _x <= MAX_NAT_EXP
    if _x < 0:
        # exp(-x) = 1/exp(x)
        return unsafe_mul(E18, E18) / self.__exp(-_x)
    return self.__exp(_x)

@internal
@pure
def __exp(_x: int256) -> int256:
    """
    @notice Calculate natural exponent `e^x`, assuming exponent is positive
    @param _x Exponent (18 decimals)
    @return Natural exponent in 18 decimals
    @dev Caller should perform bounds checks before calling this function
    """
    
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

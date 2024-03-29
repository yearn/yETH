# @version 0.3.7

# Adapted from https://github.com/balancer-labs/balancer-v2-monorepo/blob/599b0cd8f744e1eabef3600d79a2c2b0aea3ddcb/pkg/solidity-utils/contracts/math/LogExpMath.sol

# powers of 10
E3: constant(int256)               = 1_000
E6: constant(int256)               = E3 * E3
E9: constant(int256)               = E3 * E6
E12: constant(int256)              = E3 * E9
E15: constant(int256)              = E3 * E12
E17: constant(int256)              = 100 * E15
E18: constant(int256)              = E3 * E15
E20: constant(int256)              = E3 * E17
E36: constant(int256)              = E18 * E18
MAX_POW_REL_ERR: constant(uint256) = 100 # 1e-16
MIN_NAT_EXP: constant(int256)      = -41 * E18
MAX_NAT_EXP: constant(int256)      = 130 * E18
LOG36_LOWER: constant(int256)      = E18 - E17
LOG36_UPPER: constant(int256)      = E18 + E17
MILD_EXP_BOUND: constant(uint256)  = 2**254 / 100_000_000_000_000_000_000
MAX_N: constant(uint256)           = 32
PRECISION: constant(uint256)       = 1_000_000_000_000_000_000

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

WEIGHT_MASK: constant(uint256) = 2**85 - 1
LOWER_BAND_SHIFT: constant(int128) = -85
UPPER_BAND_SHIFT: constant(int128) = -170

@external
@pure
def pow_up(_x: uint256, _y: uint256) -> uint256:
    return self._pow_up(_x, _y)

@internal
@pure
def _pow_up(_x: uint256, _y: uint256) -> uint256:
    # guaranteed to be >= the actual value
    p: uint256 = self._pow(_x, _y)
    if p == 0:
        return 0
    # p + (p * MAX_POW_REL_ERR - 1) / PRECISION + 1
    return unsafe_add(unsafe_add(p, unsafe_div(unsafe_sub(unsafe_mul(p, MAX_POW_REL_ERR), 1), PRECISION)), 1)

@external
@pure
def pow_down(_x: uint256, _y: uint256) -> uint256:
    return self._pow_down(_x, _y)

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

@external
@pure
def ln(_a: uint256) -> int256:
    assert _a > 0 # dev: out of bounds
    return self._log(convert(_a, int256))

@external
@pure
def ln36(_a: uint256) -> int256:
    a: int256 = convert(_a, int256)
    assert a > LOG36_LOWER and a < LOG36_UPPER
    return self._log36(a)

@external
@pure
def exponent(x: int256) -> int256:
    return self._exp(x)

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

@external
@pure
def pack_weight(_weight: uint256, _lower: uint256, _upper: uint256) -> uint256:
    return _weight | shift(_lower, -LOWER_BAND_SHIFT) | shift(_upper, -UPPER_BAND_SHIFT)

@external
@pure
def unpack_weight(_packed: uint256) -> (uint256, uint256, uint256):
    return _packed & WEIGHT_MASK, shift(_packed, LOWER_BAND_SHIFT) & WEIGHT_MASK, shift(_packed, UPPER_BAND_SHIFT)

@external
@pure
def solve_D(_a: uint256, _w: DynArray[uint256, MAX_N], _x: DynArray[uint256, MAX_N], _t: uint256) -> (uint256, DynArray[uint256, 255], DynArray[uint256, 255]):
    n: uint256 = len(_w)
    assert len(_x) == n

    v: DynArray[uint256, 255] = []
    w: DynArray[uint256, 255] = []

    # D[n+1] = (A w^n sum - D^(n+1)/(w^n prod^n)) / (A w^n - 1)
    #        = (l - D prod(D / (x_i / w_i)^(w_i n)))) / d
    l: uint256 = PRECISION # product(w_i^(w_i n)) = 1/w^n
    s: uint256 = 0 # sum(x_i)
    c: uint256 = 0 # sum(w_i)

    for i in range(MAX_N):
        if i == n:
            break
        wn: uint256 = _w[i] * n
        l = l * PRECISION / self._pow(_w[i], wn)
        s += _x[i]
        c += _w[i]
    assert c == PRECISION

    l = _a * l / PRECISION
    d: uint256 = l - PRECISION
    l = l * s

    for _ in range(255):
        sp: uint256 = s
        for i in range(MAX_N):
            if i == len(_w):
                break
            sp = sp * s / self._pow(_x[i] * PRECISION / _w[i] , _w[i] * n)
        sp = (l - sp * PRECISION) / d
        w.append(sp)
        if sp >= s:
            v.append(sp-s)
            if sp - s <= _t:
                return sp, w, v
        else:
            v.append(s-sp)
            if s - sp <= _t:
                return sp, w, v
        s = sp
    return 0, w, v

@external
@pure
def solve_y(_a: uint256, _w: DynArray[uint256, MAX_N], _x: DynArray[uint256, MAX_N], _d: uint256, _j: uint256, _t: uint256) -> (uint256, DynArray[uint256, 255], DynArray[uint256, 255]):
    n: uint256 = len(_w)
    assert len(_x) == n
    assert _j < n

    # y = x_j, sum' = sum(x_i, i != j), prod' = prod(x_i^w_i, i != j)
    # w = product(w_i), v_i = w_i n, f_i = 1/v_i
    # Iteratively find root of g(y) using Newton's method
    # g(y) = y^(v_j + 1) + (sum' + (w^n / A - 1) D y^(w_j n) - D^(n+1) w^2n / prod'^n
    #      = y^(v_j + 1) + b y^(v_j) - c
    # y[n+1] = y[n] - g(y[n])/g'(y[n])
    #        = (y[n]^2 + b (1 - f_j) y[n] + c f_j y[n]^(1 - v_j)) / (f_j + 1) y[n] + b)

    w: uint256 = PRECISION
    b: uint256 = 0
    c: uint256 = _d
    sw: uint256 = 0
    for i in range(MAX_N):
        if i == n:
            break

        v: uint256 = _w[i] * n
        w = w * self._pow_down(_w[i], v) / PRECISION
        sw += _w[i]
        if i == _j:
            continue
        b += _x[i]
        c = c * _d / self._pow_up(_x[i] * PRECISION / _w[i], v)
    assert sw == PRECISION
    v: uint256 = _w[_j] * n
    f: uint256 = PRECISION * PRECISION / v
    c = c * _d / _a * self._pow_up(_w[_j], v) / PRECISION * w / PRECISION
    b = b + _d * w / _a

    m: DynArray[uint256, 255] = []
    o: DynArray[uint256, 255] = []

    y: uint256 = _x[_j]
    m.append(y)
    for _ in range(255):
        yp: uint256 = (y + b + _d * f / PRECISION + c * f / self._pow_up(y, v) - b * f / PRECISION - _d) * y / (f * y / PRECISION + y + b - _d)
        m.append(yp)
        if yp >= y:
            o.append(yp - y)
            if yp - y <= _t:
                return yp, m, o
        else:
            o.append(y - yp)
            if y - yp <= _t:
                return yp, m, o
        y = yp
    return 0, m, o

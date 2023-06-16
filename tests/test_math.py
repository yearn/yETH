from mpmath import *
import random

mp.dps = 20

E3 = 1_000
E6 = E3 * E3
E9 = E3 * E6
E18 = E9 * E9
MAX_REL_ERR = 200
N_ITER = 100

def test_log(project, accounts):
    math = project.Math.deploy(sender=accounts[0])
    random.seed()

    for _ in range(N_ITER):
        x = random.randrange(0, E18)
        a = int(log(mpf(x) / E18) * E18)
        b = math.ln(x)
        assert abs(a - b) <= 2

    for _ in range(N_ITER):
        x = random.randrange(0, E3 * E18)
        a = int(log(mpf(x) / E18) * E18)
        b = math.ln(x)
        assert abs(a - b) <= 2

    for _ in range(N_ITER):
        x = random.randrange(0, E6 * E18)
        a = int(log(mpf(x) / E18) * E18)
        b = math.ln(x)
        assert abs(a - b) <= 2

def test_log36(project, accounts):
    math = project.Math.deploy(sender=accounts[0])
    random.seed()

    for _ in range(N_ITER):
        x = random.randrange(E18 * 9 // 10, E18 * 11 // 10)
        y = random.randrange(0, 4 * E18)
        a = int(log(mpf(x) / E18) * y)
        b = math.ln36(x)
        b = (b // E18 * y + (b % E18) * y // E18) // E18
        assert abs(a - b) <= 2

def test_exp(project, accounts):
    math = project.Math.deploy(sender=accounts[0])
    random.seed()

    for _ in range(N_ITER):
        x = random.randrange(0, E18)
        a = int(exp(mpf(x) / E18) * E18)
        b = math.exponent(x)
        e = abs((b * MAX_REL_ERR - 1) // E18 + 1)
        assert abs(a - b) <= e

    for _ in range(N_ITER):
        x = random.randrange(E18, 10 * E18)
        a = int(exp(mpf(x) / E18) * E18)
        b = math.exponent(x)
        e = abs((b * MAX_REL_ERR - 1) // E18 + 1)
        assert abs(a - b) <= e

    for _ in range(N_ITER):
        x = random.randrange(10 * E18, 100 * E18)
        a = int(exp(mpf(x) / E18) * E18)
        b = math.exponent(x)
        e = abs((b * MAX_REL_ERR - 1) // E18 + 1)
        assert abs(a - b) <= e

def test_pow(project, accounts):
    math = project.Math.deploy(sender=accounts[0])
    random.seed()

    for _ in range(N_ITER):
        x = random.randrange(0, E18)
        y = random.randrange(0, 4 * E18)
        a = int(pow(mpf(x) / E18, mpf(y) / E18) * E18)
        b = math.pow_up(x, y)
        c = math.pow_down(x, y)
        e = max(2, (a * MAX_REL_ERR - 1) // E18 + 1)
        assert b >= a and b - a <= e
        assert c <= a and a - c <= e

    for _ in range(N_ITER):
        x = random.randrange(E18, E3 * E18)
        y = random.randrange(0, 4 * E18)
        a = int(pow(mpf(x) / E18, mpf(y) / E18) * E18)
        b = math.pow_up(x, y)
        c = math.pow_down(x, y)
        e = (a * MAX_REL_ERR - 1) // E18 + 1
        assert b >= a and b - a <= e
        assert c <= a and a - c <= e

    for _ in range(N_ITER):
        x = random.randrange(E3 * E18, E6 * E18)
        y = random.randrange(0, 4 * E18)
        a = int(pow(mpf(x) / E18, mpf(y) / E18) * E18)
        b = math.pow_up(x, y)
        c = math.pow_down(x, y)

        e = (a * MAX_REL_ERR - 1) // E18 + 1
        assert b >= a and b - a <= e
        assert c <= a and a - c <= e

    for _ in range(N_ITER):
        x = random.randrange(E6 * E18, E9 * E18)
        y = random.randrange(0, 4 * E18)
        a = int(pow(mpf(x) / E18, mpf(y) / E18) * E18)
        b = math.pow_up(x, y)
        c = math.pow_down(x, y)

        e = (a * MAX_REL_ERR - 1) // E18 + 1
        assert b >= a and b - a <= e
        assert c <= a and a - c <= e

def test_D_2d_equal(project, accounts):
    math = project.Math.deploy(sender=accounts[0])
    
    a = 10 * E18
    w = [E18*5//10, E18*5//10]
    t = 1_000 * E18
    x = [t * v // E18 for v in w]
    s, i, _ = math.solve_D(a, w, x, 1)
    assert (t - s) / t < 1e-20

    # add single sided
    # increase in supply should be close to the amount added
    dx = 10 * E18
    x[0] += dx
    sn, i, _ = math.solve_D(10*E18, w, x, 1)
    ds = sn - s
    assert 1 - ds / dx < 0.0005 # 0.05%

def test_D_2d_weighted(project, accounts):
    math = project.Math.deploy(sender=accounts[0])

    a = 10 * E18
    w = [E18*8//10, E18*2//10]
    t = 1_000 * E18
    x = [t * v // E18 for v in w]
    s, _, _ = math.solve_D(a, w, x, 1)
    assert (t - s) / t < 1e-19

    # add to the 80% side
    # increase in supply should be close to the amount added
    # loss is smaller compared to 50/50 case
    dx = 10 * E18
    x[0] += dx
    sn, i, _ = math.solve_D(a, w, x, 10_000)
    # TODO
    ds = sn - s
    loss_80 =  1 - ds / dx
    assert loss_80 < 0.0001 # 0.01%

    # loss is bigger if added to the 20% side
    x[0] -= dx
    x[1] += dx
    sn, _, _ = math.solve_D(a, w, x, 1)
    ds = sn - s
    loss_20 = 1 - ds / dx
    assert loss_20 < 0.0015 and loss_20 > loss_80 # 0.15%

def test_D_4d_weighted(project, accounts):
    math = project.Math.deploy(sender=accounts[0])

    a = 10 * E18
    w = [E18*1//10, E18*2//10, E18*3//10, E18*4//10]
    t = 1_000_000 * E18
    x = [t * v // E18 for v in w]
    s, _, _ = math.solve_D(a, w, x, 1)
    assert abs(t - s) / t < 1e-20

def test_y_4d(project, accounts):
    math = project.Math.deploy(sender=accounts[0])

    n = 4
    a = 10 * E18
    w = [E18//n for _ in range(n)]
    d = 1000 * E18
    x = [d * v // E18 for v in w]
    x0 = x[0]
    x[0] += 10 * E18
    y, _, _ = math.solve_y(a, w, x, d, 0, 1)
    assert y < x0
    assert (x0 - y) / x0 < 1e-16
    x[0] = y
    d2, _, _ = math.solve_D(a, w, x, 1)
    assert (d - d2) / d < 1e-16

def test_weight_packing(project, accounts):
    math = project.Math.deploy(sender=accounts[0])

    weight = E18 * 5 // 10
    lower = E18 // 10
    upper = E18 * 9 // 10

    packed = math.pack_weight(weight, lower, upper)
    weight2, lower2, upper2 = math.unpack_weight(packed)
    assert weight2 == weight
    assert lower2 == lower
    assert upper2 == upper

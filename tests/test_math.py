from math import log, exp, pow
import random

E3 = 1_000
E6 = E3 * E3
E9 = E3 * E6
E18 = E9 * E9
MAX_ERR_INV = 100_000_000_000_000

def test_log(project, accounts):
    math = project.Math.deploy(sender=accounts[0])
    random.seed()

    for _ in range(100):
        x = random.randrange(0, E18)
        a = int(log(x / E18) * E18)
        b = math.ln(x)
        e = abs(b // MAX_ERR_INV)
        assert abs(a - b) <= e

    for _ in range(100):
        x = random.randrange(0, E3 * E18)
        a = int(log(x / E18) * E18)
        b = math.ln(x)
        e = abs(b // MAX_ERR_INV)
        assert abs(a - b) <= e

    for _ in range(100):
        x = random.randrange(0, E6 * E18)
        a = int(log(x / E18) * E18)
        b = math.ln(x)
        e = abs(b // MAX_ERR_INV)
        assert abs(a - b) <= e

def test_exp(project, accounts):
    math = project.Math.deploy(sender=accounts[0])
    random.seed()

    for _ in range(100):
        x = random.randrange(0, E18)
        a = int(exp(x / E18) * E18)
        b = math.exponent(x)
        e = abs(b // MAX_ERR_INV)
        assert abs(a - b) <= e

    for _ in range(100):
        x = random.randrange(E18, 10 * E18)
        a = int(exp(x / E18) * E18)
        b = math.exponent(x)
        e = abs(b // MAX_ERR_INV)
        assert abs(a - b) <= e

    for _ in range(100):
        x = random.randrange(10 * E18, 100 * E18)
        a = int(exp(x / E18) * E18)
        b = math.exponent(x)
        e = abs(b // MAX_ERR_INV)
        assert abs(a - b) <= e

def test_pow(project, accounts):
    math = project.Math.deploy(sender=accounts[0])
    random.seed()

    for _ in range(100):
        x = random.randrange(0, E18)
        y = random.randrange(0, 4 * E18)
        a = int(pow(x / E18, y / E18) * E18)
        b = math.pow(x, y)
        e = abs(b // MAX_ERR_INV)
        assert abs(a - b) <= e

    for _ in range(100):
        x = random.randrange(E18, E3 * E18)
        y = random.randrange(0, 4 * E18)
        a = int(pow(x / E18, y / E18) * E18)
        b = math.pow(x, y)
        e = abs(b // MAX_ERR_INV)
        assert abs(a - b) <= e

    for _ in range(100):
        x = random.randrange(E3 * E18, E6 * E18)
        y = random.randrange(0, 4 * E18)
        a = int(pow(x / E18, y / E18) * E18)
        b = math.pow(x, y)
        e = abs(b // MAX_ERR_INV)
        assert abs(a - b) <= e

    for _ in range(100):
        x = random.randrange(E6 * E18, E9 * E18)
        y = random.randrange(0, 4 * E18)
        a = int(pow(x / E18, y / E18) * E18)
        b = math.pow(x, y)
        e = abs(b // MAX_ERR_INV)
        assert abs(a - b) <= e

def test_D_2d_equal(project, accounts):
    math = project.Math.deploy(sender=accounts[0])
    
    a = 10 * E18
    w = [E18*5//10, E18*5//10]
    t = 1_000 * E18
    x = [t * v // E18 for v in w]
    s, i = math.solve_D(a, w, x, 1)
    assert t == s
    assert len(i) == 1

    # add single sided
    # increase in supply should be close to the amount added
    dx = 10 * E18
    x[0] += dx
    sn, i = math.solve_D(10*E18, w, x, 1)
    ds = sn - s
    assert 1 - ds / dx < 0.0005 # 0.05%

def test_D_2d_weighted(project, accounts):
    math = project.Math.deploy(sender=accounts[0])

    a = 10 * E18
    w = [E18*8//10, E18*2//10]
    t = 1_000 * E18
    x = [t * v // E18 for v in w]
    s, i = math.solve_D(a, w, x, 1)
    assert t == s
    assert len(i) == 1

    # add to the 80% side
    # increase in supply should be close to the amount added
    # loss is smaller compared to 50/50 case
    dx = 10 * E18
    x[0] += dx
    sn, i = math.solve_D(a, w, x, 1)
    ds = sn - s
    loss_80 =  1 - ds / dx
    assert loss_80 < 0.0001 # 0.01%

    # loss is bigger if added to the 20% side
    x[0] -= dx
    x[1] += dx
    sn, i = math.solve_D(a, w, x, 1)
    ds = sn - s
    loss_20 = 1 - ds / dx
    assert loss_20 < 0.0015 and loss_20 > loss_80 # 0.15%


def test_D_4d_weighted(project, accounts):
    math = project.Math.deploy(sender=accounts[0])

    a = 10 * E18
    w = [E18*1//10, E18*2//10, E18*3//10, E18*4//10]
    t = 1_000_000 * E18
    x = [t * v // E18 for v in w]
    s, i, _ = math.solve_D(a, w, x, 1)
    print(s/E18)
    print(i)
    assert False

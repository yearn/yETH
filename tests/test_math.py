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

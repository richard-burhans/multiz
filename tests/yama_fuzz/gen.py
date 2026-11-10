"""Write random yama cases (see main.c) to stdout: gen.py SEED NCASES [MAXDIM]

Columns mix ACGT, lower case, N and dash runs (including all-dash columns);
about a quarter of cases use the full band, the rest a random monotonic band
of width at least MIN(N,10), which exercises yama's LB/RB edge guards.
"""
import random, sys

def column(rng, h, dashy):
    return "".join("-" if rng.random() < dashy else rng.choice("ACGTACGTacgtN") for _ in range(h))

def block(rng, h, n):
    dashy = rng.choice([0.0, 0.1, 0.3, 0.6])
    cols, run = [], 0
    for _ in range(n):
        if run == 0 and rng.random() < 0.1:
            run = rng.randint(1, 8)
        if run:
            run -= 1
            c = list(column(rng, h, dashy))
            for i in rng.sample(range(h), rng.randint(1, h)):
                c[i] = "-"
            cols.append("".join(c))
        else:
            cols.append(column(rng, h, dashy))
    return cols

def band(rng, M, N):
    mw = min(N, 10)
    if rng.random() < 0.25:
        return [0] * (M + 1), [N] * (M + 1)
    w = rng.randint(mw, max(mw, min(N, rng.choice([10, 20, 40, 70, 150]))))
    LB, RB = [0], [min(N, rng.randint(mw, max(mw, w)))]
    for r in range(1, M + 1):
        lb = min(LB[-1] + rng.choice([0, 0, 1, 1, 1, 2, 3]), N - mw, RB[-1])
        rb = min(N, max(RB[-1], lb + mw, lb + w + rng.randint(-3, 3)))
        LB.append(lb); RB.append(rb)
    RB[M] = N
    return LB, RB

def main():
    seed, ncases = int(sys.argv[1]), int(sys.argv[2])
    maxdim = int(sys.argv[3]) if len(sys.argv) > 3 else 200
    rng = random.Random(seed)
    out = []
    for _ in range(ncases):
        K, L = rng.randint(1, 8), rng.randint(1, 8)
        if rng.random() < 0.1:
            K, L = rng.randint(1, 60), rng.randint(1, 60)
        M, N = rng.randint(1, maxdim), rng.randint(1, maxdim)
        if rng.random() < 0.3:
            M, N = rng.randint(1, 12), rng.randint(1, 12)
        LB, RB = band(rng, M, N)
        out.append(f"{K} {M}"); out += block(rng, K, M)
        out.append(f"{L} {N}"); out += block(rng, L, N)
        out.append(" ".join(map(str, LB))); out.append(" ".join(map(str, RB)))
    sys.stdout.write("\n".join(out) + "\n")

main()

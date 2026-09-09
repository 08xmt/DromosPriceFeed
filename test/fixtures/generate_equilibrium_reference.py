#!/usr/bin/env python3
"""Generate independent, deterministic equilibrium-price references (stdlib only)."""

import argparse
from decimal import Decimal, localcontext
from pathlib import Path
import random


OUTPUT = Path(__file__).with_name("equilibrium_reference.json")
WAD = 10**18
RESERVE = 1_000_000 * WAD
ONE_USD = 100_000_000


def reference(p0, p1, x, y, supply, precision):
    """Continuous invariant; use a different expression from the Solidity code."""
    with localcontext() as context:
        context.prec = precision
        a = Decimal(p0 + p1)
        b = Decimal(abs(p0 - p1))
        if p0 == p1:
            coefficient = a
        else:
            coefficient = (a ** (Decimal(4) / 3) - b ** (Decimal(4) / 3)) ** (Decimal(3) / 4)
        # x, y and supply all have 18 decimals, which cancel in this expression.
        k = Decimal(x) * y * (Decimal(x) ** 2 + Decimal(y) ** 2)
        if x == y:
            balanced = Decimal(x)
        else:
            balanced = (k / 2).sqrt().sqrt()
        return int(balanced * coefficient / supply)


def checked_reference(p0, p1, x, y, supply):
    low = reference(p0, p1, x, y, supply, 100)
    high = reference(p0, p1, x, y, supply, 160)
    if low != high:
        raise ArithmeticError(f"Reference floor not stable at higher precision: {(p0, p1, x, y, supply)}")
    return high


def canonical_cases():
    # Preserve the prototype's 324 cases first, including its random seed/order.
    axis = [1, 2, 79, 80, 99_999, 100_000, 112_200, 500_000, 10_000_000,
            50_000_000, 87_000_000, 99_000_000, 99_999_999, ONE_USD]
    pairs = [(a, b) for a in axis for b in axis]
    rng = random.Random(7813)
    pairs += [(rng.randint(1, ONE_USD), rng.randint(1, ONE_USD)) for _ in range(128)]
    seen = set(pairs)

    def add(a, b):
        if (a, b) not in seen:
            pairs.append((a, b))
            seen.add((a, b))

    # Single-token collapse, including the former 79/80 zero/overprice boundary.
    for p in range(1, 257):
        add(p, ONE_USD)
        add(ONE_USD, p)
    # Correlated collapses around the former sixth-power rounding cliffs.
    for center in [100_000, 112_246, 120_093]:
        for p in range(center - 32, center + 33):
            add(p, p)
            add(p, p + 1)
            add(p, 2 * p)
    for p in range(ONE_USD - 64, ONE_USD + 1):
        add(p, ONE_USD)
    return [(a, b, checked_reference(a, b, RESERVE, RESERVE, RESERVE)) for a, b in pairs]


def scaled_cases():
    prices = [(1, 1), (1, ONE_USD), (79, ONE_USD), (80, ONE_USD),
              (99_999, 99_999), (112_200, 112_201), (50_000_000, ONE_USD),
              (99_000_000, ONE_USD), (ONE_USD, ONE_USD)]
    # These include the larger price per 18-decimal LP unit when initial LP
    # supply was minted from raw 6-decimal token amounts.
    states = []
    for reserve in [WAD // 100, WAD, RESERVE, 100_000_000 * WAD]:
        for supply in [reserve, reserve // 10**6, reserve // 10**12, reserve * 1_000]:
            states.append((reserve, reserve, supply))
    states += [(3 * RESERVE, RESERVE, RESERVE),
               (RESERVE, 3 * RESERVE, RESERVE),
               (20 * RESERVE, RESERVE // 1_000, RESERVE)]
    return [(a, b, x, y, supply, checked_reference(a, b, x, y, supply))
            for a, b in prices for x, y, supply in states]


def flat_rows(name, rows):
    # Decimal strings preserve uint256 values in JSON tooling. Forge's typed
    # parseJsonUintArray converts them without a floating-point intermediate.
    lines = [f'  "{name}": [']
    for index, row in enumerate(rows):
        suffix = "," if index + 1 < len(rows) else ""
        lines.append("    " + ", ".join(f'"{value}"' for value in row) + suffix)
    lines.append("  ]")
    return "\n".join(lines)


def render():
    canonical = canonical_cases()
    scaled = scaled_cases()
    text = ('{\n'
            '  "description": "Fee-free equilibrium references, checked at 100 and 160 decimal digits",\n'
            '  "canonicalFields": ["price0", "price1", "expected"],\n'
            f'  "canonicalCount": {len(canonical)},\n'
            '  "scaledFields": ["price0", "price1", "reserve0", "reserve1", "supply", "expected"],\n'
            f'  "scaledCount": {len(scaled)},\n'
            + flat_rows("canonical", canonical) + ",\n"
            + flat_rows("scaled", scaled) + "\n}\n")
    return text, len(canonical), len(scaled)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true", help="verify the committed fixture without writing it")
    args = parser.parse_args()
    text, canonical, scaled = render()
    if args.check:
        if not OUTPUT.exists() or OUTPUT.read_text() != text:
            raise SystemExit("Reference fixture differs; regenerate it with this script.")
    else:
        OUTPUT.write_text(text)
    print(f"{'Checked' if args.check else 'Generated'} {canonical} canonical and {scaled} scaled references")


if __name__ == "__main__":
    main()

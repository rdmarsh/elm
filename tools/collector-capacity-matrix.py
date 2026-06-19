#!/usr/bin/env python3
"""collector-capacity-matrix: max safe per-collector utilisation for an N-x group.

For an Auto Balanced Collector Group (ABCG), if collectors fail the survivors
must absorb the whole workload without exceeding a safe utilisation ceiling. This
prints, for each group size N and each number of failed collectors k, the highest
NORMAL per-collector utilisation you can run so that AFTER losing k collectors the
surviving N-k collectors still sit at or below the target ceiling.

Output formats:
  Default        one GitHub Flavored Markdown (GFM) table per target.
  --combined     all targets side by side in one wide table; the target
                 percentages sit in their own header row spanning the Lose 1..K
                 sub-columns beneath them.
  --jira         Jira / Confluence wiki markup (|| headers ||) instead of GFM;
                 combines with --combined.
  --csv          one tidy CSV (target,collectors,lose,max_utilisation).

Formula:
  Total load is shared evenly, so N collectors each at u_start carry N*u_start of
  work. After k fail, the N-k survivors share that same load:

      u_after = u_start * N / (N - k)

  Rearranged for the highest u_start that keeps u_after <= target:

      u_start = target * (N - k) / N

  Example: N=3, lose 1, target 80%  ->  80 * (3-1)/3 = 53.33%  ->  53%.

Rounding:
  These are MAXIMUM allowable values, so the default rounds DOWN (floor):
  rounding up would permit a config that tips just over the ceiling after a
  failure. Use --rounding {floor,round,ceil} and --decimals N to change this.

Assumptions:
  Load is fungible and redistributes EVENLY across survivors (a fair model for an
  auto-balanced group). Cells where k >= N are impossible (no survivors) and show
  as "na". Status messages go to stderr; the table(s)/CSV go to stdout.
"""

import argparse
import csv
import math
import sys


def err(*args):
    print(*args, file=sys.stderr)


def quantize(value, decimals, mode):
    """Round VALUE to DECIMALS places using MODE (floor|round|ceil)."""
    scale = 10 ** decimals
    if mode == "floor":
        return math.floor(value * scale) / scale
    if mode == "ceil":
        return math.ceil(value * scale) / scale
    # round-half-up (not banker's), so 26.5 -> 27, matching human expectation
    return math.floor(value * scale + 0.5) / scale


def cell(target, n, k, decimals, mode, na):
    """Max safe u_start for group size N losing k, formatted; NA if impossible."""
    if k >= n:                                  # no survivors -> meaningless
        return na
    v = quantize(target * (n - k) / n, decimals, mode)
    return f"{v:.{decimals}f}%"


# --- table builders: each returns (caption, header_rows, aligns, body) -------
# header_rows is a list of rows (one for a flat header, two for a grouped one).

def build_single(target, rows, ks, decimals, mode, na):
    caption = ("Max per-collector utilisation to stay at or below "
               f"{target:g}% after failure")
    header_rows = [["Collectors (N)"] + [f"Lose {k}" for k in ks]]
    aligns = ["right"] + ["center"] * len(ks)
    body = [[str(n)] + [cell(target, n, k, decimals, mode, na) for k in ks]
            for n in rows]
    return caption, header_rows, aligns, body


def build_combined(targets, rows, ks, decimals, mode, na):
    caption = ("Max per-collector utilisation to stay at or below the target "
               "ceiling after failure")
    # Top header row: each target label centred over its Lose 1..K group. GFM /
    # Jira have no colspan, so the label sits in the group's middle sub-column.
    mid = (len(ks) - 1) // 2
    group_row = ["Collectors (N)"]
    loss_row = [""]
    for target in targets:
        grp = [""] * len(ks)
        grp[mid] = f"{target:g}%"
        group_row += grp
        loss_row += [f"Lose {k}" for k in ks]
    header_rows = [group_row, loss_row]
    aligns = ["right"] + ["center"] * (len(targets) * len(ks))
    body = [[str(n)] + [cell(t, n, k, decimals, mode, na)
                        for t in targets for k in ks]
            for n in rows]
    return caption, header_rows, aligns, body


# --- renderers --------------------------------------------------------------

def render_gfm(caption, header_rows, aligns, body):
    """GFM table. GFM allows only one true header row (the one above the
    separator); any further header rows are emitted as leading body rows, which
    still reads as a stacked header. Padding is cosmetic -- GFM ignores it."""
    print(f"### {caption}\n")
    extra_headers = header_rows[1:]
    all_rows = header_rows + body

    widths = [2] * len(aligns)
    for i, a in enumerate(aligns):
        if a == "center":
            widths[i] = max(widths[i], 3)
    for row in all_rows:
        for i, c in enumerate(row):
            widths[i] = max(widths[i], len(c))

    def pad(s, w, a):
        if a == "center":
            return s.center(w)
        return s.rjust(w) if a == "right" else s.ljust(w)

    def sep(w, a):
        if a == "right":
            return "-" * (w - 1) + ":"
        if a == "center":
            return ":" + "-" * (w - 2) + ":"
        return "-" * w

    def line(cells):
        print("| " + " | ".join(cells) + " |")

    line([pad(h, widths[i], aligns[i]) for i, h in enumerate(header_rows[0])])
    line([sep(widths[i], aligns[i]) for i in range(len(aligns))])
    for row in extra_headers + body:
        line([pad(c, widths[i], aligns[i]) for i, c in enumerate(row)])
    print()


def render_jira(caption, header_rows, aligns, body):
    """Jira / Confluence wiki markup. Header rows use ||cell||; data rows use
    |cell|. Multiple header rows are supported natively, so a grouped header
    renders as two bold rows. Empty cells need a space to render."""
    print(f"h3. {caption}\n")
    for hr in header_rows:
        print("|| " + " || ".join(c or " " for c in hr) + " ||")
    for row in body:
        print("| " + " | ".join(c or " " for c in row) + " |")
    print()


# --- CSV --------------------------------------------------------------------

def emit_csv(targets, rows, ks, decimals, mode, na):
    """One tidy CSV for all targets: target,collectors,lose,max_utilisation."""
    w = csv.writer(sys.stdout)
    w.writerow(["target", "collectors", "lose", "max_utilisation"])
    for target in targets:
        for n in rows:
            for k in ks:
                w.writerow([target, n, k, cell(target, n, k, decimals, mode, na)])


# --- main -------------------------------------------------------------------

def parse_args(argv):
    p = argparse.ArgumentParser(
        prog="collector-capacity-matrix.py",
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("-t", "--target", type=float, action="append", metavar="PCT",
                   help="ceiling not to exceed after failure, in percent. Repeat "
                        "for several tables. Default: 80 90 95 100.")
    p.add_argument("--min-n", type=int, default=1, metavar="N",
                   help="smallest group size (rows). Default: 1.")
    p.add_argument("--max-n", type=int, default=10, metavar="N",
                   help="largest group size (rows). Default: 10.")
    p.add_argument("-k", "--max-loss", type=int, default=3, metavar="K",
                   help="how many simultaneous collector failures to tabulate "
                        "(columns Lose 1..K). Default: 3.")
    p.add_argument("--rounding", choices=("floor", "round", "ceil"),
                   default="floor",
                   help="rounding mode. Default: floor (safe for a MAX ceiling).")
    p.add_argument("--decimals", type=int, default=0, metavar="D",
                   help="decimal places in each percentage. Default: 0.")
    p.add_argument("--na", default="na", metavar="STR",
                   help="text for impossible cells (k >= N). Default: 'na'.")
    p.add_argument("--combined", action="store_true",
                   help="put all targets side by side in ONE wide table, with the "
                        "target percentages on their own header row above the "
                        "Lose 1..K sub-columns.")
    p.add_argument("--jira", action="store_true",
                   help="emit Jira / Confluence wiki markup instead of GFM.")
    p.add_argument("--csv", action="store_true",
                   help="emit one tidy CSV (target,collectors,lose,max) instead "
                        "of a rendered table.")
    return p.parse_args(argv)


def main(argv=None):
    args = parse_args(argv)
    targets = args.target if args.target else [80, 90, 95, 100]

    if args.min_n < 1 or args.max_n < args.min_n:
        err("need 1 <= --min-n <= --max-n")
        return 2
    if args.max_loss < 1:
        err("--max-loss must be >= 1")
        return 2

    rows = list(range(args.min_n, args.max_n + 1))
    ks = list(range(1, args.max_loss + 1))
    q = (args.decimals, args.rounding, args.na)

    if args.csv:
        emit_csv(targets, rows, ks, *q)
        return 0

    if args.combined:
        specs = [build_combined(targets, rows, ks, *q)]
    else:
        specs = [build_single(t, rows, ks, *q) for t in targets]

    render = render_jira if args.jira else render_gfm
    for caption, header_rows, aligns, body in specs:
        render(caption, header_rows, aligns, body)
    return 0


if __name__ == "__main__":
    sys.exit(main())

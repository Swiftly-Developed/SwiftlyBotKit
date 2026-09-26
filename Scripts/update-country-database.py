#!/usr/bin/env python3
"""Builds the country table SwiftlyBotKit's page view dimensions look IPs up in.

    python3 Scripts/update-country-database.py OUTPUT.bin
    python3 Scripts/update-country-database.py OUTPUT.bin --month 2026-09
    python3 Scripts/update-country-database.py OUTPUT.bin --from dbip-country-lite-2026-09.csv.gz

Downloads DB-IP's free "IP to Country Lite" CSV for the current month (or
`--month`, or reads a local copy with `--from`) and writes it in the compact
binary layout `CountryLookup` reads (see its documentation for the byte
layout). Point `BotKitConfiguration.PageViews.Dimensions.countryDatabasePath`
at the output.

DB-IP publishes a new file at the start of each month. Run this monthly; the
country of an address changes rarely, so a file a few months old is still
fine. The data is licensed CC BY 4.0, which asks for attribution: the text
stored in the file is shown in the dashboard footer.

Adjacent ranges with the same country are merged, and IPv6 ranges are kept
to their upper 64 bits. When several IPv6 ranges share those 64 bits, one
of them stands for the whole /64; DB-IP has a few hundred such ranges out of
about 360,000.
"""
import argparse
import datetime
import gzip
import ipaddress
import struct
import sys
import urllib.request

URL = "https://download.db-ip.com/free/dbip-country-lite-{month}.csv.gz"


def read_rows(args):
    if args.source:
        with open(args.source, "rb") as handle:
            raw = handle.read()
        month = args.month or "local file"
    else:
        month = args.month or datetime.date.today().strftime("%Y-%m")
        url = URL.format(month=month)
        print(f"Downloading {url}", file=sys.stderr)
        request = urllib.request.Request(url, headers={"User-Agent": "SwiftlyBotKit country table builder"})
        with urllib.request.urlopen(request, timeout=60) as response:
            raw = response.read()
    text = gzip.decompress(raw).decode("ascii") if raw[:2] == b"\x1f\x8b" else raw.decode("ascii")
    rows = []
    for number, line in enumerate(text.splitlines(), start=1):
        if not line.strip():
            continue
        parts = line.strip().split(",")
        if len(parts) != 3:
            sys.exit(f"line {number}: expected start,end,country but got {line!r}")
        start, _end, code = parts
        if len(code) != 2 or not code.isascii() or not code.isalpha():
            sys.exit(f"line {number}: {code!r} is not a two-letter country code")
        rows.append((ipaddress.ip_address(start), code.upper()))
    return rows, month


def merged(entries):
    """Drops a start whose country equals the previous range's."""
    out = []
    for start, code in sorted(entries):
        if out and out[-1][1] == code:
            continue
        if out and out[-1][0] == start:
            out[-1] = (start, code)
            continue
        out.append((start, code))
    return out


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("output")
    parser.add_argument("--month", help="YYYY-MM of the DB-IP release (default: this month)")
    parser.add_argument("--from", dest="source", help="read this local .csv or .csv.gz instead of downloading")
    args = parser.parse_args()

    rows, month = read_rows(args)
    v4 = merged((int(address), code) for address, code in rows if address.version == 4)
    v6 = merged((int(address) >> 64, code) for address, code in rows if address.version == 6)
    if len(v4) < 100_000 or len(v6) < 100_000:
        sys.exit(f"only {len(v4)} IPv4 and {len(v6)} IPv6 ranges; refusing to write a table that small")

    attribution = f"IP to Country Lite by DB-IP (db-ip.com), {month}, CC BY 4.0".encode("utf-8")
    with open(args.output, "wb") as out:
        out.write(b"BKCC")
        out.write(struct.pack(">B", 1))
        out.write(struct.pack(">H", len(attribution)))
        out.write(attribution)
        out.write(struct.pack(">II", len(v4), len(v6)))
        out.write(b"".join(struct.pack(">I", start) for start, _ in v4))
        out.write("".join(code for _, code in v4).encode("ascii"))
        out.write(b"".join(struct.pack(">Q", start) for start, _ in v6))
        out.write("".join(code for _, code in v6).encode("ascii"))
    print(f"Wrote {len(v4)} IPv4 and {len(v6)} IPv6 ranges to {args.output}", file=sys.stderr)


if __name__ == "__main__":
    main()

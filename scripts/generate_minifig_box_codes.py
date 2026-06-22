#!/usr/bin/env python3
"""Generates BrickScan/Resources/MinifigBoxCodes.json.

LEGO prints a small Data Matrix code under the boxes of recent Collectible
Minifigures (CMF) series. There is no official Rebrickable/LEGO API for what
the code encodes, so the community (collector blogs, fan scanners) has
reverse-engineered it series by series: the decoded payload ends in a short
run of digits, and the *last two digits* select the figure from a table that
differs by packing region (the rest of the payload is reportedly a
factory/batch code that isn't needed for identification).

Each entry below is sourced from a community write-up for that series and
cross-referenced against Rebrickable's own per-figure set numbers (every CMF
character is catalogued as its own set, e.g. "71045-3" for the Series 25
Vampire Knight). Add a new SERIES entry per series as soon as someone
publishes its code table, then re-run this script:

    python3 scripts/generate_minifig_box_codes.py

Source for Series 25 (set 71045) region tables:
https://github.com/mrdiamonddirt/Lego-MiniFig-Decoder
"""

import json
import os

SERIES = {
    # LEGO Minifigures Series 25 (2024)
    "71045": {
        "name": "Series 25",
        # figure name -> (Europe suffix, North America suffix, Denmark suffix, Rebrickable set num)
        "figures": {
            "Fierce Barbarian":          (59, 60, 93, "71045-11"),
            "Fitness Instructor":        (60, 61, 94, "71045-7"),
            "Mushroom Sprite":           (61, 62, 95, "71045-6"),
            "Goatherd":                  (62, 63, 96, "71045-5"),
            "Harpy":                     (63, 64, 97, "71045-9"),
            "Train Kid":                 (64, 65, 98, "71045-10"),
            "Film Noir Detective":       (65, 66, 99, "71045-1"),
            "Sprinter":                  (66, 67, 100, "71045-4"),
            "Pet Groomer":               (67, 68, 101, "71045-12"),
            "Triceratops Costume Fan":   (68, 69, 102, "71045-8"),
            "E-Sports Gamer":            (69, 70, 103, "71045-2"),
            "Vampire Knight":            (70, 71, 104, "71045-3"),
        },
    },
}

REGIONS = ("EU", "NA", "DK")


def build_catalog():
    catalog = {}
    for set_prefix, series in SERIES.items():
        regions = {region: {} for region in REGIONS}
        for figure_name, (eu, na, dk, set_num) in series["figures"].items():
            for region, suffix in zip(REGIONS, (eu, na, dk)):
                regions[region][str(suffix)] = {"setNum": set_num, "name": figure_name}
        catalog[set_prefix] = {"name": series["name"], "regions": regions}
    return catalog


def main():
    catalog = build_catalog()
    repo_root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    out_path = os.path.join(repo_root, "BrickScan", "Resources", "MinifigBoxCodes.json")
    with open(out_path, "w") as f:
        json.dump(catalog, f, indent=2, sort_keys=True, ensure_ascii=False)
        f.write("\n")
    print(f"Wrote {out_path}")


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""
Fetch DICOM PS3.6 (Part 6) from:
  https://dicom.nema.org/medical/dicom/current/output/html/part06.html
Parse the big data element table, and generate a JSON file mapping tags to VR.

DEFAULT OUTPUT (compatible with your Swift loader):
  {
    "00080005": "CS",
    "00080016": "UI",
    ...
  }

OPTIONAL (--with-names):
  {
    "00080005": {"vr":"CS", "name":"Specific Character Set"},
    "00080016": {"vr":"UI", "name":"SOP Class UID"},
    ...
  }

USAGE
-----
python make_json_from_part6.py \
  --out dicom_vr_map.json \
  [--url https://dicom.nema.org/medical/dicom/current/output/html/part06.html] \
  [--expand-wildcards] [--even-groups-only] [--group-step 2] \
  [--exclude-retired] [--pretty] [--with-names]
"""

import argparse, re, sys, json
from typing import List, Tuple
try:
    import requests
    from bs4 import BeautifulSoup
except Exception:
    print("This script requires 'requests' and 'beautifulsoup4':")
    print("  pip install requests beautifulsoup4")
    raise

VR_SET = {
    "AE","AS","AT","CS","DA","DS","DT","FL","FD","IS","LO","LT","OB","OD","OF","OL","OV",
    "OW","PN","SH","SL","SQ","SS","ST","TM","UC","UI","UL","UN","UR","US","UT"
}

# Matches: "0008,0005", "(0008,0005)", "0008 0005", "0008-0005"
TAG_RE = re.compile(r'^\(?\s*([0-9A-Fa-fxX]{4})\s*[,;:\-\s]\s*([0-9A-Fa-fxX]{4})\s*\)?$')

def pick_vr(cell_text: str) -> str:
    """Choose the first known DICOM VR from a cell like 'US or SS' / 'OB or OW'."""
    txt = (cell_text or "").strip()
    parts = re.split(r'\bor\b|/|,|\||\s+', txt, flags=re.IGNORECASE)
    for p in parts:
        vr = p.strip().upper()
        if vr in VR_SET:
            return vr
    for vr in VR_SET:
        if re.search(r'\b'+re.escape(vr)+r'\b', txt):
            return vr
    return ""

def expand_wildcards(group_hex: str, elem_hex: str, even_groups_only: bool, group_step: int) -> List[Tuple[str,str]]:
    def expand_word(word: str, is_group: bool) -> List[str]:
        word = word.lower()
        if 'x' not in word:
            return [word.upper()]
        results = ['']
        for ch in word:
            if ch == 'x':
                results = [r + h for r in results for h in '0123456789abcdef']
            else:
                results = [r + ch for r in results]
        out: List[str] = []
        for r in results:
            if len(r) != 4:
                continue
            n = int(r, 16)
            if is_group:
                if even_groups_only and (n % 2) == 1:
                    continue
                if group_step > 1 and (n % group_step) != 0:
                    continue
            out.append(f"{n:04X}")
        return out
    groups = expand_word(group_hex, is_group=True)
    elems  = expand_word(elem_hex, is_group=False)
    return [(g, e) for g in groups for e in elems]

def parse_table(url: str, expand: bool, even_groups_only: bool, group_step: int, exclude_retired: bool):
    html = requests.get(url, timeout=60).text
    soup = BeautifulSoup(html, 'html.parser')
    tables = soup.find_all('table')
    entries: List[Tuple[str,str,str,str]] = []  # (group, element, vr, name)

    for tbl in tables:
        # Gather header row (th/td fallback)
        headers = [th.get_text(strip=True) for th in tbl.find_all('th')]
        if not headers:
            first_row = tbl.find('tr')
            if first_row:
                headers = [td.get_text(strip=True) for td in first_row.find_all(['th','td'])]
        header_lc = [h.lower() for h in headers]
        if not header_lc:
            continue
        if not (any('tag' in h for h in header_lc) and any('vr' in h for h in header_lc) and any('name' in h for h in header_lc)):
            continue

        # Column indices
        idx_tag = idx_vr = idx_name = None
        for i,h in enumerate(header_lc):
            if idx_tag is None and 'tag' in h: idx_tag = i
            if idx_vr  is None and 'vr'  in h: idx_vr  = i
            if idx_name is None and 'name' in h: idx_name = i
        if idx_tag is None or idx_vr is None or idx_name is None:
            continue

        # Iterate data rows
        rows = tbl.find_all('tr')
        for r in rows[1:]:
            cells = r.find_all(['td','th'])
            if len(cells) <= max(idx_tag, idx_vr, idx_name):
                continue
            tag_txt  = cells[idx_tag].get_text(" ", strip=True)
            vr_txt   = cells[idx_vr].get_text(" ", strip=True)
            name_txt = cells[idx_name].get_text(" ", strip=True)
            if exclude_retired and '(Retired' in name_txt:
                continue

            m = TAG_RE.match(tag_txt)
            if not m:
                continue
            g, e = m.group(1), m.group(2)
            vr = pick_vr(vr_txt)
            if not vr:
                continue

            if expand and (('x' in g.lower()) or ('x' in e.lower())):
                pairs = expand_wildcards(g, e, even_groups_only, group_step)
            else:
                pairs = [(g.upper(), e.upper())]

            for (gg, ee) in pairs:
                entries.append((gg, ee, vr, name_txt))

    # Deduplicate (last wins), sort
    seen = {}
    for (g,e,vr,name) in entries:
        key = (g, e)
        seen[key] = (vr, name)
    out = [ (k[0], k[1], v[0], v[1]) for k,v in sorted(seen.items(), key=lambda kv: (int(kv[0][0],16), int(kv[0][1],16))) ]
    return out

def write_json(entries, out_path, with_names: bool, pretty: bool):
    if with_names:
        mapping = { f"{g}{e}": {"vr": vr, "name": name} for (g,e,vr,name) in entries }
    else:
        mapping = { f"{g}{e}": vr for (g,e,vr,name) in entries }
    with open(out_path, 'w', encoding='utf-8') as f:
        if pretty:
            json.dump(mapping, f, indent=2, ensure_ascii=False)
            f.write('\n')
        else:
            json.dump(mapping, f, separators=(',',':'), ensure_ascii=False)

def main(argv=None):
    ap = argparse.ArgumentParser(description="Generate JSON DICOM VR map from PS3.6 Part 6")
    ap.add_argument('--url', default='https://dicom.nema.org/medical/dicom/current/output/html/part06.html', help='Part 6 HTML URL')
    ap.add_argument('--out', default='dicom_vr_map.json', help='Output JSON file')
    ap.add_argument('--expand-wildcards', action='store_true', help='Expand tags with x/X wildcards (e.g., 60xx,3000)')
    ap.add_argument('--even-groups-only', action='store_true', help='When expanding, keep only even groups')
    ap.add_argument('--group-step', type=int, default=1, help='Group step when expanding (use 2 for overlays)')
    ap.add_argument('--exclude-retired', action='store_true', help='Skip entries marked as retired')
    ap.add_argument('--pretty', action='store_true', help='Pretty-print JSON')
    ap.add_argument('--with-names', action='store_true', help='Include attribute names alongside VR')
    args = ap.parse_args(argv)

    entries = parse_table(args.url, args.expand_wildcards, args.even_groups_only, args.group_step, args.exclude_retired)
    write_json(entries, args.out, args.with_names, args.pretty)
    print(f"Wrote {len(entries)} entries to {args.out} (with_names={args.with_names})")

if __name__ == '__main__':
    main()

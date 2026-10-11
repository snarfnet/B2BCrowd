# -*- coding: utf-8 -*-
"""L.t("日本語", "English") の組を全部取り出す／中国語（簡体・繁体）を差し込む。

  python tools/loc_extract.py dump  > tools/loc_strings.json   # 未翻訳の組（ja, en）
  python tools/loc_extract.py apply tools/loc_zh.json          # L.t(ja, en) → L.t(ja, en, hans: .., hant: ..)

文字列の中の \\(式) はそのまま残す（中国語の文にも同じ \\(式) を書く）。apply は ja+en が一致する呼び出しだけ書き換える。
"""
import json, os, re, sys

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'B2BCrowd')


def parse_string(src, i):
    """src[i] == '"'。Swift の文字列リテラル（\\( ) の中の入れ子の文字列も含む）を読んで (中身, 終わりの次) を返す。"""
    assert src[i] == '"'
    j = i + 1
    while j < len(src):
        c = src[j]
        if c == '\\':
            if src[j + 1] == '(':
                # interpolation: balance parentheses, skipping nested strings
                depth = 1; k = j + 2
                while depth:
                    if src[k] == '"':
                        _, k = parse_string(src, k); continue
                    if src[k] == '(': depth += 1
                    elif src[k] == ')': depth -= 1
                    k += 1
                j = k; continue
            j += 2; continue
        if c == '"':
            return src[i + 1:j], j + 1
        j += 1
    raise ValueError('unterminated string')


def calls(src):
    """(start, end, ja, en, rest) for each L.t( "ja" , "en" [, ...] )"""
    for m in re.finditer(r'\bL\.t\(', src):
        i = m.end()
        while src[i].isspace(): i += 1
        if src[i] != '"': continue
        ja, i = parse_string(src, i)
        while src[i].isspace(): i += 1
        if src[i] != ',': continue
        i += 1
        while src[i].isspace(): i += 1
        if src[i] != '"': continue
        en, i = parse_string(src, i)
        while src[i].isspace(): i += 1
        yield m.start(), i, ja, en, src[i] == ')'


def files():
    for d, _, fs in os.walk(ROOT):
        for f in fs:
            if f.endswith('.swift'): yield os.path.join(d, f)


def dump():
    seen = {}
    for p in files():
        src = open(p, encoding='utf-8').read()
        for _, _, ja, en, closed in calls(src):
            if closed: seen[(ja, en)] = None
    out = [{'ja': ja, 'en': en, 'hans': '', 'hant': ''} for ja, en in seen]
    json.dump(out, sys.stdout, ensure_ascii=False, indent=1)


def apply(path):
    table = {(x['ja'], x['en']): x for x in json.load(open(path, encoding='utf-8'))}
    n = 0
    for p in files():
        src = open(p, encoding='utf-8').read()
        out, last = [], 0
        for start, end, ja, en, closed in list(calls(src)):
            x = table.get((ja, en))
            if not closed or not x or not x.get('hans'): continue
            out.append(src[last:end])
            out.append(f', hans: "{x["hans"]}", hant: "{x["hant"]}"')
            last = end; n += 1
        if out:
            out.append(src[last:])
            open(p, 'w', encoding='utf-8', newline='\n').write(''.join(out))
    print('rewritten', n)


if __name__ == '__main__':
    sys.stdout.reconfigure(encoding='utf-8')
    if sys.argv[1] == 'dump': dump()
    else: apply(sys.argv[2])

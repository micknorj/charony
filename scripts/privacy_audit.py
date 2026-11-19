#!/usr/bin/env python3
"""Source/optional Mach-O privacy checks. This is one release gate."""
import argparse
from pathlib import Path
import re
import subprocess

ROOT = Path(__file__).resolve().parents[1]
FORBIDDEN = re.compile(
    r'(?<![A-Za-z0-9])_?(?:wq_log\w*|NSLog|os_log\w*|NSAssert|NSCAssert|printf|fprintf|puts|'
    r'NSURLSession|NSURLConnection|NWListener|NWConnection|WKWebView|UIWebView|'
    r'CFHTTP\w*|CFStreamCreatePairWithSocket\w*|socket|connect|bind|listen|accept|'
    r'sendto|recvfrom|nw_connection\w*|nw_listener\w*|getaddrinfo|'
    r'NSUserDefaults|WQ_TOUCH_TRACE)\b'
)


def without_comments(source):
    # Preserve strings, including URLs, while discarding legal/comment text.
    tokens = re.compile(r'"(?:\\.|[^"\\])*"|\'(?:\\.|[^\'\\])*\'|//[^\n]*|/\*.*?\*/', re.S)
    return tokens.sub(lambda match: ' ' if match.group().startswith(('//', '/*')) else match.group(), source)


def production_files():
    return sorted([*ROOT.glob('*.m'), *ROOT.glob('*.h')])


def source_failures():
    failures = []
    for path in production_files():
        source = without_comments(path.read_text())
        for match in FORBIDDEN.finditer(source):
            failures.append(f'{path.name} contains {match.group()}')
        for match in re.finditer(r'(?:https?|wss?|ftp)://[^\s"<>]+', source):
            failures.append(f'{path.name} contains a runtime network URL')
    return failures


def binary_failures(binary):
    # Undefined/imported symbols and strings catch logging, listener APIs,
    # dynamic lookups and embedded update/telemetry URLs.
    outputs = [subprocess.check_output(['nm', '-u', str(binary)], text=True),
               subprocess.check_output(['strings', '-a', str(binary)], text=True)]
    failures = []
    for text in outputs:
        for match in FORBIDDEN.finditer(text.replace('_NSLog', 'NSLog')):
            failures.append(f'binary contains forbidden symbol/string {match.group()}')
    # Legal source attribution is permitted in comments and distributed LICENSE.
    for match in re.finditer(r'(?:https?|wss?|ftp)://[^\s"<>]+', outputs[1]):
        failures.append(f'binary contains network URL {match.group()}')
    return sorted(set(failures))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--binary', type=Path)
    args = parser.parse_args()
    failures = source_failures()
    if args.binary:
        failures.extend(binary_failures(args.binary))
    if failures:
        raise SystemExit('\n'.join(failures))
    print('Privacy source audit passed' + (' and binary audit passed' if args.binary else ''))


if __name__ == '__main__':
    main()

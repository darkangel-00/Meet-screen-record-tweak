#!/usr/bin/env python3
"""Patch top-level Info.plist in a user-provided IPA BEFORE re-signing.

Usage: python3 patch_ipa_info.py original.ipa Meet-unsigned-patched.ipa
Requires Python 3 stdlib only. This invalidates any existing code signature.
"""
import pathlib
import plistlib
import re
import shutil
import sys
import zipfile

if len(sys.argv) != 3:
    raise SystemExit('Usage: python3 patch_ipa_info.py input.ipa output.ipa')
source = pathlib.Path(sys.argv[1]).resolve()
dest = pathlib.Path(sys.argv[2]).resolve()
if source == dest:
    raise SystemExit('Choose a different output file; originals are preserved.')
if not source.exists():
    raise SystemExit(f'Missing input: {source}')

with zipfile.ZipFile(source, 'r') as zin:
    matches = [n for n in zin.namelist()
               if re.fullmatch(r'Payload/[^/]+\.app/Info\.plist', n)]
    if len(matches) != 1:
        raise SystemExit(f'Expected one top-level app Info.plist, found {matches}')
    target = matches[0]
    old = zin.read(target)
    info = plistlib.loads(old)
    info['NSPhotoLibraryAddUsageDescription'] = (
        'Save meeting recordings you start to your Photos library.')
    if not info.get('NSMicrophoneUsageDescription'):
        info['NSMicrophoneUsageDescription'] = (
            'Record microphone audio when you start a meeting recording.')
    new = plistlib.dumps(info, fmt=plistlib.FMT_BINARY, sort_keys=False)

    with zipfile.ZipFile(dest, 'w') as zout:
        zout.comment = zin.comment
        for item in zin.infolist():
            if item.filename == target:
                zout.writestr(item, new)
            elif item.is_dir():
                zout.writestr(item, b'')
            else:
                with zin.open(item, 'r') as reader, zout.open(item, 'w') as writer:
                    shutil.copyfileobj(reader, writer, length=1024 * 1024)
print(f'Updated {target} in {dest}')
print('Original signature is invalidated; inject tweak and sign the new IPA.')
print('If the signer changes CFBundleIdentifier, update MeetLocalRecorder.plist.')

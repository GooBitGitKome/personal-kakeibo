#!/usr/bin/env python3
"""Generate the development CloudKit configuration using real account identifiers."""
import argparse
import plistlib
import re
from pathlib import Path

parser = argparse.ArgumentParser()
parser.add_argument('--team', required=True)
parser.add_argument('--bundle', required=True)
parser.add_argument('--container', required=True)
args = parser.parse_args()
if not re.fullmatch(r'[A-Z0-9]{10}', args.team):
    parser.error('team must be the 10-character Apple Developer Team ID')
if not re.fullmatch(r'[A-Za-z0-9.-]+', args.bundle) or args.bundle.startswith('com.example.'):
    parser.error('supply your registered bundle identifier')
if not re.fullmatch(r'iCloud\.[A-Za-z0-9.-]+', args.container):
    parser.error('container must be a registered iCloud.* identifier')
root = Path(__file__).resolve().parent.parent
entitlements = {
    'com.apple.developer.icloud-container-identifiers': [args.container],
    'com.apple.developer.icloud-services': ['CloudKit'],
    'aps-environment': 'development',
    'com.apple.security.application-groups': [f'group.{args.bundle}.shared'],
}
(root / 'PersonalKakeibo/App/Cloud.entitlements').write_bytes(plistlib.dumps(entitlements))
text = (root / 'project.yml').read_text()
# Keep app and widget on the same App Group and CloudKit container.
# The Team ID goes to the untracked local xcconfig, never into a committed file.
(root / 'Config/Signing.local.xcconfig').write_text(f'DEVELOPMENT_TEAM = {args.team}\n')
text = re.sub(r'^    KAKEIBO_BUNDLE_ID:.*$', f'    KAKEIBO_BUNDLE_ID: {args.bundle}', text, flags=re.MULTILINE)
text = re.sub(r'^    KAKEIBO_APP_GROUP:.*$', f'    KAKEIBO_APP_GROUP: group.{args.bundle}.shared', text, flags=re.MULTILINE)
text = text.replace('PersonalKakeibo/App/App.entitlements', 'PersonalKakeibo/App/Cloud.entitlements')
text = text.replace('PersonalKakeiboWidget/Widget.entitlements', 'PersonalKakeiboWidget/Cloud.entitlements')
text = re.sub(r'^(\s*)KakeiboAppGroup:.*$',
    lambda match: match.group(0) + '\n' + match.group(1) + f'KakeiboCloudContainer: {args.container}',
    text, flags=re.MULTILINE)
text = text.replace('        INFOPLIST_KEY_UILaunchScreen_Generation: YES',
    '        INFOPLIST_KEY_UIBackgroundModes: [remote-notification]\n'
    '        INFOPLIST_KEY_UILaunchScreen_Generation: YES')
widget_entitlements = {key: value for key, value in entitlements.items() if key != 'aps-environment'}
(root / 'PersonalKakeiboWidget/Cloud.entitlements').write_bytes(plistlib.dumps(widget_entitlements))
(root / 'project-cloud.yml').write_text(text)
print('Generated project-cloud.yml. Run: xcodegen generate --spec project-cloud.yml')

#!/usr/bin/env python3
"""Prepare, validate, and publish Input Source Pro releases."""
import argparse
import datetime
import hashlib
import html
import json
import os
from pathlib import Path
import plistlib
import re
import subprocess
import xml.etree.ElementTree as ET

OFFSET = 1000
REPOSITORY = 'runjuu/InputSourcePro'
REPO_URL = f'https://github.com/{REPOSITORY}'
SPARKLE = 'http://www.andymatuschak.org/xml-namespaces/sparkle'
VERSION = re.compile(r'v?(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)\Z')


def run(*args):
    return subprocess.check_output(args, text=True).strip()


def git(*args):
    return run('git', *args)


def gh_json(*args):
    return json.loads(run('gh', *args))


def releases():
    pages = gh_json('api', '--paginate', '--slurp', f'repos/{REPOSITORY}/releases?per_page=100')
    return [release for page in pages for release in page]


def version_tuple(tag):
    match = VERSION.fullmatch(tag)
    return tuple(map(int, match.groups())) if match else None


def build_number(commit):
    if git('rev-parse', '--is-shallow-repository') != 'false':
        raise ValueError('Release builds require full Git history')
    return int(git('rev-list', '--count', commit)) + OFFSET


def release_build(release):
    builds = [int(match.group(1)) for asset in release['assets']
              if (match := re.fullmatch(r'Input-Source-Pro-(\d+)\.dmg', asset['name']))]
    return builds[0] if len(builds) == 1 else None


def render_markdown(markdown):
    return subprocess.check_output(
        ['gh', 'api', '--method', 'POST', 'markdown', '--input', '-'],
        input=json.dumps(dict(text=markdown, mode='gfm', context=REPOSITORY)), text=True)


def notes(channel, baseline, commit, version):
    if channel == 'beta':
        return (f'Follow development on [GitHub]({REPO_URL}).\n',
                f'<p>Follow development on <a href="{REPO_URL}">GitHub</a>.</p>')
    path = f'docs/release-notes/{version}.md'
    if git('ls-tree', '--name-only', commit, '--', path):
        markdown = subprocess.check_output(['git', 'show', f'{commit}:{path}'], text=True)
        if not markdown.strip():
            raise ValueError(f'Release notes must not be empty: {path}')
        return markdown, render_markdown(markdown)
    entries = git('log', '--reverse', '--no-merges', '--format=%H %s', f'{baseline}..{commit}').splitlines()
    markdown, items = [], []
    for entry in entries:
        sha, subject = entry.split(' ', 1)
        # HTML escaping also keeps raw HTML in commit messages inert in GitHub notes.
        escaped = re.sub(r'([\\`*_{}\[\]()#+.!|>~-])', r'\\\1', html.escape(subject))
        markdown.append(f'- {escaped} ([{sha[:7]}]({REPO_URL}/commit/{sha}))')
        items.append(f'<li>{html.escape(subject)} (<a href="{REPO_URL}/commit/{sha}">{sha[:7]}</a>)</li>')
    return '\n'.join(markdown) + '\n', '<ul>' + ''.join(items) + '</ul>'


def prepare(args):
    commit = git('rev-parse', f'{os.environ["GITHUB_SHA"]}^{{commit}}')
    ref = os.environ['GITHUB_REF']
    if ref == 'refs/heads/main':
        channel = 'beta'
        project = Path('Input Source Pro.xcodeproj/project.pbxproj').read_text()
        version = re.search(r'MARKETING_VERSION = ([0-9.]+);', project).group(1)
    elif ref.startswith('refs/tags/') and version_tuple(ref.removeprefix('refs/tags/')):
        channel = 'stable'
        version = ref.removeprefix('refs/tags/').removeprefix('v')
    else:
        raise ValueError('Only main pushes and numeric version tags may release')
    subprocess.run(['git', 'merge-base', '--is-ancestor', commit, 'origin/main'], check=True)
    build = build_number(commit)
    tag = f'beta-{build}' if channel == 'beta' else ref.removeprefix('refs/tags/')
    tag_exists = subprocess.run(['git', 'show-ref', '--verify', '--quiet', f'refs/tags/{tag}']).returncode == 0
    if tag_exists and git('rev-parse', f'{tag}^{{commit}}') != commit:
        raise ValueError('Release tag belongs to another commit; history may have been rewritten')
    existing_releases = releases()
    existing = next((r for r in existing_releases if r['tag_name'] == tag), None)
    complete = existing is not None and not existing['draft']
    if existing:
        tagged_commit = (existing['target_commitish'] if existing['draft'] and channel == 'beta'
                         else git('rev-parse', f'{tag}^{{commit}}'))
        if tagged_commit != commit:
            raise ValueError('Release tag belongs to another commit; history may have been rewritten')
        if complete and (release_build(existing) != build or
                         not any(a['name'] == 'appcast.xml' for a in existing['assets'])):
            raise ValueError('Published release exists but is incomplete; refusing to overwrite it')
    baseline = '2.12.0'
    if channel == 'stable' and not complete:
        previous = [r for r in existing_releases if not r['draft'] and not r['prerelease']
                    and version_tuple(r['tag_name']) and r['tag_name'] != tag]
        if previous:
            latest = max(previous, key=lambda r: version_tuple(r['tag_name']))
            baseline = latest['tag_name']
        if version_tuple(tag) <= version_tuple(baseline) or build <= build_number(baseline):
            raise ValueError('Stable release must advance the previous stable version and build')
        subprocess.run(['git', 'merge-base', '--is-ancestor', baseline, commit], check=True)
    metadata = dict(channel=channel, version=version, build=build, tag=tag, commit=commit,
                    asset=f'Input-Source-Pro-{build}.dmg', complete=complete)
    Path('dist').mkdir(exist_ok=True)
    Path('dist/release.json').write_text(json.dumps(metadata, indent=2) + '\n')
    if not complete:
        markdown, description = notes(channel, baseline, commit, version)
        Path('dist/notes.md').write_text(markdown)
        Path('dist/notes.html').write_text(description)
    with open(os.environ['GITHUB_OUTPUT'], 'a') as output:
        for key, value in metadata.items():
            output.write(f'{key}={str(value).lower() if isinstance(value, bool) else value}\n')


def check_bundle(args):
    metadata = json.loads(Path('dist/release.json').read_text())
    info = plistlib.loads(Path('dist/export/Input Source Pro.app/Contents/Info.plist').read_bytes())
    source = plistlib.loads(Path('Input Source Pro/Resources/Info.plist').read_bytes())
    expected = {'CFBundleVersion': str(metadata['build']),
                'CFBundleShortVersionString': metadata['version'],
                'ISPReleaseChannel': metadata['channel'], 'SUPublicEDKey': source['SUPublicEDKey']}
    for key, value in expected.items():
        if info.get(key) != value:
            raise ValueError(f'Exported app has an unexpected {key}')


def finish_appcast(args):
    metadata = json.loads(Path('dist/release.json').read_text())
    path = Path('dist/updates/appcast.xml')
    ET.register_namespace('sparkle', SPARKLE)
    tree = ET.parse(path)
    item = tree.find('./channel/item')
    if item is None or len(tree.findall('./channel/item')) != 1:
        raise ValueError('Expected exactly one generated update')
    if item.findtext(f'{{{SPARKLE}}}version') != str(metadata['build']):
        raise ValueError('Appcast build does not match release')
    if metadata['channel'] == 'beta':
        item.find('title').text = f'Beta ({metadata["build"]})'
        item.find(f'{{{SPARKLE}}}shortVersionString').text = 'Beta'
    enclosure = item.find('enclosure')
    dmg = Path('dist/updates') / metadata['asset']
    expected_url = f'https://inputsource.pro/releases/{metadata["tag"]}/{metadata["asset"]}'
    if enclosure.get('url') != expected_url or int(enclosure.get('length', '0')) != dmg.stat().st_size:
        raise ValueError('Appcast enclosure does not match the packaged DMG')
    signature = enclosure.get(f'{{{SPARKLE}}}edSignature')
    if not signature:
        raise ValueError('Appcast is missing the Sparkle signature')
    # Verify against the public key shipped to existing users, independently of the private key.
    info = plistlib.loads(Path('Input Source Pro/Resources/Info.plist').read_bytes())
    subprocess.run(['swift', 'scripts/verify-signature.swift', str(dmg),
                    info['SUPublicEDKey'], signature], check=True)
    item.find('pubDate').text = datetime.datetime.now(datetime.timezone.utc).strftime('%a, %d %b %Y %H:%M:%S GMT')
    tree.write(path, encoding='utf-8', xml_declaration=True)


def publish(args):
    metadata = json.loads(Path('dist/release.json').read_text())
    if metadata['complete']:
        return
    tag = metadata['tag']
    existing = next((r for r in releases() if r['tag_name'] == tag), None)
    if existing and not existing['draft']:
        raise ValueError('Release was published during this run; refusing to overwrite assets')
    if not existing:
        subprocess.run(['gh', 'release', 'create', tag, '--repo', REPOSITORY, '--draft',
                        '--target', metadata['commit'], '--title',
                        f'{"Beta" if metadata["channel"] == "beta" else metadata["version"]} ({metadata["build"]})',
                        '--notes-file', 'dist/notes.md',
                        *(['--prerelease'] if metadata['channel'] == 'beta' else [])], check=True)
    else:
        subprocess.run(['gh', 'release', 'edit', tag, '--repo', REPOSITORY,
                        '--notes-file', 'dist/notes.md'], check=True)
    paths = [Path('dist/updates') / metadata['asset'], Path('dist/updates/appcast.xml')]
    subprocess.run(['gh', 'release', 'upload', tag, '--repo', REPOSITORY,
                    '--clobber', *map(str, paths)], check=True)
    draft = next(r for r in releases() if r['tag_name'] == tag)
    uploaded = gh_json('api', f'repos/{REPOSITORY}/releases/{draft["id"]}')
    for path in paths:
        asset = next(a for a in uploaded['assets'] if a['name'] == path.name)
        digest = 'sha256:' + hashlib.sha256(path.read_bytes()).hexdigest()
        if asset['size'] != path.stat().st_size or asset.get('digest') != digest:
            raise ValueError(f'Uploaded asset failed verification: {path.name}')
    if metadata['channel'] == 'stable':
        for release in releases():
            if not release['draft'] and not release['prerelease'] and version_tuple(release['tag_name']):
                if version_tuple(release['tag_name']) >= version_tuple(tag):
                    raise ValueError('A newer stable release was published during this build')
    subprocess.run(['gh', 'release', 'edit', tag, '--repo', REPOSITORY, '--draft=false',
                    '--latest=true' if metadata['channel'] == 'stable' else '--latest=false'], check=True)


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('command', choices=['prepare', 'check-bundle', 'finish-appcast', 'publish'])
    arguments = parser.parse_args()
    {'prepare': prepare, 'check-bundle': check_bundle, 'finish-appcast': finish_appcast, 'publish': publish}[arguments.command](arguments)

#!/usr/bin/env python3
"""Publish a reviewed release through the official Factorio Mod Portal API."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import sys
import urllib.error
import urllib.parse
import urllib.request
import uuid

from build import ROOT, archive_bytes, release_files, version_tuple

PORTAL = 'https://mods.factorio.com'


class PublishError(Exception):
    pass


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        raise PublishError('API redirect refused')


def secure_url(url):
    if not isinstance(url, str) or any(character.isspace() or ord(character) < 32 for character in url):
        raise PublishError('Invalid URL characters')
    parsed = urllib.parse.urlsplit(url)
    if parsed.scheme != 'https' or not parsed.hostname or parsed.username or parsed.password or parsed.fragment:
        raise PublishError('API returned an unsafe upload URL')
    # Resolve malformed port syntax now, before a request can be sent.
    try:
        parsed.port
    except ValueError as error:
        raise PublishError('Invalid upload URL port') from error
    return url


class Client:
    def __init__(self):
        self.opener = urllib.request.build_opener(NoRedirect())

    def request(self, url, data=None, headers=None, missing_ok=False):
        secure_url(url)
        request = urllib.request.Request(url, data=data, headers=headers or {})
        try:
            with self.opener.open(request, timeout=120) as response:
                result = json.loads(response.read(2_000_000))
        except urllib.error.HTTPError as error:
            if missing_ok and error.code == 404:
                return None
            raise PublishError('Portal HTTP error ' + str(error.code)) from None
        except (urllib.error.URLError, TimeoutError, OSError, ValueError) as error:
            # Do not include exception text: it may contain a signed URL.
            raise PublishError('Portal request failed; check release state before retrying') from None
        if not isinstance(result, dict) or result.get('error'):
            raise PublishError('Portal returned an error or invalid response')
        return result


def multipart(fields, filename, data):
    boundary = 'factorio-' + uuid.uuid4().hex
    parts = []
    for key, value in fields.items():
        parts.append(('--' + boundary + '\r\nContent-Disposition: form-data; name="' + key + '"\r\n\r\n').encode() + value.encode() + b'\r\n')
    parts.append(('--' + boundary + '\r\nContent-Disposition: form-data; name="file"; filename="' + filename + '"\r\nContent-Type: application/zip\r\n\r\n').encode() + data + b'\r\n')
    parts.append(('--' + boundary + '--\r\n').encode())
    return b''.join(parts), 'multipart/form-data; boundary=' + boundary


def releases(client, name):
    result = client.request(PORTAL + '/api/mods/' + urllib.parse.quote(name, safe='') + '/full', missing_ok=True)
    if result is not None and (result.get('name') != name or not isinstance(result.get('releases'), list)):
        raise PublishError('Malformed existing mod metadata')
    return result


def matching_release(existing, version, digest):
    for release in existing.get('releases', []) if existing else []:
        if not isinstance(release, dict) or not isinstance(release.get('version'), str):
            raise PublishError('Malformed Portal release')
        if release['version'] == version:
            if release.get('sha1') == digest:
                return True
            raise PublishError('Version already exists with different archive contents')
    return False


def publish(mode, tag, archive, source_url, root=ROOT, client=None, api_key=None):
    if mode not in ('first', 'update'):
        raise PublishError('Explicit first or update mode is required')
    client = client or Client()
    metadata, _ = release_files(root, tag)
    if (root / 'LICENSE').read_text().startswith('License selection pending'):
        raise PublishError('Source publication rights and license must be confirmed before publishing')
    filename, data = archive_bytes(root, tag)
    if archive.name != filename or archive.read_bytes() != data:
        raise PublishError('Archive does not match the reviewed source package')
    secure_url(source_url)
    if not source_url.startswith('https://github.com/'):
        raise PublishError('Expected HTTPS GitHub source repository URL')
    digest = hashlib.sha1(data).hexdigest()
    name, version = metadata['name'], metadata['version']
    existing = releases(client, name)
    if matching_release(existing, version, digest):
        return 'Release already published with identical archive; skipped'
    if mode == 'first' and existing is not None:
        raise PublishError('Mod already exists; explicitly use update mode with an authorized account')
    if mode == 'update' and existing is None:
        raise PublishError('Mod does not exist; explicitly use first mode')
    if existing:
        for item in existing['releases']:
            if version_tuple(item['version']) >= version_tuple(version):
                raise PublishError('Release version must be newer than existing Portal releases')
    fields = {}
    if mode == 'first':
        # Explicit configuration is required; never infer ownership or licensing.
        license_id = (root / 'portal-license.txt').read_text().strip()
        if license_id not in {'default_mit', 'default_gnugplv3', 'default_gnulgplv3', 'default_mozilla2', 'default_apache2', 'default_unlicense'} and not (license_id.startswith('custom_') and license_id[7:].isdigit()):
            raise PublishError('Unsupported or unconfirmed Portal license configuration')
        description = (root / 'docs' / 'PORTAL.md').read_text().strip()
        if not description:
            raise PublishError('Portal description is empty')
        fields = {'description': description, 'category': 'utilities', 'license': license_id, 'source_url': source_url}
    key = api_key if api_key is not None else os.environ.get('FACTORIO_MOD_PORTAL_API_KEY', '')
    if not key or not key.strip() or '\n' in key or '\r' in key:
        raise PublishError('Missing valid FACTORIO_MOD_PORTAL_API_KEY environment secret')
    endpoint = '/api/v2/mods/init_publish' if mode == 'first' else '/api/v2/mods/releases/init_upload'
    initialized = client.request(PORTAL + endpoint,
                                 urllib.parse.urlencode({'mod': name}).encode(),
                                 {'Authorization': 'Bearer ' + key, 'Content-Type': 'application/x-www-form-urlencoded'})
    upload_url = initialized.get('upload_url')
    if not isinstance(upload_url, str):
        raise PublishError('Portal did not supply an upload URL')
    secure_url(upload_url)
    body, content_type = multipart(fields, filename, data)
    try:
        result = client.request(upload_url, body, {'Content-Type': content_type})
    except PublishError:
        # A response may be lost after the server commits the upload. Read back
        # once; never automatically repeat a potentially committed POST.
        try:
            if matching_release(releases(client, name), version, digest):
                return 'Published successfully (confirmed by archive hash after lost response)'
        except PublishError:
            pass
        raise PublishError('Upload outcome uncertain; inspect Portal version/hash before retrying') from None
    if result.get('success') is not True:
        raise PublishError('Portal did not confirm upload success')
    return 'Published ' + name + ' ' + version + ' successfully'


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--mode', choices=('first', 'update'), required=True)
    parser.add_argument('--tag', required=True)
    parser.add_argument('--archive', type=Path, required=True)
    parser.add_argument('--source-url', required=True)
    args = parser.parse_args()
    try:
        print(publish(args.mode, args.tag, args.archive, args.source_url))
    except (PublishError, ValueError, OSError, KeyError, TypeError) as error:
        print('Publish failed: ' + str(error), file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())

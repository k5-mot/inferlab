"""Nextcloud WebDAV responseの構造化parseを検証する。"""

from llm_wiki_platform.connectors.nextcloud import _parse_multistatus


def test_parse_multistatus_extracts_file_properties() -> None:
    """DAVとownCloud namespaceのpropertyが正しく抽出されることを検証する。"""
    xml = b"""<?xml version="1.0"?>
<d:multistatus xmlns:d="DAV:" xmlns:oc="http://owncloud.org/ns">
  <d:response>
    <d:href>/remote.php/dav/files/wiki/Engineering/design.pdf</d:href>
    <d:propstat>
      <d:prop>
        <d:getlastmodified>Wed, 19 Aug 2026 01:00:00 GMT</d:getlastmodified>
        <d:getcontenttype>application/pdf</d:getcontenttype>
        <d:getetag>\"abc\"</d:getetag>
        <d:resourcetype />
        <oc:fileid>42</oc:fileid>
      </d:prop>
    </d:propstat>
  </d:response>
</d:multistatus>
"""

    entries = _parse_multistatus(xml)

    assert entries == [
        {
            "href": "/remote.php/dav/files/wiki/Engineering/design.pdf",
            "is_collection": False,
            "last_modified": "Wed, 19 Aug 2026 01:00:00 GMT",
            "content_type": "application/pdf",
            "etag": '"abc"',
            "file_id": "42",
        }
    ]

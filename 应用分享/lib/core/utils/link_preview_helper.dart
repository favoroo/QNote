import 'dart:convert';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:http/http.dart' as http;

class LinkMetadata {
  final String url;
  final String title;
  final String? imageUrl;
  final String domain;

  LinkMetadata({
    required this.url,
    required this.title,
    this.imageUrl,
    required this.domain,
  });
}

class LinkPreviewHelper {
  static final Map<String, LinkMetadata> _cache = {};

  static Future<LinkMetadata?> getMetadata(String url) async {
    if (_cache.containsKey(url)) {
      return _cache[url];
    }

    LinkMetadata? fallback;
    try {
      final uri = Uri.parse(url);
      final domain = uri.host;
      fallback = LinkMetadata(
        url: url,
        title: url,
        domain: domain,
        imageUrl: null,
      );
    } catch (_) {
      // Ignored
    }

    try {
      final uri = Uri.parse(url);
      var targetUrl = url;
      if (kIsWeb) {
        // Use a reliable public CORS proxy on Web to bypass browser restrictions
        targetUrl = 'https://api.allorigins.win/raw?url=${Uri.encodeComponent(url)}';
      }
      final targetUri = Uri.parse(targetUrl);
      final response = await http.get(targetUri).timeout(const Duration(seconds: 4));
      
      final domain = uri.host;
      
      if (response.statusCode != 200) {
        return fallback;
      }

      String html;
      try {
        html = utf8.decode(response.bodyBytes);
      } catch (_) {
        html = latin1.decode(response.bodyBytes);
      }

      // Parse og:title
      String? title = _findMetaTag(html, 'og:title');
      if (title == null || title.isEmpty) {
        // Fallback to <title>
        final titleMatch = RegExp(r'<title[^>]*>(.*?)</title>', caseSensitive: false, dotAll: true).firstMatch(html);
        if (titleMatch != null) {
          title = titleMatch.group(1)?.trim();
        }
      }
      
      if (title == null || title.isEmpty) {
        title = domain;
      }

      // Decode HTML entities
      title = _decodeHtmlEntities(title);

      // Parse og:image
      String? imageUrl = _findMetaTag(html, 'og:image');
      if (imageUrl == null || imageUrl.isEmpty) {
        imageUrl = _findMetaTag(html, 'twitter:image');
      }

      // Resolve relative image URLs
      if (imageUrl != null && imageUrl.isNotEmpty && !imageUrl.startsWith('http')) {
        if (imageUrl.startsWith('//')) {
          imageUrl = '${uri.scheme}:$imageUrl';
        } else if (imageUrl.startsWith('/')) {
          imageUrl = '${uri.scheme}://${uri.host}$imageUrl';
        } else {
          String pathDir = uri.path;
          if (pathDir.contains('/')) {
            pathDir = pathDir.substring(0, pathDir.lastIndexOf('/') + 1);
          } else {
            pathDir = '/';
          }
          imageUrl = '${uri.scheme}://${uri.host}$pathDir$imageUrl';
        }
      }

      final metadata = LinkMetadata(
        url: url,
        title: title,
        imageUrl: imageUrl,
        domain: domain,
      );

      _cache[url] = metadata;
      return metadata;
    } catch (e) {
      // Return the fallback metadata so we still display a clean card instead of nothing
      if (fallback != null) {
        _cache[url] = fallback;
      }
      return fallback;
    }
  }

  static String? _findMetaTag(String html, String property) {
    final escapedProperty = RegExp.escape(property);
    final pattern1 = RegExp(
      '<meta[^>]+(?:property|name)\\s*=\\s*[\'"]$escapedProperty[\'"][^>]+content\\s*=\\s*[\'"]([^\'"]*)[\'"]',
      caseSensitive: false,
    );
    final pattern2 = RegExp(
      '<meta[^>]+content\\s*=\\s*[\'"]([^\'"]*)[\'"][^>]+(?:property|name)\\s*=\\s*[\'"]$escapedProperty[\'"]',
      caseSensitive: false,
    );

    var match = pattern1.firstMatch(html);
    if (match != null) return match.group(1);

    match = pattern2.firstMatch(html);
    if (match != null) return match.group(1);

    return null;
  }

  static String _decodeHtmlEntities(String text) {
    return text
        .replaceAll('&amp;', '&')
        .replaceAll('&quot;', '"')
        .replaceAll('&#39;', "'")
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&nbsp;', ' ')
        .replaceAll('&ndash;', '–')
        .replaceAll('&mdash;', '—');
  }
}

import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import 'commit_object.dart';

final _decoder = const Utf8Decoder().fuse(const JsonDecoder());

Object? _decodeBytes(Uint8List bytes) {
  return _decoder.convert(bytes);
}

class GitHubClient {
  static const _baseUrl = 'https://api.github.com';
  final String? token;
  final http.Client _client = http.Client();

  GitHubClient(this.token);

  Future<CommitObject> getCommit(String repo, String sha) async {
    final response = await _get('/repos/$repo/commits/$sha');
    return CommitObject.extract(_decodeBytes(response) as Map<String, dynamic>);
  }

  Stream<Map<String, dynamic>> getAllTags(String repo) async* {
    var page = 1;
    while (true) {
      final response = await _get('/repos/$repo/tags?per_page=100&page=$page');
      final list = _decodeBytes(response) as List<dynamic>;
      if (list.isEmpty) break;
      for (final tag in list) {
        yield tag as Map<String, dynamic>;
      }
      page++;
      // Safety break for very large repos if needed, but Flutter has ~100s of
      // tags, should be fine.
      // Actually Flutter has thousands. This might take a while.
      // 3000 tags / 100 = 30 requests. Acceptable.
    }
  }

  Future<bool> isAncestor(
    String repo,
    String ancestorSha,
    String descendantSha,
  ) async {
    // Use compare API
    // /repos/{owner}/{repo}/compare/{base}...{head}
    // base = ancestor, head = descendant
    final response = await _get(
      '/repos/$repo/compare/$ancestorSha...$descendantSha',
    );
    final data = _decodeBytes(response) as Map<String, dynamic>;

    // status can be: ahead, behind, identical, diverged
    // If ancestor is truly an ancestor of descendant, status should be 'ahead'
    // (descendant is ahead of ancestor)
    // or 'identical'.
    final status = data['status'] as String;
    return status == 'ahead' || status == 'identical';
  }

  Future<Uint8List> _get(String path) async {
    final uri = Uri.parse('$_baseUrl$path');
    final headers = <String, String>{
      'Accept': 'application/vnd.github.v3+json',
    };
    if (token != null) {
      headers['Authorization'] = 'token $token';
    }

    final response = await _client.get(uri, headers: headers);

    if (response.statusCode == 403 &&
        response.headers['x-ratelimit-remaining'] == '0') {
      throw Exception(
        'GitHub API Rate Limit Exceeded. Please provide a token.',
      );
    }

    if (response.statusCode >= 400) {
      throw GitHubHttpException(response.statusCode, response.body);
    }

    return response.bodyBytes;
  }

  void close() {
    _client.close();
  }
}

class GitHubHttpException implements Exception {
  GitHubHttpException(this.statusCode, this.body);
  final int statusCode;
  final String body;
  @override
  String toString() => 'HTTP $statusCode: $body';
}

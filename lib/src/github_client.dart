import 'dart:convert';

import 'package:http/http.dart' as http;

import 'commit_object.dart';

class GitHubClient {
  static const _baseUrl = 'https://api.github.com';
  final String? token;
  final http.Client _client = http.Client();

  GitHubClient(this.token);

  Future<CommitObject> getCommit(String repo, String sha) async {
    final response = await _get('/repos/$repo/commits/$sha');
    return CommitObject.extract(
      jsonDecode(response.body) as Map<String, dynamic>,
    );
  }

  Stream<Map<String, dynamic>> getAllTags(String repo) async* {
    var page = 1;
    while (true) {
      final response = await _get('/repos/$repo/tags?per_page=100&page=$page');
      final list = jsonDecode(response.body) as List<dynamic>;
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

  Future<List<CommitObject>> getCommits(
    String repo, {
    String? path,
    int page = 1,
  }) async {
    var url = '/repos/$repo/commits?page=$page&per_page=30';
    if (path != null) url += '&path=$path';
    final response = await _get(url);
    return (jsonDecode(response.body) as List<dynamic>)
        .map((e) => CommitObject.extract(e as Map<String, dynamic>))
        .toList();
  }

  Future<String> getFileContent(String repo, String path, String ref) async {
    // Use raw content API
    // https://raw.githubusercontent.com/:owner/:repo/:ref/:path
    // Or API: /repos/:owner/:repo/contents/:path?ref=:ref
    // API returns base64.
    // Raw is easier but might need different client handling?
    // Let's use API to stay consistent with token usage.
    final response = await _get('/repos/$repo/contents/$path?ref=$ref');
    final data = jsonDecode(response.body) as Map<String, dynamic>;
    final content = data['content'] as String;
    // content is base64 encoded, with newlines
    return utf8.decode(base64.decode(content.replaceAll('\n', '')));
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
    final data = jsonDecode(response.body) as Map<String, dynamic>;

    // status can be: ahead, behind, identical, diverged
    // If ancestor is truly an ancestor of descendant, status should be 'ahead'
    // (descendant is ahead of ancestor)
    // or 'identical'.
    final status = data['status'] as String;
    return status == 'ahead' || status == 'identical';
  }

  Future<http.Response> _get(String path) async {
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

    return response;
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

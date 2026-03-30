import 'dart:io';

import 'package:args/args.dart';
import 'package:flutter_tag_locator/src/exit_code.dart';
import 'package:github/github.dart';
import 'package:pub_semver/pub_semver.dart';

void main(List<String> arguments) async {
  final parser = ArgParser()
    ..addOption('sha', abbr: 's', help: 'The commit SHA to look for.')
    ..addOption('token', abbr: 't', help: 'GitHub API token (optional).');

  final argResults = parser.parse(arguments);
  final sha = argResults['sha'] as String?;
  final token =
      argResults['token'] as String? ??
      Platform.environment['GITHUB_TOKEN'] ??
      Platform.environment['HOMEBREW_GITHUB_API_TOKEN'];

  if (sha == null) {
    print('Error: --sha is required.');
    print(parser.usage);
    exitCode = ExitCode.usage;
    return;
  }

  final github = GitHub(
    auth: token != null
        ? Authentication.withToken(token)
        : const Authentication.anonymous(),
  );
  final slug = RepositorySlug('flutter', 'flutter');

  try {
    print('Analyzing ENGINE commit $sha');

    // 1. Determine if it's a Framework or Engine commit
    var frameworkCommitSha = sha;
    RepositoryCommit commit;
    try {
      commit = await github.repositories.getCommit(slug, sha);
    } catch (e) {
      print('Error: Could not find commit $sha in $slug');
      exitCode = ExitCode.tempFail;
      return;
    }
    final commitDate = commit.commit!.committer!.date!;
    print('\tFound ENGINE commit date: $commitDate');
    // Successfully found a framework commit

    // 2. Fetch all tags
    print('Fetching tags...');

    // 3. Filter and Sort tags
    final validTags = <Version, String>{};
    await for (var tag in github.repositories.listTags(slug)) {
      var name = tag.name;
      if (name.startsWith('v')) name = name.substring(1);
      try {
        final version = Version.parse(name);
        validTags[version] = tag.commit.sha!;
      } on FormatException {
        // Ignore invalid version tags
      }
    }

    final sortedVersions = validTags.keys.toList()..sort();
    print('Sorted ${sortedVersions.length} versions.');

    // Optimization: Since it's almost certainly a very recent commit,
    // we can search BACKWARDS from the newest tags. The first time we hit
    // tags that don't contain the commit (after finding ones that do),
    // we have found the oldest tag! This avoids both complex binary search
    // bounds and excessive forward-scanning API calls.

    print('Searching backwards from the newest tags...');

    Version? oldestTag;
    String? oldestTagSha;
    var consecutiveMisses = 0;
    final maxTagsToCheck = 50;
    final startIndex = sortedVersions.length - 1;

    for (var i = startIndex; i >= 0 && i >= startIndex - maxTagsToCheck; i--) {
      final version = sortedVersions[i];
      final tagSha = validTags[version]!;

      // Check if frameworkCommitSha is an ancestor of tagSha
      try {
        final comparison = await github.repositories.compareCommits(
          slug,
          frameworkCommitSha,
          tagSha,
        );
        final isAncestor =
            comparison.status == 'ahead' || comparison.status == 'identical';

        if (isAncestor) {
          oldestTag = version;
          oldestTagSha = tagSha;
          consecutiveMisses = 0; // reset
          stdout.write('T');
        } else {
          consecutiveMisses++;
          stdout.write('.');

          // Once we've found tags that contain the commit, and then hit
          // a string of tags that don't (tolerate a few for cherry-picks),
          // we've crossed the boundary and found our oldest tag.
          if (oldestTag != null && consecutiveMisses >= 4) {
            break;
          }
          // If we haven't found any tags that contain it after a while,
          // give up.
          if (oldestTag == null && consecutiveMisses >= 20) {
            break;
          }
        }
      } catch (e) {
        if (e.toString().contains('Rate Limit')) {
          print('\nRate limit hit. Try providing a GitHub token with --token.');
          exitCode = ExitCode.tempFail;
          return;
        }
        stdout.write('x');
      }
    }

    if (oldestTag != null) {
      print('\nFound oldest tag: $oldestTag');
      print('Tag Commit: $oldestTagSha');
      print(
        'Release URL: '
        'https://github.com/${slug.fullName}/releases/tag/${oldestTag.toString()}',
      );

      final dateStr = commitDate.toIso8601String().substring(0, 10);
      print('\n\n$sha, $oldestTag, $oldestTagSha, $dateStr');
      exitCode = 0;
      return;
    }

    print('\nNo tag found containing ENGINE commit $sha');
  } finally {
    github.dispose();
  }
}
